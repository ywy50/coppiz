# Research - What bounds per-process memory (OQ 61)

## Status

Open - measurement pending (was OQ 61 (historical), retired
when the register was removed 2026-08-29).

Research is evidence, not a decision: it records what exists, how good it is,
and how confident the finding is. The decision that follows belongs in an
[RFC](../rfcs/) and, once made, an [ADR](../adrs/).

## Question

What bounds per-process memory, and what does a member do at the bound?

PRD 0001 goal 6 requires entry size, journal count *and per-process memory*
to be bounded by settings, but only the first two have keys
(`journal.max_entry_bytes`, `cluster.max_journals`; the unslotted queue adds
`sync.unslotted_max_bytes`). No memory bound exists anywhere in the schema,
and no acceptance criterion covers the clause. The knob is a measurement
question first: a fold/snapshot cache cap, a per-journal page budget, or
nothing before the measurement shows where the memory actually goes.

## Current state

Phases 3-4 shipped without a memory bound; the knob and the behaviour at
the bound stay open. The sibling size bounds settled their mechanism on
2026-08-29 (journal cap and entry size are chain settings, the queue bound a
local-config key) - the memory bound has no mechanism at all yet.

## Harness (plan)

- Profile a member's memory at the tier sizes research 0007 defines (8, 16,
  32 members) to see where the bytes go: the fold/snapshot cache, the index
  maps, the per-journal segments.
- The knob follows the profile - whatever dominates gets the bound; what a
  member does at the bound (refuse, evict cache, backpressure) is the
  design decision that the measurement frames.

## References

- [PRD 0001](../prds/0001-journal-core.md) - goal 6 (size bounds).
- [Research 0007](0007-tier-number-measurements.md) - the tier sizes the
  profile runs at, and the umbrella measurement program.
