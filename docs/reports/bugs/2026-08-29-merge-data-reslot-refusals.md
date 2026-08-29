# Bug — Merge data re-slots refuse `settings`/`checkpoint`/`stale` records: the heal never completes (and a `leave` before data can lose the branch)

## TL;DR

- **What failed:** `doMergeData` re-slots *every* record of the losing data branch through `applyData`, which has no re-slotted variant: a journal-scoped `settings` or `checkpoint` entry is refused (`checkAuthorIsLeader` — the author is the losing leader), and a `stale` entry can refuse under a differing `stale.enforce`. The refusal propagates and aborts the merge; every retry fails identically. A re-slotted `leave` that removed a data author makes that branch's data fail `UnknownAuthor` — the branch is silently dropped instead.
- **Impact:** The partition-merge feature ([PRD 0003](../../prds/0003-membership-and-leadership.md) phase 3) never converges when the losing branch contains such records, or converges without the losing side's data (silent data loss).
- **Resolution:** Still open. Statically validated.

## Status

Open. The control chain got its re-slotted variants (OQ 33: `settings` re-slots as no-op, `join`/`leave`/`create_journal` variants); the data chain was never mirrored.

## Symptom and impact

The control-chain re-slot rule documents that the losing branch's `settings` entries re-slot as no-ops (the survivor's value wins) and that cleanup records have already served their purpose (`applyControlReslotted`, `chain.zig:374-381`). `applyData` has no equivalent: a losing data branch containing a journal-scoped settings change, a checkpoint (routine whenever `ttl`/`stale` enforcement is enabled), or a stale mark under a different enforcement setting refuses with `NotLeader`/`StalenessDisabled`/`NotAuthor`. `doMergeData` (`node.zig:2341-2369`) then errors out of `mergePage` → `onSyncPage` → `onFrame`, which closes the connection and aborts the heal. The survivor's control chain already carries the merge entry, so the retry re-enters the same refusal forever; the loser's divergent data is never merged.

## Reproduction

Not dynamically reproduced (needs a full partition with enforcement-enabled journals); statically certain:

- `doMergeData` (`node.zig:2353-2367`): decodes every record of the branch — no kind filter — and calls `applyReplicated(jid, &sl, &e, false)`.
- `applyData` (`chain.zig:414-418`): routes `.settings` → `applyJournalSettings` (`:649-667`, `checkAuthorIsLeader` against the *current* leader — the re-slotted author is the losing leader) and `.checkpoint` → `applyCheckpoint` (`:684-690`, same check). Both refuse.
- The merge e2e test writes only `.data` entries during the partition, so the suite never exercises these kinds.

Second manifestation (silent loss): the survivor re-slots the losing *control* branch first (`doMergeControl`, `node.zig:2259-2337`), including a re-slotted `leave` that removes a member. A data branch whose author was removed then fails `applyData`'s author lookup (`chain.zig:407-410`, `UnknownAuthor`), the merge aborts, and since the survivor's chain already has the merge entry, both sides converge on a chain that never contained that data — the "every entry written on either side resolves on both" invariant fails silently.

## Root cause

The OQ 33 no-op/relaxed-authorization rules were implemented for the control chain only. The data chain re-slot path needs the same treatment: journal-scoped `settings` and `checkpoint` from the losing branch should re-slot per the documented rules (no-op / survivor-wins), and the ordering must handle a `leave` before the data it removes (data re-slots before the leaves that remove their authors, or the removed author's records folded before removal).

## Resolution

Not yet fixed. Suggested direction: give `applyData` a reslotted path (or re-slot data records as `.data`-only), mirroring `applyControlReslotted`: journal `settings`/`checkpoint`/`stale` from a losing branch fold per OQ 33 instead of refusing; re-order `doMergeControl`/`doMergeData` so a branch's data folds before the leaves that remove its authors. A regression test should partition with enforcement-enabled journals (and with an eviction + data on the losing side) and assert the heal converges with every entry resolving.

## Verification

- Static: `doMergeData`'s kind-unfiltered loop, `applyData`'s routing to author-checked functions, `applyControlReslotted`'s no-op rules (the intended pattern), and `doMergeControl`'s leave-first ordering all verified by reading.

## Follow-up

Related merge defects reported separately: the settle-rule cadence crash-loop (2026-08-29) and the unclamped re-slot timestamp (2026-08-29). The whole re-slot path deserves an e2e with enforcement enabled.

## References

- Code: `src/cluster/node.zig:2341-2369` (`doMergeData`), `:2259-2337` (`doMergeControl`), `src/journal/chain.zig:414-418` (`applyData` routing), `:649-667` (`applyJournalSettings`), `:684-690` (`applyCheckpoint`), `:374-381` (`applyControlReslotted` no-ops)
- Fix: none
