# Bug - Backfill over a chain containing compacted (`retain = none`) records never terminates

## TL;DR

- **What failed:** `onSyncReq` skips slot-only (compacted) records without advancing the page cursor. A requester whose window spans a compacted record parks its cursor at the gap and re-requests it forever (`BadPrevHash` on the first post-gap record, cursor never advanced); a fully-compacted window is declared done with a permanent gap.
- **Impact:** A joiner backfilling a journal with `retain = none` compaction never finishes (stuck `syncing`, never a member), or completes with a chain the next broadcast can never close.
- **Resolution:** **Resolved 2026-08-31, after a false resolution on 2026-08-29.** The 2026-08-29 record claimed a fix no commit ever contained; the sync path was unchanged and `onSyncPage` refused the compacted shape outright. It is now fixed for real, with two regression tests that were seen to fail on the parent commit.

## Status

Resolved 2026-08-31, after a false resolution on 2026-08-29.

Reopened and fixed in the same change. `8893ae1`
("docs(reports): mark the sweep fixes resolved (#116)") flipped this record
to `Resolved` in a commit that touched 29 report files and no source file;
the record's own TL;DR still read "Still open" and its References still read
`Fix: none`. See *Reopened - what was checked* for the evidence and
*Resolution* for what actually shipped.

## Symptom and impact

`onSyncReq` (`node.zig:1936-1951`): the callback does `const e = en orelse return;` **without advancing `ctx.next`** - unlike the read path, which advances `next` from the served position. Two consequences:

1. **Compacted record mid-window:** the page serves the records before and after it; `next` is the last *served* position + 1, so the requester's cursor parks at the compacted slot. The requester folds the served records, then the first post-gap record arrives (or is re-requested): its `prev_slot_hash` chains to the compacted slot's hash, not the requester's head → `BadPrevHash` → same-leader divergence no-op → the cursor never advances. Every tick re-requests the same window and re-fails - infinite retry, `syncing` never clears.
2. **Fully-compacted window:** the page is empty → the cursor is removed → the journal is declared done with a permanent gap; the next broadcast for that journal re-triggers `requestSync` with the same empty-page result forever.

The skip itself is documented (OQ 43, `:1939`); the *consequence* - the requester's cursor never advancing - is not handled anywhere. (The already-reported `2026-08-29-wire-read-drops-compacted-slots` covers the read path; this is the sync/backfill path.)

## Reproduction

Originally recorded as: not dynamically reproduced (needs a joiner over a
compacted chain); statically certain from the cursor arithmetic.

Now reproduced at the two ends of the sync protocol, on the parent commit
`c6983b9`:

- `cluster.node.test."a sync page carries a compacted slot instead of
  skipping the gap"` appends three data records, compacts the middle one
  with `store.compact(.., .none)`, and calls `onSyncReq` over a
  frame-recording connection. It fails at
  `expectEqualSlices(bool, &.{ true, false, true }, kinds.items)` with
  `TestExpectedEqual`: the served page holds two records, not three - the
  compacted position is simply absent.
- `cluster.node.test."a compacted slot on a sync page advances the fold
  head, not the connection"` feeds one hand-signed slot-only record, chained
  to the node's own head, into `onSyncPage`. It fails at
  `expect(!cn.conns.getPtr(9).?.closing)` with `TestUnexpectedResult`: the
  connection is dropped rather than the head advanced.

Together those are the two halves of the loop: the server omits the record
and the client could not have used it if it were sent.

## Root cause

`onSyncReq` drops the record without advancing `next`, and `onSyncPage` has no "the gap is at a compacted slot" case - the requester cannot progress past a record the server will never serve.

## Reopened - what was checked

Checked at `c6983b9` (2026-08-31), by reading and by search:

- `onSyncReq`'s scan callback still read
  `const e = en orelse return; // compacted records are not served (OQ 43)` -
  the record is dropped and `ctx.next` is not touched. No slot-only encoding
  existed on the sync path.
- `onSyncPage`'s record loop still read
  `const e = rec.entry orelse { self.closeConn(conn_id); return; }` with the
  comment "A compacted record cannot be folded (OQ 43); refuse it." So even a
  correctly served page would have been refused.
