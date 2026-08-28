# Bug — The simulator's `heal` discards losing-side messages still in inboxes

## TL;DR

- **What failed:** `heal` builds the losing branch from a side node's *folded* chain and then clears every node's inbox. A message broadcast by the losing leader that sits in a side-member's inbox (not yet folded) at heal time is silently dropped from the merged chain.
- **Impact:** Simulator-only: a scenario that appends on the losing side and calls `heal` without an intervening `tick` silently loses that message while still passing `assertConverged` (every node re-folds the same chain).
- **Resolution:** Still open. Statically validated.

## Status

Open.

## Symptom and impact

`heal` (`sim.zig:589-600`): the merged chain is built from `tailOf(side)` = `partition_sides[side].items[0]`'s chain (only *folded* messages, `sim.zig:604-607`); then every node's `inbox` is cleared (`:596`) and re-folded from the merged chain. A broadcast in flight (in an inbox, not yet folded — `slotAndBroadcast` applies only to the author, `sim.zig:299-324`) at heal time never makes it into the merged chain. No test currently hits it (all shipped scenarios `tick` before `heal`), and `assertConverged` cannot catch it (all nodes share the same merged chain).

## Reproduction

Not dynamically reproduced; statically certain. A scenario that appends on the losing side and calls `heal` without an intervening `tick` loses that message.

## Root cause

Heal snapshots the folded chains instead of draining pending inboxes; inbox messages are treated as if they had never been broadcast.

## Resolution

Not yet fixed. Suggested direction: fold each side's inboxes into the branch before building the merged chain (or refuse to heal with pending inboxes). A regression test should append on the losing side and `heal` immediately, then assert the entry resolves.

## Verification

- Static: `heal`/`tailOf`/`slotAndBroadcast` read; the inbox-clearing line (`sim.zig:596`) is the drop point.

## Follow-up

None. Simulator-fidelity issue only; the shipped scenarios are unaffected.

## References

- Code: `src/sim/sim.zig:589-600` (`heal`), `:604-607` (`tailOf`), `:299-324` (`slotAndBroadcast`)
- Fix: none
