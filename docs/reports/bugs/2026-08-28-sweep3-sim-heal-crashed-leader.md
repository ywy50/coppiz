# Bug - The simulator's `heal` truncates a side's post-crash branch when the side leader crashed mid-partition

## TL;DR

- **What failed:** `sideLeader`/`tailOf` use the partition set's *first* node without checking `alive`. If that node is a crashed leader, its frozen chain is used both to name the survivor and to build the merged branch - the side's post-crash writes (and its new epoch) are silently dropped, and the result depends on the index order inside the set.
- **Impact:** Simulator-only, but a harness invariant violation: a scenario combining `partition` → leader `crash` → side re-elects and writes → `heal` silently loses the surviving side's branch. No in-tree test exercises it.
- **Resolution:** **Resolved 2026-08-31, after a false resolution on 2026-08-29.** The 2026-08-29 record claimed a fix that no commit ever contained; the defect was live until now. It is now fixed for real, with a regression test that was seen to fail on the parent commit.

## Status

Resolved 2026-08-31, after a false resolution on 2026-08-29.

Reopened and fixed in the same change. The record had been marked `Resolved`
on 2026-08-29 while its own TL;DR still read "Still open" and its References
still read "Fix: none", and the fix it described was not in the tree. See
*Reopened - what was checked* for the evidence and *Resolution* for what
actually shipped.

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

Originally recorded as: not dynamically reproduced; statically certain.
`partition` → `crash(leader)` → side re-elects and appends → `heal`, with no
intervening tick that would fold the broadcasts.

Now reproduced dynamically. The regression test
`sim.sim.test."heal reads a side's branch from a live node, not a crashed
leader"` builds exactly that scenario over three members and asserts the
surviving side's post-crash write resolves after the heal. On the parent
commit (`9765d30`) it fails at the post-heal
`entryResolves(b, b_write_id)` with `TestUnexpectedResult`: the same
assertion passes *before* `heal`, `heal` itself returns without error, and
`assertConverged` passes - so the failure is the silent truncation the report
describes, not a crash or a divergence.

## Root cause

The survivor/branch selection reads the first-listed node's state without an `alive` check; a crashed node's chain is not the side's live chain.

## Reopened - what was checked

Checked at `9765d30` (2026-08-31), by reading and by search:

- `sideLeader` and `tailOf` in `src/sim/sim.zig` still read
  `partition_sides[side].items[0]` with no `alive` check - the exact shape
  this report describes. No `alive` test, and no live-node helper, exists on
  either path.
- `grep -rn 'firstLive' src/` matches nothing, and
  `git log --all -S firstLive -- src/sim/sim.zig` returns no commit, so no
  such helper was added and later removed either.
- The commit that set `Status: Resolved` here is `8893ae1`
  ("docs(reports): mark the sweep fixes resolved (#116)"). `git show --stat
  8893ae1` lists **29 report files and no source file at all**: it changed
  four lines in this record (Status and Resolution) and touched nothing under
  `src/`.
- Of the eight commits touching `src/sim/sim.zig` between `8893ae1` and
  `9765d30`, none changes `sideLeader`, `tailOf` or the branch construction
  in `heal`.

So the *Resolution* recorded on 2026-08-29 describes work that was not done.
It is kept verbatim below rather than deleted, because the record's value now
includes knowing that it was wrong: a `Resolved` row in the inventory hides
live work exactly as effectively as a missing row would.

What is *not* claimed here: why the record said otherwise. It may have
described an intended change, or a change that was reverted; no attempt was
made to reconstruct that, and the reader should not infer one.

## Resolution (as recorded 2026-08-29 - not implemented)

Fixed: `sideLeader`/`tailOf` use the first live node of a side, so a crashed leader's frozen chain no longer names the survivor or builds the merged branch; regression test added.

## Resolution

Fixed 2026-08-31. A new `World.firstLiveOn(side)` returns the first `alive`
node listed on a side, and both readers go through it:

- `sideLeader` reads the side's folded leader from that live node instead of
  from `items[0]`, so a crashed leader's frozen fold no longer names the
  survivor. The membership check (the named leader must itself be on this
  side) is unchanged.
- `tailOf` slices that live node's chain, so the merged branch is the side's
  live branch. A side with no live node left returns an empty tail - it
  contributes no branch, which matches `heal` re-folding only live nodes.

`commonPrefixLen` and `heal`'s `common_len` still read
`nodes.items[0].chain`; that was left alone deliberately. Both filter by slot
*position* against `partition_head` rather than by length, so a node that
crashed mid-partition (holding common prefix plus part of a branch) still
yields the correct count. This was not changed and is not claimed as fixed.

## Verification

- Static, original: `sideLeader` (`sim.zig:493-502`), `tailOf` (`:604-607`),
  and the merged-chain construction (`:552-557`) read.
- Static, 2026-08-31: the search and re-read recorded above.
- Dynamic, 2026-08-31: regression test "heal reads a side's branch from a
  live node, not a crashed leader" (`src/sim/sim.zig`). Seen to fail on the
  parent `9765d30` at the post-heal `entryResolves` and to pass with the fix.
- Full `zig build test --summary all` green - see the resolving PR for the
  quoted `Build Summary` line.

## Follow-up

Related simulator defect reported separately (2026-08-29-sim-heal-drops-inbox): both are heal-time silent-loss paths. That record carries the same false-resolution pattern and is being corrected the same way.

The general lesson is not simulator-specific: `8893ae1` flipped 29 reports to
`Resolved` in one docs-only commit. A `Status` line is a claim about the tree,
and the only thing that settles it is a search of the tree.

## References

- Code: `src/sim/sim.zig` (`sideLeader`, `firstLiveOn`, `heal`, `tailOf`)
- False resolution: `8893ae1` (docs-only, 29 reports)
- Fix: this report's resolving commit
