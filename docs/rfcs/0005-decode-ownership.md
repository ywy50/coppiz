# RFC 0005 - should a decoded message own its parts, or borrow from the frame?

## Status

Discussion - opened 2026-08-29.

An RFC is a *request for comment*: it presents the options and a recommendation
so a decision can be made, and it is not itself the decision record. When it is
decided, set the status, then write the
[ADR](../adrs/) that records the choice and link it from References. A later
reversal supersedes that ADR; this file keeps the reasoning that produced it.

## Overview

Every received message pays a full copy of each variable-length part: the
decoder dupes journal names, addresses, and the slot/sync/read **records**
into a per-frame arena, because "a decoded message owns what it names and
borrows nothing from the frame body" (`message.zig:6-8`). The frame body is
provably alive for the whole handler (it is freed after dispatch,
`node.zig:622-625, 368`), so borrowing is lifetime-safe today - the question
is whether the copies are worth the ownership certainty.

**Decision to make.** Which ownership model should decoded messages use:
fully owned (today), borrow-within-dispatch, or owned scalars plus
zero-copy records?

**Why now.** The 2026-08-29 runtime sweep flagged the per-frame dupes as the
receive side's constant factor (sweep findings item 15): every replicated
slot memcpys its full record into the arena after the wire already carried
it, on top of the decode. With the leader-side encode-once work landed
(2026-08-29), the remaining per-slot copies are on the receive path.

**Drivers.** Any acceptable option must:

- keep the decoder's untrusted-input discipline (bounds checks, version and
  kind refusal, CRC-validated records) unchanged;
- not let a handler outlive the bytes it borrowed (the borrow must be
  documented and enforced by review - or by construction);
- not change the wire format or the on-disk record format;
- preserve the dedup/idempotency guarantees that rest on the decoded entry
  (`checkAuthorSeq` compares the recomputed entry hash against the stored
  one - a borrowed entry decodes the same bytes).

**Out of scope.** The queue drain shape (RFC 0004), the fsync policy (RFC
0003/ADR 0008), and the store's read path are separate decisions.

## Current state

`message.decode` (called with a per-frame arena, `node.zig:796-798`) copies
every variable-length part into the arena and returns a message that owns
them. The frame body is freed by the reader after the handler returns
(`node.zig:622-625` for the loop, `transport.zig` for the hub/TCP readers).

