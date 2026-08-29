# RFC 0001 - Library-first or service-first: which surface leads the design

## Status

Decided - 2026-08-28, option A (library-first; the node binary is a thin
wrapper). [ADR 0007](../adrs/0007-the-library-is-the-primary-surface.md)
records the choice; PRD 0005's steps 1–3 (the embedded write path and the
`examples/` hosts) shipped with it, and its step-4 service API stays deferred
as a wrapper module behind the first non-Zig consumer. Opened 2026-08-21;
clanker's RFC 0019 (option T, Packaging) named this "the new project's first
design decision".

An RFC is a *request for comment*: it presents the options and a recommendation
so a decision can be made, and it is not itself the decision record. When it is
decided, set the status, then write the
[ADR](../adrs/) that records the choice and link it from References. A later
reversal supersedes that ADR; this file keeps the reasoning that produced it.

## Overview

**Decision to make.** Which of the two integration surfaces - an embeddable
Zig library (the dqlite shape) or a standalone node with a service API (the
rqlite shape) - is the primary contract whose design drives the other?

**Why now.** The two shapes pull the core in different directions from the
first line of code: who owns I/O and threads (the host, or the node), whether
the API is synchronous calls or request/response over a wire, how settings
are delivered (struct, or config file), and what "version" means for
compatibility (Zig declarations, or an HTTP contract). Building both as
equals doubles the stable surface before there is one user.

**Drivers.**

1. Any Zig host must be able to use it with nothing stood up beside it
   ([ADR 0003](../adrs/0003-batteries-included-no-external-infrastructure-at-any-size.md)).
   The first host, clanker, is the strictest known instance of that: a Zig
   0.16 musl static binary with two fetched dependencies, a rule that `serve`
   owns sockets, a sandbox whose guests never get a path or a socket, and a
   stated non-goal of a second daemon (clanker PRD 0011).
2. Public release: non-Zig consumers and operators need *some* way in that
   does not require linking Zig.
3. One implementation of every rule: whichever surface is secondary must be a
   thin wrapper, never a second opinion (clanker's CLI/web-UI-over-one-tool
   rule).
4. Size-1 simplicity: opening a journal must be as cheap as opening a SQLite
   file.

**Out of scope.** The wire protocol for replication between members ([OQ
19](../open-questions.md)) - that exists in either shape. Language bindings
beyond Zig (roadmap).

## Current state

Nothing of the design is implemented; `src/root.zig` carries only the package
version so far.

clanker's shared state was JSON/JSONL files under
`state/` when RFC 0019 surveyed it (2026-08-19); since its ADR 0033
(accepted 2026-08-20) sessions are per-session SQLite databases written
directly in-process, their append-only `events` stream replicating to mesh
peers at `cursor + 1`, while the remaining JSONL streams have no replication
and the symlink + `shared_root` workaround stands
([research 0001](../research/0001-evidence-carried-from-the-state-store-survey.md);
[PRD 0005](../prds/0005-embedding-the-library-as-the-product.md), *Example
host*). The stage-1 spike RFC 0019 names has not been run.

## Options considered

### Option A - Library-first; the node binary is a thin wrapper

- **What it is:** `src/root.zig` is the product. `Node.open(io, alloc,
  options)` returns a handle; the host supplies `std.Io` and drives `run()`.
  `src/main.zig` is that library plus TOML parsing and a CLI; a service API,
  if any, is added later as a wrapper module and versioned separately.
- **Maturity:** the dqlite/SQLite shape; proven for embedding.
- **How it would fit:** clanker adds a third `build.zig.zon` dependency, a
  `ck_state` host channel, and calls the library inside `serve`. No second
  process, keys never leave the host.
- **Pros:** exactly clanker's constraints; one binary; host controls threads
  and I/O (no surprise listeners); size-1 use is a function call; the
  service API, when added, is forced to be a wrapper by construction.
- **Cons:** non-Zig consumers wait for the wrapper or a C ABI; the public
  contract is Zig declarations, which pre-1.0 Zig churn makes fragile; a
  library cannot be upgraded independently of its host (clanker must rebuild
  to pick up a coppiz fix).
- **Cost to adopt:** none beyond building the core; this is the default
  direction of the PRDs as drafted.
- **Cost to leave:** moderate - moving to service-first later means the API
  becomes request/response and the host's `std.Io` ownership inverts.
- **Evidence:** clanker RFC 0019 option T Packaging paragraph; dqlite's role
  in LXD (embedded, no separate process) - read 2026-08-16 in clanker's
  research note, carried here ([research 0001](../research/0001-evidence-carried-from-the-state-store-survey.md)).

### Option B - Service-first; the library is internal

- **What it is:** the `coppiz` node and its HTTP/JSON API are the product; the
  Zig library exists but is not a stable contract. Hosts, clanker included,
  run a node and speak HTTP.
- **Maturity:** the rqlite/etcd shape; every language can use it on day one.
- **How it would fit:** clanker runs a `coppiz` process per instance and a
  WASM guest or native client speaks loopback HTTP (PRD 0005 route B).
- **Pros:** language-neutral from the start; independent upgrade of the
  store; the contract is an HTTP API, which versions cleanly; operators can
  `curl` it.
- **Cons:** a second daemon, which clanker's PRD 0011 explicitly rules out
  and RFC 0019 counts against Corrosion; clanker's `network_allow` cannot
  scope a guest to one local port (RFC 0019 option A evidence), so route B
  is a weaker sandbox story than a host channel; size-1 use means running a
  process to append a line; every call pays a request.
