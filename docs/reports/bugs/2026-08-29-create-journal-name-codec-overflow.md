# Bug - `encodeCreateJournalPayload` writes the journal name with an unchecked u16 cast: a 64 KiB name panics in debug

## TL;DR

- **What failed:** `chain.zig:988` writes `@intCast(payload.name.len)` into the u16 name-length field with no size check. The fold caps names at `max_journal_name = 256` on decode, but nothing caps them on encode.
- **Impact:** `coppiz init --journal <name of >65535 bytes>` panics in debug builds and silently wraps the length field in release - the founder and followers then disagree about the journal name.
- **Resolution:** Fixed. Encode refuses `error.SettingsTooLarge` before the
  u16 cast.

## Status

Resolved - `encodeCreateJournalPayload` refuses a name longer than
`max u16` with `error.SettingsTooLarge`; the regression test in `chain.zig`
encodes a 65,536-byte name.

## Symptom and impact

`journal.init` (`journal.zig:1029-1044`) passes the CLI's `--journal` argument straight to `createJournal` → `encodeCreateJournalPayload`. The u16 field is what the decode side reads; an over-long name cannot round-trip.

## Reproduction

Not dynamically reproduced; statically certain. `createJournalPayloadLen` (`chain.zig:979-981`) computes the size in `usize`; `encodeCreateJournalPayload` (`:983-991`) truncates. In Debug, `@intCast` panics; in ReleaseFast/Small it wraps silently.

## Root cause

The settings codec got its `settings_too_large` cap in the sweep fix; this sibling codec's name-length field was not covered.

## Resolution

Fixed. `encodeCreateJournalPayload` returns `error.SettingsTooLarge` when
`name.len` exceeds `max u16`, before the length field is written. The
fold's 256-byte `max_journal_name` still refuses over-long names on
decode and apply; this cap is the codec's own bound, matching the
settings encode path.

## Verification

- Static: encode (`chain.zig:983-991`) vs decode (`:993+`, u16 field) read; the fold's 256 cap (`:612`) confirms names were never meant to be large.
- Dynamic: `a create-journal name past the u16 codec cap is refused at encode` in `src/journal/chain.zig` builds a 65,536-byte name and expects `error.SettingsTooLarge`.

## Follow-up

None. Low priority (contrived trigger).

## References

- Code: `src/journal/chain.zig:979-991` (`createJournalPayloadLen`/`encodeCreateJournalPayload`)
- Fix: `src/journal/chain.zig` (`encodeCreateJournalPayload`). Regression
  test in the same file.
