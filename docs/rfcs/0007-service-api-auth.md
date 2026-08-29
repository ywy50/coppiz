# RFC 0007 - what authenticates service-API callers off loopback?

## Status

Discussion - opened 2026-08-29. Addresses OQ 38 (the
register keeps the stable pointer).

An RFC is a *request for comment*: it presents the options and a recommendation
so a decision can be made, and it is not itself the decision record. When it is
decided, set the status, then write the [ADR](../adrs/) that records the choice
and link it from References.

## Overview

The service API is deferred: it lands as a wrapper module over the library
behind the first non-Zig consumer ([ADR 0007](../adrs/0007-the-library-is-the-primary-surface.md),
PRD 0005 phase 4). When it lands, its HTTP surface on a listen address needs
an answer to "who may call it off loopback" - a static token, member keys,
or mTLS. The v1 draft is loopback-only with a warning on any other bind
(PRD 0005 *Failure modes*).

**Decision to make.** What authenticates a caller of the service API when it
is bound beyond loopback?

**Why now.** The decision is parked on a deferred phase, but the shape of the
answer affects two things already built: the operator channel (how the CLI
authenticates to a node) and the local config (where a token would live). If
the answer is "reuse the operator channel", nothing new is added when the
API lands; if it is a token, the config schema and the wrapper's design both
change. Deciding now keeps the deferred phase cheap.

**Drivers.** Any acceptable option must:

- not weaken the loopback case: a caller on the same host must not need
  setup beyond what the node has;
- avoid a second credential store where one exists (the member key already
  authenticates the operator channel);
- keep the wrapper a thin HTTP veneer over the library (ADR 0007) - the
  auth mechanism must be something the library already provides or the
  wrapper can check without reimplementing protocol logic;
- survive the "first non-Zig consumer" test: a non-Zig caller must be able
  to authenticate with what it can hold (a token, a key file), not Zig
  internals.

**Out of scope.** Authorizing what a caller may *do* (read-only vs write);
admission of new members. The service API itself (that is ADR 0007's
deferral).

## Current state

No service API exists. The only off-process surface is the replication wire,
whose admission is the operator channel: a client dials with the data
directory's member key and is admitted without a join (the glossary's *wire
client*). The CLI uses it for every command when the directory is locked.
There is no token in the local config schema, and no HTTP surface to
protect.

## Options considered

### Option A - loopback-only for v1, warning on any other bind (status quo)

- **What it is:** the wrapper binds loopback; a non-loopback bind is
  refused or emits a loud warning until an auth mechanism is configured.
  Short-lived processes beside the node (the multi-process case, RFC 0006)
  use the operator channel over the wire instead of HTTP.
- **Maturity:** the standard posture for local control surfaces; the v1
  draft already says it.
- **How it would fit:** nothing to build; the warning is a config check.
- **Pros:** zero new surface; the loopback caller needs nothing; the
  off-loopback story is "do not bind off loopback until you have an auth
  story".
- **Cons:** a non-Zig consumer on another host has no way in; the warning
  is advisory (the operator can ignore it).
- **Cost to adopt:** none now.
- **Cost to leave:** none - the decision only gates what the wrapper does
  when it lands.
- **Evidence:** PRD 0005's failure-mode row; the operator channel as
  shipped.

### Option B - static token in local config

- **What it is:** an operator-generated secret (`service.token`) in
  `coppiz.toml`; the wrapper checks a bearer token on every request.
- **Pros:** dead simple; any language can send a header; no key material
  to manage beyond one file.
- **Cons:** a second credential store beside the member key; the token
  sits in the same config as everything else, so a config leak is a
  service takeover; rotation is manual; nothing ties a caller to a member.
- **Cost to adopt:** a config key plus a header check in the wrapper.
- **Cost to leave:** the config key is additive; removable.
- **Evidence:** common practice for local HTTP surfaces; design reasoning.

### Option C - the operator channel: callers authenticate with the directory's member key (out-of-the-box)

