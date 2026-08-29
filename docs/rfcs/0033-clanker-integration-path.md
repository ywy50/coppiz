# RFC 0033 - the clanker integration path

## Status

Discussion - opened 2026-08-29. Addresses [OQ 30](../open-questions.md) (the
register keeps the stable pointer).

An RFC is a *request for comment*: it presents the options and a recommendation
so a decision can be made, and it is not itself the decision record. When it is
decided, set the status, then write the [ADR](../adrs/) that records the choice
and link it from References.

## Overview

clanker's RFC 0019 names a stage-1 spike - a throwaway experiment to prove
the shared-state-store shape - specified in clanker's tree and unrun. The
question: run the spike there first and then build coppiz, or build
coppiz's core and make the spike *use* coppiz?

**Decision to make.** Which order, and which code survives into the real
integration (PRD 0005 phase 5)?

**Why now.** coppiz's core is built and tested; PRD 0005 phase 5 (the
clanker branch with `ck_state`) is the next milestone. The spike's purpose
- proving the shape - is largely served by what now exists.

**Drivers.** Any acceptable option must:

- not build the same logic twice: the cursor/follow machinery exists in
  coppiz; a spike that reimplements it is waste;
- give clanker a decision about its mesh: the spike's real output is the
  answer "coppiz fits" or "coppiz does not fit", at the least cost.

**Out of scope.** The integration's feature set (PRD 0005 phase 5). The
second host (RFC 0021).

## Current state

clanker's RFC 0019 stage-1 spike is specified and unrun (research 0001
carries the read dates). coppiz's core ships the pieces the spike was to
prove: replicated append-only journals, backfill, the embedded write path
(PRD 0005 steps 1-3).

## Options considered

### Option A - run the spike first, then build coppiz (status quo drafted)

- **What it is:** write the spike in clanker's tree as RFC 0019
  specified, learn from it, then build.
- **Pros:** clanker gets an answer without depending on coppiz.
- **Cons:** the spike's questions are now answerable directly with
  coppiz - building it separately builds the cursor/follow logic twice
  (the OQ's own point), and its conclusions would be about a shape
  coppiz already implements better.
- **Cost to adopt:** the spike's authoring cost, duplicated logic.
- **Cost to leave:** none.
- **Evidence:** research 0001's spike note; PRD 0005's shipped steps.

### Option B - build coppiz's core, make the spike use coppiz (out-of-the-box)

- **What it is:** the spike becomes the *integration test*: a clanker
  branch fetches coppiz, adds `ck_state` behind a flag, routes one
  stream through it, and measures against the spike note's three
  journeys (burst, backfill, hostile wire). The spike's "answer" is the
  integration's pass/fail.
- **Pros:** no logic built twice; the spike and the integration are the
  same work; the embedded write path (PRD 0005 G6) gets its first real
  proof.
- **Cons:** clanker's answer waits for the integration branch (but the
  core exists - the wait is small); the spike's independence is lost
  (it can no longer conclude "maybe coppiz is wrong" without building
  it).
- **Cost to adopt:** the clanker branch (PRD 0005 phase 5 work).
- **Cost to leave:** the spike as a separate throwaway.
- **Evidence:** PRD 0005's phase-5 plan; the shipped embedded paths.

### Option C - the spike as a throwaway *outside* clanker

- **What it is:** a minimal harness that drives coppiz's library the way
  clanker would, without touching clanker's tree.
- **Pros:** an answer fast, no clanker changes.
- **Cons:** a harness is not the integration; the real answer needs the
  clanker branch anyway.
- **Cost to adopt:** the harness.
- **Cost to leave:** none.
- **Evidence:** the examples already serve this role partially.

## Implications by horizon

### Short term (PRD 0005 phase 5)

- **If B:** the clanker branch is the spike.

### Medium term

- **If B:** the branch's three-journey measurement is the RFC 0019
  answer.

## Recommendation

**Recommended option:** B - the spike and the integration are the same
work: a clanker branch that fetches coppiz, adds `ck_state`, routes one
stream, and measures the three journeys. A is rejected (duplicate logic);
C is a pre-step only if clanker cannot be touched yet.

**Confidence:** 8/10

**Why this confidence.** The core exists; the spike's questions are the
integration's questions now. What would move it: a clanker constraint
making the branch impossible before a decision (arguing C first).

**Rationale.** The spike existed to prove a shape; the shape now ships as
the library. Building the proof separately duplicates logic whose
behavior is already tested; B converts the spike into the acceptance test
it was always meant to be.

**Reversibility.** B is the phase-5 work; the branch is throwaway-able if
the answer is "does not fit".

## Open questions

- Which stream first (the session `events` or a JSONL stream)? (PRD
  0005's own first-consumer plan; sessions are explicitly not first)

## Next steps / action items

- [ ] Start the clanker branch per PRD 0005 phase 5 (fetch coppiz,
      `ck_state`, one stream, three journeys).
- [ ] Write the ADR once decided; update OQ 30's status.

## References

- [OQ 30](../open-questions.md) - the register entry this RFC addresses.
- [PRD 0005](../prds/0005-embedding-the-library-as-the-product.md) -
  phase 5 and the first-consumer plan.
- research 0001 - the spike note and its journeys.
