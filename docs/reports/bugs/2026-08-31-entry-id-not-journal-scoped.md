# Bug - two journals share entry ids, so one member's pending acks and completions collide

## TL;DR

- **What failed:** `author_seq` is a per-(author, journal) counter, so an entry id `(author, author_seq)` repeats across journals. `ClusterNode`'s `pending_clients` and `pending_locals` were keyed on it alone, and `positionOf` walked every fold with it.
- **Impact:** A member appending to two journals with no reachable leader overwrote the first journal's waiter with the second's: one embedded host thread blocked until shutdown, and the other woke naming the wrong entry. For a wire client the same collision sends one connection's ack to the other's `conn_id`, or drops it.
- **Resolution:** Fixed 2026-08-31: both maps and the position lookup key on `entry.ScopedId` = `(journal, id)`.

## Status

Resolved.

## Symptom and impact

`author_seq` is "the author's per-journal counter" ([glossary](../../glossary.md)), a "dense per-(author, journal) counter, starts at 1" ([PRD 0001](../../prds/0001-journal-core.md), the entry header table). `ClusterNode.nextAuthorSeq` implements exactly that - the floor comes from the target journal's fold and `my_seq` is keyed by journal id - so a member's first entry in every journal it writes to, the control journal included, is `(author, 1)`.

Three places used the bare id where the scope is the member, not one chain:

- `pending_locals: AutoHashMapUnmanaged(entry.Id, *LocalCompletion)` - an embedded host's `localAppend` parked while the entry is forwarded to a leader.
- `pending_clients: AutoHashMapUnmanaged(entry.Id, u64)` - a wire client's connection, parked the same way.
- `positionOf(id)`, which returned the first match while walking the control fold and then every data fold, and supplies the `position` field of every `ack`.

`onLocalAppend`'s follower branch does `self.pending_locals.put(self.allocator, en.id(), a.completion)`. A `put` on a key already present replaces the value, so the second journal's append silently dropped the first journal's completion pointer. Nothing ever posts to it again: `completePendingFor` (and the two queue-drain sweeps) remove by the same key, so the slot that folds back for journal A resolves whichever waiter is under `(author, 1)` - the journal B one - handing it journal A's entry id, and the journal A host stays parked until `releaseLocalWaiters` answers it `shutdown` at deinit. `onAppend` does the same with `pending_clients`, so the ack goes to the other client's `conn_id`.

Everything under `src/journal/` that keys on an entry id is inside one journal's `FoldState`, which is the identity wanted there; those uses are correct and unchanged.

## Reproduction

Preconditions: one member, two data journals, and a fold naming a leader it cannot reach, so both appends park rather than slotting.

1. Found a solo node ("main" from `journal.init`), then `node.createJournal("other", &.{})`.
2. Point the fold's epoch at another member id. `isLeader()` is then false while `electsNobody()` stays false (mode `seniority` always elects among the live members), which is the state that holds two waiters at once.
3. `onLocalAppend` for "main", then for "other", each with its own `LocalCompletion`.

Expected: two parked waiters, neither posted. Actual, before the fix: one.

```
error: 'cluster.node.test.two journals' appends by one author do not share a pending-completion key' failed:
       expected 2, found 1
       src/cluster/node.zig: try std.testing.expectEqual(@as(usize, 2), cn.pending_locals.count());
```

## Root cause

An entry id names an entry within a journal. `entry.zig`'s doc comment said "stable forever - across merges and restarts", which is true and was read as "unique", which it is not. The two maps live on `ClusterNode`, whose scope is every journal the member holds, so they needed the journal in the key from the start.

## Resolution

`entry.ScopedId` = `{ journal: [16]u8, id: Id }`, with `Entry.scopedId()` to build one, and `Id`'s doc comment now states the per-journal limit and points at it. `pending_clients` and `pending_locals` are keyed on it; every `put` and `fetchRemove` goes through `en.scopedId()`. `ackClient` takes `?entry.ScopedId` and `positionOf` takes one, looking the id up in that journal's fold only instead of walking all of them.

Nothing on the wire or on disk changes: the `ack` message still carries the bare id (the request it answers named the journal), and no encoded format contains an id without its journal beside it.

## Verification

- `cluster.node.test."two journals' appends by one author do not share a pending-completion key"`, the reproduction above. Observed failing on `1f99e60` with `expected 2, found 1`. After the fix both waiters are parked and unposted, and `completePendingFor` for an entry in "main" posts the "main" waiter only, leaving the "other" waiter parked - so the fix routes rather than merely counting.
- The same test pins the `positionOf` half: nothing is slotted in "main", so `positionOf({main, (author, 1)})` is `(0, 0)`, and the test also asserts the control fold *does* hold `(author, 1)` - which is what the replaced bare-id walk would have answered with, since it checked the control fold first.
- Not reproduced: a wrong non-zero position from the old walk. That needs two chains at different depths, and in a single-author cluster `position.seq` advances in lockstep with `author_seq` in every chain, so the colliding ids sit at equal positions. The `pending_clients` collision is likewise argued from the shared code path rather than separately reproduced - `onAppend`'s follower branch is line-for-line `onLocalAppend`'s.
- `zig build test --summary all` green; the `Build Summary` line is in the pull request.

## Follow-up

None. The remaining `entry.Id` maps (`chain.FoldState.entries`, the store's compaction `removed` set, `expiry`) are all per-journal and were checked.

## References

- Investigation: none
- Code: `src/journal/entry.zig` (`Id`, `ScopedId`, `Entry.scopedId`), `src/cluster/node.zig` (`pending_clients`, `pending_locals`, `ackClient`, `positionOf`, `completePendingFor`, `onLocalAppend`, `onAppend`)
- PRD: [PRD 0001](../../prds/0001-journal-core.md) (the `author_seq` header field)
- Fix: this change