- `grep -rn advanceHead src/` matched three places -
  `chain.zig` (the definition) and two call sites in `journal.zig` (the
  open-time fold and the refold). None in `src/cluster/`. `git log --all -S
  advanceHead -- src/cluster/` returns no commit, so the claimed client-side
  call was never added and later removed either.
- The read path *was* fixed for the sibling defect
  ([2026-08-29-wire-read-drops-compacted-slots](2026-08-29-wire-read-drops-compacted-slots.md)):
  `onReadReq` emits the slot-only marker. The sync path was not, which is why
  the shape of the fix was already in the tree next to the gap.

So the *Resolution (as recorded 2026-08-29)* below describes work that was
not done. It is kept verbatim rather than deleted: a `Resolved` row hides
live work exactly as effectively as a missing row would, and knowing this
record was wrong is now part of its value. No attempt was made to reconstruct
why it said otherwise, and the reader should not infer one.

## Resolution (as recorded 2026-08-29 - not implemented)

Fixed: sync pages carry slot-only records, the client's `onSyncPage` advances the fold head over them via `advanceHead`, and the merge re-slot skips them - backfill over a `retain = none` chain terminates.

## Resolution

Fixed 2026-08-31, in the sync path only:

- **Server.** `onSyncReq`'s scan callback encodes a compacted record as a
  slot-only marker (`segment.encodeSlotOnlyRecord`, the same shape the wire
  read already serves) and advances `ctx.next` past it. The page-size bound
  is honoured for the marker exactly as `encodeRecordIntoPage` honours it
  for a full record.
- **Client.** `onSyncPage` routes a record with no entry to a new
  `applySlotOnly`, which checks the position against my head (at or behind
  it is a redelivery), checks `prev_slot_hash` against my head hash
  (a mismatch is a divergence, handed to `onDivergence` as for a full
  record), verifies the slot signature against the *control* fold's member
  table - the membership lives there even for a data journal's slot, as in
  `chain.applyDataChecked` - then `fold.advanceHead(sl)` and
  `store.appendRecord` with the page's own bytes. Fold first, store second,
  matching `applyReplicated`.

Storing the bytes is not optional: `journal.foldJournal` advances the head
over a slot-only record on open, so a backfilled member that folded the gap
but did not persist it would refuse the record chaining to it on the next
restart (bug 2026-08-28-retain-none-reopen-badprevhash).

What is *not* claimed: the merge re-slot path is untouched. `mergePage`
handles pages in merge mode before this code runs, and a compacted record in
a merged branch is a separate question from backfill - it was not
investigated here.

## Verification

- Static, original: `onSyncReq` callback (`node.zig:1936-1951`) and
  `onSyncPage` cursor handling (`:1979-1996, :2027`) read; `advanceHead` read
  as the intended shape.
- Static, 2026-08-31: the search and re-read recorded under *Reopened*.
- Dynamic, 2026-08-31: the two regression tests above, each seen to fail on
  `c6983b9` for the reason quoted and to pass with the fix.
  `zig build test --summary all` on the fix: `Build Summary: 25/25 steps
  succeeded; 374/374 tests passed`.
- Not covered: no test drives a *joiner* end to end across a compacted
  chain. The two tests exercise the server and client halves separately, on
  one node each; the claim that a real backfill now terminates is argued from
  the two halves composing, not reproduced.

## Follow-up

Related sync-path defect: the oversized-entry loop (2026-08-28-sweep3-oversized-entry-unreplicable) - both leave backfill non-terminating.

## References

- Code (line numbers as of the original report): `src/cluster/node.zig:1936-1951` (`onSyncReq`), `:1979-1996, :2027` (`onSyncPage`), `src/journal/journal.zig:671-679` (`advanceHead`)
- Code (current): `src/cluster/node.zig` - `onSyncReq`, `onSyncPage`, `applySlotOnly`; `src/journal/chain.zig` - `FoldState.advanceHead`
- False resolution: `8893ae1` (docs-only, 29 report files, no source change)
- Fix: this change
