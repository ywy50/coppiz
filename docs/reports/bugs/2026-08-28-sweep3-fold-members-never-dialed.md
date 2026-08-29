# Bug - Members learned from the fold after startup are never dialed: the "full mesh" never forms

## TL;DR

- **What failed:** `syncMembersFromFold` adds fold-learned members with `dial_at_ms = 0`, and the `onTick` dial branch requires `dial_at_ms != 0`. `bootstrapDial` covers only members present at startup. So no first dial is ever scheduled for a member that joined after this node started.
- **Impact:** The topology is a star around each member's configured seeds, not the full mesh [PRD 0006](../../prds/0006-scaling-to-groups-sharding-and-parity.md) (2–32 members) describes. Pairs that never shared a connection never connect; when the founder dies, the healthy remaining members never see each other's heartbeats, self-elect independently (N divergent branches instead of one agreed leader), and heal only when the founder returns.
- **Resolution:** Still open. Statically validated.

## Status

Open.

## Symptom and impact

The mesh design: "One dialer per member pair, so the full mesh never double-dials: the member with the lower id dials the higher" (`node.zig:664-669`). It relies on `onTick` scheduling the dial when `dial_at_ms != 0`. But a member that entered the map via a fold `join` entry (`syncMembersFromFold`, `node.zig:486-506`) is created with `dial_at_ms = 0` (default), `conn_id = null`, `last_heard_ms = 0`, and none of the three `onTick` branches matches it: no heartbeat ever sent (`conn_id == null`), never suspected (`last_heard_ms == 0`), never dialed (`dial_at_ms == 0`, `:864-868`). The only dial paths are `bootstrapDial` (startup, `:645-662`), seed retries, and post-connection/post-failure re-dials (`:858, :1166, :782`). In a growing cluster, each new member talks only to its configured seeds.

## Reproduction

Not dynamically reproduced; statically certain. Observable whenever the founder of a >2-member cluster fails: the non-seeded pairs have no connection, no heartbeats, and self-elect simultaneously - where a full mesh would have one agreed leader.

## Root cause

The first dial for a fold-learned member is never scheduled: the scheduler's precondition (`dial_at_ms != 0`) is never established for members that were not present at startup and were never connected or failed.

## Resolution

Not yet fixed. Suggested direction: in `syncMembersFromFold`, schedule the first dial for new members that this node should dial (lower-id dials higher-id), e.g. set `dial_at_ms = now` when the id rule says this node dials. A regression test should grow a cluster past its seeds and assert every pair eventually holds a connection.

## Verification

- Static: `syncMembersFromFold` (`:486-506`), `onTick` dial branch (`:864-868`), `bootstrapDial` (`:645-662`), and the dial-at setters all read.

## Follow-up

None beyond the fix. Availability/divergence defect; merges do converge once a connection exists.

## References

- Code: `src/cluster/node.zig:486-506` (`syncMembersFromFold`), `:645-662` (`bootstrapDial`), `:864-868` (`onTick` dial branch)
- Fix: none
