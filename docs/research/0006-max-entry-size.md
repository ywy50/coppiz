# Research - Maximum entry size and large payloads (OQ 36)

## Status

Open - measurement pending (was OQ 36 (historical), retired
when the register was removed 2026-08-29). The provisional default is
shipped; the measurement replaces it.

Research is evidence, not a decision: it records what exists, how good it is,
and how confident the finding is. The decision that follows belongs in an
[RFC](../rfcs/) and, once made, an [ADR](../adrs/).

## Question

Is 16 MiB (`journal.max_entry_bytes`, provisional) the right default for the
first consumers, and when does the large-payload shape (chunked entries, or
content-addressed side storage) become necessary?

The value question is a measurement; the blob-shape question is a design
decision that rides on the measured ceiling. clanker's streams are 1-2 KB
lines; sessions run up to 1.75 MB and are explicitly *not* a first consumer
(PRD 0005). The operator settled the mechanism on 2026-08-29: the value is a
live-changeable journal setting, and the provisional 16 MiB stands until
measurement replaces it.

## Current state

`journal.max_entry_bytes` ships at the provisional 16 MiB; a too-large
payload refuses `too_large`. The blob shape (chunked entries or
content-addressed side storage) is roadmap.

## Harness (plan)

- Measure the entry-size distribution of the first real consumers
  (clanker's streams first, sessions later) to size the default against
  actual payloads.
- The blob-shape decision follows when a payload approaches the ceiling and
  no first consumer is bounded by it.

## References

- [PRD 0001](../prds/0001-journal-core.md) - goal 6 (size bounds) and the
  entry format.
- [PRD 0004](../prds/0004-settings.md) - `journal.max_entry_bytes` as a
  live-changeable journal setting.
- [Research 0007](0007-tier-number-measurements.md) - the umbrella
  measurement program this measurement belongs to.
