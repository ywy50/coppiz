# Bug - The `freshest` tiebreak is dead in the node: every member's `last_ack` is the node's own head, and the node/simulator merge survivors can disagree

## TL;DR

- **What failed:** `viewsFor` sets `last_ack = self.node.control.head` for *every* member (peers included), so under `combined`/`freshest` all members compare equal and the tiebreak always falls to seniority. The heartbeat carries a real `last_ack` that the sender populates and the receiver drops. The merge survivor path (`viewOf`) feeds the node's own head as both branches' `last_ack`.
- **Impact:** `tiebreak = freshest` never elects the more complete authority; and because the simulator computes survivors from per-branch heads, the node and the simulator can pick different survivors for the same two branches - breaking the deterministic-merge invariant between the two implementations.
- **Resolution:** Still open. Statically validated.

## Status

Open.

## Symptom and impact

`election.View.last_ack` is documented as the member's own verified head for `tiebreak = freshest` (`election.zig`). The node fills it with its own head for everyone (`viewsFor`, `node.zig:2588`), so the freshest authority never wins. `sendHeartbeat` populates the wire `last_ack` with the sender's head (`node.zig:1149`; field at `message.zig:434-452`) but `onHeartbeat` never reads it (`node.zig:1862-1878`) - the field is written, transmitted, and dropped, strong evidence the per-member wiring was intended and lost. The merge path has the same defect: `viewOf` (`node.zig:2202-2215`) feeds the node's own head as *both* branch leaders' `last_ack`, while the simulator's `branchOf`/`viewsFor` use each branch's own head (`sim.zig:667, 379`).

## Reproduction

Not dynamically reproduced; statically certain. `leadership.mode = combined`, `tiebreak = freshest`, authorities at different heads (a lagging authority follower): the node ranks by seniority; a member with a *more complete* chain loses an election it should win, and `survivorVs` can disagree with the simulator's survivor for the same branches.

## Root cause

The per-member `last_ack` plumbing exists (view field, wire field, sender side) but the receiver/view-construction side was never wired.

## Resolution

Not yet fixed. Suggested direction: track each member's head from heartbeats (`onHeartbeat` should store `hb.last_ack` on the member state) and use it in `viewsFor`/`viewOf`. A regression test should run `combined`+`freshest` with a lagging authority and assert the fresher one leads, and that the node's survivor matches the simulator's for the same branch pair.

## Verification

- Static: `viewsFor` (`:2571-2592`), `viewOf` (`:2202-2215`), `sendHeartbeat` (`:1149`), `onHeartbeat` (`:1862-1878`) read; simulator's per-member heads (`sim.zig:362-373, 667`) read as the intended semantics.

## Follow-up

None beyond the fix. Deterministic-merge divergence between the node and the simulator is the highest-value consequence (the simulator is the merge rule's reference implementation).

## References

- Code: `src/cluster/node.zig:2571-2592` (`viewsFor`), `:2202-2215` (`viewOf`), `:1149` (`sendHeartbeat`), `:1862-1878` (`onHeartbeat`), `src/sim/sim.zig:362-373, 667`
- Fix: none
