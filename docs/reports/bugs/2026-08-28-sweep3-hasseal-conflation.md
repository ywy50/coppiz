# Bug - `hasSeal` conflates "seal invalid" with "no seal": sealed-segment corruption silently truncates acknowledged data

## TL;DR

- **What failed:** `hasSeal` returns `false` for *any* failure - including a present seal trailer whose hash does not verify. The caller then treats the segment as unsealed and the 38-byte trailer becomes part of the scanned record region.
- **Impact:** A damaged final record (or damaged trailer) of a sealed segment silently truncates acknowledged, fsynced records - the exact case the mid-file corruption rule (G3) exists to refuse. Sealed records were acknowledged past `local`, so the module's own "torn tail = unacknowledged" invariant is violated.
- **Resolution:** Fixed in `773af4d`; refined by `13d5a39`. Originally validated statically.

## Status

Resolved.

## Symptom and impact

`hasSeal` (`store.zig:748-761`) returns false on any decode/hash failure; `loadJournal` (`:698-728`) then scans the trailer bytes as records. Two consequences:

- A corrupted **last record** of a sealed segment: the scan breaks at the bad record, `findValidRecordAfter` finds nothing after it (the trailer bytes never decode as a record), and the store truncates at the last good record - **silently dropping an acknowledged record**.
- A corrupted **trailer only** (hash field): the seal is silently discarded and the segment downgraded to unsealed - the seal is the unit [PRD 0006](../../prds/0006-scaling-to-groups-sharding-and-parity.md) parity works on.

The mid-file corruption case is refused (`error.Corrupt`, G3 - test at `store.zig:984`); the tail-of-sealed-segment case is not, because the discriminator (a seal trailer with valid magic but a bad hash) is discarded by `hasSeal`'s boolean.

## Reproduction

Not dynamically reproduced (bit-rot injection needed); statically certain from the `hasSeal` contract.

## Root cause

`hasSeal` collapses three states into one boolean: no trailer, valid trailer, and **present-but-invalid trailer**. The third is corruption and should refuse (`error.Corrupt`), exactly as mid-file damage does.

## Resolution

Fixed: a present-but-invalid seal trailer refuses the open with `Corrupt` (tri-state `sealStatus`), instead of being scanned as records and silently truncating the sealed prefix; regression test damages a sealed trailer.

## Verification

- Static: `hasSeal` and `loadJournal` read; the G3 refusal path (`store.zig:984`) read as the intended contract.

## Follow-up

Related storage-path defects reported separately: `truncate`'s errdefer double-close and the interrupted-compact window (2026-08-29).

## References

- Code: `src/journal/store.zig:748-761` (`hasSeal`), `:698-728` (`loadJournal`), `:984` (G3 test)
- Fix: `773af4d` - `store.zig` gained the tri-state `sealStatus` (`absent` /
  `valid` / `corrupt`), `loadJournal` refuses `error.Corrupt` on `.corrupt`,
  and the test "a sealed segment whose seal hash does not verify refuses to
  open" damages a sealed trailer.
- Refined by `13d5a39` (`2026-08-31-payload-tail-mimics-seal-trailer`): a
  trailer that does not verify is only damage if the records region excluding
  it decodes as a whole number of records, because an entry payload's last 38
  bytes are author-chosen and can spell a seal trailer.
- Re-checked 2026-08-31: the code and the test are both present. The
  "Still open" TL;DR line and the `Fix: none` reference above were left
  behind by `8893ae1`, which flipped 29 reports to `Resolved.` in a docs-only
  commit and did not update either line. The fix itself is real.
