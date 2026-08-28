# Bug — A re-slot redelivery lowers `authors.last_seq`, bypassing the `DuplicateConflict` rule for later conflicting entries

## TL;DR

- **What failed:** `checkAuthorSeq` accepts a byte-identical redelivery of an entry *below* the author's recorded `last_seq`, and `registerEntry` then unconditionally writes `authors.last_seq = en.author_seq` — lowering the high-water mark. With the floor lowered, a *different* entry at a seq between the lowered mark and the true last passes the seq check (which early-returns when `author_seq > last_seq`) without any dedup comparison and overwrites the original record.
- **Impact:** The dedup promise in `checkAuthorSeq`'s docstring ("accepted only when it is a byte-identical redelivery") is weakened; a conflicting entry can replace an already-slotted record under a misbehaving/merged leader.
- **Resolution:** Still open. Statically validated (low severity: trigger requires an adversarial author + slotting order).

## Status

Resolved — `registerEntry` only ever raises the author's `last_seq`;
regression test redelivers an old entry and checks a conflicting
same-id entry is still refused.

## Symptom and impact

Low severity: the trigger is adversarial (a leader re-slotting entries out of order, or a malicious author). But the invariant the whole dedup design rests on — "the entries table is the dedup store; an entry at or below the last seq is accepted only when byte-identical" — is broken by the lowering, and a *different* entry can then be accepted and overwrite the recorded one.

## Reproduction

Not dynamically reproduced; statically certain. Sketch: author A has seqs 5 (E1) and 6 (E2) slotted (`last_seq = 6`). A re-slot redelivers E1 (seq 5, byte-identical) → accepted → `registerEntry` writes `last_seq = 5`. A conflicting entry E2′ (seq 6, different payload) now arrives: `author_seq (6) > last_seq (5)` → `checkAuthorSeq` returns early **without** the dedup comparison (`chain.zig:474-480`) → `registerEntry` overwrites E2's entry hash with E2′'s. The original E2 is no longer redeliverable (hash mismatch → refusal), and the chain has silently replaced a record.

## Root cause

`registerEntry` (`chain.zig:492-522`) writes `authors.put(en.author, .{ .last_seq = en.author_seq })` unconditionally (`:518`), even when the accepted entry is a redelivery at a *lower* seq. The high-water mark must be monotone: a redelivery should not move it.

## Resolution

Fixed as suggested: `registerEntry` writes
`last_seq = max(old last_seq, en.author_seq)` instead of
unconditionally `en.author_seq`, so a redelivered entry below the
high-water mark never lowers it and the dedup rule's early return for
`author_seq > last_seq` stays sound.

Regression test (`chain.zig` "a redelivery below the author's last_seq
does not lower it"): E1 (seq 5) and E2 (seq 6) fold, E1 is redelivered
at a new position (accepted as the byte-identical dedup), then a
*conflicting* entry with E2's id is refused with `DuplicateConflict` —
before the fix the redelivery lowered the mark to 5 and the conflict
passed the seq check without any dedup comparison.

## Verification

- Static: `checkAuthorSeq` (`chain.zig:474-480`) and `registerEntry` (`:518`) verified line-by-line; the early-return path confirmed to skip the dedup check.

## Follow-up

None — contained. Low priority.

## References

- Code: `src/journal/chain.zig:474-480` (`checkAuthorSeq`), `:492-522` (`registerEntry`, esp. `:518`)
- Fix: `src/journal/chain.zig` (`registerEntry`); regression test in the same file. `zig build test` green.
