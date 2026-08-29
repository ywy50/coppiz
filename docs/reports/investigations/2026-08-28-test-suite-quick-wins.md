# Investigation - making `zig build test` faster without dropping tests

## TL;DR

- **Question:** what is the fastest, safest way to cut `zig build test` wall
  clock, keeping every test?
- **Finding:** the biggest code-level win is compile work `zig build test`
  does that no test needs - it builds and installs the three example
  *executables* (`embed-single`, `embed-cluster`, `sidecar`) even though the
  process-level tests only ever spawn `zig-out/bin/coppiz`. The rest is
  mostly real wall-clock in the cluster/process e2e tests, which is inherent
  to what they verify.
- **Resolution:** implemented and measured - the test step now installs only
  the `coppiz` binary; the suite's remaining wall clock is e2e runtime, which
  the measured profile confirms is inherent to what the tests verify. One
  follow-up risk (an intermittent CPU spin) is [OQ 62](../../open-questions.md).

## Status

Resolved and implemented - the recommendation below landed with
measurements; the follow-up findings (runtime profile, e2e wait mechanics,
an intermittent CPU spin) are recorded in the Resolution section. The suite
was also red at `main` @ `51caeb0` when the implementation pass started; the
two compile failures and their fixes are the bug reports
[2026-08-28 - `zig build test` is red: `Hub.deinit(self, io)` called with no arguments at three test sites](../bugs/2026-08-28-build-test-red-hub-deinit-arity.md)
and
[2026-08-28 - `zig build test` is red: the CLI test root uses `std.c.getpid()` without linking libc](../bugs/2026-08-28-build-test-red-libc-getpid.md),
both now Resolved.

## Trigger and scope

`zig build test` was repeatedly slow enough to time out interactive sessions
(observed during the review-stack merges on 2026-08-28). This investigation
read `build.zig` and the test entry points to find where time goes and what a
faster wiring would look like, without removing or weakening any test.

## Evidence

All observations are from reading the tree on `main` @ `838fee9`, not from a
timed run.

1. `zig build test` runs **five** test binaries, each compiling the library
   module (`coppiz`) whole, plus the install step:

   - `lib_tests` (`src/root.zig`) - build.zig:173
   - `exe_tests` (`src/main.zig`) - build.zig:174
   - `build_tests` (`build.zig`) - build.zig:177
   - one test binary per example (`examples/embed-single|embed-cluster|sidecar`) - build.zig:188-192
   - `test_step.dependOn(b.getInstallStep())` - build.zig:194

2. **The install step builds three executables no test runs.** `build()` calls
   `b.installArtifact(example_exe)` for every example (build.zig:69-74), and
   `test_step` depends on the whole install step (build.zig:194). The only
   artifact the process-level tests spawn is `zig-out/bin/coppiz`
   (`src/main.zig:856,905`). The example executables exist for
   `zig build examples` (build.zig:73 runs them), not for the suite. So every
   `zig build test` recompiles the entire library up to three extra times as
   standalone executables that never execute.

3. Each example is therefore compiled **twice** by the test path: once as its
   test binary (needed, build.zig:190) and once as the installed executable
   (unneeded, build.zig:72). `zig-out/bin/{embed-single,embed-cluster,sidecar}`
   are never spawned by any test (grep for `embed-` in `src/` finds only
   comments).

4. The slow *runtime* portion is real time, not compile: the cluster e2e
   tests in `src/cluster/node.zig` and the process-level cluster tests in
   `src/main.zig` wait on wall-clock conditions with deadlines up to 20 s
   (e.g. node.zig:2682, 2739, 2923, 2987, 3139, 3414). Their timings are
   already minimal - heartbeat 50 ms, suspect 2000 ms (node.zig:2584-2590) -
   so there is little to shave without changing what the tests verify.

5. The three custom lint steps each re-read every checked file:
   `LineLengthStep`, `TestRegistrationStep` and `GateCoverageStep` all call
   `loadCheckedSources` (build.zig:840, 1040, and the coverage step's own
   make), i.e. the tree is read whole three times plus once by `zig fmt`. The
   files are small; this is expected to be minor next to (2).

## Hypotheses and tests

- **Hypothesis A - the install step is the biggest compile win.**
  *Read:* the test path builds `installArtifact(example_exe)` (build.zig:72)
  yet nothing spawns those binaries (`src/main.zig:856,905`).
  *Result:* supported by the wiring; the saving is proportional to the number
  of times the library compiles into executables per run.
  *Not quantified:* a timed run is needed to confirm it dominates.

- **Hypothesis B - the e2e wall-clock is irreducible without changing tests.**
  *Read:* all cluster/process e2e waits are condition loops with deadlines,
  and the timings are already near the floor.
  *Result:* supported. A speedup here means dropping or shrinking a test's
  timing assumption, which is out of scope for this audit.

- **Hypothesis C - the three lint steps duplicate file reads.**
  *Read:* `loadCheckedSources` called by three steps (build.zig:840, 1040,
  and GateCoverageStep.make).
  *Result:* true, but expected small - the files are a few tens of kB each.

