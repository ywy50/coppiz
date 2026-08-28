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
- **Resolution:** recommend, not implemented here — each change below is
  small, local to `build.zig`, and safe to land with a full `zig build test`
  run as its gate. Marked *unverified* where only a timed run can quantify
  the saving.

## Status

Resolved — the suite was not benchmarked; the report stands as the audit and
its ordered recommendations.

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

Ordered by expected impact over risk:

1. **Install only what the suite spawns.** Give the examples an install only
   for `zig build examples`, and make `test_step` depend on installing the
   `coppiz` binary alone instead of `b.getInstallStep()` (build.zig:194). The
   suite needs `zig-out/bin/coppiz` (src/main.zig:856,905) and the three
   example *test binaries* (build.zig:188-192); it never needs the installed
   example executables. This removes up to three full library compiles per
   run. Smallest change: a dedicated install step for `exe` that the test
   step depends on, leaving the examples' install to the `examples` step.
   *Unverified:* quantify with a timed `zig build test` before and after.

2. **If the saving is still not enough, look at example compile count** — the
   examples are each compiled as a test binary *and* an executable by the
   test path (build.zig:72 vs 190). Any reduction must keep the example test
   binaries running.

3. **Do not shrink the e2e timings** to buy seconds: they encode the
   failure-detector semantics the tests exist to check, and the deadlines are
   caps, not sleeps.

## References

- Code: `build.zig` (addChecks at build.zig:160-233; examples at
  build.zig:65-74; lint steps at build.zig:207-232)
- Tests that spawn the binary: `src/main.zig` (`BinTest.run`/`spawn`,
  src/main.zig:823-907)
- Cluster e2e waits: `src/cluster/node.zig` (tests at node.zig:2399-3553)
