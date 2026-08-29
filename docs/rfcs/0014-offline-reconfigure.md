# RFC 0014 - changing leadership settings when `reconfigurable = false`

## Status

Discussion - opened 2026-08-29. Addresses OQ 5 (the
register keeps the stable pointer).

An RFC is a *request for comment*: it presents the options and a recommendation
so a decision can be made, and it is not itself the decision record. When it is
decided, set the status, then write the [ADR](../adrs/) that records the choice
and link it from References.

## Overview

`leadership.reconfigurable = false` freezes every `leadership.*` setting:
a live `settings` entry touching them is refused by every member. The
drafted escape hatch is an offline procedure - stop every member, run
`coppiz reconfigure` on one (a command that does not exist yet), restart
the rest to backfill.

**Decision to make.** When the leadership lock is frozen, is the offline
procedure the way to change it, or is a signed operator override wanted so
the lock can be lifted live by someone who is not a member?

**Why now.** The freeze is a safety property; the escape hatch is its
price. `coppiz reconfigure` is named in PRD 0003 and not built. Deciding
the mechanism decides what the CLI must provide before 1.0 (OQ 22's
operator key interacts).

**Drivers.** Any acceptable option must:

- keep the freeze meaningful: changing frozen settings must require
  something a compromised live cluster cannot do on its own;
- keep the change a chain event: the fold must still fold the new
  settings identically on every member (PRD 0004);
- not add a second credential store where the member key already exists.

**Out of scope.** Routine rotation of member keys (OQ 22, RFC 0017). The
`quorum` mode (roadmap).

## Current state

`leadership.reconfigurable` defaults to `true`; an operator freezes the
cluster after its final shape by setting it `false` live (allowed only
true-to-false). While `false`, a live `settings` entry touching
`leadership.*` is refused `leadership frozen` on every member (PRD 0003).
There is no `coppiz reconfigure` command; the offline procedure is
drafted, not built. The member key authenticates everything a node does;
there is no distinct operator credential.

## Options considered

### Option A - the offline procedure (status quo drafted)

- **What it is:** stop every member, run `coppiz reconfigure` on one
  stopped member - it appends the `settings` entry and the follow-on
  epoch locally - then restart the rest, which backfill the change. The
  chain stays the single source of truth; a stopped member writing a
  chain entry is not a "live override".
- **Pros:** the freeze is absolute while the cluster runs - the only
  change path is physical access to the data; no new credential; the
  chain event stays ordinary (backfill, validation, same fold).
- **Cons:** downtime; the operator must stop the whole cluster to change
  leadership shape, which is exactly the kind of operation the freeze is
  meant to prevent abuse of.
- **Cost to adopt:** the `coppiz reconfigure` command plus a procedure
  (and a runbook, OQ 26's family).
- **Cost to leave:** the freeze has no escape hatch at all today.
- **Evidence:** PRD 0003's drafted procedure; the frozen-refusal rule as
  shipped.

### Option B - signed operator override

- **What it is:** a non-member operator key (OQ 22's operator key) signs
  the `settings` entry; the fold accepts a frozen-key change when the
  signature is the operator's, live, without stopping the cluster.
- **Pros:** no downtime; the operator is a distinct principal, so a
  compromised leader still cannot reconfigure (the OQ 22 hardening).
- **Cons:** a second credential to issue, store and rotate; the fold
  learns an exception to the frozen rule - the exception is the attack
  surface the freeze exists to close; the operator key must be present to
  validate, which means the chain carries its public key.
- **Cost to adopt:** the operator-key mechanism (OQ 22/RFC 0017) plus the
  frozen-rule exception.
- **Cost to leave:** none - it is additive.
- **Evidence:** OQ 22's operator-key discussion.

### Option C - no escape hatch (freeze is permanent per data directory)

- **What it is:** once frozen, the only way to change leadership settings
  is a new cluster (or manual chain surgery, unsupported).
- **Pros:** the strongest freeze.
- **Cons:** an operator error (freezing with the wrong authorities) is
  unrecoverable in place; the freeze's cost outweighs its benefit.
- **Cost to adopt:** none.
- **Cost to leave:** a rebuild.
- **Evidence:** design reasoning.

## Implications by horizon

### Short term (this release / 0-3 months)

- **If A:** `coppiz reconfigure` is built; the offline procedure gets a
  runbook.
- **If B:** the operator key is designed first (RFC 0017) - they are the
  same mechanism.

### Medium term (3-12 months)

- **If A and a live change is later wanted:** B becomes the upgrade path,
  still additive.

## Recommendation

**Recommended option:** A for v1 - the offline procedure, with
`coppiz reconfigure` built and documented. B (the operator override) is
the same mechanism as OQ 22's operator key and should be designed
together, but the offline procedure is the honest v1 answer: the freeze
is meant to be rare and deliberate, and stopping the cluster is the
price of absolute safety.

**Confidence:** 7/10

**Why this confidence.** A is the only option with no new credential and
no exception to the frozen rule; what would move it: an operator reporting
that freezing is common enough that downtime hurts. What would sink it: a
consumer that must reconfigure leadership shape regularly - which would
argue the freeze itself is being overused.

**Rationale.** The freeze exists to stop a compromised leader from
reconfiguring; B's exception reintroduces exactly that risk (the operator
key becomes the target). A keeps the freeze absolute and pays downtime
for the rare, deliberate change.

**Reversibility.** A to B is additive; B to A is removing the exception.

## Open questions

- Does `coppiz reconfigure` belong with OQ 22's operator key, or is it a
  plain CLI command using the member key of the stopped node? (the
  implementation; the stopped node's key is on disk either way)

## Next steps / action items

- [ ] Build `coppiz reconfigure` (offline: stop, change, restart).
- [ ] Write the procedure as a runbook (rolling-upgrade family, OQ 26).
- [ ] Write the ADR once decided; update OQ 5's status.

## References

- OQ 5 (historical) - the question this RFC addresses.
- [PRD 0003](../prds/0003-membership-and-leadership.md) - the frozen rule
  and the drafted offline procedure.
- [OQ 22](0017-key-rotation-operator-key.md) / RFC 0017 - the operator key this
  decision interacts with.
