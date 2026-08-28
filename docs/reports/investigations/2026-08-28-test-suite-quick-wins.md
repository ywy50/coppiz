# Investigation — making `zig build test` faster without dropping tests

## TL;DR

- **Question:** what is the fastest, safest way to cut `zig build test` wall
  clock, keeping every test?
- **Finding:** the biggest code-level win is compile work `zig build test`
  does that no test needs — it builds and installs the three example
  *executables* (`embed-single`, `embed-cluster`, `sidecar`) even though the
  process-level tests only ever spawn `zig-out/bin/coppiz`. The rest is
  mostly real wall-clock in the cluster/process e2e tests, which is inherent
  to what they verify.
- **Resolution:** implemented and measured — the test step now installs only
  the `coppiz` binary; the suite's remaining wall clock is e2e runtime, which
  the measured profile confirms is inherent to what the tests verify. One
  follow-up risk (an intermittent CPU spin) is [OQ 62](../../open-questions.md).

## Status

Resolved and implemented — the recommendation below landed with
measurements; the follow-up findings (runtime profile, e2e wait mechanics,
an intermittent CPU spin) are recorded in the Resolution section. The suite
was also red at `main` @ `51caeb0` when the implementation pass started; the
two compile failures and their fixes are the bug reports
[2026-08-28 — `zig build test` is red: `Hub.deinit(self, io)` called with no arguments at three test sites](../bugs/2026-08-28-build-test-red-hub-deinit-arity.md)
and
[2026-08-28 — `zig build test` is red: the CLI test root uses `std.c.getpid()` without linking libc](../bugs/2026-08-28-build-test-red-libc-getpid.md),
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

   - `lib_tests` (`src/root.zig`) — build.zig:173
   - `exe_tests` (`src/main.zig`) — build.zig:174
   - `build_tests` (`build.zig`) — build.zig:177
   - one test binary per example (`examples/embed-single|embed-cluster|sidecar`) — build.zig:188-192
   - `test_step.dependOn(b.getInstallStep())` — build.zig:194

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
   already minimal — heartbeat 50 ms, suspect 2000 ms (node.zig:2584-2590) —
   so there is little to shave without changing what the tests verify.

5. The three custom lint steps each re-read every checked file:
   `LineLengthStep`, `TestRegistrationStep` and `GateCoverageStep` all call
   `loadCheckedSources` (build.zig:840, 1040, and the coverage step's own
   make), i.e. the tree is read whole three times plus once by `zig fmt`. The
   files are small; this is expected to be minor next to (2).

## Hypotheses and tests

- **Hypothesis A — the install step is the biggest compile win.**
  *Read:* the test path builds `installArtifact(example_exe)` (build.zig:72)
  yet nothing spawns those binaries (`src/main.zig:856,905`).
  *Result:* supported by the wiring; the saving is proportional to the number
  of times the library compiles into executables per run.
  *Not quantified:* a timed run is needed to confirm it dominates.

- **Hypothesis B — the e2e wall-clock is irreducible without changing tests.**
  *Read:* all cluster/process e2e waits are condition loops with deadlines,
  and the timings are already near the floor.
  *Result:* supported. A speedup here means dropping or shrinking a test's
  timing assumption, which is out of scope for this audit.

- **Hypothesis C — the three lint steps duplicate file reads.**
  *Read:* `loadCheckedSources` called by three steps (build.zig:840, 1040,
  and GateCoverageStep.make).
  *Result:* true, but expected small — the files are a few tens of kB each.

## Finding

The actionable waste is in `build.zig`, not in the tests:

- `zig build test` compiles the library into three extra executables it never
  runs, because `test_step` rides the full install step and the examples are
  installed unconditionally.

Nothing else is a clear win without touching what the tests assert.

## Resolution or handoff

### Recommendation 1 — installed: the test step installs only the coppiz binary

`test_step` no longer depends on `b.getInstallStep()`; the examples are
installed by `zig build examples` (which now builds, installs *and* runs the
hosts), not by the default install step. `zig build` installs
`zig-out/bin/coppiz` alone; the suite needs exactly that (the process-level
tests spawn it — src/main.zig:856,905) plus the three example *test
binaries*. The `exe_tests` run also now depends on the coppiz install step
explicitly, closing the spawn-before-install race reported as
[2026-08-28 — the process-level e2e tests race the install step](../bugs/2026-08-28-process-tests-race-install.md).

Measured effect (warm cache, four consecutive full runs): 196–212 s total,
of which the compile steps are ~1–2 s — the saving is the three example
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

### Rejected: replacing the busy-spin settle waits with `io.sleep`

Six test waits busy-spin the main thread for 1.5–2.5 s
(`while (wallMs(tio) < deadline) {}` — node.zig:2703, 2952, 2972, 3107,
3333, 3431) with a comment claiming an `io.sleep` from the test task starves
the node loops' timers. The claim is load-bearing and correct on Linux:
`std.Io.Threaded` sets `use_parking_sleep = false` there, so `io.sleep`
becomes a whole-thread `clock_nanosleep`, and a test task sharing a worker
with a node loop would block that loop for the sleep's full duration. The
spins give the loops the CPU for the whole wait. Replacing them would make
the e2e tests' correctness depend on the host's core count / thread-pool
dynamics to save ~12 s (6%); not a good trade. Left as-is (including the
doubled comment at node.zig:2697-2700, which is a leftover, not a hazard).

### Finding for follow-up: intermittent CPU spin in direct test-binary runs

Running a test binary directly (not through `zig build test`'s protocol)
stuck three times on this machine at ~100% CPU for 10+ minutes in three io
worker threads: twice at `e2e (G4)` and once at the journal member-key test.
The gate (`zig build test`) did not reproduce it in three full runs, and
stacks could not be captured (ptrace blocked). The loop, mailbox and hub
transport are all semaphore-based (no busy-poll found by reading). Tracked
as [OQ 62](../../open-questions.md) — before it is resolved, a direct
`test`-binary run can peg a core indefinitely and a `zig build test` run
could hit it intermittently.

### Recommendations 2 and 3

- Recommendation 2 (reduce example compile count) is subsumed by
  recommendation 1: the test path now compiles each example once (its test
  binary), never as an executable.
- Recommendation 3 stands as written: do not shrink the e2e timings. The
  measured profile confirms they are the suite's cost and that the waits
  exit early; a timing change would alter what the tests verify.

## References

- Related bugs:
  [2026-08-28 — `zig build test` is red: `Hub.deinit(self, io)` arity](../bugs/2026-08-28-build-test-red-hub-deinit-arity.md),
  [2026-08-28 — the CLI test root uses `std.c.getpid()` without linking libc](../bugs/2026-08-28-build-test-red-libc-getpid.md),
  [2026-08-28 — the process-level e2e tests race the install step](../bugs/2026-08-28-process-tests-race-install.md)
  (all Resolved by this work)
- Follow-up: [OQ 62](../../open-questions.md) — the intermittent CPU spin
- Code: `build.zig` (addChecks at build.zig:160-233; examples at
  build.zig:65-74; lint steps at build.zig:207-232)
- Tests that spawn the binary: `src/main.zig` (`BinTest.run`/`spawn`,
  src/main.zig:823-907)
- Cluster e2e waits: `src/cluster/node.zig` (tests at node.zig:2399-3553)
- Timed runs: `zig build test --summary all` on `main` @ `51caeb0` before and
  after the change (before: red, 230 tests; after: 21/21 steps, 242/242
  tests, 196–212 s)
