# Bug - Duplicate top-level keys in `coppiz.toml` leak the previous value

## TL;DR

- **What failed:** `parseTopLevel` assigns each of `data_dir`, `member.key_file`, `listen`, `log.level` with a fresh `dupe` and no free of the prior value; TOML forbids duplicate keys and the parser neither rejects nor frees them.
- **Impact:** Startup-only leak (one allocation per duplicated key) on malformed config; the peers/genesis paths handle duplicates correctly, only the four top-level string keys leak.
- **Resolution:** Fixed in `773af4d` (2026-08-29). Statically validated; the fix is confirmed present in the tree by the 2026-08-31 audit below.

## Status

Resolved 2026-08-29 (audited 2026-08-31).

## Symptom and impact

`parseTopLevel` (`local.zig:180-195`) does `config.data_dir = try allocator.dupe(...)` etc. for the four string keys with no `free` of a previous value. `data_dir = "/a"\ndata_dir = "/b"\n` leaks the first allocation. `parsePeerKey` frees before re-assign (and the `""` placeholder free is a no-op), and genesis appends - only the top-level strings leak. The peer double-free report's follow-up already noted that the parser does not reject duplicate keys.

## Reproduction

Not dynamically reproduced (leak-only); statically certain.

## Root cause

Assign-without-free on keys that can legally appear once per file but are not rejected when repeated.

## Resolution

Fixed: duplicate top-level keys (`data_dir`, `member.key_file`, `listen`, `log.level`) are refused with a named `DuplicateKey` error instead of leaking the previous value.

## Correction - what the 2026-08-31 audit checked

`8893ae1` ("docs(reports): mark the sweep fixes resolved", 2026-08-29) flipped
this report's `## Status` to `Resolved` and rewrote its `## Resolution` in a
commit that touched 29 report files and no source. It left the `## TL;DR`
resolution bullet reading "Still open" and the `- Fix:` reference reading
"none", so the record contradicted itself and gave a reader no way to tell
whether the fix existed. Five other reports flipped by that commit were
audited on 2026-08-31 and found to have no fix in the tree at all.

This one does. Audited 2026-08-31 by reading the shipped code and the history
of the symbol the resolution credits. The fix landed in `773af4d`, whose
subject ("fix(wire): a read of an unknown journal refuses with a named error
(#90)") names only the last of the twelve fixes it carries. `8893ae1` has that
commit as an ancestor, so its status flip was right - only the two metadata
lines were left behind.

`parseTopLevel` now guards each of the four string keys with `if
(config.<field> != null) return error.DuplicateKey;` before the `dupe`, and
the test *duplicate top-level keys are refused, not leaked* covers it.

Only the `## TL;DR` resolution bullet, the `## Status` line and the `- Fix:`
reference were corrected; the symptom, reproduction, root cause and resolution
are unchanged.

## Verification

- Static: `parseTopLevel` (`local.zig:180-195`) read; the peer/genesis paths read as the non-leaking pattern.

## Follow-up

None. Low severity (startup-only, malformed input).

## References

- Code: `src/config/local.zig:180-195` (`parseTopLevel`)
- Fix: `773af4d` (PR #90)
