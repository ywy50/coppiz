# Research - Checkpoint cadence defaults (OQ 10)

## Status

Open - measurement pending (was OQ 10 (historical), retired
when the register was removed 2026-08-29).

Research is evidence, not a decision: it records what exists, how good it is,
and how confident the finding is. The decision that follows belongs in an
[RFC](../rfcs/) and, once made, an [ADR](../adrs/).

## Question

What are the right `checkpoint.every_ms` (60 s provisional) and
`checkpoint.pending_bytes` (64 MiB provisional) defaults?

The question is a measurement: too frequent a cadence spams control entries
on every member; too rare delays reclaim. The answer is the trade-off point
between control-entry volume and reclaim latency, not a candidate
exploration. The values shipped as placeholders with PRD 0002 phase 4; the
measurement replaces them.

## Current state

The leader's checkpoint cadence runs on `checkpoint.every_ms` with the
`checkpoint.pending_bytes` early trigger (PRD 0002 phases 4-5, shipped).
Every member replays every checkpoint, so each one costs control entries
cluster-wide.

## Harness (plan)

- Vary the cadence across the provisional range (30 s - 5 min, and the
  pending-bytes trigger across 16-256 MiB) on a small cluster under a
  steady append load.
- Record control-entry volume per member and the reclaim latency (how long
  a removed payload stays on disk) at each point; the default sits where
  the reclaim delay stops mattering without the control-entry cost
  dominating.

## References

- [PRD 0002](../prds/0002-ttl-and-staleness.md) - the checkpoint rules and
  the cadence settings.
- [Research 0007](0007-tier-number-measurements.md) - the umbrella
  measurement program this cadence measurement belongs to.
