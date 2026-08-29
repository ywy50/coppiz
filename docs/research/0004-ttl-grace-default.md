# Research - `ttl.grace_ms`: default and derivation (OQ 9)

## Status

Open - measurement pending (was OQ 9 (historical), retired when
the register was removed 2026-08-29).

Research is evidence, not a decision: it records what exists, how good it is,
and how confident the finding is. The decision that follows belongs in an
[RFC](../rfcs/) and, once made, an [ADR](../adrs/).

## Question

What should `ttl.grace_ms` default to, and can it be derived from the
observed skew between a member's local clock and the leader's `slot_ts_ms`
at the head, instead of being a fixed setting?

The question is a measurement: "what does the data say?" about the read-side
skew window, not an exploration of candidates. The default (0) shipped; the
derivation from observed skew stays open.

## Current state

`ttl.grace_ms` is the read-side skew tolerance: how much later than its
nominal expiry a member may still show an entry, so a follower whose clock
lags the leader's does not hide entries early. The default 0 shipped with
PRD 0002. Derivation would observe the offset between the local clock and
the leader's `slot_ts_ms` at the head and size the grace window from it.

## Harness (plan)

- Measure the local-vs-leader `slot_ts_ms` offset on a member at the head,
  under normal operation and with a deliberately skewed clock (the PRD 0001
  clock assumptions bound skew at seconds, not hours).
- The default should bound the observed read-side window; the derived value
  should stay inside it with margin.

## References

- [PRD 0002](../prds/0002-ttl-and-staleness.md) - the `ttl.grace_ms`
  setting and its expiry predicates.
- [PRD 0001](../prds/0001-journal-core.md) - *Slot layout* (Clock
  assumptions), which bounds the skew the grace window must absorb.
- [Research 0008](0008-merge-settle-default.md) - `merge.settle_ms` wants
  the same skew data.
