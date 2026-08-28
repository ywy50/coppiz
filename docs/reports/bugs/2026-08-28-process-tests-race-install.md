# Bug — The process-level e2e tests race the install step: they spawn `zig-out/bin/coppiz` before it may exist

## TL;DR

- **What failed:** The process-level tests in `src/main.zig` spawn the installed binary by relative path (`"zig-out/bin/coppiz"`), but `build.zig` wires the install step as a *sibling* of the run steps under `test`, not a dependency of them. The test binary can start before the exe is compiled and copied.
- **Impact:** Spurious `zig build test` failures on fast machines/CI — the binary isn't found when the test spawns it. Latent today only because the suite is already red on the two compile errors.
- **Resolution:** Still open. Statically validated (dependency-graph structure).

## Status

Resolved — the `exe_tests` run step now depends on the coppiz install step
(`build.zig`, `addChecks`), wired during the test-build speedup work
(investigation
[2026-08-28 — making `zig build test` faster without dropping tests](../investigations/2026-08-28-test-suite-quick-wins.md)).

## Symptom and impact

`src/main.zig:856, 905` spawn `"zig-out/bin/coppiz"` (relative to the build root). `build.zig:183-194`:

```zig
test_step.dependOn(&b.addRunArtifact(exe_tests).step);   // :183 — runs the test binary
...
test_step.dependOn(b.getInstallStep());                  // :194 — installs the exe + examples
```

Both are siblings under `test`. The build runner executes dependencies concurrently (the observed `zig build test` run already shows several test binaries executing in parallel), and `dependOn` between siblings imposes no ordering. The test binary and the exe compile the same module graph from the same start time, so whichever finishes first is scheduling luck; if the test binary wins, `spawn` finds no `zig-out/bin/coppiz` and the test fails spuriously.

## Reproduction

Not deterministically reproduced (the suite can't currently reach it — the two compile errors block it; after those are fixed, the race appears probabilistically depending on compile scheduling). Statically certain from the dependency graph.

## Root cause

The run step needs the install step to complete first, but they are siblings. The install step's make only starts after the exe *and* the three example artifacts compile (`build.zig:36, 72`), so the window is real.

## Resolution

Fixed as suggested. `addChecks` now wires an explicit ordering instead of
siblings:

```zig
const install_exe = b.addInstallArtifact(exe, .{});
const exe_tests_run = b.addRunArtifact(exe_tests);
exe_tests_run.step.dependOn(&install_exe.step);
test_step.dependOn(&exe_tests_run.step);
```

The run cannot start before the install step (compile + copy to
`zig-out/bin/coppiz`) completes. The install is scoped to the coppiz binary
alone — the suite never spawns the example executables, so they stay off the
test path (the same change that removed the wasted example compiles).

## Verification

`zig build test --summary all`: green (21/21 steps, 242/242 tests, exit 0,
three consecutive runs). The race was never deterministically reproducible
(previously blocked by the two compile errors), so verification is
dependency-graph structure plus the green gate; repeated runs would be the
regression check.

## Follow-up

Related test-suite defect: the hardcoded port `17431` (reported separately). Both are in the same process-level suite.

## References

- Code: `build.zig:181-194`, `src/main.zig:856, 905`
- Fix: working tree (see the investigation 2026-08-28 test-build speedup; not yet committed)
