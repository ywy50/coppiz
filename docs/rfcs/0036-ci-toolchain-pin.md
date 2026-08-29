# RFC 0036 - CI and toolchain pin

## Status

Discussion - opened 2026-08-29. Addresses OQ 45 (the
register keeps the stable pointer).

An RFC is a *request for comment*: it presents the options and a recommendation
so a decision can be made, and it is not itself the decision record. When it is
decided, set the status, then write the [ADR](../adrs/) that records the choice
and link it from References.

## Overview

coppiz is Zig 0.16.0, standard library only (ADR 0001). The merge gate already
runs in-tree - `zig build test` includes the lint gates (formatting, the
100-column cap, test registration, declaration analysis, gate coverage), and
`zig build lint` runs them alone - so the question is what CI adds on top of
that.

**Decision to make.** Which Zig build to pin in CI (the 0.16.0 release), and
whether to test musl and glibc targets there.

**Why now.** There is no CI today. The repository's own commits are gated
locally by `zig build test`, which is enough for a solo author; it stops
being enough at the first external contribution, and nothing verifies the
toolchain floor or the platform matrix automatically.

**Drivers.** Any acceptable option must:

- pin the toolchain to what the build script enforces - build.zig.zon declares
  `minimum_zig_version = "0.16.0"`, and build.zig refuses to run under an
  older one, so CI must run the release build, not a nightly;
- gate the same thing CI would gate: `zig build test` with the lint gates
  inside, because the gates are part of the build's contract;
- cover the platform claim: clanker, the strictest known host, wants a static
  musl binary (AGENTS.md), and the tree should not drift from that.

**Out of scope.** The merge-gate half of OQ 45 - that is settled in-tree.
Build reproducibility beyond the platform matrix (caching, hermetic toolchains).

## Current state

- No CI configuration exists (no `.github/workflows`), and no other runner is
  configured.
- The toolchain floor is verified only by whoever runs the build: build.zig
  enforces `minimum_zig_version` itself (Zig checks the `.zon` floor only when
  coppiz is fetched as a dependency, never for a tree built directly).
- The strictest host constraint - a static musl binary - is asserted in
  AGENTS.md and in the examples' build, but no runner exercises it on a clean
  machine.

## Options considered

### Option A - no CI (status quo)

- **What it is:** local `zig build test` remains the only gate.
- **Pros:** zero infrastructure; nothing to maintain.
- **Cons:** an external contribution is un-gated; the toolchain floor is
  verified by nobody in particular; the musl claim stays unverified on clean
  machines.
- **Cost to adopt:** none.
- **Cost to leave:** the moment the repo grows a second author, the first
  broken contribution lands un-gated.
- **Evidence:** the repo's own history - every commit so far passed `zig
  build test` locally, so A has not failed yet.

### Option B - minimal CI: pin Zig 0.16.0, run the merge gate

- **What it is:** a small workflow that installs Zig 0.16.0 and runs `zig
  build test` (lint gates included) on every push and pull request.
- **Pros:** the contribution gate exists; the gate is identical to the local
  one, so CI and local runs cannot disagree; cheap.
- **Cons:** one platform only - the musl/glibc claim stays unverified.
- **Cost to adopt:** one workflow file.
- **Cost to leave:** a single-platform gate that misses the platform half of
  the question.
- **Evidence:** `zig build test` already bundles the gates; the workflow is a
  thin wrapper around it.

### Option C - CI with a platform matrix: musl and glibc plus docs-check

- **What it is:** Option B, plus the platform matrix the OQ names - build and
  test on a static-musl target (clanker's constraint) and a glibc target -
  and `docs-check` as a doc gate so docs break builds the same way they break
  locally.
- **Pros:** the toolchain floor, the merge gate, the platform claim and the
  docs gate are all verified on every change; the matrix is two jobs.
- **Cons:** slightly more CI time than B; the matrix needs a Zig-version step
  that works on both targets.
- **Cost to adopt:** the matrix steps plus the docs-check job.
- **Cost to leave:** a platform claim that rests on local runs only.
- **Evidence:** the examples build against both flavors today (embed-single,
  embed-cluster, sidecar); the OQ names the two targets explicitly.

## Implications by horizon

### Short term

- **If C:** add `.github/workflows/ci.yml`: Zig 0.16.0, `zig build test` on
  musl and glibc, plus `python3 scripts/project-kit.py docs-check` (or `zig
  build docs-check`).

### Medium term

- **If C:** when the fetchable package ships (PRD 0005 phase 5), the same
  workflow can add the dependency-consumer build - the `.zon` floor check that
  only happens when coppiz is fetched.

## Recommendation

**Recommended option:** C - pin Zig 0.16.0 in CI with the platform matrix and
docs-check. A is the status quo that stops working at the first external
contribution; B answers the gate half but leaves the platform half of the
question unverified.

**Confidence:** 7/10

**Why this confidence.** The pin is unambiguous (build.zig.zon declares it,
build.zig enforces it); the only judgment is whether the matrix is worth two
jobs, and the strictest host is already a musl constraint. What would move
it: a CI-host constraint that makes the musl target awkward (arguing B until
it is resolved).

**Rationale.** CI's whole value here is verifying on a clean machine what
`zig build test` verifies locally, on the platforms the project claims. B
gets the gate; C gets the claim, at the cost of one extra job.

**Reversibility.** C is a workflow file: dropping to B or A is a deletion.

## Open questions

- Which runner (GitHub Actions is assumed; the repo is GitHub-hosted).
- Whether the musl job should also run the examples (`zig build
  examples`-style target), or the unit test binary alone.

## Next steps / action items

- [ ] Add `.github/workflows/ci.yml` per the short-term plan.
- [ ] Run it against a first pull request and confirm both targets build.
- [ ] Write the ADR once decided; update OQ 45's status.

## References

- OQ 45 (historical) - the question this RFC addresses.
- [ADR 0001](../adrs/0001-zig-0-16-standard-library-only-for-the-core.md) -
  the toolchain the pin names.
- [AGENTS.md](../../AGENTS.md) - the strictest-host (static musl) constraint
  the matrix verifies.
