# Bug — `zig build test` is red: the CLI test root uses `std.c.getpid()` without linking libc

## TL;DR

- **What failed:** `zig build test` fails to compile the `src/main.zig` test root on a fresh checkout of `main`.
- **Impact:** The one blocking CI entry point (`zig build test`, per the build script's own comment) is red for everyone.
- **Resolution:** Still open.

## Status

Open. Introduced by `db0024bb` ("chore(test): apply review findings", merged via the ad67 test-review stack).

## Symptom and impact

`zig build test` exits 1 on a clean `main` (verified on a fresh worktree at `467dbff`). The failing step is the compile of the `src/main.zig` test root:

```
/usr/lib/zig/std/c.zig:11013:12: error: dependency on libc must be explicitly specified in the build command
pub extern "c" fn getpid() pid_t;
referenced by:
    testAddr: src/main.zig:1046:45
    test.process-level: a live cluster grows 1 → 2 → 3 members over TCP, founder stays leader: src/main.zig:1146:32
error: 1 compilation errors
failed command: /usr/bin/zig test -ODebug --dep coppiz -Mroot=.../src/main.zig ...
```

`zig build` (the binaries) and `zig build lint` both pass; only the `test` gate is affected. The three example tests (`embed-single`, `sidecar`, `embed-cluster`) are transitively skipped by the same failure — they pass when their binaries are run directly.

## Reproduction

```bash
git checkout main && git pull && zig build test
```

Expected: the gate runs the unit tests and lint gates and exits 0. Actual: compile error above, exit 1.

## Root cause

`src/main.zig:1046` — the process-level test helper introduced by `db0024bb`:

```zig
const pid: u32 = @intCast(@as(i64, std.c.getpid()));
```

`std.c` is the libc namespace; calling it requires the test binary to link libc. The project is standard-library-only ([ADR 0001](docs/adrs/0001-zig-0-16-standard-library-only-for-the-core.md)) and no libc is linked anywhere in `build.zig` (verified: no `linkLibC` call in the script). The binary itself never references `testAddr`, so the exe compiles; only the test root — where `testAddr` is analyzed — hits the error. `std.posix.getpid()` would work without libc (it uses the raw syscall path), which is the likely fix; not applied here.

## Resolution

Not yet fixed. Suggested fix: replace `std.c.getpid()` with `std.posix.getpid()` in `src/main.zig:1046` (keeps the test root libc-free), then re-run `zig build test`.

## Verification

Confirmed by reproduction on a clean worktree (`git worktree add ... main`, then `zig build test`). The exact compiler error is quoted above. After the fix, re-running `zig build test` must compile the `src/main.zig` test root and run the process-level cluster tests.

## Follow-up

The same test file's process-level tests hardcode an additional port (`127.0.0.1:17431`) that the pid-derived design (`testAddr`) is meant to make impossible — reported separately. Note also that this commit landed through a review stack that evidently never ran `zig build test`; the gate's test-registration machinery does not catch libc usage.

## References

- Code: `src/main.zig:1046` (`testAddr`), regression commit `db0024bb`
- Fix: none
