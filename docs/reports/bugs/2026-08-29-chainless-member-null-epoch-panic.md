# Bug - a chainless member panics on a peer's control record: the fold unwraps a null epoch

## TL;DR

- **What failed:** `FoldState.applyControl` and `applyControlReslotted` read `self.epoch.?.leader` after a journal-id check that a chainless member passes, so a control record other than a genesis reached a null unwrap. `Node.epoch()` had the same unguarded `.?` on the whole write path.
- **Impact:** A member that holds `member.key` but has not folded a genesis yet - every joiner before backfill - aborts on a control record any peer can send, before any signature is checked.
- **Resolution:** Fixed - both folds refuse with `no_epoch`, and `Node.epoch()` returns an optional exactly as `Node.leader()` does.

## Status

Resolved.

## Symptom and impact

A chainless member's control fold has `journal_id = [16]u8{0}` and
`epoch = null`; `Node.open` succeeds in that state, because `foldAll` returns
early and zeroes the journal id. `Node.applyReplicated` routes a record into
the control fold when its journal id equals the control fold's:

```zig
const control_unset = std.mem.eql(u8, &self.control.journal_id, &([_]u8{0} ** 16));
const is_control = std.mem.eql(u8, &journal_id, &self.control.journal_id) or
    (control_unset and en.kind == .genesis);
```

A record whose `journal` field is all zeros satisfies the first clause. In
`applyControl`, `checkChainContinuity` then passes (no head, `seq == 1`,
`prev_slot_hash` all zeros), the journal-id equality on the next line passes
(zeros equal zeros), and the following line is:

```zig
const leader = self.epoch.?.leader;
```

which aborts with "attempt to use null value". `applyControlReslotted` has the
same line with the same reachability. Nothing has verified a signature at that
point, so the record costs the sender nothing.

`Node.leader()` was hardened for exactly this state
([2026-08-28-sweep3-cmdadmit-chainless-panic](2026-08-28-sweep3-cmdadmit-chainless-panic.md))
and carries a comment saying so. `Node.epoch()` was not:

```zig
pub fn epoch(self: *const Node) u64 {
    return self.control.epoch.?.number;
}
```

`slotFor` calls it unconditionally, so `append`, `appendControl`,
`checkpointForBroadcast` and `replayQueue` all abort rather than erroring on
a member with a queue and no epoch.

## Reproduction

The regression tests added with the fix:

- `chain.zig` - "a control record offered to a fold with no epoch is refused,
  not a null unwrap": builds a fresh control `FoldState`, offers a non-genesis
  control record whose journal id is all zeros, and expects `error.NoEpoch`.
- `journal.zig` - the same shape through `Node.applyReplicated` on a node
  opened over a directory holding only `member.key`.

Both abort on the unfixed fold.

## Root cause

The genesis is the only control entry that may fold into an epoch-less chain,
and it is short-circuited at the top of `applyControl`. Everything after that
point assumed an epoch exists because in a healthy chain it does; the
zero-journal-id coincidence is what makes the assumption reachable.

## Resolution

Both folds bind the epoch through `orelse return error.NoEpoch` before using
it, and a new `NoEpoch` refusal (`no_epoch`) joins the `Refusal` set and
`refusalName`. `Node.epoch()` returns `?u64`; `slotFor` turns the absent case
into `error.NoEpoch` instead of a panic. The only caller of `Node.epoch()` in
the tree is `slotFor`.

## Verification

- `zig build test` green on the branch.
- Both regression tests abort on the unfixed code with "attempt to use null
  value" and return the named refusal after the fix.

## Follow-up

`applyControlReslotted`'s `.genesis => return error.BadGenesis` arm was
unreachable before this change, because the null unwrap fired first. It is
reachable now.

## References

- Investigation: none
- Code: `src/journal/chain.zig` (`applyControl`, `applyControlReslotted`,
  `Refusal`, `refusalName`), `src/journal/journal.zig` (`epoch`, `slotFor`)
- Related: [2026-08-28-sweep3-cmdadmit-chainless-panic](2026-08-28-sweep3-cmdadmit-chainless-panic.md),
  [2026-08-28-sweep3-joiner-syncing-race](2026-08-28-sweep3-joiner-syncing-race.md)
