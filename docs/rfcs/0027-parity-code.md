# RFC 0027 - parity code and reconstruction cost

## Status

Discussion - opened 2026-08-29. Addresses OQ 50 (the
register keeps the stable pointer).

An RFC is a *request for comment*: it presents the options and a recommendation
so a decision can be made, and it is not itself the decision record. When it is
decided, set the status, then write the [ADR](../adrs/) that records the choice
and link it from References.

## Overview

Parity is k-of-m erasure coding of sealed segments across groups (PRD
0006). The open questions: the code (Reed-Solomon over GF(2^8) is
feasible in std-only Zig), the k/m defaults, fragment size, the read cost
(k network fetches + decode) versus a follower copy, and whether parity
applies to slots or only payloads given `ttl.retain`.

**Decision to make.** What is the parity mechanism (code, units, defaults)
and when is it worth using over a follower copy?

**Why now.** Parity is PRD 0006 phase 4 - the last mechanism, behind a
measured storage-cost trigger. The mechanism decision (what parity is) is
cheap now; the defaults are measurement.

**Drivers.** Any acceptable option must:

- stay std-only (ADR 0001): Reed-Solomon over GF(2^8) is implementable
  with std's primitives;
- preserve chain verifiability: fragments are of sealed bytes whose slot
  hashes already exist (PRD 0006);
- give a crisp read story: what a parity read costs against a follower
  copy must be stateable.

**Out of scope.** The trigger (storage cost measured as binding - PRD
0006 phase 4). The grouping unit (RFC 0026).

## Current state

Nothing implemented. PRD 0006 drafts: fragments of sealed segments, k of
m reconstruct, applied to sealed bytes only (the live tail is fully
replicated in the owning group).

## Options considered

### Option A - Reed-Solomon over GF(2^8), parity over sealed slots (status quo)

- **What it is:** k-of-m Reed-Solomon; the encoded units are sealed
  segments' *records* (slots + whatever the segment retains, honouring
  `ttl.retain` - a removed entry's slot still exists and hashes, so the
  parity input is the segment as stored).
- **Pros:** the drafted shape; fits std; the chain is unaffected (the
  parity is over bytes whose hashes exist).
- **Cons:** the read cost (k fetches + decode) is the honest price; the
  fragment granularity and defaults are unmeasured.
- **Cost to adopt:** the encoder/decoder, the placement map, the read
  path.
- **Cost to leave:** none - phase 4.
- **Evidence:** PRD 0006's parity section.

### Option B - parity over payloads only

- **What it is:** encode only payload bytes; reconstruct drops the
  headers/slots from parity.
- **Pros:** smaller parity for `retain = none` journals.
- **Cons:** the parity then cannot rebuild a *segment* (which needs the
  slot structure); two encodings (per retain) instead of one; the
  chain-verifiability argument weakens (a rebuilt payload-only fragment
  does not verify against the chain).
- **Cost to adopt:** two formats.
- **Cost to leave:** none.
- **Evidence:** PRD 0002's retain shapes.

### Option C - follower copy as the default; parity behind a cost trigger (out-of-the-box)

- **What it is:** the read path's default is a follower copy (local,
  lagging - RFC 0028's semantics); parity is selected per journal only
  when storage cost makes full copies binding, and its read cost is then
  the accepted price.
- **Pros:** the trigger governs; the mechanism's defaults (k, m, fragment
  size) are set by the measurement that justifies parity at all.
- **Cons:** parity reads are always the slower path; a journal that needs
  low-latency reads should never be parity-stored.
- **Cost to adopt:** the trigger in OQ 54's measurements.
- **Cost to leave:** none.
- **Evidence:** PRD 0006's measured trigger.

## Implications by horizon

### Short term (PRD 0006 phase 4)

- **If A/C:** the mechanism is A; the defaults and trigger are C's
  measurement.

### Medium term

- **If storage cost binds:** the measurement sets k, m, fragment size.

## Recommendation

**Recommended option:** A - Reed-Solomon over GF(2^8) on sealed segment
records as stored (honouring `ttl.retain`), with C's trigger and defaults
measured before any journal is parity-stored. B is rejected - it breaks
the chain-verifiability of a reconstructed segment.

**Confidence:** 6/10

**Why this confidence.** The mechanism is the drafted, std-feasible
shape; the defaults are explicitly unmeasured. What would move it: the
OQ 54 measurement set (storage cost and read cost). What would sink it:
a workload where k-fetch + decode cannot beat a follower copy - which
would argue follower copies are always the answer and parity stays a
niche.

**Rationale.** Parity exists to trade copies for reconstruction cost; the
mechanism (A) is the only std-feasible one that keeps the chain
verifiable, and the trigger (C) decides when the trade is worth it.

**Reversibility.** Phase 4; the codec is internal.

## Open questions

- The k/m and fragment-size defaults - measured or provisional? (OQ 54's
  suite; provisional until then)

## Next steps / action items

- [ ] Record the parity cost question in OQ 54's measurement list.
- [ ] Write the ADR once decided; update OQ 50's status.

## References

- OQ 50 (historical) - the question this RFC addresses.
- [PRD 0006](../prds/0006-scaling-to-groups-sharding-and-parity.md) - the
  parity draft and trigger.
- [RFC 0028](0028-cross-group-routing.md) - the read semantics parity
  reads participate in.
