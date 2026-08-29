# RFC 0017 - key rotation and compromise; an operator key

## Status

Discussion - opened 2026-08-29. Addresses [OQ 22](../open-questions.md) (the
register keeps the stable pointer).

An RFC is a *request for comment*: it presents the options and a recommendation
so a decision can be made, and it is not itself the decision record. When it is
decided, set the status, then write the [ADR](../adrs/) that records the choice
and link it from References.

## Overview

A member's Ed25519 key is its identity: the member id derives from the
public key, and seniority is the slot of its `join`. Rotating the key is
drafted as `leave` + `join`, which assigns a new seniority - punitive for
routine rotation. Separately, should *operator* actions (settings,
reconfigure, evict) be signed by a key that is not any member's, so a
compromised leader cannot reconfigure the cluster?

**Decision to make.** How is a member's key rotated without changing its
seniority, and is there a distinct operator key for operator actions?

**Why now.** The question says it: both answers change the `join` payload
(or add a control entry), so both must be decided before 1.0 when the
format freezes.

**Drivers.** Any acceptable option must:

- keep identity stable: rotation must not reorder leadership (RFC
  0013's rule: seniority resets only on `leave`);
- keep the chain the source of truth: a key change is a chain fact every
  member folds, not a local-config edit;
- not weaken the trust model (RFC 0009): a compromised leader already
  cannot rewrite history; the question is what operator actions it can
  take.

**Out of scope.** The offline-reconfigure mechanism itself (OQ 5, RFC
0014 - which option B of this RFC feeds).

## Current state

A member id derives from the public key (PRD 0003); the chain records the
public key in `genesis`/`join`. Rotating = `leave` (new seniority) +
`join` (new key, newest seniority) - the punitive path. There is no
operator credential: every node authenticates as its member key, and the
leader authors `settings`, `reconfigure` and eviction `leave`s with it.
The `join` payload is not yet frozen (pre-1.0).

## Options considered

### Option A - rotation is `leave` + `join` (status quo)

- **What it is:** rotate by leaving and rejoining; the member accepts
  the new seniority.
- **Pros:** no format change; the chain already handles it.
- **Cons:** punitive for routine rotation (new seniority, seat churn);
  during the leave-join gap the member is absent from the fold.
- **Cost to adopt:** none.
- **Cost to leave:** none.
- **Evidence:** the shipped `leave`/`join` semantics.

### Option B - key re-registration preserving seniority (out-of-the-box)

- **What it is:** a new control entry (e.g. a `key_change`) that replaces
  the member's public key in the fold while keeping its member id and
  seniority. The member signs the change with its *old* key; the fold
  then accepts its *new* key. Revocation for compromise: the same entry,
  signed by the old key, is the "I was compromised" path.
- **Pros:** rotation without leadership churn; the member id stays stable
  (the id derives from the key - so the id must be decoupled from the
  key, or the entry re-derives it - a deliberate format decision);
  compromise recovery is the same mechanism.
- **Cons:** a new control kind and a fold rule; decoupling member id from
  key (if desired) is a format change; the old-key-signs-new-key rule
  must be validated on every member.
- **Cost to adopt:** the control entry plus validation; before the format
  freeze.
- **Cost to leave:** high after freeze.
- **Evidence:** design reasoning; the OQ 22 premise.

### Option C - operator key for operator actions

- **What it is:** a non-member key (in local config, or in a settings
  entry) signs `settings` changes that touch the frozen set,
  `reconfigure` (RFC 0014's option B) and evictions. The fold validates
  the operator signature; a compromised leader still cannot reconfigure.
- **Pros:** a compromised leader cannot change leadership shape or evict
  members; the operator is a distinct principal.
- **Cons:** a second credential to issue, store and rotate; the chain
  must carry the operator public key (or the local configs must agree -
  disagreeing configs fork the validation); the operator key becomes the
  target (RFC 0014's point).
- **Cost to adopt:** the operator-key mechanism plus the fold rule.
- **Cost to leave:** none - additive.
- **Evidence:** RFC 0014's option B; OQ 22's premise.

## Implications by horizon

### Short term (this release / 0-3 months)

- **If A + C:** nothing until 1.0; the format freeze is the deadline.
- **If B:** the control entry lands before the freeze.

### Medium term (3-12 months)

- **If B:** routine rotation stops churning leadership; compromise
  recovery is a signed `key_change`.
- **If C:** the operator key is the offline-reconfigure path's live
  alternative (RFC 0014).

## Recommendation

**Recommended option:** B - a `key_change` control entry that replaces a
member's public key while preserving member id and seniority, signed by
the old key - as the rotation mechanism. C (the operator key) is
recommended **not** for v1: the offline procedure (RFC 0014 option A) is
the honest answer to frozen changes, and a second credential that becomes
the attack target buys little against the single-operator model (RFC
0009).

**Confidence:** 6/10

**Why this confidence.** B is a bounded format addition with a clear
validation rule; C's value depends on a threat (a compromised leader
abusing operator actions) that RFC 0009's model already treats as
self-harm-only. What would move it: a real compromise incident, or an
operator requiring live frozen changes. What would sink B: a desire to
keep the member id derived purely from the key (which makes rotation
change identity - the OQ 22 premise itself).

**Rationale.** Rotation without leadership churn is the ergonomic need;
B delivers it as a chain fact. C's cost (second credential, new attack
surface) outweighs its benefit while the offline path exists.

**Reversibility.** B before the freeze is cheap; after, it is a format
change. C is additive.

## Open questions

- Should the member id stay derived from the key (forcing the id to
  change on rotation), or be decoupled so rotation preserves it?
  (implementation; the RFC assumes decoupling is acceptable)
- Does `key_change` double as the compromise-revocation path, or is a
  separate revoke entry needed? (implementation)

## Next steps / action items

- [ ] Design `key_change` (payload, validation, fold rule) before the
      format freeze.
- [ ] Write the ADR once decided; update OQ 22's status.

## References

- [OQ 22](../open-questions.md) - the register entry this RFC addresses.
- [PRD 0003](../prds/0003-membership-and-leadership.md) - member identity
  and the `join` payload.
- [RFC 0009](0009-trust-model.md) - the trust model the operator key
  would harden.
- [RFC 0014](0014-offline-reconfigure.md) - the offline path that makes
  the operator key optional.
