# RFCs - requests for comment

An RFC presents a decision that has not been made yet: the options, what each
one implies over time, and a recommendation with a confidence score. It is the
step before an [ADR](../adrs/) - the ADR records what was chosen, this file
records why the alternatives lost. Not every ADR needs an RFC, and not every
RFC leads to one.

## Quick start

Open a new RFC from the template, numbered after the last in the inventory:

```bash
cp docs/rfcs/TEMPLATE.md "docs/rfcs/0004-<slug>.md"
```

Then add it to the inventory below. An RFC needs at least two candidates, the
status quo, one out-of-the-box option, and a recommendation whose confidence
is a number from 0 to 10. When it is decided, set its status here and in the
file, and write the ADR.

There is no tool maintaining this store yet; clanker's `rfc` tool is the
reference for what one would do ([OQ 41](../open-questions.md#oq-41)).

## Inventory

| # | Status | Title |
|---|---|---|
| [0001](0001-library-first-or-service-first.md) | Decided | Library-first or service-first: which surface leads the design |
| [0002](0002-how-join-order-is-made-unspoofable.md) | Decided | How join order is made unspoofable |
| [0003](0003-append-durability-fsync-policy.md) | Decided | What does `storage.fsync` govern? (ADR 0008) |
| [0004](0004-queue-drain-shape.md) | Discussion | What shape should the queue drain take? (tombstone / watermark / batched) |
| [0005](0005-decode-ownership.md) | Discussion | Should a decoded message own its parts, or borrow from the frame? |
| [0006](0006-multi-process-one-data-directory.md) | Discussion | Several processes on one data directory: native multi-process opens or the wire fallback? (OQ 47) |
| [0007](0007-service-api-auth.md) | Discussion | What authenticates service-API callers off loopback? (OQ 38) |
| [0008](0008-wire-encryption.md) | Discussion | Wire encryption: plaintext v1, and what protects a non-private deployment (OQ 23) |
| [0009](0009-trust-model.md) | Discussion | The trust model: crash faults and tamper evidence, not BFT (OQ 1) |
| [0010](0010-per-journal-leadership.md) | Discussion | Per-journal or cluster-level leadership? (OQ 8) |
| [0011](0011-topology-past-32.md) | Discussion | Topology past 32 members: leader-star first, gossip later (OQ 25) |
| [0012](0012-backpressure.md) | Discussion | Backpressure: a slow follower must not slow the writers (OQ 28) |
