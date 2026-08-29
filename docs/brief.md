# The brief

The founding notes for coppiz, written 2026-08-21. Records in this
repository cite this document as "the brief". The goal is a storage
solution for Zig, in the shape of a distributed ledger or dqlite. What was
clarified in conversation the same day is recorded where it is used
([ADR 0003](adrs/0003-batteries-included-no-external-infrastructure-at-any-size.md)).

## What it must support

- Append-only entries.
- TTL on entries.
- Settings for the storage system, covering:
  - whether entries whose TTL is reached are completely deleted from the
    ledger or marked stale;
  - whether TTL enforcement is enabled at all, and whether it applies to
    every entry or only to those that carry a TTL (enforcing it for all
    entries in the schema is also possible).
- Concurrency handling / leader election, in different modes, with an
  option to change them on the fly; when disabled, changing the mode at
  runtime is not allowed.

## Leader election

Append-only content keeps concurrency simple to handle, but some kind of
leader election is still needed, and the mode must be configurable. The
system must run standalone and scale up from there, at which point "who
is the leader" is no longer obvious: with 2 instances, common protocols
like raft or etcd have trouble electing.

- **Seniority.** The leader is whoever joined the ledger the earliest,
  detected automatically. This works for a single instance, for 2
  instances, and for other uneven numbers. It requires a mechanism to
  make sure the join date "cannot be spoofed by any member to falsify
  their join date".
- **Configured authorities.** In case of conflict, the config names the
  highest-authority members (by IP, DNS name, or whatever). For a
  two-instance ledger, we can define a specific one who is the leader,
  which also covers a single instance as its own leader. For any even
  number of instances, say 6 nodes, an uneven subset (1, 3, 5, ...) can
  be named to hold leadership.
- **Combined.** Authorities filter the candidates and another rule orders
  them: for example 5 authorities are set, and within those 5 the leader
  is chosen by join time, or by who has the latest entries and definitely
  has the full state of the ledger.

## Cleanup and mutability

As a distributed, append-only ledger, every node will have the full state
of course. That is why it must be possible to have a toggle to allow
mutability for automatic cleanup via TTL or marking entries stale, where a
specific instance can only mark its own added entries as stale, which then
get removed/cleanup as well.

## Scaling

If concurrency handling / leader election can change during runtime via
the mentioned config, the system can switch between modes and scale all
the way from 1 to n seamlessly, no matter if it's even or uneven number.

## The name

The tool has no name yet. Give it a temporary project name first and think
about it again before publishing.

## How to proceed

- Write the draft docs (PRDs and the rest) for the design, and anything
  else: any information already available, plus a document with open
  questions and anything that might be missing or still needs to be
  clarified and defined in the new repository.
- Check the RFC clanker wrote on the topic first.
- On the roadmap, the storage system must be able to plug into e.g.
  clanker as easily as SQLite plugs in.
- The system will be written in Zig.
