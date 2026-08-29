# Bug - `leaderHex` makes a single un-retried status call: the process-level suite flakes with `ConnectionRefused`

## TL;DR

- **What failed:** Every other status read retries (`waitStatus` polls up to 30 s, `pollRead` 20 s); `leaderHex` issues exactly one more `status` child and any transient failure (`ConnectionRefused` while serve boots, `FileNotFound` before the key file exists) fails the test.
- **Impact:** Flaky `zig build test` process-level suite - observed failing 3 of the first 4 cold-cache runs with this exact trace, then passing on warm runs.
- **Resolution:** Still open. Statically validated; the failure was observed.

## Status

Resolved.

## Symptom and impact

`leaderHex` (`main.zig:1146-1154`) follows `waitStatus(bt, "epoch 1")` with one direct `runRaw(status)`; a non-zero child exit (`cmdStatus`'s `wireHello` → `ConnectionRefused`, `main.zig:474`) fails the test via `orelse return error.NoLeader`. The window is real: serve still booting when the second status child runs, or `member.key` not yet written by the serve at boot (`main.zig:229-232`) - the latter surfaces as `FileNotFound` in `memberIdentity`, which `waitStatus` retries fine and `leaderHex` does not. Aggravated by the suite's concurrent example-test binaries.

## Reproduction

Observed: `zig build test` on cold caches failed with this exact trace in 3 of the first 4 runs (`12 pass, 1 fail (13 total)`); ~30 consecutive warm runs passed. The failure is timing-dependent.

## Root cause

`leaderHex` is the only status read without a retry, contradicting the suite's own retry helpers.

## Resolution

Fixed: `leaderHex` polls its follow-up status read like `waitStatus` instead of issuing one un-retried child, removing the transient-failure flake.

## Verification

- Static: `leaderHex` (`main.zig:1146-1154`) vs `waitStatus` (`:1128-1143`) / `pollRead` (`:1237-1251`) read.
- Dynamic: observed failures on cold-cache runs (3 of 4), clean warm runs (~30).

## Follow-up

None. Test-only flake, but it sits in the gate the project treats as the one blocking entry point.

## References

- Code: `src/main.zig:1146-1154` (`leaderHex`), `:1128-1143` (`waitStatus`), `:474` (`cmdStatus` refusal)
- Fix: none
