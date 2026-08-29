# RFC 0008 - wire encryption: plaintext v1, and what protects a non-private deployment

## Status

Discussion - opened 2026-08-29. Addresses [OQ 23](../open-questions.md) (the
register keeps the stable pointer).

An RFC is a *request for comment*: it presents the options and a recommendation
so a decision can be made, and it is not itself the decision record. When it is
decided, set the status, then write the [ADR](../adrs/) that records the choice
and link it from References.

## Overview

The replication wire is plain TCP for v1, on loopback or RFC1918 addresses -
clanker's mesh made the same call. For anything else, the options are TLS
(Zig `std` has a TLS client but no server) or a Noise-style handshake over
the member keys the cluster already has, using `std.crypto`'s X25519 and
ChaCha20-Poly1305. [ADR 0001](../adrs/0001-zig-0-16-standard-library-only-for-the-core.md)
bounds the library to what `std` ships.

**Decision to make.** What protects member-to-member traffic when a cluster
runs off a private network, and is anything needed before then?

**Why now.** The wire is not frozen, and the transport seam (OQ 19's
decision, `src/net/transport.zig`) is where a handshake would sit. Deciding
now - before any non-private deployment - lets the wire carry the decision
instead of retrofitting it onto a frozen protocol. There is no current
deployment that needs it; the decision is about what the wire's contract
promises.

**Drivers.** Any acceptable option must:

- stay inside what `std` ships for the library (ADR 0001) - a vendored
  TLS implementation in the library is the reversal ADR 0001 names;
- not invent key management: the members already hold Ed25519 keypairs and
  the chain already binds identity to keys;
- keep the plaintext path (loopback/RFC1918) unchanged and unencumbered;
- not change the message set or the on-disk format.

**Out of scope.** Encryption at rest (the host's disk is trusted, PRD 0001
non-goals). The service API's TLS needs (RFC 0007's option D touches the
same TLS-server gap, but the service wrapper is a different surface).

## Current state

Frames are length-prefixed binary with a versioned body (OQ 19 resolved);
the transport is a thin seam with TCP and an in-memory hub implementation,
and the same loop runs under both. There is no encryption or handshake:
a member-to-member connection is plain. The member table holds every
member's Ed25519 public key from the chain (PRD 0003), so each side can
verify the other's identity and negotiate a session key without a separate
PKI.

## Options considered

### Option A - plaintext v1, documented (status quo)

- **What it is:** the wire stays plain; the docs say loopback/RFC1918 only,
  and anything off a private network is unsupported until a handshake
  lands.
- **Maturity:** what clanker's mesh did; the shipped state.
- **How it would fit:** a documentation promise in the wire's contract.
- **Pros:** nothing to build; the plaintext path stays the fastest; no
  handshake failure modes.
- **Cons:** an operator that deploys across the public internet gets no
  warning from the code, only the docs.
- **Cost to adopt:** none.
- **Cost to leave:** none - the seam keeps a handshake additive.
- **Evidence:** the shipped seam; clanker's mesh precedent.

### Option B - Noise-style handshake over the member keys (out-of-the-box)

- **What it is:** on connect, the two members run a Noise IK-style
  handshake: each side knows the other's public key from the member table,
  uses X25519 for the ephemeral exchange and ChaCha20-Poly1305 for the
  session, and authenticates the peer's key (which the chain already
  vouches for). A single handshake message pattern over the existing
  framing, then the plaintext protocol runs inside the session's AEAD.
  `std.crypto` has all of it (X25519, ChaCha20-Poly1305, and a keyed
  hash); ADR 0001 is satisfied.
- **Maturity:** Noise is a published, audited protocol family; the
  primitives are in `std.crypto`. The implementation is new to this tree.
- **How it would fit:** the transport seam gains an optional handshake
  mode selected by a setting (e.g. `wire.encrypt = off | noise`); loopback
  stays `off` by default. The hub transport (tests, simulator) can skip
  it.
- **Pros:** uses the identity the chain already establishes - no CA, no
  certificate store, no new key material; fits ADR 0001 exactly; the
  handshake is a small, bounded protocol.
