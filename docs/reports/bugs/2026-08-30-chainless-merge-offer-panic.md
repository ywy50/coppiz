# Bug - one `merge_offer` frame aborts a member that has not finished its first backfill

## TL;DR

- **What failed:** `survivorVs` unwrapped `control.epoch.?`. `onDivergence`
  guards that unwrap; `onMergeOffer` does not.
- **Impact:** a chainless member - the state every joiner is in between
  admission and its first sync page - aborts on a single `merge_offer` frame
  from any connection whose hello completed.
- **Resolution:** fixed. `survivorVs` returns `null` when this member has no
  chain, which the callers already treat as "drop the connection".

## Status

Resolved. Found by reading `src/cluster/node.zig`; no investigation record.

## Symptom and impact

`survivorVs` answers "which branch survives, mine or the peer's", and its
first act is to read this member's current leader:

```zig
fn survivorVs(self: *ClusterNode, peer_leader: [16]u8) ?epoch.Winner {
    const inputs = self.electionInputs();
    const my_leader = self.node.control.epoch.?.leader;
```

`control.epoch` is `null` for a member that has folded nothing. That is not
an exotic state: a joiner's data directory holds `member.key` and no chain
until its backfill delivers one, which is why `runElection` opens with
`if (fold.epoch == null) return; // no chain yet`, why `driveBackfill`
refuses to clear `syncing` while `control.head == null`, and why
`Node.epoch()` returns an optional at all
([2026-08-29 - a chainless member panics on a peer's control
record](2026-08-29-chainless-member-null-epoch-panic.md)).

`survivorVs` has two callers. `onDivergence` guards the unwrap:

```zig
if (self.node.control.epoch == null) return;
```

`onMergeOffer` has no such guard, and it is reachable from the wire:
`frameAllowed` admits `.merge_offer` on any connection with `role ==
.member`, which is every connection whose hello or hello_ack completed. A
joiner dials a member, completes the handshake, and is then one 32-byte
frame away from aborting - before it has folded a single record, and
therefore before any of the chain's own validation can weigh in.

`becomeLoser` carried the same unwrap. It was not reachable with a null
epoch (its `onMergeOffer` path goes through `survivorVs` first, and its
`onDivergence` path is guarded), but it is one line from the same trap.

## Reproduction

`a chainless member drops a peer's merge_offer instead of aborting` in
`src/cluster/node.zig`. It builds a joiner's directory - `member.key`
written, `journal.init` deliberately not called - opens the node, asserts
`node.epoch() == null`, and hands `onMergeOffer` an offer on a connection.

Before the fix:

```
error: 'cluster.node.test.a chainless member drops a peer's merge_offer
instead of aborting' terminated with signal ABRT with stderr:
       thread 7270699 panic: attempt to use null value
       src/cluster/node.zig:2480:50: in survivorVs
           const my_leader = self.node.control.epoch.?.leader;
       src/cluster/node.zig:2453:39: in onMergeOffer
```

After the fix the offer is dropped, the connection is closed, and the test
asserts no merge state was entered and the chain is still empty.

## Root cause

The guard was written at one call site instead of in the function that needs
it. `survivorVs` already returns `?Winner` and already uses `null` to mean
"I cannot rank this - drop the connection" (the forged-branch-leader case),
so the missing precondition had an existing, correct expression; it just was
not used for this one.

## Resolution

`survivorVs` takes `control.epoch` with `orelse return null`. Both callers
already handle `null` by closing the connection, which is the right response
to a merge offer aimed at a member with nothing to merge. `becomeLoser` gets
the same guard as `orelse return`, so neither entry point unwraps.

## Verification

- The new test aborts with `panic: attempt to use null value` at
  `survivorVs` before the change and passes after.
- `zig build test` green on the branch.

## Follow-up

The wider question - whether replication frames should be admitted at all
before a member has a chain, rather than being made individually safe - is
not settled here. Each such site has been fixed as it was found; this is the
third (`Node.epoch`, `applyControl`, now `survivorVs`).

## References

- Code: `src/cluster/node.zig` (`survivorVs`, `onMergeOffer`, `becomeLoser`)
- Related: [2026-08-29 - a chainless member panics on a peer's control
  record](2026-08-29-chainless-member-null-epoch-panic.md), the same class at
  different sites
- Fix: this PR
