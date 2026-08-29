# RFC 0039 - observability: metrics format and log destination

## Status

Discussion - opened 2026-08-29. Addresses OQ 29 (the
register keeps the stable pointer).

An RFC is a *request for comment*: it presents the options and a recommendation
so a decision can be made, and it is not itself the decision record. When it is
decided, set the status, then write the [ADR](../adrs/) that records the choice
and link it from References.

## Overview

The human surface shipped: `coppiz status` and `node.status()` report leader,
epoch, head, members and states, lag per follower, pending checkpoint bytes
and last merge. What is open is the machine surface - a metrics format for
scrapers - and where node logs go.

**Decision to make.** The metrics format (Prometheus text exposition is the
candidate the OQ names) and the log destination.

**Why now.** The first host branch (PRD 0005 phase 5) is next; a host that
embeds coppiz needs to observe it without shelling out to `coppiz status`,
and a multi-member deployment needs logs that survive a crash of the member
that wrote them.

**Drivers.** Any acceptable option must:

- stay host-agnostic (ADR 0003): no clanker-shaped surface, no HTTP
  dependency - the core is std-lib-only and the wire is framed, not HTTP;
- reuse the status data that already exists rather than building a second
  collection path;
- keep the log path explicit: stderr today, a configured destination if the
  operator wants one.

**Out of scope.** The metrics' *content* (the OQ's list is the baseline).
Log rotation and retention (the host's business). Tracing.

## Current state

- `coppiz status` / `node.status()` carry the data the OQ lists; the CLI
  commands `status`, `members` and `doctor` shipped.
- No metrics endpoint exists; nothing in the tree mentions Prometheus.
- Logs go to stderr; the only file-logging code is test plumbing
  (`src/main.zig:937`), not a node feature.
- The wire is framed and binary; there is no HTTP surface and none is
  planned (ADR 0003).

## Options considered

### Option A - status quo: status for humans, logs to stderr

- **What it is:** the shipped surface stays the whole surface.
- **Pros:** nothing to build; the CLI covers ad-hoc inspection.
- **Cons:** a host cannot scrape; a crashed member's last words die with its
  stderr (no destination), which is exactly when logs matter most.
- **Cost to adopt:** none.
- **Cost to leave:** the first multi-member incident without logs.
- **Evidence:** the OQ's "none - status/members/doctor shipped" is about
  *this* option.

### Option B - Prometheus text exposition plus a log destination

- **What it is:** a `metrics` surface that emits Prometheus text exposition
  (the de facto standard, plain text lines, no HTTP needed - exposed over
  the existing wire as a verb, and as `node.metrics()` for embedded hosts);
  logs gain a local-config destination (`log.dir`), defaulting to stderr.
- **Pros:** scrapers and dashboards work out of the box; the data reuses
  `node.status()`; the exposition format is a text dump, trivial to emit
  from std lib; `log.dir` costs one local key.
- **Cons:** a new wire verb (small); Prometheus names need care (unit
  suffixes, label discipline); a host that wants a different format gets
  nothing.
- **Cost to adopt:** the wire verb + `node.metrics()`, the Prometheus text
  renderer, the `log.dir` key.
- **Cost to leave:** the status surface stays text-only for machines.
- **Evidence:** the OQ names Prometheus text as the candidate; the status
  fields are already the content.

### Option C - a structured log format instead of metrics

- **What it is:** JSONL logs to `log.dir` as the machine surface; scrapers
  parse the logs.
- **Pros:** one mechanism (logs) instead of two; captures events metrics
  cannot (joins, evictions, merges).
- **Cons:** metrics and events are different queries - summing lag over a
  JSONL stream is work a Prometheus scrape does for free; no counters, no
  histograms; every scraper reimplements aggregation.
- **Cost to adopt:** a JSONL emitter and the same `log.dir`.
- **Cost to leave:** the counter/histogram gap grows with the deployment.
- **Evidence:** the standard split between logs (events) and metrics
  (sampled state).

## Implications by horizon

### Short term

- **If B:** the `metrics` verb returns the status fields as Prometheus text;
  `node.metrics()` mirrors it for embedded hosts; `log.dir` lands as a local
  setting with stderr as the default.

### Medium term

- **If B:** counters that live in the node loop (appends, refusals, sync
  pages) join the exposition as the loop gains them; histogram-worthy
  timings (OQ 54) become metrics when measured.

## Recommendation

**Recommended option:** B - Prometheus text exposition over the existing wire
plus `node.metrics()`, and a `log.dir` local setting defaulting to stderr. A
leaves machines and crash logs unserved; C mixes events and samples into one
stream and pushes aggregation onto every consumer.

**Confidence:** 6/10

**Why this confidence.** The format choice is a standard with near-universal
tooling, but the wire-verb surface is a real API decision and a host might
legitimately prefer its own transport. What would move it: a host constraint
against a new verb (arguing C, or B with the exposition exposed only via
`node.metrics()`).

**Rationale.** Metrics are sampled state, logs are events; the OQ asks for
the sampled-state surface, and Prometheus text is the least novel way to
ship it without HTTP. Keeping the destination configurable but defaulted to
stderr preserves the current behaviour.

**Reversibility.** The verb and the key are additive; removing them restores
A exactly.

## Open questions

- Whether the `metrics` verb needs auth beyond the existing admission model
  (it is read-only; RFC 0007's auth applies if it does).
- Counter inventory: which loop counters ship with the first exposition
  beyond the status fields.

## Next steps / action items

- [ ] Add the `metrics` wire verb and `node.metrics()`; render the status
      fields as Prometheus text.
- [ ] Add `log.dir` as a local setting (PRD 0004), stderr the default.
- [ ] Write the ADR once decided; update OQ 29's status.

## References

- OQ 29 (historical) - the question this RFC addresses.
- [ADR 0003](../adrs/0003-batteries-included-no-external-infrastructure-at-any-size.md) -
  the no-HTTP constraint the exposition format respects.
- [RFC 0007](0007-service-api-auth.md) - the auth question a new verb raises.
- [PRD 0004](../prds/0004-settings.md) - where `log.dir` lands.
