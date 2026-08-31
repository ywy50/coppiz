# Bug - `slotQueuedEntries` propagates a per-entry slot refusal to `fatal()`, stopping the whole node

## TL;DR

- **What failed:** `reforwardQueue` handles a per-entry slot failure by acking the refusal and continuing; `slotQueuedEntries` uses a bare `try`, so a refusal on one queued entry propagates to `onTick` → `fatal()` - the whole node stops.
- **Impact:** A single un-slotable queued entry (e.g. `TooLarge` after `max_entry_bytes` was lowered, or `DuplicateConflict` after a seq was consumed) kills the leader's loop.
- **Resolution:** Fixed 2026-08-31. This record was marked Resolved on 2026-08-29 while the defect was still in the tree - see *Correction*.

## Status

Resolved.

## Symptom and impact

`slotQueuedEntries` (`node.zig:979-1003` as of 2026-08-28): the callback's `_ = try c.self.slotAndBroadcast(en, false)` (`:994`) propagates any refusal out of the queue scan → `onTick` (`:894`) → `catch self.fatal()` (`:608`). `reforwardQueue`'s equivalent branch catches and acks the refusal per entry (`:563-568`). The two queue-drain paths should treat per-entry refusals identically.

## Reproduction

Original record (2026-08-28): not dynamically reproduced; statically certain. A queued entry whose slot now refuses (settings changed while it sat queued, or an id already consumed) triggers it.

Reproduced dynamically 2026-08-31 by the regression test named under *Verification*: a solo founder (the epoch-1 leader out of genesis) with an entry in the durable queue naming a journal id it has no fold for. `slotAndBroadcast` refuses it with `UnknownJournal` on every sweep. Before the fix, `slotQueuedEntries` returned that error - the exact value `onTick` hands to `fatal()`:

```
error: 'cluster.node.test.one un-slotable queued entry refuses that entry, not the whole node' failed:
  src/cluster/node.zig:2091 in slotAndBroadcast
      const fold = self.foldFor(en.journal) orelse return error.UnknownJournal;
  src/cluster/node.zig:1341 in cb
      _ = try c.self.slotAndBroadcast(en, false);
  src/journal/queue.zig:181 in scan
  src/cluster/node.zig:1331 in slotQueuedEntries
```

## Root cause

The two queue-drain paths disagree on error handling: one acks-and-continues, the other dies.

## Resolution

`slotQueuedEntries` now mirrors `reforwardQueue`: on a per-entry refusal it removes the entry's `pending_clients` / `pending_locals` waiter, answers it with `clientRefusalName(err)`, and returns from the scan callback so the sweep continues with the next queued entry. The entry stays in the durable queue, exactly as `reforwardQueue` leaves it - the refusal may be transient (a lowered `max_entry_bytes` can be raised again), and dropping acknowledged-but-unslotted entries is a separate decision.

## Correction

The `## Status` and `## Resolution` sections of this record were changed from `Open.` / "Not yet fixed. Suggested fix: mirror `reforwardQueue` …" to `Resolved.` / "Fixed: `slotQueuedEntries` acks waiters and continues on a per-entry slot refusal instead of propagating it to `fatal()`." by commit `8893ae1` ("docs(reports): mark the sweep fixes resolved (#116)", 2026-08-29), a docs-only commit in a stack of 29 status updates. No such code change existed then or at any point before 2026-08-31:

- `git log --all -S'slotQueuedEntries' -- src/cluster/node.zig` names two commits, `51caeb0` (which introduced the function) and `f401606` (the sweep fix). `git show f401606 -- src/cluster/node.zig` touches `completePendingFor`, for a different bug (`2026-08-28-localappend-completion-lost`); it does not touch the `try`.
- On `9765d30`, `src/cluster/node.zig:1341` still read `_ = try c.self.slotAndBroadcast(en, false);`.

The original TL;DR line ("**Resolution:** Still open. Statically validated.") and the original `## Verification` were left in place by that commit, which is what made the record self-contradictory and how the drift was caught. The evidence above is kept rather than rewritten; the sections now describe the fix that is actually in the tree.

## Verification

- Static (2026-08-28): `slotQueuedEntries` (`node.zig:979-1003`) vs `reforwardQueue` (`:552-575`) read; the `fatal` path (`:608`) confirmed.
- Regression test (2026-08-31): `cluster.node.test."one un-slotable queued entry refuses that entry, not the whole node"`. It queues the refusing entry with a `pending_locals` waiter, queues a slotable entry behind it, and calls `slotQueuedEntries` directly. Observed failing on `9765d30` with the trace quoted under *Reproduction*; passing after the fix, with the refused entry's waiter answered `unknown_journal` and the entry behind it in the fold - so the sweep continues rather than merely swallowing the error.
- `zig build test --summary all` green; the `Build Summary` line is in the pull request.

## Follow-up

None for this defect. The correction above is the second instance of a report's `## Status` moving ahead of the tree; there is no tooling that ties a report's status to a commit ([RFC 0035](../../rfcs/0035-record-store-tooling.md) is where that would go).

## References

- Investigation: none
- Code: `src/cluster/node.zig` (`slotQueuedEntries`, `reforwardQueue`, `fatal`)
- Fix: this change
- Mis-marked by: `8893ae1`
