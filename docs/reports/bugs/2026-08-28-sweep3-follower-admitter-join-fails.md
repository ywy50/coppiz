# Bug - A hello landing on a non-leader is answered "admitted", then the join is refused and the connection closed: the joiner retries forever

## TL;DR

- **What failed:** `onHello` sends `hello_ack` with `admitted = true` *before* `admitNewcomer` authors the join - locally, as the receiving member. A follower admitter's join slot is refused by the fold (`NotLeader`: the slot's leader is not the epoch's leader), the error closes the connection, and the joiner, which was already told it was admitted, redials the same follower forever.
- **Impact:** A joiner whose only reachable peer is a follower (leader down at join time, or a single-peer config pointing at a follower) can never join - silently, permanently.
- **Resolution:** Still open. Statically validated.

## Status

Resolved.

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

Not dynamically reproduced (needs a follower-only seed); statically certain from the slotting path.

## Root cause

The join is authored and slotted locally instead of being forwarded to (or signed by) the current leader. `authorControl` cannot produce a leader-valid slot on a follower.

## Resolution

Fixed: a follower admitter now forwards the join entry to the leader, whose
slot the fold's re-slot inference applies as the validated join; it refuses
when no leader is reachable so the joiner retries, and `onForward` allows
the `.join` kind alongside `.data` (the other control kinds stay refused).
A failed admit no longer leaves a phantom member entry that blocks every
later re-admission (the phantom-member follow-up below is fixed by the same
change: the newcomer's member entry is removed on failure).

## Follow-up

Related join-path defects reported separately: the joiner-syncing race (2026-08-28-sweep3-joiner-syncing-race) and the phantom-member block below. **Phantom member:** `onHello` inserts the newcomer into `members` before `admitNewcomer`; a refused join leaves the phantom entry, and every subsequent hello from that member takes the known-member branch (`:1279-1286`) which never re-authors the join - so even after the operator fixes the cause, the newcomer can never be admitted again without a node restart.

## References

- Code: `src/cluster/node.zig:1246-1298` (`onHello`), `:1367-1382` (`admitNewcomer`), `:619` (conn close), `src/journal/chain.zig:329` (`NotLeader`)
- Fix: none
