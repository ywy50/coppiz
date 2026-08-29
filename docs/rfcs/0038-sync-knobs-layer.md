# RFC 0038 - the `sync.*` knobs: layer and values

## Status

Discussion - opened 2026-08-29. Addresses [OQ 56](../open-questions.md) (the
register keeps the stable pointer).

An RFC is a *request for comment*: it presents the options and a recommendation
so a decision can be made, and it is not itself the decision record. When it is
decided, set the status, then write the [ADR](../adrs/) that records the choice
and link it from References.

## Overview

Three knobs are named in the PRDs but appear in no settings table:
`sync.page_bytes`, `sync.lag_slots` and `sync.gap_timeout_ms`. Each is a
"who decides" question: local config (a per-member choice, risks only that
member) or a chain setting (replicated, folded, agreed by the group).

**Decision to make.** The layer of each knob, and its default value.

**Why now.** The knobs are exercised by the shipped sync path (PRD 0001 phase
5): backfill pages are bounded, `syncing` members need a head threshold for
leader eligibility, and held gaps need a timeout. One knob already has a
provisional local value (`page_bytes`); the other two have none.

**Drivers.** Any acceptable option must:

- let disagreement be harmless where it can be - the OQ's test is "does
  disagreeing break the group?";
- elect leaders deterministically - leader eligibility must mean the same
  thing to every member;
- give each knob a default that ships, so the settings schema is complete
  (PRD 0004).

**Out of scope.** The timing values themselves where they are measurement
(OQ 54 owns the failure-detector and checkpoint timings; this RFC owns the
*layer*, with defaults as placeholders on the record).

## Current state

- `sync.page_bytes` (backfill page bound, PRD 0001 *Backfill*): provisional
  local value 64 KiB (`provisional_page_bytes` in `src/cluster/node.zig:48`,
  which names the missing layer in its comment).
- `sync.lag_slots` (when a `syncing` member counts as at head, and so
  leader-eligible, PRD 0003 *Member states*): named in
  `src/cluster/election.zig:23`, no value and no layer.
- `sync.gap_timeout_ms` (when a held gap is refused `unknown_target`, PRD
  0002 failure modes): named in PRD 0002's failure table, no value and no
  layer, and no code reference.
- `sync.unslotted_max_bytes` already landed as a local-config key (OQ 55,
  resolved); it is the sibling precedent for the local half of this question.

## Options considered

### Option A - all three as chain settings

- **What it is:** a settings-schema entry per knob; every member folds them;
  a change is a chain event.
- **Pros:** uniform; a `lag_slots` change cannot put members on different
  eligibility thresholds.
- **Cons:** `page_bytes` and `gap_timeout_ms` risk only their own tail - a
  member with a small page bound backfills slower, a member with a short gap
  timeout refuses a gap sooner; replicating those manages a disagreement
  that cannot break the group. Chain settings also cost schema and fold
  machinery per knob.
- **Cost to adopt:** three settings keys plus fold handling.
- **Cost to leave:** none.
- **Evidence:** the OQ's own split ("a page size only risks its own tail,
  which suggests local").

### Option B - all three as local config

- **What it is:** three local-config keys; every member reads its own.
- **Pros:** simple; matches the `page_bytes` precedent.
- **Cons:** `lag_slots` elects leaders - two members with different
  thresholds can disagree about who is at head, and PRD 0003 makes at-head a
  leader-eligibility condition. Local config is the wrong layer for a
  group-agreed fact.
- **Cost to adopt:** three local keys.
- **Cost to leave:** none.
- **Evidence:** PRD 0003's member states; `election.zig`'s eligibility rule.

### Option C - split by what needs agreement (recommended)

- **What it is:** `lag_slots` as a chain setting (leader eligibility is a
  cluster property; a disagreement can elect different leaders). `page_bytes`
  and `gap_timeout_ms` as local config (each risks only its own tail; the
  64 KiB `page_bytes` provisional stands, `gap_timeout_ms` ships a placeholder
  default with the measurement on the record at OQ 54).
- **Pros:** each knob sits at the layer its failure mode justifies; the
  precedent (OQ 55's local key, `page_bytes`) is honoured; one replicated
  knob instead of three.
- **Cons:** two layers for one `sync.*` family - a small asymmetry in the
  settings tables.
- **Cost to adopt:** one chain key (`lag_slots`) with schema and fold
  handling; two local keys.
- **Cost to leave:** none.
- **Evidence:** the OQ's per-knob reasoning; the `page_bytes` provisional.

## Implications by horizon

### Short term

- **If C:** `lag_slots` enters the settings schema with a provisional value;
  `page_bytes` stays local at 64 KiB; `gap_timeout_ms` becomes a local key
  with a placeholder default.

### Medium term

- **If C:** measurement replaces the placeholder defaults (OQ 54); the
  `lag_slots` chain value is tuned like any other chain setting.

## Recommendation

**Recommended option:** C - `lag_slots` chain, `page_bytes` and
`gap_timeout_ms` local. A replicates disagreement that cannot break the
group; B puts a leader-eligibility threshold where a per-member value can
disagree.

**Confidence:** 7/10

**Why this confidence.** The "what can disagreement break" test is decisive
and the OQ states it; the only judgment is whether the split's asymmetry is
worth it, and the failure modes make it so. What would move it: a design
where `lag_slots` stops being leader-eligibility-relevant (arguing B).

**Rationale.** A knob's layer should match the blast radius of disagreeing
on it. Only `lag_slots` has a cluster blast radius; the other two are
self-contained per-member tuning.

**Reversibility.** Moving a knob between layers later is a settings-schema
change - visible, but mechanical.

## Open questions

- The provisional default for `gap_timeout_ms` (a placeholder on the record,
  measured under OQ 54).
- Whether `lag_slots` should be expressed as a slot delta or a time delta
  (PRD 0003 says slots; time would couple it to the heartbeat cadence).

## Next steps / action items

- [ ] Add `lag_slots` to the settings schema; add the two local keys.
- [ ] Wire `gap_timeout_ms` into the held-gap refusal path (PRD 0002).
- [ ] Write the ADR once decided; update OQ 56's status.

## References

- [OQ 56](../open-questions.md) - the register entry this RFC addresses.
- [PRD 0001](../prds/0001-journal-core.md) - *Backfill* (`page_bytes`).
- [PRD 0003](../prds/0003-membership-and-leadership.md) - *Member states*
  (`lag_slots`).
- [PRD 0002](../prds/0002-ttl-and-staleness.md) - failure modes
  (`gap_timeout_ms`).
- [RFC 0019](0019-journal-lifecycle.md) and OQ 55 - the local-config
  precedent for the local half.
- `src/cluster/node.zig:48` and `src/cluster/election.zig:23` - the code
  sites that name the knobs.
