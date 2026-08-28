# Bug — A re-slotted `create_journal` is always refused: the merge stalls whenever the losing branch created a journal during the partition

## TL;DR

- **What failed:** The re-slot classification routes every non-epoch control entry whose author is not the current leader into `applyControlReslotted`, whose `.create_journal` case calls `applyCreateJournal` — and that function's first check refuses exactly those entries (`checkAuthorIsLeader`). The two conditions are mutually exclusive, so a reslotted `create_journal` always fails with `error.NotLeader`.
- **Impact:** The partition-merge feature ([PRD 0003](docs/prds/0003-membership-and-leadership.md) phase 3, shipped) never converges when the losing branch created a journal during the partition: every member refuses identically and the merge stalls.
- **Resolution:** Still open. Statically validated (the two gates are provably mutually exclusive).

## Status

Open.

## Symptom and impact

`join` and `leave` got dedicated reslotted variants (`applyJoinReslotted`/`applyLeaveReslotted`) precisely to relax their authorization, and the routing docstring says `create_journal` re-slots "with its normal rule" — but the normal rule is the leader check, which the re-slot path can never satisfy. No test covers a reslotted `create_journal` (only join/leave/settings/epoch are tested), which is why the suite is green.

## Reproduction

Not dynamically reproduced (needs a full heal with a loser-side journal creation); statically airtight. Trace:

1. During a partition, the losing leader appends a `create_journal` control entry.
2. On heal, `doMergeControl` re-slots the losing branch's control records (`cluster/node.zig:2115-2118` → `applyReplicated(..., true)` → `applyControl`).
3. The routing rule (`chain.zig:311-313`): `reslotted_entry = en.kind != .epoch and !eql(en.author, leader)` — true here by construction (the author is the *losing* leader, never the survivor).
4. `applyControlReslotted` (`chain.zig:374-381`) dispatches `.create_journal` to `applyCreateJournal`, whose first check is `checkAuthorIsLeader(en, leader)` (`chain.zig:564-565`) — which returns `error.NotLeader` for exactly the entries step 3 routed here.

The `create_journal` entry never folds; the merge aborts.

## Root cause

`chain.zig:312` (routing: reslotted ⇒ author ≠ leader) and `chain.zig:565` (applyCreateJournal: author must = leader) are contradictory for re-slots. The intended behavior is documented in the routing docstring ("`create_journal` with its normal rule" — i.e., validated like a live one, but the authorization must be relaxed the way `join`/`leave` re-slots are, since the entry's author is legitimately not the survivor's leader). The entry bytes are still signature-checked and the journal-id/name/settings validation runs, so relaxing the author check does not let anything unvalidated in.

## Resolution

Not yet fixed. Suggested direction: give `create_journal` a reslotted variant (mirroring `applyJoinReslotted`) that skips `checkAuthorIsLeader` but keeps payload/name/max-journals validation, and route `.create_journal` to it from `applyControlReslotted`. A regression test should fold a losing branch containing a `create_journal` through `doMergeControl` and expect the merge to complete with the journal registered.

## Verification

- Static: the routing condition (`chain.zig:311-313`) and `applyCreateJournal`'s guard (`chain.zig:564-565`) are mutually exclusive by construction; both verified by reading the code and callers.

## Follow-up

Related merge-path defects: the settle rule reading the wrong fold (reported separately). Both are on the same heal path.

## References

- Code: `src/journal/chain.zig:311-316` (routing), `:374-381` (reslotted dispatch), `:559-587` (`applyCreateJournal`), `src/cluster/node.zig:2115-2118` (merge re-slot)
- Fix: none
