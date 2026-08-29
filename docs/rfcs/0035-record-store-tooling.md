# RFC 0035 - record-store tooling

## Status

Discussion - opened 2026-08-29. Addresses [OQ 41](../open-questions.md) (the
register keeps the stable pointer).

An RFC is a *request for comment*: it presents the options and a recommendation
so a decision can be made, and it is not itself the decision record. When it is
decided, set the status, then write the [ADR](../adrs/) that records the choice
and link it from References.

## Overview

The design records (PRDs, ADRs, RFCs, research) are hand-authored prose; the
question is what tooling maintains the *store* around them - the inventories,
the numbering, the cross-links. clanker keeps its stores with sandboxed tools
(`clanker rfc`, `clanker adr`, ...) that write compare-and-swap and keep the
inventories in sync. coppiz's stores are hand-maintained, and inventories drift
the way clanker's did before its tools existed.

**Decision to make.** Reuse clanker's tools pointed at this tree, or accept
hand maintenance until the project is bigger?

**Why now.** The store is not small anymore: 6 PRDs, 8 ADRs, 36 RFCs, plus
research and reports, all cross-referencing each other and the open-questions
register. The OQ was opened when the store was a fraction of this.

**Drivers.** Any acceptable option must:

- not couple coppiz's docs workflow to another host's runtime (ADR 0003's
  spirit: no external infrastructure at any size - that is a `src/` rule, but
  a docs pipeline that requires clanker's sandbox has the same smell);
- catch drift, because drift is the failure this question exists to fix;
- cost little, because the records are prose and no tool can author them.

**Out of scope.** The content of the records. The docs-check rule set itself
(em dashes, paragraph length, link checking) - that exists and is enforced
already.

## Current state

- The per-store inventories (`docs/*/README.md`) are hand-maintained, per
  [AGENTS.md](../../AGENTS.md) ("hand-maintained until tooling exists (OQ
  41)").
- `scripts/docs-index.sh` generates the top-level `docs/INDEX.md` from PRDs,
  ADRs, plans, handovers, reviews, reports, prompts and agent rules - but it
  does not cover `rfcs/` or `research/`, and it never touches the per-store
  READMEs.
- `project-kit.py docs-check` validates required PRD/ADR sections, local
  Markdown links, record numbering, the generated index, and readability
  (paragraph length); it is a hard gate in `zig build test`.
- clanker's tools (`clanker rfc`, `clanker adr`, ...) exist and work, but they
  are clanker-hosted: sandboxed, named for clanker's store, and unaware of
  coppiz's conventions (RFCs exist here; clanker's do not).

## Options considered

### Option A - reuse clanker's tools pointed at this tree

- **What it is:** run `clanker rfc`, `clanker adr`, ... against coppiz's
  `docs/`, writing compare-and-swap and syncing the inventories.
- **Pros:** proven machinery; CAS writes; inventories never drift.
- **Cons:** coppiz's docs workflow starts depending on clanker's sandbox
  (another host's runtime, against ADR 0003's spirit); the tools would need
  retargeting for coppiz's record kinds and conventions; the benefit - sync
  inventories - is already largely covered by docs-check catching drift.
- **Cost to adopt:** the retargeting, and a standing dependency.
- **Cost to leave:** none.
- **Evidence:** clanker's tools and their pre-tooling drift history (the OQ's
  own note).

### Option B - hand-maintained until the project is bigger (status quo)

- **What it is:** keep the README inventories manual; docs-check stays the
  drift detector.
- **Pros:** no coupling, no tooling cost, no new dependency.
- **Cons:** the OQ's point stands - the inventories are one forgetful edit
  from staleness, and the store is already at 36 RFCs; "until bigger" is
  now.
- **Cost to adopt:** none.
- **Cost to leave:** continued manual rows.
- **Evidence:** every batch of this migration hand-edited
  `docs/rfcs/README.md`; docs-check was what caught the one broken row.

### Option C - hand-maintained records + the kit's indexer and checkers as the tooling

- **What it is:** extend `docs-index.sh` to cover `rfcs/` and `research/` in
  `docs/INDEX.md`; keep docs-check as the hard gate that catches inventory
  drift, dead links and stale index rows; keep the README rows manual but
  verified. clanker's tools remain the reference for what a full writer would
  look like if the store grows enough to need one.
- **Pros:** exists and already catches drift (Option B's only failure mode);
  no external dependency; the indexer extension is small and stays in-tree.
- **Cons:** does not *write* records - but no tool can author an RFC; the
  per-store READMEs stay manual, checked rather than generated.
- **Cost to adopt:** the `docs-index.sh` extension (RFCs + research) and its
  docs-check coverage.
- **Cost to leave:** a `docs/INDEX.md` that omits two of the store's kinds.
- **Evidence:** docs-index.sh's existing `write_rows` writer is reusable
  verbatim for RFCs; docs-check already gates the index's freshness
  (`--check`).

## Implications by horizon

### Short term

- **If C:** one small scripts change plus a docs-check fixture for the two new
  sections; RFC and research rows in `docs/INDEX.md` appear.

### Medium term

- **If C:** if the store keeps growing and the README inventories keep
  needing manual care, that is the signal to build the full writer - with
  clanker's tools as the reference, not the dependency.

## Recommendation

**Recommended option:** C - hand-maintained records, the kit's indexer and
checkers as the tooling. A is rejected (external dependency, ADR 0003's
spirit); B is the status quo whose failure mode docs-check already answers.

**Confidence:** 6/10

**Why this confidence.** The evidence for "inventories drift" is real but the
drift is already caught; the open question is whether the residual manual rows
justify a writer. What would move it: a second observed inventory break
through the gate (arguing for the writer sooner), or the store tripling
(arguing A).

**Rationale.** The tooling's job is to catch drift, and docs-check already
does; the indexer extension removes the two kinds the generated index omits.
A writer is the answer when *authoring* hurts, not when *checking* does.

**Reversibility.** C is additive: the scripts change is small, and A stays
available if the store outgrows it.

## Open questions

- Should docs-check enforce that every store row's target exists (the batch-5
  broken-row failure)? (It does check links; the row-format check is the
  gap.)

## Next steps / action items

- [ ] Extend `scripts/docs-index.sh` with RFC and research sections.
- [ ] Regenerate `docs/INDEX.md` and run docs-check.
- [ ] Write the ADR once decided; update OQ 41's status.

## References

- [OQ 41](../open-questions.md) - the register entry this RFC addresses.
- [ADR 0003](../adrs/0003-batteries-included-no-external-infrastructure-at-any-size.md) -
  the no-external-infrastructure principle the recommendation leans on.
- `scripts/docs-index.sh` and `scripts/project-kit.py docs-check` - the
  existing tooling this RFC builds on.
