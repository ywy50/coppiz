# Bug - `reforwardQueue`'s leader-slot branches never complete `pending_locals`: an embedded host's `localAppend` hangs forever on election

## TL;DR

- **What failed:** When a queued local entry is slotted by the newly-elected leader, `reforwardQueue`'s leader branches ack only `pending_clients` and never touch `pending_locals`; `applyReplicated` then trims the queue, so no later site (`onSlot`, `onSyncPage`, `slotQueuedEntries`) ever sees the id again. The host's `completion.sem.wait` never returns.
- **Impact:** The embedded-host write API ([PRD 0005](../../prds/0005-embedding-the-library-as-the-product.md)) deadlocks permanently when a host appends while this member is a leaderless follower and the member is then elected.
- **Resolution:** Still open. Statically validated (incomplete fix of `2026-08-28-localappend-completion-lost`).

## Status

Resolved. Regression window introduced by `f401606` (the sweep-1 fix added `completePendingFor` to the *known*-entry branch of `reforwardQueue` but not to its two leader-slot branches).

## Symptom and impact

A host thread blocked forever in `localAppend` with no timeout and no error - the entry is durably queued and eventually slotted (replicated), but the caller is never told. The wire-client sibling is handled (acked); only the embedded-host path leaks.

## Reproduction

Not dynamically reproduced (needs a leaderless window + an election); statically complete. The relevant ordering, verified in `node.zig`:

1. Member is a follower with no reachable leader; host calls `localAppend` → `onLocalAppend` (follower branch) queues the entry, registers the completion in `pending_locals`, `sendForward` no-ops (`node.zig:1726-1729`).
2. The member is elected: `onTick` → `runElection` → `appendEpoch` → **`reforwardQueue()`** (`node.zig:1721`) runs *before* `slotQueuedEntries` (`node.zig:894`).
3. `reforwardQueue`'s leader branch (`node.zig:562-571`) finds the entry unknown, `slotAndBroadcast`s it, and acks **only** `pending_clients` (`:564-571`). `pending_locals` is untouched.
4. `applyReplicated` (inside `slotAndBroadcast`) trims the queue; `slotQueuedEntries` (`:979-1003`) - which *does* complete `pending_locals` (`:998-1000`) - never sees the entry.

Contrast the already-fixed sibling: the entry-known branch (`:553-561`) calls `completePendingFor` (`:1848-1856`, resolves both), and `slotQueuedEntries`' known branch does too (`:987-993`). Only the two leader-slot branches of `reforwardQueue` were missed.

## Root cause

The `f401606` fix enumerated the completion sites (`onSlot`, `onSyncPage`, `slotQueuedEntries`, `reforwardQueue`-known-branch) but not the two error/success branches that slot the entry as leader. `completePendingFor` is the single correct primitive and is already in scope.

## Resolution

Fixed: `reforwardQueue`'s leader-slot branches resolve `pending_locals` — `completePendingFor` on success and the refusal name on error — so an embedded host's `localAppend` no longer hangs when its entry is slotted by a newly-elected leader.

## Verification

- Static: all four `reforwardQueue` branches read; `completePendingFor` and `slotQueuedEntries` read as the correct pattern; the `appendEpoch`-before-`slotQueuedEntries` ordering verified in `onTick` (`:889-894`).

## Follow-up

None beyond the fix.

## References

- Code: `src/cluster/node.zig:552-575` (`reforwardQueue`), `:1721` (`appendEpoch`), `:894` (`slotQueuedEntries` call), `:1848-1856` (`completePendingFor`), `:979-1003` (`slotQueuedEntries`)
- Fix: none
