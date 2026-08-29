# RFC 0016 - how the allowlist learns a newcomer's key

## Status

Discussion - opened 2026-08-29. Addresses OQ 21 (the
register keeps the stable pointer).

An RFC is a *request for comment*: it presents the options and a recommendation
so a decision can be made, and it is not itself the decision record. When it is
decided, set the status, then write the [ADR](../adrs/) that records the choice
and link it from References.

## Overview

`cluster.admission` ships with three modes: `allowlist` (a dial whose
public key matches a `[[peers]]` entry is admitted), `prompt` (queued for
`coppiz admit <id>`), and `open` (anyone who can reach the port). The
unanswered part is how the allowlist learns a newcomer's public key out of
band - the operator copying the key into `[[peers]]`, or a one-time join
token the founder prints and the newcomer presents.

**Decision to make.** How does the allowlist acquire a newcomer's key:
the operator copies it (status quo), or the founder issues a one-time
token that binds it?

**Why now.** Admission is the cluster's trust boundary (PRD 0003); the
key-learning mechanism is the ergonomics of that boundary. It is a v1
question because it shapes the CLI and the founder's first-join flow.

**Drivers.** Any acceptable option must:

- keep the admission decision receiver-side: the dialing node never
  decides its own admission (PRD 0003);
- bind the key, not just announce it: whatever the newcomer presents must
  end with the fold holding the key it actually signs with;
- not weaken `allowlist`'s guarantee: an admitted key must be one the
  operator (or a delegated founder action) vouched for.

**Out of scope.** Membership ordering (RFC 0002). Admission *modes*
(themselves - `allowlist`/`prompt`/`open` are shipped).

## Current state

The operator edits `[[peers]]` in the founder's local config with the
newcomer's public key (a 64-hex string); the dial is admitted when its key
matches. `prompt` admission queues a dial for `coppiz admit <id>`; `open`
admits anyone. There is no token mechanism; the key must travel to the
operator by some channel the operator chooses (copy-paste, a file, a
channel).

## Options considered

### Option A - out-of-band key copy (status quo)

- **What it is:** the operator copies the newcomer's public key into
  `[[peers]]` (or the newcomer sends it over the operator's chosen
  channel; the operator pastes).
- **Pros:** the operator's existing channel is the trust anchor - the
  same channel that would carry a token; zero new machinery; the key is
  bound exactly (the fold holds the bytes the newcomer signs with).
- **Cons:** ergonomics: a 64-hex key is error-prone to copy; the operator
  must fetch the key from the newcomer before it can even attempt a dial.
- **Cost to adopt:** none.
- **Cost to leave:** none.
- **Evidence:** the shipped `[[peers]]` mechanism.

### Option B - one-time join token (out-of-the-box)

- **What it is:** the founder prints a short one-time token; the newcomer
  presents it on its first dial; the founder (or the dial handler) binds
  the key that presented it into the allowlist, then the token is spent.
- **Pros:** ergonomics (a short token to type); the key is bound at the
  moment of first contact, so the operator never handles the key bytes.
- **Cons:** a token is a bearer credential - whoever holds it can bind
  *their* key, so the token's channel must be as trusted as the key's
  would have been; token lifecycle (expiry, single-use, revocation)
  needs design; the founder prints it somewhere the newcomer can read.
- **Cost to adopt:** the token mechanism plus its lifecycle.
- **Cost to leave:** none.
- **Evidence:** common first-join ergonomics in other systems (the
  pattern clanker's mesh chose differently - a TLS pin).

### Option C - TLS-pin binding (clanker's mesh pattern)

- **What it is:** identity is bound to a TLS pin (clanker's mesh binds
  identity to a TLS pin in its phase 2).
- **Pros:** proven in clanker's own mesh.
- **Cons:** a TLS pin is a certificate/handshake concept - coppiz's wire
  has no TLS (OQ 23/RFC 0008's plaintext v1) and its identity is the
  Ed25519 key, not a pin; adopting the pattern means adopting a
  certificate story, which OQ 23 deferred.
- **Cost to adopt:** the certificate/pin machinery.
- **Cost to leave:** none.
- **Evidence:** clanker's mesh; RFC 0008's TLS stance.

## Implications by horizon

### Short term (this release / 0-3 months)

- **If A:** the docs describe the copy flow; `prompt` admission already
  covers the "I cannot copy" case.

### Medium term (3-12 months)

- **If B:** the token mechanism lands as the ergonomic front end over the
  same allowlist; both remain.

## Recommendation

**Recommended option:** A for v1 - out-of-band key copy - with B (the
one-time token) as an ergonomic addition over the same allowlist if a
host's operator finds the key copy painful. C is not adopted: it imports
a certificate concept the wire deliberately does not have.

**Confidence:** 7/10

**Why this confidence.** A is the shipped, trust-anchor-clean path; B is
the same trust with better ergonomics. What would move it: a host whose
operator flow makes key copy genuinely painful. What would sink A: a
requirement that the newcomer self-service (which is what `prompt` +
`admit` already covers).

**Rationale.** The trust anchor is the operator's channel either way; the
token only changes what travels over it. B's lifecycle is the cost; A's
ergonomics is the only downside.

**Reversibility.** A to B is additive.

## Open questions

- If B is built, does the token expire or is it single-use until spent?
  (implementation; the conservative default is single-use + expiry)

## Next steps / action items

- [ ] Document the out-of-band copy flow in PRD 0003's admission section.
- [ ] Write the ADR once decided; update OQ 21's status.

## References

- OQ 21 (historical) - the question this RFC addresses.
- [PRD 0003](../prds/0003-membership-and-leadership.md) - admission modes
  and the trust boundary.
- [RFC 0008](0008-wire-encryption.md) - the TLS stance that rules out
  option C's pin.
