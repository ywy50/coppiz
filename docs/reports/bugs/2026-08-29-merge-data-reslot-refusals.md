# Bug - Merge data re-slots refuse `settings`/`checkpoint`/`stale` records: the heal never completes (and a `leave` before data can lose the branch)

## TL;DR

- **What failed:** `doMergeData` re-slots *every* record of the losing data branch through `applyData`, which has no re-slotted variant: a journal-scoped `settings` or `checkpoint` entry is refused (`checkAuthorIsLeader` - the author is the losing leader), and a `stale` entry can refuse under a differing `stale.enforce`. The refusal propagates and aborts the merge; every retry fails identically. A re-slotted `leave` that removed a data author makes that branch's data fail `UnknownAuthor` - the branch is silently dropped instead.
- **Impact:** The partition-merge feature ([PRD 0003](../../prds/0003-membership-and-leadership.md) phase 3) never converges when the losing branch contains such records, or converges without the losing side's data (silent data loss).
- **Resolution:** Resolved - `applyData` gained its re-slotted variant (`applyDataReslotted`, mirroring `applyControlReslotted`: journal `settings`/`checkpoint`/`stale` re-slot as no-ops, `data` folds normally), and `doMergeControl` defers the control `leave`s until every data branch has folded, so a leave can never remove a member whose losing-branch data is still ahead of it.

## Status

Resolved - `applyDataReslotted` (chain.zig, threaded through
`applyReplicated` with the merge's `reslotted` flag) folds journal-scoped
`settings`/`checkpoint`/`stale` from the losing branch as no-ops per OQ 33
(the survivor's value wins; cleanup already served) while `data` folds
normally, and a re-slotted checkpoint no longer triggers a compaction.
`doMergeControl` now defers the control `leave` entries and
`reSlotDeferredLeaves` re-slots them after every data branch has folded -
the "data before the leaves that remove its authors" ordering the report
asked for, with join-vs-join seniority and join-before-data preserved.

## Symptom and impact

The control-chain re-slot rule documents that the losing branch's `settings`
entries re-slot as no-ops (the survivor's value wins) and that cleanup
records have already served their purpose (`applyControlReslotted`,
`chain.zig:374-381`). `applyData` has no equivalent: a losing data branch
containing a journal-scoped settings change, a checkpoint (routine whenever
`ttl`/`stale` enforcement is enabled), or a stale mark under a different
enforcement setting refuses with `NotLeader`/`StalenessDisabled`/`NotAuthor`.
`doMergeData` (`node.zig:2341-2369`) then errors out of `mergePage` →
`onSyncPage` → `onFrame`, which closes the connection and aborts the heal.

The survivor's control chain already carries the merge entry, so the retry
re-enters the same refusal forever; the loser's divergent data is never
merged.

## Reproduction

Not dynamically reproduced (needs a full partition with enforcement-enabled journals); statically certain:

- `doMergeData` (`node.zig:2353-2367`): decodes every record of the branch - no kind filter - and calls `applyReplicated(jid, &sl, &e, false)`.
- `applyData` (`chain.zig:414-418`): routes `.settings` → `applyJournalSettings` (`:649-667`, `checkAuthorIsLeader` against the *current* leader - the re-slotted author is the losing leader) and `.checkpoint` → `applyCheckpoint` (`:684-690`, same check). Both refuse.
- The merge e2e test writes only `.data` entries during the partition, so the suite never exercises these kinds.

Second manifestation (silent loss): the survivor re-slots the losing *control* branch first (`doMergeControl`, `node.zig:2259-2337`), including a re-slotted `leave` that removes a member. A data branch whose author was removed then fails `applyData`'s author lookup (`chain.zig:407-410`, `UnknownAuthor`), the merge aborts, and since the survivor's chain already has the merge entry, both sides converge on a chain that never contained that data - the "every entry written on either side resolves on both" invariant fails silently.

## Root cause

The OQ 33 no-op/relaxed-authorization rules were implemented for the control chain only. The data chain re-slot path needs the same treatment: journal-scoped `settings` and `checkpoint` from the losing branch should re-slot per the documented rules (no-op / survivor-wins), and the ordering must handle a `leave` before the data it removes (data re-slots before the leaves that remove their authors, or the removed author's records folded before removal).

## Resolution

Fixed. The first manifestation needed a re-slotted *data* path, so
`applyData` was split into `applyDataChecked` with a `reslotted` flag and a
public `applyDataReslotted`: it runs the same checks (chain continuity,
slot signature, entry signature, author seq, size) but routes
journal-scoped `settings`/`checkpoint`/`stale` as no-ops instead of through
`applyJournalSettings`/`applyCheckpoint`/`applyStale` - whose
`checkAuthorIsLeader` cannot hold (the author is the losing branch's
leader) and whose `stale.enforce` gate may differ. `applyReplicated`
threads the merge's `reslotted` flag to the data fold and skips the
checkpoint-triggered compaction for re-slots.

The second manifestation is fixed by ordering: `doMergeControl` defers the
control `leave` entries into `merge_pending_leaves` and
`reSlotDeferredLeaves` re-slots them after every data branch has folded -
the report's "data re-slots before the leaves that remove their authors",
while join-vs-join seniority and join-before-data order are preserved.

Regression test: "a re-slotted data entry folds journal
settings/checkpoint/stale as no-ops" (chain.zig) - a non-leader-authored
settings entry that the live rule refuses `NotLeader` folds as a no-op
through the re-slot, a stale mark and an out-of-range checkpoint fold as
no-ops, and a `data` entry re-slots normally. The merge e2e still writes
only `.data` during the partition; an enforcement-enabled partition e2e
remains a follow-up.

## Verification

- Static: `doMergeData`'s kind-unfiltered loop, `applyData`'s routing to author-checked functions, `applyControlReslotted`'s no-op rules (the intended pattern), and `doMergeControl`'s leave-first ordering all verified by reading.

## Follow-up

Related merge defects reported separately: the settle-rule cadence crash-loop (2026-08-29) and the unclamped re-slot timestamp (2026-08-29). The whole re-slot path deserves an e2e with enforcement enabled.

## References

- Code: `src/cluster/node.zig:2341-2369` (`doMergeData`), `:2259-2337` (`doMergeControl`), `src/journal/chain.zig:414-418` (`applyData` routing), `:649-667` (`applyJournalSettings`), `:684-690` (`applyCheckpoint`), `:374-381` (`applyControlReslotted` no-ops)
- Fix: none
