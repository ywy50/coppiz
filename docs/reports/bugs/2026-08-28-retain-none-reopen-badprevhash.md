# Bug - `ttl.retain = none` compaction makes a journal unfoldable on reopen: `Node.open` fails with `BadPrevHash`

## TL;DR

- **What failed:** Under `ttl.retain = none`, compaction rewrites removed entries as slot-only records. On reopen, the fold's scan callback skips those records *without advancing the chain head*, so the next full record fails the `prev_slot_hash` continuity check and `Node.open` errors.
- **Impact:** A documented, e2e-tested storage mode (`ttl.retain = none`) makes every member unable to reopen its own store after legitimate operation (checkpoint → compact → restart).
- **Resolution:** Still open. Mechanism validated dynamically at the store level; the fold failure follows directly from the scan callback.

## Status

Resolved - `foldJournal` advances the fold's chain head over slot-only
records via the new `FoldState.advanceHead`; regression test compacts
under `ttl.retain = none` and reopens.

## Symptom and impact

A member that compacted under `retain = none` and restarts fails to open: the fold rebuild (`Node.open` → `foldAll` → `foldJournal` → `store.scan`) hits a chain-continuity refusal and the node cannot start. `refold()` (the [OQ 44](../../open-questions.md) heal path) breaks identically. The shipped e2e test exercising `retain = none` (`cluster/node.zig:3118`) never reopens the node, so the gap is uncovered.

## Reproduction

Mechanism proof (validated by standalone repro at the store level): append three chained records (slot1 ← slot2 ← slot3) to a journal, then `compact` out record 2 with `retain = .none`. The store's scan now yields record 1, a slot-only record (entry = null), record 3. Record 3's `prev_slot_hash` equals `slotHash(slot2)` - the chain is over *slots*, and the removed slot is still part of it:

```
record 3 prev_slot_hash == hash(slot2): true
record 3 prev_slot_hash == hash(slot1): false
```

The fold, however, folds only records with an entry. `foldJournal`'s callback does `const e = en orelse return;` - the slot-only record is skipped and the fold's `head_slot_hash` stays at `slotHash(slot1)`. When record 3 arrives, `checkChainContinuity` (`chain.zig:426`) compares `prev_slot_hash` (`hash(slot2)`) against the stale head (`hash(slot1)`) and refuses with `BadPrevHash`, which propagates out of `foldAll` and fails `Node.open`. A full record always follows the gap - the checkpoint record itself is never in the removal set (no `expires_at`, `ttl_action = mark_stale`) - so the failure is guaranteed after any `retain = none` compaction that removed entries.

## Root cause

Two pieces combine:

- `store.compact` under `retain = none` rewrites removed entries as slot-only records (`store.zig:437-443`) - by design ([PRD 0002](../../prds/0002-ttl-and-staleness.md)); the chain still verifies because slots are kept verbatim.
- `foldJournal` (`journal.zig:682-701`) skips entry-less records with `orelse return` instead of advancing the fold's head/hash over them. There is no `retain = none` handling anywhere in the fold path; the sync path acknowledges the shape (`cluster/node.zig:1771`, "A compacted record cannot be folded") but the open path does not.

Under the default `retain = header` the surviving header-only records still decode to entries and fold fine (the existing reopen test, `journal.zig:1290-1362`, covers only that value).

## Resolution

Fixed. `FoldState.advanceHead(sl)` runs `checkChainContinuity` and moves
`head`/`head_slot_hash`/`last_slot_ts_ms` without registering an entry;
`foldJournal`'s scan callback calls it for `retain = none` slot-only
records instead of `orelse return`. The next full record then chains
against the removed slot's hash as the writer intended. The divergent-
epoch skip (a losing branch's tail) is untouched: those records form the
tail and are never followed by a chainable record, so skipping without
advancing is still correct there. The sync server's OQ 43 refusal of
compacted records is unchanged.

Regression test (`journal.zig` "retain = none compaction leaves a journal
that folds on reopen"): set `ttl.enforce = all`, `ttl.action = delete`,
`ttl.retain = none`, append two entries, checkpoint past the first one's
expiry, reopen - before the fix `Node.open` failed with `BadPrevHash`.
The surviving entry reads back after reopen.

## Verification

- Dynamic: standalone store-level repro demonstrates the chain gap (record 3 chains to the removed slot's hash, not the fold's stale head).
- Static: `journal.zig:684` (`orelse return`) and `chain.zig:425-427` (`BadPrevHash`) verified; the checkpoint record is never in the removal set (expiry semantics), so a full record always follows.

## Follow-up

Related: `foldJournal`'s other skip (`journal.zig:696-697`, divergent-epoch data records) has the same "skip without advancing head" shape and can fail the same way if a later record in the same scan chains to a skipped slot - worth covering in the same fix.

## References

- Code: `src/journal/journal.zig:679-702` (`foldJournal`), `src/journal/chain.zig:425-427` (`checkChainContinuity`), `src/journal/store.zig:437-443` (slot-only rewrite), `src/journal/segment.zig` (`encodeSlotOnlyRecord`)
- Fix: `src/journal/chain.zig` (`FoldState.advanceHead`), `src/journal/journal.zig` (`foldJournal`); regression test in `journal.zig`. `zig build test` green.
