# Bug - `ServingProc.stop` burns 5 s per killed serve: the process-level tests spent ~60 s of the gate on zombie polls

## TL;DR

- **What failed:** `ServingProc.stop` (src/main.zig) SIGKILLs a spawned serve and
  then polls `kill(pid, 0)` up to 500 × 10 ms. The killed child was never
  reaped, so it sat as a zombie and `kill(pid, 0)` kept succeeding - every
  stop burned the full 5 s. The process-level tests also stopped every serve
  twice (explicitly and via `defer`), doubling the cost.
- **Impact:** `exe_tests` (13 tests) took ~60 s of the ~75 s gate, almost all
  of it zombie polling - the tests' real cluster work is under a second
  (verified by replicating the phases by hand: joins, settings and reads all
  complete in 0.1–0.3 s).
- **Resolution:** `stop` now reaps the child (`wait`) when it still exists,
  guarded so a second stop on an already-reaped child skips the wait (a
  second wait panics the io: wait4 → ECHILD → `errnoBug`). `exe_tests`:
  60 s → 4 s; the gate: ~75 s → ~31 s. All 244 tests still pass.

## Status

Resolved. Found and fixed during the third test-build speedup pass
(follow-up to the investigation
[2026-08-28 - making `zig build test` faster without dropping tests](../investigations/2026-08-28-test-suite-quick-wins.md)).

## Symptom and impact

`zig build test --summary all` on `main` @ `a7cd417`:

```
+- run test 13 pass (13 total) 1m        <- exe_tests
total ~75 s (idle machine)
```

The gate's critical path was `exe_tests` at ~60 s. Instrumenting
`waitStatus` and `stop` showed the waits are fast (1–2 polls, 7–287 ms) and
every `stop` took 5028–5032 ms - the full 500 × 10 ms poll. Six stops in
the "grows" test alone (3 serves × explicit + defer) = 30 s of polling.

## Reproduction

Any process-level test that stops a serve. The mechanism, independent of
the cluster code:

```zig
std.posix.kill(pid, SIG.KILL) catch {};   // child dies -> zombie (never reaped)
while (tries < 500) {                      // on a zombie, kill(pid, 0) SUCCEEDS
    std.posix.kill(pid, 0) catch break;    // ... so this never breaks early
    sleep(10 ms);
}
```

A killed-but-unreaped child remains in the process table as a zombie;
`kill(pid, 0)` (the existence probe) succeeds on a zombie, so the poll ran
its full 5 s. The serves were never waited (the tests' `runRaw` reaps its
one-shot children; the serves' `ServingProc` only killed).

## Root cause

`ServingProc.stop` used a kill-then-poll-for-ESRCH pattern without a
`wait`: the SIGKILL takes effect (the child dies), but ESRCH only appears
after the parent reaps the child. Nothing reaped the serves, so the poll
was always a full 5 s. The tests compounded it by stopping every serve
twice (explicit `stop` at the end - needed to release the directory lock
before `memberCountOf`/`Node.open` - plus the `defer` safety net for failed
tests).

## Resolution

`stop` reaps the child when it still exists:

```zig
std.posix.kill(pid, std.posix.SIG.KILL) catch {};
if (std.posix.kill(pid, @enumFromInt(0))) |_| {
    _ = child.wait(tio) catch {};   // reap: the poll below sees ESRCH at once
} else |_| {}                       // already reaped: a second wait would panic
```

The `kill(0)` guard handles the double-stop: the second stop finds the
child reaped (ESRCH), skips the wait, and the poll breaks on the first
try. The first stop's reap leaves no zombie window (the SIGKILL'd child is
either alive-dying or a zombie when the guard runs, and `wait` reaps both).

## Verification

`zig build test --summary all`: **23/23 steps, 244/244 tests, exit 0** -
two consecutive runs at ~31 s (was ~75 s). `exe_tests`: 13 tests in 4 s
(was ~60 s). No zombies remain after a run (`ps` shows no `coppiz
<defunct>`).

## Follow-up

- The tests still double-stop every serve (explicit + defer). With the reap
  in place the second stop is a no-op, so it is harmless; removing the
  redundancy is optional cleanup.
- `lib_tests` (31 s) is now the gate's critical path - the in-process
  cluster e2e, whose cost is the semantic settle/expiry waits, not the
  harness.

## References

- Investigation: [2026-08-28 - making `zig build test` faster without dropping tests](../investigations/2026-08-28-test-suite-quick-wins.md)
- Code: `src/main.zig` (`ServingProc.stop`, `BinTest`)
- Fix: worktree branch `perf/test-build-pass3` (this PR)
