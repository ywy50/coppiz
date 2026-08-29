# RFC 0025 - does the fetchable package carry the design docs?

## Status

Discussion - opened 2026-08-29. Addresses [OQ 59](../open-questions.md) (the
register keeps the stable pointer).

An RFC is a *request for comment*: it presents the options and a recommendation
so a decision can be made, and it is not itself the decision record. When it is
decided, set the status, then write the [ADR](../adrs/) that records the choice
and link it from References.

## Overview

`build.zig.zon`'s `.paths` list - the declaration of what a host receives
when it fetches coppiz - names `CHANGELOG.md`, `README.md`, `RELEASES.md`,
`build.zig`, `build.zig.zon` and `src/`. Every design record lives under
`docs/`, and PRD 0001 says a document "is the spec" until code replaces
it, so a host gets a library whose spec is not in the package (SQLite and
dqlite ship theirs).

**Decision to make.** Does the fetchable package include `docs/`, and if
not all of it, what subset?

**Why now.** The first host to fetch coppiz (PRD 0005 phase 5) or the
first public release makes the `.paths` list the shipped contract.

**Drivers.** Any acceptable option must:

- keep the package honest: a host should get the spec for what it
  links, or a clear pointer to where the spec lives;
- not bloat the fetch with every historical record: the package size and
  the "this is a dependency, not a repository" expectation matter;
- keep the operator's private notes out (the brief - excluding it is
  settled, OQ 59's own premise).

**Out of scope.** The versioning of docs with the package (a host fetches
a specific version; docs ride it either way).

## Current state

The `.paths` list excludes `docs/` entirely. The README links the design
records, but the links point at a repository the host may not have
fetched (a fetched package's README links to `docs/...` that are absent
from the package). The glossary, the register and the PRDs are all under
`docs/`.

## Options considered

### Option A - include `docs/` wholesale (out-of-the-box)

- **What it is:** add `docs` to `.paths`.
- **Pros:** the spec ships with the library, like SQLite and dqlite;
  the README's links resolve inside the package.
- **Cons:** every historical record (bug reports, investigations,
  reports) ships in every dependency fetch; the package becomes the
  repository's docs tree, which is larger than a library dependency
  needs.
- **Cost to adopt:** one line in `.paths`.
- **Cost to leave:** hosts fetch a library without its spec.
- **Evidence:** the `.paths` list; PRD 0001's spec-until-code rule.

### Option B - include a curated subset: the README-facing records

- **What it is:** ship `docs/README.md` (the map), the PRDs, ADRs, RFCs,
  research, glossary, register and ROADMAP - the design records - but
  not the reports (bugs, investigations) and runbooks, which are
  operational history, not spec.
- **Pros:** the spec ships; the operational history does not bloat the
  fetch; the boundary is principled (design vs operations).
- **Cons:** a second list in `.paths` to maintain (every new record kind
  must be added); the boundary is a judgment call a host may not share.
- **Cost to adopt:** an explicit per-directory `.paths` list and a test
  that it stays current (the lint-gate family already maintains lists).
- **Cost to leave:** same as A's.
- **Evidence:** the docs taxonomy (design vs reports).

### Option C - keep docs out; the README links the repository

- **What it is:** the status quo; the README's doc links point at the
  repository (hosts with the repo get the spec; fetched packages get the
  links as pointers).
- **Pros:** smallest package; no list to maintain.
- **Cons:** a host that only fetches the dependency cannot read the spec
  without leaving the package - the exact gap SQLite and dqlite do not
  have.
- **Cost to adopt:** none.
- **Cost to leave:** the gap.
- **Evidence:** the current `.paths`.

## Implications by horizon

### Short term (before the first fetch / first release)

- **If A/B:** the `.paths` list changes before any host pins it.

### Medium term

- **If B:** the boundary list is maintained by the docs tooling (OQ 41's
  inventory work).

## Recommendation

**Recommended option:** B - ship the design records (docs/README, PRDs,
ADRs, RFCs, research, glossary, register, ROADMAP, templates) and exclude
the operational history (reports, runbooks). This matches the "the spec
ships with the library" expectation without shipping every incident
report. A is the fallback if the curated boundary proves unmaintainable.

**Confidence:** 7/10

**Why this confidence.** B is principled and matches the comparison set
(SQLite, dqlite); what would move it: evidence that hosts fetch without
the repo and need the full tree (which would argue A), or that the
curated list drifts (arguing C). 

**Rationale.** C leaves the exact gap the question exists to close; A
ships operational history nobody asked for; B draws the line where the
taxonomy already draws it - design records are the spec, reports are the
incident history.

**Reversibility.** A one-line/one-list `.paths` change; reversible until
a host pins the list.

## Open questions

- Does the design/operations boundary hold for the reports a consumer
  might genuinely need (e.g. a known-bug report)? (the docs taxonomy;
  the register already points at open bugs)

## Next steps / action items

- [ ] If B: update `.paths` with the design-record directories and add a
      test that the list matches the taxonomy.
- [ ] Write the ADR once decided; update OQ 59's status.

## References

- [OQ 59](../open-questions.md) - the register entry this RFC addresses.
- [PRD 0001](../prds/0001-journal-core.md) - the "a document is the spec"
  rule.
- [docs/README.md](../README.md) - the taxonomy the boundary uses.
- [OQ 41](../open-questions.md) - the inventory tooling that would
  maintain the list.
