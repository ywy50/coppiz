# Research - Measurements that replace the tier numbers (OQ 54)

## Status

Open - measurement pending (was OQ 54 (historical), retired
when the register was removed 2026-08-29).

Research is evidence, not a decision: it records what exists, how good it is,
and how confident the finding is. The decision that follows belongs in an
[RFC](../rfcs/) and, once made, an [ADR](../adrs/).

## Question

Which measurements replace the intent tier numbers - 32 members per group
and ~1,000 / ~100,000 per tier - before any of them can be promoted from
intent to claim?

The question is a measurement program: what to measure, where the harness
is, and what hardware counts. The first measurement set, as the register
recorded it:

- size-1 append latency;
- per-member connection count and memory at 8, 16, 32 members;
- append-to-visible p50/p99 across one group;
- join/backfill time for a 1 GB journal;
- then the same at 3 x 8 and 10 x 8 in two groups of groups.

## Current state

The tier numbers are intent, not claims (PRD 0006). Several sibling
measurements hang off this one: the checkpoint cadence (research 0005), the
memory bound (research 0009), and the parity defaults (RFC 0027 "the
defaults ride OQ 54's measurements").

## Harness (plan)

- Build the harness around the existing cluster examples (embed-cluster,
  sidecar) so a measurement run is a known command, not a bespoke script.
- State the hardware floor on the record with each run, so a number is a
  claim only for machines at or above it.

## References

- [PRD 0006](../prds/0006-scaling-to-groups-sharding-and-parity.md) - the
  tier numbers this program replaces.
- [RFC 0027](../rfcs/0027-parity-code.md) - parity defaults that ride these
  measurements.
- [Research 0003](0003-fsync-default-measurement.md) - the established
  measurement-note pattern this program generalizes.
