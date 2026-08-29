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
reference for what one would do ([OQ 41](../open-questions.md)).

## Inventory

| # | Status | Title |
|---|---|---|
| [0001](0001-library-first-or-service-first.md) | Decided | Library-first or service-first: which surface leads the design |
| [0002](0002-how-join-order-is-made-unspoofable.md) | Decided | How join order is made unspoofable |
| [0003](0003-append-durability-fsync-policy.md) | Decided | What does `storage.fsync` govern? (ADR 0008) |
| [0004](0004-queue-drain-shape.md) | Discussion | What shape should the queue drain take? (tombstone / watermark / batched) |
| [0005](0005-decode-ownership.md) | Discussion | Should a decoded message own its parts, or borrow from the frame? |
