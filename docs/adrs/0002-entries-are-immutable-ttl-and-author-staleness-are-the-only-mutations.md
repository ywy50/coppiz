# ADR 0002 — Entries are immutable; TTL expiry and author-marked staleness are the only mutations, and both are opt-in by setting

## Status

Accepted — 2026-08-21.

## Context

The brief (2026-08-21) asks for an append-only ledger and, in the same
breath, for two kinds of cleanup: entries whose TTL is reached are deleted or
marked stale, by setting; and a member may mark its own entries stale — only
its own — after which they are cleaned up too. It also asks that TTL
enforcement be switchable: off, per entry, or for every entry in the journal.

The alternative shapes were a general `update`/`delete` API (which makes
every pair of concurrent writes a potential conflict and drags in
merge/consensus for content, not just order), or strict immutability with no
cleanup (which makes a fully replicated journal grow without bound on every
member). clanker's research (RFC 0019 option T) established that append-only
content is what lets replication run without consensus; giving that up to
get cleanup would be paying for the whole problem to solve a corner of it.

## Decision

An entry's bytes never change after it is written. There is no `update` and
no `delete(id)`. The only state transitions are `live → stale → removed` —
or `live → expired → removed` when the journal's expiry action is delete
rather than mark_stale —
driven by exactly two causes — a TTL reached, and a `stale` control entry
authored by the entry's own author — and made durable only by a leader
`checkpoint` entry so every member removes the same set at the same chain
position. Whether either cause is active, and whether expiry marks or
deletes, are per-journal settings stored in the chain ([PRD 0002](../prds/0002-ttl-and-staleness.md),
[PRD 0004](../prds/0004-settings.md)) — the schema gates both causes, after
[OQ 57](../open-questions.md) was resolved (2026-08-27) by adding
`stale.enforce` (default `off`) and defaulting `stale.cleanup` to `keep`.
Slots are never removed; at most an
entry's payload (and, under `ttl.retain = none`, its header) is.

## Consequences

- Replication of content needs no consensus and no merge; only order needs
  a leader, and order can heal after a partition without touching content
  ([PRD 0003](../prds/0003-membership-and-leadership.md) merge).
- A consumer that wants "update" appends a new entry and folds; a consumer
  that wants "delete" uses TTL or marks stale. Both are how clanker's board
  already works (its ADR 0001), so the first consumer loses nothing.
- The hash chain survives cleanup because slots stay and entry hashes stay;
  the cost is that the slot sequence only grows, and a very long-lived,
  high-churn journal eventually needs an archival checkpoint
  ([OQ 24](../open-questions.md)).
- Author-only staleness means a compromised or defective member can hide its
  own history but nobody else's; extending the right to a leader or operator
  is a later, separate decision ([OQ 6](../open-questions.md)).
- "Delete" is not secure erasure: removed payloads linger in un-compacted
  segments and in backups until rewritten.