- **Cons:** real implementation and review work (a handshake is exactly
  the kind of code that is "subtly wrong"); a protocol to version; the
  member table must be current on both sides (a fresh joiner has keys
  only for what it has folded).
- **Cost to adopt:** the handshake implementation plus tests, behind the
  setting; no format change to the message set.
- **Cost to leave:** the seam keeps it removable.
- **Evidence:** `std.crypto`'s X25519/ChaCha20-Poly1305; Noise protocol
  family design; the member keys as shipped (PRD 0003).

### Option C - TLS

- **What it is:** TLS 1.3 on the wire, as a client-server pair per
  connection.
- **Pros:** the industry standard; off-the-shelf tooling for certificates.
- **Cons:** Zig `std` has a TLS client but no server, and a server is what
  a member needs when it accepts connections - so the library would need a
  vendored TLS implementation, which is exactly ADR 0001's reversal
  (vendoring is allowed for the node binary, not for what the library's
  wire uses). Certificate management for a self-contained cluster (CA,
  issuance, rotation) is a whole operational surface for a group that
  already has a key-per-member identity.
- **Cost to adopt:** the highest of the three; ADR 0001's reversal cost on
  top.
- **Cost to leave:** none.
- **Evidence:** `std`'s TLS client-only gap (OQ 23's premise); ADR 0001's
  bounds.

## Implications by horizon

### Short term (this release / 0-3 months)

- **If A:** nothing changes; the docs state the boundary.
- **If B:** the handshake lands behind the setting; loopback unaffected.

### Medium term (3-12 months)

- **If A and a non-private deployment appears:** the decision is made
  under pressure instead of now.
- **If B:** the wire's contract promises confidentiality when the setting
  is on.

### Long term (12+ months)

- **If B:** the handshake is part of the wire's versioned contract; a
  future C would supersede it.
- **If C were ever chosen:** it requires the ADR 0001 reversal first - the
  point of deciding now is to avoid that.

## Recommendation

**Recommended option:** A for v1 - plaintext on loopback/RFC1918,
documented as the only supported placement - with B (Noise-style over the
member keys, behind a `wire.encrypt` setting) as the agreed mechanism for
the first non-private deployment.

**Confidence:** 6/10

**Why this confidence.** B fits every driver and reuses the chain's
identity, but a handshake is real, subtle code and no deployment needs it
yet; the confidence reflects "the mechanism is right, the timing is not
urgent". What would move it up: a concrete non-private deployment, or the
handshake implemented and reviewed in the seam. What would sink it: a
requirement for interop with an off-the-shelf TLS-only peer, which would
force the ADR 0001 question.

**Rationale.** A is correct for the only placements that exist; B beats C
on every driver except familiarity - it uses the identity the cluster
already has instead of importing a PKI, and it stays inside `std`, which
C cannot without reversing ADR 0001. The seam keeps B cheap to add when
the deployment exists.

**Reversibility.** A to B is additive (a setting and a handshake in the
seam). B to C would be a superseding decision requiring ADR 0001's
reversal.

## Open questions

- When the first non-private deployment appears, is interop with a
  TLS-only peer required, or can both ends be coppiz? (the deployment;
  would decide B vs C)
- Should the handshake cover the hello (admission) itself, or only
  post-hello traffic? (implementation; the hello carries the admission
  decision)

## Next steps / action items

- [ ] Document the loopback/RFC1918 boundary as the wire's v1 contract.
- [ ] When a non-private deployment is real: implement the Noise handshake
      in the seam behind `wire.encrypt`, with the hub transport skipping
      it.
- [ ] Write the ADR once decided; update OQ 23's status.

## References

- [OQ 23](../open-questions.md) - the register entry this RFC addresses.
- [ADR 0001](../adrs/0001-zig-0-16-standard-library-only-for-the-core.md) -
  the std-only bound that disqualifies TLS-in-the-library.
- [PRD 0003](../prds/0003-membership-and-leadership.md) - member keys and
  the identity the handshake would reuse.
- OQ 19's resolution - the transport seam the handshake would sit in
  (recorded in PRD 0003's status, implemented in `src/net/`).
- [RFC 0007](0007-service-api-auth.md) - the sibling question (the
  service wrapper hits the same TLS-server gap).
