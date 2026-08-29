# ADR 0003 - Batteries included: replication, election and storage ship inside the library, and no external infrastructure is required at any size

## Status

Accepted - 2026-08-21.

## Context

The brief, clarified 2026-08-21: the store is for anyone facing this class
of problem, not for clanker specifically; it must be usable "as a Zig library
to just use, similar to SQLite or dqlite or rqlite", where "all the
implications are already built-in" and "ideally we don't need to set up an
extra set of infrastructure resources"; it should be "slim to start, but
expandable as needed and scalable naturally".

What makes SQLite easy is that opening a file *is* the whole setup. What makes
dqlite easy relative to etcd is that the Raft engine is inside the library,
not a cluster someone runs beside the application. Every store clanker's
survey rejected for small fleets was rejected for the same reason: it asks the
operator to stand something up before the application can store a byte
([research 0001](../research/0001-evidence-carried-from-the-state-store-survey.md)).
A library that required an external coordinator, a discovery service, or a
separate replication daemon would reproduce exactly that.

## Decision

Everything a cluster needs at any size ships inside the library: storage,
the hash chain, replication, failure detection, leader election, backfill,
TTL cleanup, and the settings fold. A host links the library and opens a data
directory; with no peers that is a complete one-member journal, and adding
peers is configuration of the *same* node, never a new component. coppiz
never depends on an external coordinator (etcd, ZooKeeper, Consul), a
separate replication daemon, a message broker, or a discovery service, and
the node binary is the same library wrapped - a convenience, not a required
piece of infrastructure.

"Slim to start, expandable" is a rule on how features land: each mechanism
is off or trivial at size 1 (no listener, no failure detector, no
checkpoints on an idle journal) and is switched on by settings as the cluster
grows ([PRD 0003](../prds/0003-membership-and-leadership.md) modes,
[PRD 0004](../prds/0004-settings.md) live reconfiguration). A mechanism that
cannot be absent at size 1 needs a reason in its PRD.

## Consequences

- A host pays one dependency and one data directory; "deploying coppiz" is
  deploying the host. Any Zig program embeds it the same way; clanker's
  single static binary is one instance of that, not the reason for it.
- coppiz owns the whole distributed-systems surface - delivery, retention,
  backfill, election, merge - which clanker's research called "the category
  of work most likely to be subtly wrong". The deterministic simulator
  ([OQ 27](../open-questions.md)) is the mitigation, and it is why the pure
  fold/election/merge split in PRDs 0001–0003 is not optional.
- Features that would need external infrastructure to do well (global
  discovery, cross-datacenter routing) arrive late or not at all; past the
  small-cluster range the growth path is more groups rather than bigger ones
  ([PRD 0006](../prds/0006-scaling-to-groups-sharding-and-parity.md)), with
  leader-star or gossip topology inside large groups ([OQ
  25](../open-questions.md)) - still inside the library.
- Non-Zig hosts reach it through the node binary or a future C ABI
  ([RFC 0001](../rfcs/0001-library-first-or-service-first.md)); anything the
  node binary can do, the library can do.
- Reversing this - requiring a component outside the library - is a
  superseding ADR, because it changes what "using coppiz" means for every
  host.
