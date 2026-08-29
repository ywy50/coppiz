# RFC 0021 - which non-clanker hosts are the design targets?

## Status

Discussion - opened 2026-08-29. Addresses OQ 46 (the
register keeps the stable pointer).

An RFC is a *request for comment*: it presents the options and a recommendation
so a decision can be made, and it is not itself the decision record. When it is
decided, set the status, then write the [ADR](../adrs/) that records the choice
and link it from References.

## Overview

coppiz is general-purpose by brief (clarified 2026-08-21: for anyone with
this class of problem, not clanker specifically), but every concrete
constraint so far comes from one host. Naming two or three other host
shapes - a CLI tool in short processes, a long-lived service on a few
machines, an embedded/edge fleet with flaky links - would show which API
shapes are general and which are clanker's.

**Decision to make.** Which host shapes are the explicit design targets,
and how does the design stay honest about them (a second example host in
`examples/`)?

**Why now.** PRD 0005's API is pre-1.0; the shapes that constrain it are
still only clanker's. Naming targets now is cheaper than discovering a
shape mismatch after the API freezes.

**Drivers.** Any acceptable option must:

- keep the library host-agnostic (ADR 0003: nothing in `src/` knows a
  host);
- produce checkable constraints, not prose: each target shape should map
  to concrete API properties (threading, sync vs async, size-1 cost,
  multi-process);
- not invent a fake host to justify decisions already made.

**Out of scope.** The first real second host's identity (that is a future
integration). The clanker integration itself (PRD 0005 phase 5).

## Current state

clanker is the only host, and its constraints (static musl binary,
sandboxed guests, no second daemon, one process per data directory) are
the strictest known - the docs keep them in view for that reason, not
because clanker is the target (docs/README *Hosts*). The examples
directory has three shapes, all derived from clanker's needs (embedded
single, embedded cluster, wire sidecar).

## Options considered

### Option A - keep clanker-only until a real second host appears (status quo)

- **What it is:** no explicit targets; the API is shaped by clanker and
  checked for generality only by reasoning.
- **Pros:** no speculative work; the strictest host's constraints are
  supersets of most others' (sandbox, single binary, no daemon).
- **Cons:** "superset" is an assumption; a shape clanker does not
  exercise (many short-lived processes, flaky-link edge, multi-machine
  service) may silently assume the wrong API.
- **Cost to adopt:** none.
- **Cost to leave:** an API frozen against the wrong shape.
- **Evidence:** the docs' host-agnostic rule; the clanker constraints.

### Option B - name the target shapes now, one second example host (out-of-the-box)

- **What it is:** the design names three shapes - (1) a CLI tool running
  in short processes, (2) a long-lived service on a few machines, (3) an
  embedded/edge fleet with flaky links - each with checkable API
  properties, and `examples/` gains one second host that exercises the
  shape clanker does not (e.g. the short-process CLI: open, append, read,
  close, repeatedly). The concrete second *consumer* still waits for a
  real one.
- **Pros:** the API is tested against a shape clanker does not exercise;
  the example host is the honest check the roadmap names; cheap.
- **Cons:** an example host is still a synthetic host - it proves the API
  *can* serve the shape, not that a real consumer wants it.
- **Cost to adopt:** the shape table plus one example host.
- **Cost to leave:** none.
- **Evidence:** the roadmap's "a second, unrelated host example follows
  to keep the API general"; PRD 0005's examples.

### Option C - design for a specific named second host

- **What it is:** pick a real target (e.g. a mesh node, a job runner) and
  shape the API to it.
- **Pros:** the strongest check.
- **Cons:** there is no named real host; inventing one is exactly the
  fake-host trap.
- **Cost to adopt:** the highest; speculative.
- **Cost to leave:** the invented target's constraints leak into the API.
- **Evidence:** the brief's general-purpose clarification.

## Implications by horizon

### Short term (this release / 0-3 months)

- **If B:** the shape table lands in PRD 0005; the second example host
  is chosen and built.

### Medium term (3-12 months)

- **If B and a real second host appears:** the example host is replaced
  or complemented by it; the shape table is checked against it.

## Recommendation

**Recommended option:** B - name the three shapes with checkable
properties, and add one second example host that exercises the shape
clanker does not (the short-process CLI is the cheapest: open, append,
read, close, repeatedly). C is rejected - there is no real second host to
name.

**Confidence:** 6/10

**Why this confidence.** B is the roadmap's own plan and cheap; what
would move it: a real second host appearing (making C possible). What
would sink it: the example host proving too synthetic to catch real
shape problems.

**Rationale.** The strictest-host argument (A) is sound but unchecked; B
adds the check the roadmap already promised, at the cost of one example
host. C invents a target - the opposite of the brief's "anyone with this
problem".

**Reversibility.** B is additive (docs + one example).

## Open questions

- Which second example host shape first - the short-process CLI, or the
  long-lived service? (implementation; the CLI is cheapest and exercises
  the multi-process story of RFC 0006)

## Next steps / action items

- [ ] Add the shape table to PRD 0005 and pick the second example host.
- [ ] Write the ADR once decided; update OQ 46's status.

## References

- OQ 46 (historical) - the question this RFC addresses.
- [PRD 0005](../prds/0005-embedding-the-library-as-the-product.md) - the
  examples and the host-agnostic rule.
- [ADR 0003](../adrs/0003-batteries-included-no-external-infrastructure-at-any-size.md) -
  the general-purpose stance.
- [RFC 0006](0006-multi-process-one-data-directory.md) - the multi-process
  story a short-process CLI would exercise.
