# RFC 0037 - `write.ack`: the `local` variant and its layer

## Status

Discussion - opened 2026-08-29. Addresses [OQ 3](../open-questions.md) (the
register keeps the stable pointer).

An RFC is a *request for comment*: it presents the options and a recommendation
so a decision can be made, and it is not itself the decision record. When it is
decided, set the status, then write the [ADR](../adrs/) that records the choice
and link it from References.

## Overview

The shipped write path acknowledges at the slot everywhere: `node.append`, the
wire append and `cluster.ClusterNode.localAppend` all block until the entry's
slot folds back. What is open is a `local` ack variant - return as soon as the
queue holds the entry durably - and the *layer* the choice lives at.

**Decision to make.** Where does `write.ack = local` live: a chain setting, a
local setting, or a per-call parameter with a configured default?

**Why now.** PRD 0003 phase 5 is shipped and PRD 0005 phase 5 (the first host
branch) is next; the first host will want the `local` variant before its
streams are built. `localAppend`'s docstring already names the variant as open
question 3.

**Drivers.** Any acceptable option must:

- let a writer ask for `slotted` - PRD 0003 assumes that without saying where
  the choice lives (a writer on the losing side that asked for `slotted` gets
  to retry, PRD 0003's *Merge* section);
- not add replicated state for a property that cannot disagree - the OQ's key
  observation is that ack mode cannot fork the journal, because the slot
  position is the same for every member;
- keep the default the shipped behaviour: block until the slot folds back.

**Out of scope.** The `ack` semantics of the wire protocol's response (the
wire already returns the entry id on the slot; a `local` ack is a timing
change, not a shape change). Backpressure - RFC 0012 owns that.

## Current state

- Every write path acknowledges at the slot (`node.append`, the wire append,
  `cluster.ClusterNode.localAppend`); `localAppend` blocks the host's thread
  until the slot folds back (`src/cluster/node.zig:413`).
- PRDs 0001 and 0006 call `write.ack` a setting (`local | slotted`, honoured
  by the owning group); PRD 0003 assumes a writer can ask for `slotted`
  without naming the layer. The settings schema has no `write.ack` key yet
  (PRD 0004).
- clanker's RFC 0019 open question 1 ("stall or keep working") is the host
  side of the same tradeoff; the OQ names it as the operator input.

## Options considered

### Option A - a chain setting (`write.ack` in the replicated settings)

- **What it is:** a settings-schema entry (PRD 0004) that every member folds;
  the owning group honours it.
- **Pros:** matches PRDs 0001 and 0006 as drafted; one knob for the whole
  journal, visible to every member.
- **Cons:** ack mode is a *per-writer* tradeoff (a follower writing through a
  partitioned leader wants `local` while the group's default stays
  `slotted`); disagreement cannot fork the journal, so replicating the knob
  manages a disagreement that cannot happen. A single chain value cannot
  express "this writer wants local, the group stays slotted" at all.
- **Cost to adopt:** a settings key, schema generation, fold handling.
- **Cost to leave:** none - nothing depends on it being a chain setting.
- **Evidence:** PRD 0001:259, PRD 0006:138; the OQ's "cannot fork" note.

### Option B - a local setting only

- **What it is:** a local-config key that names the member's default ack
  mode; every append this member makes honours it.
- **Pros:** simple; the disagreement-can't-happen argument points here; no
  replicated state.
- **Cons:** cannot express the per-call ask PRD 0003 assumes ("a writer can
  ask for `slotted`") - a local default alone is a blunt instrument for a
  mixed workload.
- **Cost to adopt:** one local-config key.
- **Cost to leave:** none.
- **Evidence:** the OQ's "suggests local config or a call parameter with a
  configured default".

### Option C - a per-call parameter with a local-config default

- **What it is:** the write APIs take an ack mode (default `slotted`, the
  shipped behaviour); a local-config key sets the default for writers that
  do not pass one. `localAppend`'s docstring variant becomes the parameter.
- **Pros:** both PRDs' claims hold - the setting exists (as the default) and
  a writer can ask for `slotted` (per call); the shipped behaviour stays the
  default; nothing replicated.
- **Cons:** a parameter on every write API (a small, optional arg); the
  local-config key and the parameter can disagree for one call (which is the
  point - per-call override).
- **Cost to adopt:** the parameter, the local key, the docstring update.
- **Cost to leave:** none.
- **Evidence:** `localAppend`'s docstring names exactly this shape; the OQ's
  phrasing is C's.

## Implications by horizon

### Short term (PRD 0005 phase 5)

- **If C:** the host branch calls `localAppend` with the `local` mode and a
  durably-queued return; the wire append gains the same optional parameter.

### Medium term

- **If C:** PRD 0006's group writes inherit the parameter ("returns when the
  owner acknowledges"); the local default stays the fallback.

## Recommendation

**Recommended option:** C - a per-call ack parameter with a local-config
default. A is rejected (replicated state for a property that cannot
disagree, and it cannot express a per-writer choice); B is a component of C
(the default), not a complete answer.

**Confidence:** 7/10

**Why this confidence.** The "cannot fork" argument is the OQ's own and it is
solid; the only judgment is whether the per-call surface is worth the
parameter, and PRD 0003 already assumes the per-call ask exists. What would
move it: a host requirement that the mode be settable by a non-programmer
(arguing A).

**Rationale.** Ack mode is a latency-vs-visibility tradeoff made per write
under a partitioned leader; it is local by nature. C gives the writer the
choice, the group the default, and the shipped behaviour the default value.

**Reversibility.** C is additive: the parameter defaults to the shipped
behaviour, so adopting it later does not change the wire or the store.

## Open questions

- Should the wire protocol carry the ack mode as a field, or as a distinct
  verb? (The wire append's response shape stays the same either way.)

## Next steps / action items

- [ ] Add the ack parameter to `node.append`, the wire append and
      `localAppend`; add the local-config default key (PRD 0004).
- [ ] Update PRDs 0001 and 0006 to name the layer C picks.
- [ ] Write the ADR once decided; update OQ 3's status.

## References

- [OQ 3](../open-questions.md) - the register entry this RFC addresses.
- [PRD 0001](../prds/0001-journal-core.md) and
  [PRD 0006](../prds/0006-scaling-to-groups-sharding-and-parity.md) - the
  `write.ack` setting as drafted.
- [PRD 0003](../prds/0003-membership-and-leadership.md) - the per-call
  `slotted` assumption and the losing-side retry.
- [RFC 0012](0012-backpressure.md) - the adjacent backpressure question.
- `src/cluster/node.zig:413` - `localAppend` and its docstring.
