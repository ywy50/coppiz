# Bug - `leaderHex` makes a single un-retried status call: the process-level suite flakes with `ConnectionRefused`

## TL;DR

- **What failed:** Every other status read retries (`waitStatus` polls up to 30 s, `pollRead` 20 s); `leaderHex` issues exactly one more `status` child and any transient failure (`ConnectionRefused` while serve boots, `FileNotFound` before the key file exists) fails the test.
- **Impact:** Flaky `zig build test` process-level suite - observed failing 3 of the first 4 cold-cache runs with this exact trace, then passing on warm runs.
- **Resolution:** Fixed in `2761a64` (2026-08-29). Statically validated and the failure was observed before the fix; the poll is confirmed present in the tree by the 2026-08-31 audit below.

## Status

Resolved 2026-08-29 (audited 2026-08-31).

## Symptom and impact

`leaderHex` (`main.zig:1146-1154`) follows `waitStatus(bt, "epoch 1")` with one direct `runRaw(status)`; a non-zero child exit (`cmdStatus`'s `wireHello` → `ConnectionRefused`, `main.zig:474`) fails the test via `orelse return error.NoLeader`. The window is real: serve still booting when the second status child runs, or `member.key` not yet written by the serve at boot (`main.zig:229-232`) - the latter surfaces as `FileNotFound` in `memberIdentity`, which `waitStatus` retries fine and `leaderHex` does not. Aggravated by the suite's concurrent example-test binaries.

## Reproduction

Observed: `zig build test` on cold caches failed with this exact trace in 3 of the first 4 runs (`12 pass, 1 fail (13 total)`); ~30 consecutive warm runs passed. The failure is timing-dependent.

## Root cause

`leaderHex` is the only status read without a retry, contradicting the suite's own retry helpers.

## Resolution

Fixed: `leaderHex` polls its follow-up status read like `waitStatus` instead of issuing one un-retried child, removing the transient-failure flake.

## Correction - what the 2026-08-31 audit checked

`8893ae1` ("docs(reports): mark the sweep fixes resolved", 2026-08-29) flipped
this report's `## Status` to `Resolved` and rewrote its `## Resolution` in a
commit that touched 29 report files and no source. It left the `## TL;DR`
resolution bullet reading "Still open" and the `- Fix:` reference reading
"none", so the record contradicted itself and gave a reader no way to tell
whether the fix existed. Five other reports flipped by that commit were
audited on 2026-08-31 and found to have no fix in the tree at all.

This one does. Audited 2026-08-31 by reading the shipped code and the history
of the symbol the resolution credits. The fix landed in `2761a64`, whose
subject ("fix(cli): coppiz admit refuses cleanly on a chainless directory
(#92)") likewise names only one of its fixes. `8893ae1` has that commit as an
ancestor, so its status flip was right - only the two metadata lines were left
behind.

`leaderHex` now polls its follow-up status read against a 10 s deadline,
retrying both on a failed spawn and on a non-zero child exit, the way
`waitStatus` does. Being a test-only flake it carries no regression test,
which is why a history search rather than a test result is the evidence here.

Only the `## TL;DR` resolution bullet, the `## Status` line and the `- Fix:`
reference were corrected; the symptom, reproduction, root cause and resolution
are unchanged.

## Verification

- Static: `leaderHex` (`main.zig:1146-1154`) vs `waitStatus` (`:1128-1143`) / `pollRead` (`:1237-1251`) read.
- Dynamic: observed failures on cold-cache runs (3 of 4), clean warm runs (~30).

## Follow-up

None. Test-only flake, but it sits in the gate the project treats as the one blocking entry point.

## References

- Code: `src/main.zig:1146-1154` (`leaderHex`), `:1128-1143` (`waitStatus`), `:474` (`cmdStatus` refusal)
- Fix: `2761a64` (PR #92)
