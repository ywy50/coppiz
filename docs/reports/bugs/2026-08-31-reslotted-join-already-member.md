# Bug - a re-slotted `join` for a member the survivor already holds refuses `AlreadyMember`, and the heal can never complete

## TL;DR

- **What failed:** `applyJoinReslotted` delegated verbatim to `applyJoin`, so
  a re-slotted `join` naming an id already in the member table returned
  `error.AlreadyMember`. `doMergeControl` appends the `merge` entry *before*
  re-slotting the branch, so the refusal arrives with the merge already
  committed to the survivor's chain.
- **Impact:** the merge aborts part-way and every retry refuses in exactly
  the same place, so the two branches never converge. Two ordinary branch
  shapes produce such a `join`: a newcomer that could reach both sides of a
  partition, and a losing branch that holds `leave X` then `join X`.
- **Resolution:** fixed - `applyJoinReslotted` is idempotent for a member the
  fold already holds, like `applyLeaveReslotted`, and still refuses a payload
  whose id does not derive from its key.

## Status

Resolved 2026-08-31.

## Symptom and impact

`src/cluster/membership.zig`, before the fix:

```zig
pub fn applyJoinReslotted(fold, sl, en) ApplyError!void {
    try applyJoin(fold, sl, en);
}
```

and inside `applyJoin`:

```zig
if (fold.memberById(payload.member_id) != null) return error.AlreadyMember;
```

The symmetric case for `leave` was made idempotent deliberately -
`applyLeaveReslotted` returns early for a target that is already gone,
because "a member can legitimately leave on both sides of a partition". The
same reasoning applies to `join` and was not applied.

The refusal is not recoverable. `doMergeControl` in `src/cluster/node.zig`
authors the `merge` control entry first and then re-slots the losing
branch's records with `try`, so a refusal leaves the `merge` entry on the
survivor's chain and the branch half re-slotted. On the next attempt the
already-folded prefix is accepted as redelivery and the same `join` refuses
again, identically. This is the class recorded in
[2026-08-29 - merge data re-slots refuse `settings`/`checkpoint`/`stale` records](2026-08-29-merge-data-reslot-refusals.md),
which fixed the data path and the loser's deferred `leave`s; the control
`join` was left.

Two branch shapes reach it:

**Dual admission.** A newcomer seeded with both addresses (and allowlisted,
or the cluster running `cluster.admission = open`) dials during a partition
and is admitted by each side's leader. Each branch gets its own `join` for
that id - different admitter, different `author_seq`, possibly a different
advertised address, so the entries are genuinely distinct and neither is a
redelivery of the other. On heal the survivor holds its own; the losing
branch's is re-slotted and refuses.

**Rejoin behind a deferred leave.** `doMergeControl` defers control `leave`
entries until every data branch has folded (that is the fix for the report
linked above), so a branch that recorded `leave X` and then `join X` replays
the `join` while X is still in the survivor's table.

## Reproduction

Deterministic, in the pure fold - no cluster or loop needed. The test
`a re-slotted join for a member the fold already holds is a no-op` in
`src/cluster/membership.zig`:

1. Fold a live `join` for the second member (the survivor's own admission).
2. Fold a re-slotted `join` for the same id with a different admitter
   sequence and a different advertised address.

- Expected: step 2 is accepted as a no-op; the member count and the
  seniority the merged chain gave stay put.
- Actual (before the fix): step 2 returns `error.AlreadyMember`.

## Root cause

`applyJoinReslotted` was written as "the same rules at a new slot", and for
the rules that judge the *entry* - the id deriving from the key - that is
right. `AlreadyMember` is not a rule about the entry; it is a rule about the
fold's current contents, and after a merge the fold's contents legitimately
already include what the losing branch is replaying. The distinction had been
drawn for `leave` and not for `join`.

## Resolution

`applyJoinReslotted` now decodes the payload itself, refuses a payload whose
`member_id` does not derive from its `public_key` (so a re-slot still cannot
smuggle a forged pairing past the live rule, present member or not), and
returns without touching the fold when the id is already a member. Otherwise
it delegates to `applyJoin` as before.

The seniority that survives is the one the merged chain carries, which every
member folding that chain computes identically - so the choice is
deterministic, which is what PRD 0003's merge rule requires.

## Verification

`zig build test` (the merge gate: unit tests plus the fmt, 100-column,
test-registration, refAllDecls-pairing and gate-coverage lint gates), green.

The new test covers the no-op, that the surviving seniority and address are
the pre-existing ones rather than the branch's, and that a forged id/key
pairing for a *present* member is still refused `BadJoin` - so the early
return cannot be used as a way around the live rule. The existing test
`re-slots validate like live entries` continues to assert `BadJoin` for a
forged re-slot of an absent member.

## Follow-up

`doMergeControl`'s order - `merge` entry first, branch re-slots after, with a
bare `try` - is what turns any re-slot refusal into an unrecoverable state.
Each refusing kind has been fixed one at a time (this report, and the two it
links). Making the re-slot loop able to fail without stranding the merge is
larger than any of them and is not attempted here.

## References

- Investigation: none
- Code: `src/cluster/membership.zig` (`applyJoinReslotted`, `applyJoin`),
  `src/cluster/node.zig` (`doMergeControl`)
- Related: [2026-08-29 - merge data re-slots refuse `settings`/`checkpoint`/`stale` records](2026-08-29-merge-data-reslot-refusals.md),
  [2026-08-28 - a re-slotted `create_journal` is always refused: the merge stalls](2026-08-28-reslotted-create-journal-refused.md)
- Fix: this commit