The biggest parts are the segment records inside `slot`, `sync_page` and
`read_page`: a broadcast slot's record is `dupe`d (`message.zig:348`), then
`decodeSlot` parses it; `onSlot` hands it to `applyReplicated`, which writes
it to the store verbatim (`Store.appendRecord`). The same shape applies to
every record in a sync/read page (`decodeSyncPage`/`decodeReadPage` dupe the
whole page's record bytes).

The invariant is documented and has tests (`message.zig:6-8`; decoder tests
assert owned parts). Changing it is a contract change, not a refactor.

## Options considered

### Option A - status quo: full ownership

- **What it is:** keep the owning contract; every part is copied into the
  arena.
- **Pros:** airtight - a handler can retain any part safely; no borrow
  discipline to enforce; existing tests keep their meaning.
- **Cons:** one full memcpy of every record and name per received message,
  on every member, forever; the arena churn on top.
- **Cost to adopt:** zero.
- **Cost to leave:** the per-message copies stay a permanent line item.
- **Evidence:** the copies are measurable by reading (`message.zig:348`,
  `decodeSyncPage`, `decodeReadPage`); a benchmark of hub append throughput
  with the copies disabled is the planned gate (see Open questions) -
  `unverified` until then.

### Option B - borrow within dispatch

- **What it is:** decoded slices point into the frame body (records decode
  in place); the handler must not retain them beyond the call.
- **Pros:** removes the record memcpy and the arena's dupe allocations; the
  body provably outlives the handler today.
- **Cons:** every decoder consumer becomes a borrow-context; a retained
  slice is silent use-after-free (the arena is gone, the body is freed); the
  decoder's "owns what it names" promise disappears, so the tests that pin
  it must be rewritten; review burden on every future handler.
- **Cost to adopt:** decoder + all dispatch sites + tests; the borrow rule
  needs a documented home (the message module header).
- **Cost to leave:** reverting restores the copies; nothing else changes.
- **Evidence:** mechanism read at `node.zig:622-625, 368` (body lifetime),
  `message.zig:343-360` (the slot record dupe), `message.zig:6-8` (the
  contract).

### Option C - owned scalars, zero-copy records (out-of-the-box)

- **What it is:** the small string parts (journal names, addresses, refusal
  names) stay owned as today; only the **segment records** - the
  self-describing `len | crc | slot | entry` blocks inside `slot`,
  `sync_page`, `read_page` - are decoded in place from the frame body. They
  are already CRC-validated before use and written to disk (or re-encoded
  into pages) within the handler, so their borrow is short and narrow.
- **Pros:** removes the largest copies (a page's whole record set; a
  broadcast slot's record) while keeping the ownership story simple for the
  small parts; the record format already carries its own length and CRC, so
  in-place decode needs no format change; `appendRecord` already consumes
  the raw bytes verbatim.
- **Cons:** still a contract change for the record fields; the record
  borrow must be documented on `SlotMsg.record`/page fields; the same
  retain-hazard as B, but confined to records.
- **Cost to adopt:** decodeSlot/decodeSyncPage/decodeReadPage + the record
  consumers (onSlot, onSyncPage, onReadReq) + the ownership tests for the
  record fields.
- **Cost to leave:** trivial - restore the dupes.
- **Evidence:** the record bytes are consumed verbatim by
  `Store.appendRecord` (`store.zig:265-284`) and re-encoded into pages by
  the serving side - both within the handler; mechanism read, benchmark
  pending.

## Implications by horizon

### Short term (this release / 0-3 months)

- **If A:** nothing changes; the copies stay.
- **If B:** the biggest behavioral churn for the biggest copy removal;
  every handler is re-audited for retention.
- **If C:** the record copies disappear (the dominant cost) with a narrow
  borrow surface; the small-part ownership is unchanged.

### Medium term (3-12 months)

- **If A:** the receive-path copies remain a fixed cost at scale (backfill
  of a large journal copies every page's records twice more than needed).
- **If B/C:** the receive path is copy-light; new handlers must know the
  rule.

### Long term (12+ months)

- **If A:** ownership is trivially explainable forever; the cost is
  constant.
- **If B/C:** the borrow rule is part of the codebase's vocabulary (the
  loop is already single-threaded and synchronous, which is what makes the
  borrow safe at all); a future multi-threaded dispatch would need to
  revisit it.

## Recommendation

**Recommended option:** C - owned scalars, zero-copy records - **if** the
benchmark (Open questions) shows the record copies matter; otherwise A.

**Confidence:** 6/10.

**Why this confidence.** The mechanism is verified by reading; what is not
measured is the win's size. The benchmark - hub append/backfill throughput
with the record copies disabled - decides between C and A; the small-part
dupes are too cheap to justify changing their ownership. B is rejected
because its full-surface borrow buys little over C (the records are the
dominant part) at much higher review risk.

**Rationale.** Against the drivers: C keeps the decoder's validation intact
(records are CRC-checked before any slice is handed out), keeps the format
unchanged, and confines the borrow to bytes that are consumed verbatim
within the handler (store append, page serving). It beats B by limiting the
contract change to the parts that are actually large, and it beats A if the
benchmark confirms the copies dominate the receive path.

**Reversibility.** Fully reversible: restoring the dupes is a localized
change; no wire, disk, or public API surface is touched.

## Open questions

- **What does the benchmark show?** Hub-based append and backfill
  throughput with the record dupes disabled vs enabled (the sweep's
  proposed experiment). *Answerable by:* a scratch benchmark or an
  instrumented decode. This decides C vs A.
- **Do any handlers retain a record beyond dispatch?** The audit says no
  (onSlot/onSyncPage/onReadReq consume synchronously); a grep for
  `\.record`/`records` retention would settle it before C lands.

## Next steps / action items

- [ ] Run the record-copy benchmark (hub append + backfill) and record it
      in an investigation report linked here.
- [ ] If the win is material: implement C (in-place record decode), update
      the ownership tests, and re-run the gate.
- [ ] Write the ADR once the decision is made.

## References

- Investigation evidence: [2026-08-29 write-path data flow](../reports/investigations/2026-08-29-runtime-sweep-queue-wire.md)
  (the receive-path dupe), [2026-08-29 runtime speedup sweep findings](../reports/investigations/2026-08-29-runtime-sweep-findings.md)
  (item 15)
- Code: `src/net/message.zig` (`decode`, `decodeSlot`, `decodeSyncPage`,
  `decodeReadPage`), `src/cluster/node.zig` (`onFrame` arena, `onSlot`,
  `onSyncPage`, `onReadReq`), `src/journal/store.zig` (`appendRecord`)
- Prior RFCs: [0003](0003-append-durability-fsync-policy.md) (the queue's
  idempotent-replay argument that also underlies the queue drain),
  [0004](0004-queue-drain-shape.md)
