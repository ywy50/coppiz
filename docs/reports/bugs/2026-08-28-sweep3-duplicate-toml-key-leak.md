# Bug — Duplicate top-level keys in `coppiz.toml` leak the previous value

## TL;DR

- **What failed:** `parseTopLevel` assigns each of `data_dir`, `member.key_file`, `listen`, `log.level` with a fresh `dupe` and no free of the prior value; TOML forbids duplicate keys and the parser neither rejects nor frees them.
- **Impact:** Startup-only leak (one allocation per duplicated key) on malformed config; the peers/genesis paths handle duplicates correctly, only the four top-level string keys leak.
- **Resolution:** Still open. Statically validated.

## Status

Open.

## Symptom and impact

`parseTopLevel` (`local.zig:180-195`) does `config.data_dir = try allocator.dupe(...)` etc. for the four string keys with no `free` of a previous value. `data_dir = "/a"\ndata_dir = "/b"\n` leaks the first allocation. `parsePeerKey` frees before re-assign (and the `""` placeholder free is a no-op), and genesis appends — only the top-level strings leak. The peer double-free report's follow-up already noted that the parser does not reject duplicate keys.

## Reproduction

Not dynamically reproduced (leak-only); statically certain.

## Root cause

Assign-without-free on keys that can legally appear once per file but are not rejected when repeated.

## Resolution

Not yet fixed. Suggested fix: reject duplicate keys with a named error (matching the parser's strictness) or free the prior value on re-assign. A regression test should parse a duplicated top-level key under `std.testing.allocator` and assert no leak.

## Verification

- Static: `parseTopLevel` (`local.zig:180-195`) read; the peer/genesis paths read as the non-leaking pattern.

## Follow-up

None. Low severity (startup-only, malformed input).

## References

- Code: `src/config/local.zig:180-195` (`parseTopLevel`)
- Fix: none
