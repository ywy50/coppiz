# Bug — The process-level e2e tests race the install step: they spawn `zig-out/bin/coppiz` before it may exist

## TL;DR

- **What failed:** The process-level tests in `src/main.zig` spawn the installed binary by relative path (`"zig-out/bin/coppiz"`), but `build.zig` wires the install step as a *sibling* of the run steps under `test`, not a dependency of them. The test binary can start before the exe is compiled and copied.
- **Impact:** Spurious `zig build test` failures on fast machines/CI — the binary isn't found when the test spawns it. Latent today only because the suite is already red on the two compile errors.
- **Resolution:** Still open. Statically validated (dependency-graph structure).

## Status

Open.

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

Not yet fixed. Suggested direction: make the install step a dependency of the run step (e.g. `exe_tests_run.step.dependOn(b.getInstallStep())`, or have `addChecks` wire the install before the run steps). A regression check is the `zig build test` gate itself, run repeatedly.

## Verification

- Static: dependency-graph structure verified in `build.zig:181-194`; the spawn paths at `main.zig:856, 905` verified.

## Follow-up

Related test-suite defect: the hardcoded port `17431` (reported separately). Both are in the same process-level suite.

## References

- Code: `build.zig:181-194`, `src/main.zig:856, 905`
- Fix: none