- **What it is:** the wrapper reuses the wire client's admission: a caller
  proves possession of the node's member key (a signature challenge over
  the existing crypto) and is admitted as the operator. The mechanism, the
  key location and the admission rule already exist; the wrapper maps it
  to an HTTP handshake.
- **Pros:** no second credential store - the key that opens the directory
  also opens the API; a caller that can read the data directory can
  already do everything the node can, so nothing new is exposed; the
  non-Zig consumer holds a key file, which any language can sign with.
- **Cons:** the handshake is new protocol surface (the wire client's hello
  is not HTTP); sharing one key among several callers is coarse; the key
  is the whole node's identity, so a leak is the whole node.
- **Cost to adopt:** the HTTP handshake mapping in the wrapper; the crypto
  is already there.
- **Cost to leave:** additive.
- **Evidence:** the shipped operator channel and member-key admission;
  RFC 0006's option B uses the same reuse argument for a unix-socket
  transport.

### Option D - mTLS

- **What it is:** mutual TLS with a CA; clients present certificates.
- **Pros:** the industry answer for machine-to-machine auth; per-client
  identity and revocation.
- **Cons:** Zig `std` has a TLS client but no server (OQ 23 names this);
  a server would mean vendoring TLS into the library or the node, against
  ADR 0001's std-only stance for the library - the reversal cost ADR 0001
  warns about. A CA and certificate lifecycle for what is a single-node
  local surface is heavy.
- **Cost to adopt:** the highest of the four (TLS server problem, CA
  tooling, cert distribution).
- **Cost to leave:** none.
- **Evidence:** OQ 23's TLS discussion; ADR 0001's bounds.

## Implications by horizon

### Short term (this release / 0-3 months)

- **If A:** nothing happens; the deferred phase stays deferred.
- **If B or C:** the decision is recorded; the wrapper's spec names the
  mechanism when the first non-Zig consumer appears.

### Medium term (3-12 months)

- **If A and the first non-Zig consumer appears:** B or C is chosen then,
  still cheap.
- **If C:** the HTTP handshake lands as part of the wrapper, reusing the
  operator channel.

### Long term (12+ months)

- **If D were ever chosen:** it needs the TLS-server problem solved first
  (OQ 23's decision interacts).

## Recommendation

**Recommended option:** A for the loopback v1, with C (the operator channel,
member-key authentication) named as the off-loopback mechanism when the
wrapper lands - unless a non-Zig consumer with a genuine multi-caller need
appears first, in which case B is the fallback.

**Confidence:** 7/10

**Why this confidence.** The mechanism for C already exists and the
non-Zig consumer question is what decides whether B or C fits better.
What would move it: the first non-Zig consumer's actual shape (OQ 46's
hosts). What would sink it: a consumer that cannot hold the member key
(an embedded device with only a token).

**Rationale.** A is free and correct for the only surface that exists
today; C reuses the one credential store the system already has instead of
inventing a second; B's token is a fallback for callers that cannot hold a
key. D fails driver 4 and the ADR 0001 bound hardest.

**Reversibility.** A to B or C is additive at wrapper time; the config
schema is not frozen on this question.

## Open questions

- Can a non-Zig consumer hold the node's member key (a file it signs
  with), or does it need a token? (the first non-Zig consumer; OQ 46)
- Does the operator channel's wire hello map cleanly to an HTTP
  handshake, or should the wrapper define a fresh challenge? (the wrapper
  implementation)

## Next steps / action items

- [ ] Record the loopback-only stance for the wrapper's v1.
- [ ] When the wrapper lands: implement C (or B) per the consumer's shape.
- [ ] Write the ADR once decided; update OQ 38's status.

## References

- OQ 38 (historical) - the question this RFC addresses.
- [ADR 0007](../adrs/0007-the-library-is-the-primary-surface.md) - the
  service API's deferral and wrapper shape.
- [PRD 0005](../prds/0005-embedding-the-library-as-the-product.md) - the
  service API sketch and failure modes.
- [RFC 0006](0006-multi-process-one-data-directory.md) - the sibling
  question (short-lived processes beside the node), same reuse argument.
- [OQ 23](0008-wire-encryption.md) - the TLS-server gap that bounds option D.
