# Bug - PR #19's install-only-coppiz wiring broke the G2 sidecar test; `zig build test` was red on `main` again

## TL;DR

- **What failed:** after PR #19 (test-build quick wins) merged, `zig build test`
  failed the process-level G2 test: the test step installed only
  `zig-out/bin/coppiz`, but the G2 test (added in PR #18) spawns
  `zig-out/bin/sidecar`, which was no longer installed.
- **Impact:** the merge gate was red on `main` (verified: `1 failed`,
  `243/244 tests`).
- **Resolution:** the test step now installs the sidecar example beside the
  coppiz binary - the suite's only two spawned binaries
  (`src/main.zig:856,905,1364`).

## Status

Resolved. Fixed in the test-build speedup follow-up (the worktree branch that
also re-verified the quick wins); linked from the investigation
[2026-08-28 - making `zig build test` faster without dropping tests](../investigations/2026-08-28-test-suite-quick-wins.md).

## Symptom and impact

`zig build test --summary all` on `main` @ `1c0418e`:

```
Build Summary: 19/21 steps succeeded (1 failed); 243/244 tests passed (1 failed)
error: 'main.test.process-level: the sidecar binary pairs with a serving coppiz over TCP (G2)' failed
```

with `child stderr: error: FileNotFound` - the sidecar binary is missing when
the test spawns it. The gate was red from the moment PR #19 merged.

## Reproduction

```bash
git checkout 1c0418e && zig build test
```

The G2 test at `src/main.zig:1342` spawns `zig-out/bin/sidecar` (line 1364).
PR #19's rec-1 wiring made the test step install only `zig-out/bin/coppiz`
(`build.zig`, `addChecks`), so the spawn fails deterministically.

## Root cause

Two merges interacted: PR #18 added the G2 acceptance test, which by design
exercises the *installed* sidecar binary ("a real `coppiz serve` process and
the sidecar executable speaking to it over loopback TCP"). PR #19 then
narrowed the test step's install to the single binary the *existing* tests
spawned, without re-checking the suite for other spawn sites. The
investigation's original audit ("grep for `embed-` in `src/` finds only
comments") predated the G2 test.

## Resolution

The test step installs the two binaries the suite actually spawns:

```zig
const install_exe = b.addInstallArtifact(exe, .{});
const install_sidecar = b.addInstallArtifact(sidecar_exe, .{});
const exe_tests_run = b.addRunArtifact(exe_tests);
exe_tests_run.step.dependOn(&install_exe.step);
exe_tests_run.step.dependOn(&install_sidecar.step);
```

`sidecar_exe` is the same artifact `zig build examples` builds, installed
through its own step so the test path never touches the whole install step.
`embed-single`/`embed-cluster` remain off the test path (no test spawns
them). The rec-1 principle survives intact: install only what the suite
spawns - the spawn set is now two binaries, not one.

## Verification

`zig build test --summary all` in the worktree: `Build Summary: 23/23 steps
succeeded; 244/244 tests passed`, exit 0 - three consecutive runs (75.6 s,
75.8 s, 75.3 s on an idle machine). The G2 test passes and its append
(`via-wire`) reads back from the serving node.

## Follow-up

Prevention: the rec-1 audit criterion ("install only what the suite spawns")
must be re-checked against the suite's spawn sites whenever a process-level
test is added. The spawn inventory is `src/main.zig:856,905,1364`.

## References

- Investigation: [2026-08-28 - making `zig build test` faster without dropping tests](../investigations/2026-08-28-test-suite-quick-wins.md)
- Code: `build.zig` (`addChecks`, the examples wiring), `src/main.zig:1342-1410` (G2)
- Spawn sites: `src/main.zig:856,905` (coppiz), `src/main.zig:1364` (sidecar)
- Fix: worktree branch `perf/test-build-speedup` (this PR)