## Finding

The actionable waste is in `build.zig`, not in the tests:

- `zig build test` compiles the library into three extra executables it never
  runs, because `test_step` rides the full install step and the examples are
  installed unconditionally.

Nothing else is a clear win without touching what the tests assert.

## Resolution or handoff

### Recommendation 1 - installed: the test step installs only the coppiz binary

`test_step` no longer depends on `b.getInstallStep()`; the examples are
installed by `zig build examples` (which now builds, installs *and* runs the
hosts), not by the default install step. `zig build` installs
`zig-out/bin/coppiz` alone; the suite needs exactly that (the process-level
tests spawn it - src/main.zig:856,905) plus the three example *test
binaries*. The `exe_tests` run also now depends on the coppiz install step
explicitly, closing the spawn-before-install race reported as
[2026-08-28 - the process-level e2e tests race the install step](../bugs/2026-08-28-process-tests-race-install.md).

Measured effect (warm cache, four consecutive full runs): 196–212 s total,
of which the compile steps are ~1–2 s - the saving is the three example
executable compiles (measured ~0.8–1.0 s each in the cold run's compile
lines) that `zig build test` no longer performs. The saving lands when the
library changes (the common interactive case), where each embedding binary
recompiles; the test path now compiles the library six times instead of
nine. Modest, but it is exactly the waste this audit identified, and it
removes the only part of the suite's work that no test consumes.

### The runtime profile (Hypothesis B, now measured)

The wall clock is e2e runtime, not compile: `lib_tests` runs 152 tests in
~3 min, `exe_tests` 12 tests in ~1 min (concurrent), everything else under
5 s. The cluster e2e waits are condition polls with deadline caps that exit
early (verified: e2e (b) ~5 s, e2e (c) ~5 s) plus fixed settle/expiry waits
of 1.5–2.5 s. Hypothesis B holds: the waits encode the failure-detector and
TTL semantics the tests exist to check.

### Busy-spin settle waits: initially rejected, then replaced (verified)

Ten test waits busy-spin the main thread for 0.15–2.5 s
(`while (wallMs(tio) < deadline) {}` - node.zig:2839, 3088, 3108, 3243,
3396, 3407, 3469, 3567, 3652, 3733 in the current tree) with a comment
claiming an `io.sleep` from the test task starves the node loops' timers.

*First pass (rejected):* the claim looked load-bearing - on Linux
`std.Io.Threaded` sets `use_parking_sleep = false`, so `io.sleep` becomes a
whole-thread `clock_nanosleep`, and a test task sharing a worker with a node
loop would block that loop for the sleep's full duration.

