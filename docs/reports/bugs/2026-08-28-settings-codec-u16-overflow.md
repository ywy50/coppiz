# Bug - Settings codec truncates u16 length fields: a value ≥ 64 KiB panics the leader in debug builds

## TL;DR

- **What failed:** `encodeChanges`/`encodeValue` write per-value and per-item lengths into u16 fields with unchecked `@intCast`; the sizes are computed in `usize`. Any settings value whose encoded form reaches 64 KiB panics in Debug/ReleaseSafe ("integer does not fit") and silently corrupts the payload in ReleaseFast/Small.
- **Impact:** A leader crashes (debug builds - the default for `zig build run` and tests) on a settings change or genesis that the fold otherwise accepts. No encode-side cap exists; `journal.max_entry_bytes` (16 MiB) is far above the limit.
- **Resolution:** Still open. Reproduced dynamically.

## Status

Resolved - `encodeChanges`/`encodePayload`/`encodeValue` now refuse with
`error.SettingsTooLarge` when a count or length exceeds `max u16`;
regression tests in `fold.zig` (a 65,536-byte item) and the atomic-commit
test drive the encode path.

## Symptom and impact

`coppiz settings set --key leadership.authorities --value '[...]'` (or a `[genesis]` authority list in `coppiz.toml`) with a single item ≥ 65,536 bytes panics during encode:

```
thread 353865 panic: integer does not fit in destination type
src/settings/fold.zig:52:41: 0x... in encodeChanges
        std.mem.writeInt(u16, &len_buf, @intCast(vlen), .little);
```

The same panic is reachable from the wire: a client's `settings` message whose change-list total value length exceeds 65,535 causes the leader's re-encode to panic (`node.zig:2288-2304` decodes with `scope_filter = null`, then the leader re-encodes the payload).

## Reproduction

Standalone repro (validated): build a `string_list` value for `leadership.authorities` with one 65,536-byte item; `changesLen` returns 65,546 (> 65,535); calling `encodeChanges` panics with "integer does not fit in destination type" at `fold.zig:52`. In ReleaseFast/Small the same call silently writes a truncated u16 length whose bytes no longer match the payload - encode and decode disagree, and the entry is later refused as `InvalidLength` or misparsed.

Expected: an error, or a documented cap, not a panic/corruption. The decode side reads u16 fields (`decodeChanges`, `decodeValue`), so the wire format itself is capped at 64 KiB per value - the encode side must enforce the same.

## Root cause

The settings payload codec is asymmetric:

- `fold.zig:36-40` (`changesLen`) and `schema.zig:383-396` (`valueLen`) compute sizes in `usize` with no cap.
- `fold.zig:52` (`encodeChanges`) and `schema.zig:408, 412` (`encodeValue`) write the count and lengths as u16 via unchecked `@intCast`.

Nothing enforces the 64 KiB bound on the encode path. `validateState`'s `authority_entry_max = 256` (`validate.zig:36,95`) bounds each *item* but not the total; `journal.max_entry_bytes` (16 MiB, `chain.zig:412-413`) bounds the whole entry, far above the codec limit. `config/local.zig`'s `parseStringArray` has no length cap either, so the CLI/TOML path reaches the same overflow.

## Resolution

Fixed. `schema.encodeValue` returns `error{SettingsTooLarge}` when the
string_list count or an item length exceeds `max u16`; `fold.encodeChanges`
refuses a change list whose count or any `valueLen` exceeds `max u16`; and
`fold.encodePayload` propagates. The error set
(`fold.SettingsTooLargeError`) ripples through every caller -
`chain.encodeGenesisPayload`/`encodeCreateJournalPayload`, the node's
settings/genesis paths, `journal.init`, the CLI `settings set`, and the
simulator - which now propagate it (`try`) instead of silently
truncating. No wire-format change: the decode side's u16 fields are the
cap, and the encode side now enforces the same bound.

Regression tests (`fold.zig`): a single 65,536-byte authority item
(`changesLen = 65546`) returns `SettingsTooLarge` from `encodeChanges`
(was a debug-build panic), and the same cap refuses an individual
over-long item from `encodeValue`.

## Verification

- Dynamic: standalone repro - `changesLen = 65546`; `encodeChanges` panics with "integer does not fit in destination type" (`fold.zig:52`). Confirmed on this toolchain (`zig 0.16.0`).
- Static: all three `@intCast` sites verified; decode side reads u16 (`fold.zig:71-92`, `schema.zig:424+`); no encode-side cap found by grep.

## Follow-up

The fold's `applySettings` is also not atomic under OOM (reported separately). Both are on the same replicated-fold path, so they share the "one member diverges" risk.

## References

- Code: `src/settings/fold.zig:36-57` (`changesLen`/`encodeChanges`), `src/settings/schema.zig:383-420` (`valueLen`/`encodeValue`), `src/config/local.zig:271-289` (`parseStringArray`)
- Fix: `src/settings/fold.zig`, `src/settings/schema.zig`, and every encode caller (`src/journal/chain.zig`, `src/journal/journal.zig`, `src/cluster/node.zig`, `src/cluster/epoch.zig`, `src/cluster/membership.zig`, `src/sim/sim.zig`, `src/main.zig`). `zig build test` green.
