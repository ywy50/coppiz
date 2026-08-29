# RFC 0020 - cursor and id encoding for consumers

## Status

Discussion - opened 2026-08-29. Addresses OQ 42 (the
register keeps the stable pointer).

An RFC is a *request for comment*: it presents the options and a recommendation
so a decision can be made, and it is not itself the decision record. When it is
decided, set the status, then write the [ADR](../adrs/) that records the choice
and link it from References.

## Overview

The library API ships with `(epoch, seq)` positions as cursors and
`(author, author_seq)` as entry ids (PRD 0001, PRD 0005). The open part:
is a single opaque token better for an HTTP API, and should ids be exposed
to consumers at all or only cursors?

**Decision to make.** What do consumers of the future service API hold: the
structured `epoch:seq` / `author:author_seq` forms, opaque tokens, or
cursors only?

**Why now.** The library API is shipped with the structured forms; the
service wrapper (RFC 0007) is where the encoding would differ. Deciding
the *principle* now (structured for the library, opaque at the HTTP
boundary) keeps the wrapper's spec cheap.

**Drivers.** Any acceptable option must:

- keep the library API's structured forms (they are shipped and the
  wire/fold use them);
- not leak implementation details a consumer cannot use - an id that
  looks parseable but is not stable across merges is a trap;
- keep the service wrapper a thin veneer (ADR 0007).

**Out of scope.** The service API's existence (ADR 0007 defers it). Read
consistency (RFC 0018).

## Current state

The library exposes `slot.Position` `(epoch, seq)` for cursors and
`entry.Id` `(author, author_seq)` for ids; both are structs in Zig, and
the CLI renders cursors as `EPOCH:SEQ` text. Entry ids are stable forever
(PRD 0001); positions change exactly once at a merge, for losing-side
entries (PRD 0003). There is no HTTP surface yet.

## Options considered

### Option A - structured forms everywhere (status quo)

- **What it is:** the service API uses `epoch:seq` and
  `author:author_seq` as the wire text, exactly like the CLI.
- **Pros:** one encoding; the CLI's forms already exist; a consumer can
  reason about positions.
- **Cons:** a position is not a stable handle (it can move once at
  merge) - exposing it as a cursor is fine, exposing it as a *token that
  looks permanent* is the trap; an id is two numbers to get wrong.
- **Cost to adopt:** none.
- **Cost to leave:** none.
- **Evidence:** the shipped CLI text forms.

### Option B - opaque tokens at the HTTP boundary (out-of-the-box)

- **What it is:** the service wrapper encodes cursors and ids as opaque
  tokens (e.g. base64url of the structured form with a version prefix);
  consumers treat them as blobs to echo back. The library keeps the
  structured forms; the wrapper maps.
- **Pros:** a consumer cannot misuse a position as a stable id (the token
  is opaque); the encoding can evolve without breaking consumers; the
  wrapper stays thin (map in, map out).
- **Cons:** debugging is harder (a token is not human-readable); the
  wrapper carries an encode/decode pair.
- **Cost to adopt:** the token mapping in the wrapper when it lands.
- **Cost to leave:** none - additive at wrapper time.
- **Evidence:** common HTTP-API practice (opaque cursors for pagination);
  the merge-stability trap (PRD 0003).

### Option C - cursors only; hide ids

- **What it is:** the service API exposes only cursors; ids are internal.
- **Pros:** the smallest surface; nothing to misuse.
- **Cons:** consumers that must reference an entry across reads (mark it,
  dedup it) cannot - the id is the stable handle (PRD 0001's "readers
  that need identity use entry ids").
- **Cost to adopt:** removes a capability.
- **Cost to leave:** the id is already shipped in the library.
- **Evidence:** PRD 0001's entry-id contract.

## Implications by horizon

### Short term (this release / 0-3 months)

- **If A/B:** nothing changes; the wrapper is deferred.

### Medium term (3-12 months)

- **If B:** the wrapper's spec names the token encoding; the library's
  forms stay structured.

## Recommendation

**Recommended option:** A for the library (structured forms, shipped),
B for the service API (opaque tokens at the HTTP boundary, with the
library's structured forms mapped in and out). C is rejected - the id is
the stable handle consumers legitimately need.

**Confidence:** 6/10

**Why this confidence.** The split follows a clear principle (structured
in the library, opaque at the HTTP boundary), but nothing exercises the
HTTP surface yet. What would move it: the first non-Zig consumer's
actual needs. What would sink it: a consumer that must *construct* a
cursor (which an opaque token forbids).

**Rationale.** The merge-move trap makes bare positions dangerous as
public tokens; opacity removes the trap at the boundary while the
library keeps the forms its own code needs. Hiding ids removes a
legitimate capability.

**Reversibility.** B is decided at wrapper time; the library is
unaffected.

## Open questions

- Should the token be base64url with a version byte (evolvable) or plain
  text? (the wrapper's spec; versioned is the conservative default)

## Next steps / action items

- [ ] Name the principle in PRD 0005's service-API sketch (structured in
      the library, opaque at HTTP).
- [ ] Write the ADR once decided; update OQ 42's status.

## References

- OQ 42 (historical) - the question this RFC addresses.
- [PRD 0001](../prds/0001-journal-core.md) - the cursor and id
  definitions.
- [PRD 0003](../prds/0003-membership-and-leadership.md) - the merge that
  moves a position once.
- [RFC 0007](0007-service-api-auth.md) - the wrapper this encoding serves.