*Correction (verified on the follow-up pass):* the premise is wrong. Both
test-runner modes run `test_fn.func()` on the **main thread**
(`mainTerminal` and the server mode's `.run_test` handler call it directly),
never on an io worker. The node loops are io tasks on the io's worker
threads, which keep running while the main thread sleeps. Replacing the ten
spins with `std.Io.sleep(tio, duration, .awake)` is safe - the gate passed
twice back-to-back (23/23 steps, 244/244 tests) with all ten replaced. The
wall clock is unchanged (the waits are wall-clock by design - a 2 s spin and
a 2 s sleep both wait 2 s); the win is that the main thread stops pegging a
core for ~16 s per run, and on small-core hosts the loops no longer compete
with the spin for CPU during the e2e convergence polls.

### Finding for follow-up: intermittent CPU spin in direct test-binary runs

Running a test binary directly (not through `zig build test`'s protocol)
stuck three times on this machine at ~100% CPU for 10+ minutes in three io
worker threads: twice at `e2e (G4)` and once at the journal member-key test.
The gate (`zig build test`) did not reproduce it in three full runs, and
stacks could not be captured (ptrace blocked). The loop, mailbox and hub
transport are all semaphore-based (no busy-poll found by reading). Tracked
as [OQ 62](../../open-questions.md) - before it is resolved, a direct
`test`-binary run can peg a core indefinitely and a `zig build test` run
could hit it intermittently.

*Follow-up (verified on the follow-up pass):* two gdb-launched repro
attempts (gdb as the parent, which can ptrace its child where attaching is
blocked) ran the direct binary to completion without the spin - all 153
tests passed both times, once even under gdb's slowdown. The spin has not
reproduced in ~8 consecutive direct runs since the original 3/3
observation; it remains open with the same evidence (three observed
instances, no stack, no repro since).

### Follow-up findings: the G2 regression and the corrected timing

- PR #18 added the G2 process-level test, which spawns the *installed*
  sidecar binary; PR #19's rec-1 wiring (install only `coppiz` for the test
  step) predated it and did not re-check the spawn set, so the gate was red
  on `main` from PR #19's merge. Fixed by installing the sidecar beside
  coppiz - the suite's only two spawned binaries
  ([bug 2026-08-28 - PR #19's install-only-coppiz wiring broke the G2 sidecar test](../bugs/2026-08-28-g2-sidecar-needs-install.md)).
- The 196–212 s gate times recorded above were measured under concurrent
  build load. On an idle machine the gate is ~75 s: `lib_tests` 153 tests in
  30 s and `exe_tests` 13 tests in ~60 s run in parallel, everything else
  under 2 s. An initial profile attributed `exe_tests`' time to three slow
  tests (grows, different-genesis, reconfiguration) - that attribution was
  off by one (the gap-before-completion method) and the slowness was not
  cluster convergence at all.

### The real `exe_tests` cost: a 5 s zombie poll per serve kill

The process-level tests' cluster work is sub-second (verified by
replicating every phase by hand: joins, settings, reads and refusals all
complete in 0.1–0.3 s). The ~60 s of `exe_tests` was the test harness:
`ServingProc.stop` SIGKILLs a serve and then polls `kill(pid, 0)` up to
500 × 10 ms, but the killed child was never reaped, so it sat as a zombie
and the poll always burned the full 5 s - and every serve was stopped twice
(explicitly and via `defer`). Six stops in the "grows" test alone = 30 s of
polling. Fixed: `stop` now reaps the child (`wait`) when it still exists,
guarded so the double-stop's second wait is skipped (a second wait panics
the io - wait4 → ECHILD). `exe_tests`: 60 s → 4 s; the gate: ~75 s → ~31 s
([bug 2026-08-28 - `ServingProc.stop` burns 5 s per killed serve](../bugs/2026-08-28-servingproc-stop-zombie-poll.md)).

### The `lib_tests` cost: fixed settle sleeps → condition polls (gate ~31 s → ~20 s)

With the harness clean, `lib_tests` (31 s) was the critical path. A complete
per-test profile (the pass-1 profile was cut short by the OQ 62 spin) shows
the six in-process cluster e2e tests are ~27 s of it, and their cost is the
fixed wall-clock waits: ~7 s of semantic waits (suspect timeouts, TTL
expiries, the G4 checkpoint cadence - irreducible, rec 3) and ~10 s of
"settle" sleeps ("let the backfill finish", "let the broadcast land") whose
conditions are directly observable in-process:

- the backfill settles wait on `ClusterNode.syncing` (cleared only when the
  control + data sync reaches the head - the exact "backfill done" state),
- the broadcast settle in e2e (c) waits on B/C's control folds holding the
  new `leadership.mode` value.

Six fixed settles became condition polls with 10 s caps: strictly more
robust (a poll waits until the state really holds - a slow machine no longer
has to fit inside a fixed guess) and faster on fast machines. `lib_tests`:
31 s → 20 s; the gate: ~31 s → ~20.4 s (three consecutive green runs,
261/261 tests). The remaining fixed waits are semantic (G4's 800 ms cadence
and 150 ms burst spacing). The OQ 62 spin has not reproduced in ~20
consecutive direct runs since the pass-2 busy-spin removal - correlation
consistent with that change having removed the trigger, though the root
cause is still unknown.

### Recommendations 2 and 3

- Recommendation 2 (reduce example compile count) is subsumed by
  recommendation 1: the test path now compiles each example once (its test
  binary), never as an executable.
- Recommendation 3 stands as written: do not shrink the e2e timings. The
  measured profile confirms they are the suite's cost and that the waits
  exit early; a timing change would alter what the tests verify. The
  settle-wait conversions above do not violate it: they replace fixed
  guesses with waits on the actual observed state, which is a robustness
  improvement, not a timing change.

## References

- Related bugs:
  [2026-08-28 - `zig build test` is red: `Hub.deinit(self, io)` arity](../bugs/2026-08-28-build-test-red-hub-deinit-arity.md),
  [2026-08-28 - the CLI test root uses `std.c.getpid()` without linking libc](../bugs/2026-08-28-build-test-red-libc-getpid.md),
  [2026-08-28 - the process-level e2e tests race the install step](../bugs/2026-08-28-process-tests-race-install.md),
  [2026-08-28 - PR #19's install-only-coppiz wiring broke the G2 sidecar test](../bugs/2026-08-28-g2-sidecar-needs-install.md),
  [2026-08-28 - `ServingProc.stop` burns 5 s per killed serve](../bugs/2026-08-28-servingproc-stop-zombie-poll.md)
  (all Resolved by this work)
- Follow-up: [OQ 62](../../open-questions.md) - the intermittent CPU spin
- Code: `build.zig` (addChecks at build.zig:160-233; examples at
  build.zig:65-74; lint steps at build.zig:207-232)
- Tests that spawn the binary: `src/main.zig` (`BinTest.run`/`spawn`,
  src/main.zig:823-907)
- Cluster e2e waits: `src/cluster/node.zig` (tests at node.zig:2399-3553)
- Timed runs: `zig build test --summary all` on `main` @ `51caeb0` before and
  after the change (before: red, 230 tests; after: 21/21 steps, 242/242
  tests, 196–212 s)
