# RFC 0026 - grouping unit and range key

## Status

Discussion - opened 2026-08-29. Addresses OQ 48 (the
register keeps the stable pointer).

An RFC is a *request for comment*: it presents the options and a recommendation
so a decision can be made, and it is not itself the decision record. When it is
decided, set the status, then write the [ADR](../adrs/) that records the choice
and link it from References.

## Overview

In PRD 0006's overlay, ownership is by whole journal, and the drafted
split key for a journal too hot for one group is the author-id prefix, so
each author's stream stays in one group and `author_seq` stays dense.

**Decision to make.** Is whole-journal ownership with author-prefix
range splits the unit, or is a payload-derived key needed for hosts with
many authors and one hot range?

**Why now.** The unit is a PRD 0006 phase-3 design; it decides what the
ownership map holds and whether the range split can ever need
`author_seq` renumbering.

**Drivers.** Any acceptable option must:

- keep `author_seq` dense per (author, journal) (PRD 0006's "what the
  core must get right now": the author id is the range key);
- keep one author's stream in one group (a split mid-stream would break
  the single-writer ordering);
- not invent a payload schema: coppiz never interprets payloads (PRD
  0001).

**Out of scope.** Arbitrary range splits (documented as later work).
Parity (RFC 0027). Routing semantics (RFC 0028).

## Current state

Nothing of the overlay is implemented; the unit (whole journal) and the
split key (author prefix) are drafted in PRD 0006.

## Options considered

### Option A - whole-journal ownership, author-prefix ranges (status quo)

- **What it is:** the ownership map holds `journal id -> group`; a hot
  journal splits by `journal id + author-id prefix -> group`, keeping
  each author's stream whole.
- **Pros:** matches the single-writer-per-stream shape every known
  consumer has; no payload inspection; `author_seq` density preserved.
- **Cons:** a journal with one hot author cannot be split (the stream is
  indivisible) - the hot-author case is a group-size problem, not a
  split problem.
- **Cost to adopt:** none (drafted).
- **Cost to leave:** a format-relevant map design; cheap now.
- **Evidence:** PRD 0006's table; the known host shapes (RFC 0021).

### Option B - payload-derived range key

- **What it is:** the split key derives from the payload (e.g. a
  consumer-supplied key field).
- **Pros:** a hot range within one author's stream could be split.
- **Cons:** coppiz would have to interpret payloads or accept a
  consumer-supplied key at append time - a schema coppiz explicitly does
  not have; splitting one author's stream breaks the single-writer
  ordering and `author_seq` density (PRD 0006's core rule).
- **Cost to adopt:** a payload contract - a core change.
- **Cost to leave:** none.
- **Evidence:** PRD 0001's "payloads are opaque".

### Option C - shard-by-author with per-author keys (out-of-the-box variant)

- **What it is:** range splits are per author id, not per prefix - the
  map holds individual author ids.
- **Pros:** a hot *author* is routable on its own.
- **Cons:** the map grows with author count (per-member state bound, PRD
  0006 G6); a prefix is just the compressed form of this.
- **Cost to adopt:** the same map, unbounded.
- **Cost to leave:** none.
- **Evidence:** PRD 0006's per-member-state bound.

## Implications by horizon

### Short term (PRD 0006 phase 3)

- **If A:** the map is `journal id (+ prefix) -> group`.

### Medium term

- **If a hot-author journal appears:** the answer is more groups or a
  per-author map (C), not payload keys.

## Recommendation

**Recommended option:** A - whole-journal ownership with author-prefix
range splits. B is rejected (a payload contract breaks the opaque-payload
rule); C is the natural growth of A if one author is hot enough to route
alone.

**Confidence:** 8/10

**Why this confidence.** A matches every known consumer shape and the
core's density rule; what would move it is a consumer with a hot-range
within one author's stream - which no known host has (RFC 0021).

**Rationale.** The split exists to route around a hot *range*; every
known stream is single-author, so the range is the author, and the
author-prefix is the right granularity without a payload contract.

**Reversibility.** A to C is a map refinement; B would be a core change.

## Open questions

- None beyond RFC 0021's host shapes.

## Next steps / action items

- [ ] Record the unit in PRD 0006 phase 3.
- [ ] Write the ADR once decided; update OQ 48's status.

## References

- OQ 48 (historical) - the question this RFC addresses.
- [PRD 0006](../prds/0006-scaling-to-groups-sharding-and-parity.md) - the
  ownership and split-key draft.
- [RFC 0021](0021-host-shapes.md) - the host shapes this depends on.
