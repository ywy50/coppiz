# Bug - A re-slotted `create_journal` is always refused: the merge stalls whenever the losing branch created a journal during the partition

## TL;DR

- **What failed:** The re-slot classification routes every non-epoch control entry whose author is not the current leader into `applyControlReslotted`, whose `.create_journal` case calls `applyCreateJournal` - and that function's first check refuses exactly those entries (`checkAuthorIsLeader`). The two conditions are mutually exclusive, so a reslotted `create_journal` always fails with `error.NotLeader`.
- **Impact:** The partition-merge feature ([PRD 0003](../../prds/0003-membership-and-leadership.md) phase 3, shipped) never converges when the losing branch created a journal during the partition: every member refuses identically and the merge stalls.
- **Resolution:** Still open. Statically validated (the two gates are provably mutually exclusive).

## Status

Resolved - `create_journal` got a re-slotted variant that skips only the
author check; regression test folds a losing-branch create_journal
through `applyControlReslotted`.

## Symptom and impact

`join` and `leave` got dedicated reslotted variants (`applyJoinReslotted`/`applyLeaveReslotted`) precisely to relax their authorization, and the routing docstring says `create_journal` re-slots "with its normal rule" - but the normal rule is the leader check, which the re-slot path can never satisfy. No test covers a reslotted `create_journal` (only join/leave/settings/epoch are tested), which is why the suite is green.

## Reproduction

Not dynamically reproduced (needs a full heal with a loser-side journal creation); statically airtight. Trace:

1. During a partition, the losing leader appends a `create_journal` control entry.
2. On heal, `doMergeControl` re-slots the losing branch's control records (`cluster/node.zig:2115-2118` → `applyReplicated(..., true)` → `applyControl`).
3. The routing rule (`chain.zig:311-313`): `reslotted_entry = en.kind != .epoch and !eql(en.author, leader)` - true here by construction (the author is the *losing* leader, never the survivor).
4. `applyControlReslotted` (`chain.zig:374-381`) dispatches `.create_journal` to `applyCreateJournal`, whose first check is `checkAuthorIsLeader(en, leader)` (`chain.zig:564-565`) - which returns `error.NotLeader` for exactly the entries step 3 routed here.

The `create_journal` entry never folds; the merge aborts.

## Root cause

`chain.zig:312` (routing: reslotted ⇒ author ≠ leader) and `chain.zig:565` (applyCreateJournal: author must = leader) are contradictory for re-slots. The intended behavior is documented in the routing docstring ("`create_journal` with its normal rule" - i.e., validated like a live one, but the authorization must be relaxed the way `join`/`leave` re-slots are, since the entry's author is legitimately not the survivor's leader). The entry bytes are still signature-checked and the journal-id/name/settings validation runs, so relaxing the author check does not let anything unvalidated in.

## Resolution

Fixed as suggested. `applyCreateJournal` is split into an author check
plus `applyCreateJournalValidated` (payload decode, name length,
max-journals, initial-settings validation, registry insert, register);
`applyControlReslotted` routes `.create_journal` to
`applyCreateJournalReslotted`, which runs the validated core without
`checkAuthorIsLeader` - the entry bytes were already signature-checked
against the member table and `checkAuthorSeq` ran in the re-slot path, so
nothing unvalidated gets in.

Regression test (`chain.zig` "a re-slotted create_journal is accepted and
registers the journal"): a second member joins, then its create_journal
is re-slotted by the founder - the merge's exact shape - and the journal
registers. Before the fix the re-slot was always refused with
`NotLeader`.

## Verification

- Static: the routing condition (`chain.zig:311-313`) and `applyCreateJournal`'s guard (`chain.zig:564-565`) are mutually exclusive by construction; both verified by reading the code and callers.

## Follow-up

Related merge-path defects: the settle rule reading the wrong fold (reported separately). Both are on the same heal path.

## References

- Code: `src/journal/chain.zig:311-316` (routing), `:374-381` (reslotted dispatch), `:559-587` (`applyCreateJournal`), `src/cluster/node.zig:2115-2118` (merge re-slot)
- Fix: `src/journal/chain.zig` (`applyCreateJournalReslotted`); regression test in the same file. `zig build test` green.
