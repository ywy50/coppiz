# Bug — `slotQueuedEntries` propagates a per-entry slot refusal to `fatal()`, stopping the whole node

## TL;DR

- **What failed:** `reforwardQueue` handles a per-entry slot failure by acking the refusal and continuing; `slotQueuedEntries` uses a bare `try`, so a refusal on one queued entry propagates to `onTick` → `fatal()` — the whole node stops.
- **Impact:** A single un-slotable queued entry (e.g. `TooLarge` after `max_entry_bytes` was lowered, or `DuplicateConflict` after a seq was consumed) kills the leader's loop.
- **Resolution:** Still open. Statically validated.

## Status

Open.

## Symptom and impact

`slotQueuedEntries` (`node.zig:979-1003`): the callback's `_ = try c.self.slotAndBroadcast(en, false)` (`:994`) propagates any refusal out of the queue scan → `onTick` (`:894`) → `catch self.fatal()` (`:608`). `reforwardQueue`'s equivalent branch catches and acks the refusal per entry (`:563-568`). The two queue-drain paths should treat per-entry refusals identically.

## Reproduction

Not dynamically reproduced; statically certain. A queued entry whose slot now refuses (settings changed while it sat queued, or an id already consumed) triggers it.

## Root cause

The two queue-drain paths disagree on error handling: one acks-and-continues, the other dies.

## Resolution

Not yet fixed. Suggested fix: mirror `reforwardQueue` — catch the refusal, ack the client, remove the entry, continue. A regression test should queue an entry that refuses at slot time and assert the node keeps running.

## Verification

- Static: `slotQueuedEntries` (`node.zig:979-1003`) vs `reforwardQueue` (`:552-575`) read; the `fatal` path (`:608`) confirmed.

## Follow-up

None. Low severity, but the failure mode (whole-node stop on one bad queued entry) is disproportionate.

## References

- Code: `src/cluster/node.zig:979-1003` (`slotQueuedEntries`), `:552-575` (`reforwardQueue`), `:608` (`fatal`)
- Fix: none
