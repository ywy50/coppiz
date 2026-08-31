# Bug - A hello landing on a non-leader is answered "admitted", then the join is refused and the connection closed: the joiner retries forever

## TL;DR

- **What failed:** `onHello` sends `hello_ack` with `admitted = true` *before* `admitNewcomer` authors the join - locally, as the receiving member. A follower admitter's join slot is refused by the fold (`NotLeader`: the slot's leader is not the epoch's leader), the error closes the connection, and the joiner, which was already told it was admitted, redials the same follower forever.
- **Impact:** A joiner whose only reachable peer is a follower (leader down at join time, or a single-peer config pointing at a follower) can never join - silently, permanently.
- **Resolution:** **Resolved 2026-08-31, after a false resolution on 2026-08-29.** The 2026-08-29 record claimed a fix no commit ever contained - `admitNewcomer` still slotted locally and `onForward` refused every non-`data` kind. It is now fixed for real, with the failure reproduced end to end first.

## Status

Resolved 2026-08-31, after a false resolution on 2026-08-29.

Reopened and fixed in the same change. `8893ae1`
("docs(reports): mark the sweep fixes resolved (#116)") flipped this record
to `Resolved` in a commit that touched 29 report files and no source file;
the record's own TL;DR still read "Still open" and its References still read
`Fix: none`. See *Reopened - what was checked* for the evidence and
*Resolution* for what actually shipped, including one deliberate narrowing of
PRD 0003's admission rule.

## Symptom and impact

`onHello` (`node.zig:1246-1298`): admission ack is sent at `:1267`, then for
a newcomer the member is inserted (`:1289-1295`) and `admitNewcomer` runs
(`:1296`). `admitNewcomer` (`:1367-1382`) calls `authorControl(.join,
payload)` - the join is slotted *as the admitter* (its own key, `sl.leader =
self.member_id`).

    `applyControl` refuses any slot whose leader is not the
current epoch's leader (`chain.zig:329`), so a follower admitter's join never
folds; the `NotLeader` error propagates out of `onHello` → `onFrame`'s catch
closes the conn (`node.zig:619`). The joiner already got an admitted ack; its
seed retry redials the same follower on a 250 ms → 8 s backoff forever, and
`syncPeerConn` finds only the dead peer, so it stays `syncing` indefinitely.

Both sides then also dial each other in a closed failure loop.

The intent is explicit: "the fold admits any member, so whoever received the hello admits - PRD 0003 *Admission*" (`:1365-1366`) and "an existing member - the admitter, normally the leader - writes it" (PRD 0003). A follower admitter is supposed to work; the local slotting makes it fail, and nothing forwards the hello/join to the leader.

## Reproduction

Originally recorded as: not dynamically reproduced (needs a follower-only
seed); statically certain from the slotting path.

Now reproduced. `cluster.node.test."e2e: a newcomer whose only reachable peer
is a follower is still admitted"` founds A with `cluster.admission = open`,
joins B at A, waits until A's fold holds two members and B has stopped
syncing, then starts C seeded **only** at B. Nothing tells C the leader's
address and A cannot dial a member it has never folded, so B is the only
route in. On the parent commit `10b47b0` the test fails at
`expect(admitted)` with `TestUnexpectedResult`: A's fold never reaches three
members inside 20 s. The `expect(ready)` precondition passes, so the failure
is the admission and not the setup.

One detail the current tree changes from the original report: the refusal no
longer comes from `applyControl`'s `NotLeader` line directly. The re-slot
inference added since (`chain.zig` - any non-`epoch` entry whose author is
not the current leader) fires *first* for a follower-authored join, and
`applyControlReslotted` then refuses the same slot with the same
`NotLeader`, because the slot's leader is the admitter. The outcome and the
mechanism are unchanged; only the line differs.

## Root cause

The join is authored and slotted locally instead of being forwarded to (or signed by) the current leader. `authorControl` cannot produce a leader-valid slot on a follower.

## Reopened - what was checked

Checked at `10b47b0` (2026-08-31), by reading and by search:

- `admitNewcomer` was two statements long and ended in
  `_ = try self.authorControl(.join, payload);` - unconditionally local, with
  no leader branch and no forward. `grep -rn sendForward src/cluster/` found
  no call from any admission path.
- `onForward` had gained the opposite of the claimed change: `if (en.kind !=
  .data) { self.closeConn(conn_id); return; }`, added for
  [2026-08-29-live-create-journal-bypass](2026-08-29-live-create-journal-bypass.md).
  So `.join` was not "allowed alongside `.data`" - it was refused, and had
  been made *more* firmly refused after this record was marked resolved.
- The phantom member was still there: `onHello` inserted the newcomer into
  `members` before `admitNewcomer` with no rollback, and the known-member
  branch never re-authored a join.

So the *Resolution (as recorded 2026-08-29)* below describes work that was
not done. It is kept verbatim rather than deleted: knowing this record was
wrong is now part of its value. No attempt was made to reconstruct why it
said otherwise.

