# Bug — `ClusterNode.localAppend` completions are lost during backfill/merge: the embedded host's write blocks forever

## TL;DR

- **What failed:** When a follower's `localAppend` is forwarded while the member is backfilling (`syncing`) or merging, the completion is registered in `pending_locals` but no code path ever posts it: `onSlot` drops the broadcast under the sync guard, the sync-page apply never resolves `pending_locals`, and `reforwardQueue` removes the queued entry via `entryKnown` without completing. The host thread's `completion.sem.wait(io)` at `node.zig:383` blocks indefinitely.
- **Impact:** The embedded-host write path ([PRD 0005](docs/prds/0005-embedding-the-library-as-the-product.md)) deadlocks permanently for the natural "append right after join/startup" flow; wire clients hit the same gap (never acked).
- **Resolution:** Still open. Statically validated by enumerating every resolution site.

## Status

Resolved — `completePendingFor` resolves the embedded host's completion
and the wire client's ack on every path where the entry's slot lands:
the broadcast (`onSlot`), a sync page (`onSyncPage`), and the queue
sweeps' already-known skip (`slotQueuedEntries`/`reforwardQueue`).

## Symptom and impact

`localAppend` is the library's host-facing write API. Its contract (docstring at `node.zig:1335-1338`): "The completion is posted exactly once on every path — a refusal or the slotted entry id." That is false on the sync path. A host that appends during backfill (or during a merge) blocks forever with no timeout — there is no error return and no cancellation while the node runs.

## Reproduction

Not dynamically reproduced (the backfill window is timing-dependent and the hang is unbounded); statically complete. The full resolution-site enumeration:

- `pending_locals` is registered only at `node.zig:1374` (`onLocalAppend`, follower branch, after `sendForward`).
- It is resolved only at:
  - `node.zig:889-890` (`slotQueuedEntries`, leader slotting its own queue) — with an `entryKnown` skip at `:884` that returns without completing,
  - `node.zig:1654-1655` (`onSlot`) — **but only if the guard at `:1610` (`if (self.syncing or self.merging_from != null) return;`) did not already drop the whole broadcast**.
- The sync path (`onSyncPage` → `applyReplicated`, `node.zig:1756-1842`) never references `pending_locals` (grep-verified).
- `reforwardQueue` (`node.zig:436-477`) resolves only `pending_clients` (`:465-472`); and its `entryKnown` skip (`:459-461`) removes the queued entry from the durable queue **without** completing — the exact drop that seals the hang once the slot arrives via sync page.

Sequence: host calls `localAppend` while the member is backfilling → entry forwarded, completion in `pending_locals` → leader slots and broadcasts → follower's `onSlot` returns at the sync guard → the slot arrives later via `onSyncPage` (fold advances, completion untouched) → backfill ends, `reforwardQueue` sees the entry known and drops it from the queue → `pending_locals` entry leaks and the semaphore never posts. The same shape loses wire-client acks (`pending_clients`) during a leader-change re-forward (`reforwardQueue`'s `slotAndBroadcast` path acks only clients, `:464-472`).

## Root cause

The completion is tied to `onSlot`'s broadcast delivery, but broadcast delivery is intentionally suppressed while syncing/merging, and the substitute paths (sync pages, reforward) were not given the completion responsibility. The docstring's "posted exactly once on every path" is enforced by nothing.

## Resolution

Fixed. A new `ClusterNode.completePendingFor(en)` posts the wire client's
ack and the embedded host's completion for an entry of mine
(`en.author == member_id`), exactly once (fetchRemove is idempotent). It
replaces the duplicated block in `onSlot` and is additionally called:
after `applyReplicated` in `onSyncPage` (the sync-guard'd broadcast was
dropped, so this apply is what must post), and in `slotQueuedEntries`
and `reforwardQueue` when the entry is already known and the queue entry
is dropped. The docstring's "posted exactly once on every path" now
holds.

The follow-up crash (`leaderConnId` null-deref on a chainless joiner)
was left as-is — it is on the same path but was not part of this defect.
A deterministic regression test is not practical (the backfill window is
timing-dependent, and the hang is unbounded); the resolution sites were
enumerated and each now resolves, matching the report's static
completeness argument.

## Verification

- Static: complete enumeration above; `pending_locals` has exactly two resolution sites, one of which is unreachable under the sync guard; the sync/reforward paths touch neither. Grep-verified across `node.zig`.

## Follow-up

Related crash on the same path: `leaderConnId` (`node.zig:1567`) does `self.node.control.epoch.?` with no null guard — a chainless joiner appending to `__cluster__` before its first sync page panics the loop. Worth covering in the same fix.

## References

- Code: `src/cluster/node.zig:370-386` (`localAppend`), `:1339-1378` (`onLocalAppend`), `:1605-1658` (`onSlot` + sync guard), `:1756-1842` (`onSyncPage`), `:436-477` (`reforwardQueue`), `:876-894` (`slotQueuedEntries`)
- Fix: `src/cluster/node.zig` (`completePendingFor`; `onSlot`, `onSyncPage`, `reforwardQueue`, `slotQueuedEntries`). `zig build test` green, including the embedded-host example tests.
