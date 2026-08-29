# Bug - The simulator's `heal` truncates a side's post-crash branch when the side leader crashed mid-partition

## TL;DR

- **What failed:** `sideLeader`/`tailOf` use the partition set's *first* node without checking `alive`. If that node is a crashed leader, its frozen chain is used both to name the survivor and to build the merged branch - the side's post-crash writes (and its new epoch) are silently dropped, and the result depends on the index order inside the set.
- **Impact:** Simulator-only, but a harness invariant violation: a scenario combining `partition` → leader `crash` → side re-elects and writes → `heal` silently loses the surviving side's branch. No in-tree test exercises it.
- **Resolution:** Still open. Statically validated.

## Status

Resolved.

## Symptom and impact

`sideLeader` (`sim.zig:493-502`) returns the fold-named leader of the set's
first node regardless of `alive`; `tailOf` (`:604-607`) slices that same
first node's `chain`, frozen at its crash point. Scenario: partition `{A,B}
| {C}`; A (leader) writes, crashes; B elects itself (epoch 2) and writes. At
`heal`: `sideLeader(0)` returns the crashed A as survivor; `tailOf(0)` slices
A's chain `[common..]`, missing B's epoch-2 entry and post-crash writes. The
merged chain (common + A's partial branch + merge + re-slots) re-folds
cleanly on every live node (A is still a member; `checkChainContinuity`
holds), so the heal *succeeds* - with the surviving side's branch permanently
truncated.

Listing the set as `{B,A}` instead yields the correct heal: the
outcome depends on set order.

## Reproduction

Not dynamically reproduced; statically certain. `partition` → `crash(leader)` → side re-elects and appends → `heal`, with no intervening tick that would fold the broadcasts.

## Root cause

The survivor/branch selection reads the first-listed node's state without an `alive` check; a crashed node's chain is not the side's live chain.

## Resolution

Fixed: `sideLeader`/`tailOf` use the first live node of a side, so a crashed leader's frozen chain no longer names the survivor or builds the merged branch; regression test added.

## Verification

- Static: `sideLeader` (`sim.zig:493-502`), `tailOf` (`:604-607`), and the merged-chain construction (`:552-557`) read.

## Follow-up

Related simulator defect reported separately (2026-08-29-sim-heal-drops-inbox): both are heal-time silent-loss paths.

## References

- Code: `src/sim/sim.zig:493-502` (`sideLeader`), `:552-557`, `:589-600` (`heal`), `:604-607` (`tailOf`)
- Fix: none