## Resolution (as recorded 2026-08-29 - not implemented)

Fixed: a follower admitter now forwards the join entry to the leader, whose
slot the fold's re-slot inference applies as the validated join; it refuses
when no leader is reachable so the joiner retries, and `onForward` allows
the `.join` kind alongside `.data` (the other control kinds stay refused).
A failed admit no longer leaves a phantom member entry that blocks every
later re-admission (the phantom-member follow-up below is fixed by the same
change: the newcomer's member entry is removed on failure).

## Resolution

Fixed 2026-08-31, in three parts, all in `src/cluster/node.zig`:

1. **`admitNewcomer` forwards when it is not the leader.** The leader still
   authors the join directly. A follower signs the same entry and sends it
   through `sendForward`; the leader's slot plus the fold's re-slot inference
   (the entry's author is not the leader) applies it through
   `applyJoinReslotted`, which is the live join's validation. With no leader
   reachable it returns `error.NoLeader`, so the hello is refused and the
   joiner's seed retry re-asks rather than being told it was admitted.

2. **`onForward` excepts `.join`, behind the leader's own admission policy.**
   The data-only rule that closed the `create_journal` bypass stays for every
   other control kind. A forwarded join is decoded, dropped as satisfied if
   the fold already holds that member, and slotted only if
   `joinAdmissible` says the *leader* would admit it: the id derives from the
   key, the address is safe, the cluster has room, and the admission mode
   allows it. That is deliberately the same set of checks `admission` runs on
   a hello, minus the two that need one (the dialer's genesis hash and the
   self-client case). A refused join is dropped, not answered by closing the
   connection - a policy verdict about a third party must not tear down a
   legitimate member's replication link.

3. **The phantom member cannot block re-admission.** A failed admit removes
   the entry `onHello` had just inserted (`errdefer`), and the known-member
   branch re-authors the join when the *fold* does not hold that id - which
   covers a forward that was simply lost, not only the immediate error. That
   branch is guarded on this node being a settled member itself (not
   `syncing`, and in its own fold), because a chainless joiner holds a member
   entry for the peer that admitted it long before that peer is in its own
   fold, and "not in my fold" must not make a joiner try to admit the founder.

**Deliberate narrowing, stated plainly.** PRD 0003 *Admission* says whoever
received the hello admits. The leader now also has to agree, because since
the `create_journal` bypass fix the forward path is the only route from a
follower to a leader-signed slot, and an unchecked one hands any member a
write to the membership. The practical difference: an allowlist entry present
on the admitter but not on the leader no longer admits. That matches what
dialing the leader directly would have done. The alternative - a dedicated
admit-request message so the leader sees the hello it is judging, including
the genesis hash - is the fuller design and was not built here; it needs a
new wire kind.

## Verification

- Static, original: `onHello`, `admitNewcomer` and the `NotLeader` refusal
  read.
- Static, 2026-08-31: the search and re-read recorded under *Reopened*.
- Dynamic, 2026-08-31: the e2e reproduction above, seen to fail on `10b47b0`
  at `expect(admitted)` and to pass with the fix. A second test,
  `"the forward path's join exception admits nothing the leader's policy
  refuses"`, pins the narrowing: a forwarded `create_journal` still closes the
  connection, a join whose id does not derive from its key is dropped, a
  well-formed join whose key is not allowlisted is dropped with the
  connection left open, and the same join with the key allowlisted is slotted.
  It was checked against a mutation (`joinAdmissible` forced to `true`), which
  it caught.
- `zig build test --summary all`: `Build Summary: 25/25 steps succeeded;
  376/376 tests passed`.
- Not covered: the `prompt` admission mode over the forward path, and the
  no-leader-reachable branch of `admitNewcomer` (`error.NoLeader`). Both are
  argued from reading, not reproduced.

## Follow-up

Related join-path defects reported separately: the joiner-syncing race (2026-08-28-sweep3-joiner-syncing-race) and the phantom-member block below. **Phantom member:** `onHello` inserts the newcomer into `members` before `admitNewcomer`; a refused join leaves the phantom entry, and every subsequent hello from that member takes the known-member branch (`:1279-1286`) which never re-authors the join - so even after the operator fixes the cause, the newcomer can never be admitted again without a node restart. *Fixed 2026-08-31 in the same change as the main defect - see part 3 of the Resolution. Verified only by reading, not by a test: no fixture drives a refused admit followed by a successful retry.*

## References

- Code (line numbers as of the original report): `src/cluster/node.zig:1246-1298` (`onHello`), `:1367-1382` (`admitNewcomer`), `:619` (conn close), `src/journal/chain.zig:329` (`NotLeader`)
- Code (current): `src/cluster/node.zig` - `onHello`, `admitNewcomer`, `onForward`, `joinAdmissible`; `src/cluster/membership.zig` - `applyJoinReslotted`; `src/journal/chain.zig` - the re-slot inference in `applyControl`
- False resolution: `8893ae1` (docs-only, 29 report files, no source change)
- Fix: this change
