# Research - `merge.settle_ms` default (OQ 60)

## Status

Open - measurement pending (was OQ 60 (historical), retired
when the register was removed 2026-08-29).

Research is evidence, not a decision: it records what exists, how good it is,
and how confident the finding is. The decision that follows belongs in an
[RFC](../rfcs/) and, once made, an [ADR](../adrs/).

## Question

What is the right `merge.settle_ms` default? The provisional value is 30 s.

The question is a measurement. PRD 0002 bars a checkpoint for slots newer
than the last `merge` until the settle window passes, so the value must
exceed the clock skew between the two leaders over the partition - or the
surviving side computes an expiry instant the losing side never meant -
while not stalling cleanup after every heal. Its siblings are
`cluster.suspect_after_ms` and `checkpoint.every_ms`.

## Current state

30 s ships as the provisional default with PRD 0002. Nothing bounds or
derives it yet; the question asked for measurement against the same skew
data `ttl.grace_ms` wants (research 0004).

## Harness (plan)

- Measure the clock skew between two partitioned leaders over the partition
  (the same data research 0004 collects), and the heal-to-cleanup latency at
  the provisional value.
- The default must exceed the measured skew with margin while keeping
  post-heal cleanup prompt; the measurement pins both bounds.

## References

- [PRD 0002](../prds/0002-ttl-and-staleness.md) - the settle rule that
  makes the value a safety bound.
- [Research 0004](0004-ttl-grace-default.md) - the shared skew data.
- [Research 0007](0007-tier-number-measurements.md) - the umbrella
  measurement program.