- **Cost to adopt:** the API and its versioning are on the critical path
  before any consumer exists.
- **Cost to leave:** high - consumers bound to HTTP shapes.
- **Evidence:** rqlite (HTTP API, standalone process) per clanker's research
  note; clanker `src/sandbox/host.zig` `networkAllowed` glob-matches hostname
  and never examines port (RFC 0019 option A).

### Option C - Both are first-class, one tree

- **What it is:** commit to both contracts from the start, each with its own
  compatibility promise.
- **Pros:** no consumer is second-class.
- **Cons:** two stable surfaces to keep compatible before one user exists;
  every feature lands twice; the pressure toward "the service does something
  the library does not" is exactly the drift driver 3 forbids.
- **Cost to adopt:** roughly double the surface work for the first year.
- **Evidence:** design reasoning; no external source.

### Option D - Out of the box: clients are observer members

- **What it is:** no separate service API at all. A non-Zig client joins the
  cluster as a *non-voting, non-authoring observer* that speaks the
  replication protocol itself: it receives slots like any member, and submits
  entries to the leader the way a follower forwards them. The "API" is the
  one wire protocol that already exists.
- **Pros:** one protocol, one implementation; observers get follow/backfill
  for free; no HTTP stack in the node.
- **Cons:** a client must implement entry signing and chain verification to
  participate - a heavier client than `curl`; the replication protocol becomes
  a public contract, which constrains how freely it can change; admission
  now has to distinguish members from observers.
- **Cost to adopt:** a client library per language instead of an HTTP doc.
- **Evidence:** this is how Hypercore-family peers consume logs (clanker
  research option R) - design reasoning, not measurement.

### Status quo - do nothing

- **What it is:** no coppiz; clanker keeps files and its in-tree fan-out.
- **Pros:** zero work.
- **Cons:** RFC 0019's problem stands; nothing general-purpose exists in Zig.
- **Cost to adopt:** zero now; the breakage and non-pooling RFC 0019 lists
  later.

## Implications by horizon

### Short term (0–3 months)

- **If A:** the core lands as a library with host-driven I/O; clanker's
  integration is `ck_state` over an in-process call; no HTTP code yet.
- **If B:** HTTP API design precedes any consumer; clanker integrates via a
  sidecar and a loosened sandbox.
- **If C:** both; slower to first consumer.
- **If D:** the wire protocol is frozen early.

### Medium term (3–12 months)

- **If A:** a service wrapper is added for operators and non-Zig hosts when
  someone needs it; it is a wrapper by construction.
- **If B:** a stable HTTP contract; clanker carries a second daemon.
- **If D:** client libraries in other languages are the way in; each must
  track protocol changes.

### Long term (12+ months)

- **If A:** Zig API churn is the compatibility risk; a C ABI is the likely
  answer for other languages.
- **If B:** independent upgrade cadence; per-call latency is the permanent
  cost.

## Recommendation

**Recommended option:** A - library-first, with the node binary in the same
tree from day one and the service API added as a wrapper module when the
first non-Zig consumer appears (and designed so that option D remains
possible: the replication protocol is specified, not incidental).

**Confidence:** 7/10

**Why this confidence.** Raises: the first clanker integration landing as an
in-process call with no new daemon, as RFC 0019 tier 1 intends; a second Zig
host appearing. Sinks: Zig 0.16 → 0.17 churn making the library contract
unmaintainable for a host on a different toolchain pin; a non-Zig consumer
arriving before clanker's `ck_state`, which would make B's day-one HTTP the
faster path.

**Rationale.** Driver 1 is decisive: "nothing stood up beside the host" is
the project's defining property (ADR 0003), and the strictest known host
additionally forbids a second daemon and cannot scope a guest to a port, so
B's strengths are unusable by it. A keeps the size-1 case a function call (driver 4) and makes
driver 3 structural rather than disciplinary. C pays for a consumer that does
not exist. D is attractive and is kept open by specifying the protocol, but
a client that must sign and verify is too heavy to be the *only* way in for
operators.

**Reversibility.** Adding a service wrapper over a library is cheap and is
the planned path. Inverting to service-first later is the expensive
direction (I/O ownership flips), so the decision is effectively "A, and keep
the protocol clean enough that D stays possible".

## Open questions

- Does clanker's `ck_state` land before a non-Zig consumer appears? (clanker
  RFC 0019 next steps; the operator.)
- Is a C ABI needed sooner than the service API, for hosts that link C but
  not Zig? (first non-Zig consumer.)
- Should the replication protocol be public (D) from v1, or internal until
  1.0? ([OQ 19](../open-questions.md#oq-19))

## Next steps / action items

- [ ] Comment period: the operator, by the time PRD 0001 phase 4 (library API)
  starts.
- [ ] Build the core as a library regardless (PRD 0001 phases 1–3 are
  surface-neutral).
- [ ] Write the ADR once decided; update PRD 0005 Status.

## References

- [ADR 0007](../adrs/0007-the-library-is-the-primary-surface.md) - the
  decision this RFC produced.
- clanker [RFC 0019 - Shared state store](https://github.com/maci0/clanker/blob/main/docs/rfcs/0019-shared-state-store.md),
  option T *Packaging* - names this decision.
- clanker PRD 0011 (mesh) - "no second daemon", "serve owns sockets".
- [Research 0001](../research/0001-evidence-carried-from-the-state-store-survey.md)
  - dqlite/rqlite/etcd shapes as surveyed there.
- [PRD 0005](../prds/0005-embedding-the-library-as-the-product.md) - the two routes
  into clanker.
