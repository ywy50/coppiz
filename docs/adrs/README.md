# ADRs - architecture decision records

An ADR records a decision that **has been made**: the constraint that forced
it, the choice, and what that choice costs. The [RFC](../rfcs/) that may
precede it argues the alternatives; this record is the answer. Neither store
requires the other - a decision can be obvious enough to need no RFC, and an
RFC can be withdrawn without ever producing an ADR.

## Quick start

Open a new ADR from the template, numbered after the last in the inventory:

```bash
cp docs/adrs/TEMPLATE.md "docs/adrs/0008-<slug>.md"
```

The title is the **choice**, not the question. Add it to the inventory
below. An ADR is never reversed by editing: mark it Superseded and link
forward to its replacement.

## Inventory

| # | Status | Decision |
|---|---|---|
| [0001](0001-zig-0-16-standard-library-only-for-the-core.md) | Accepted | The core is Zig 0.16 with the standard library only |
| [0002](0002-entries-are-immutable-ttl-and-author-staleness-are-the-only-mutations.md) | Accepted | Entries are immutable; TTL expiry and author-marked staleness are the only mutations, and both are opt-in by setting |
| [0003](0003-batteries-included-no-external-infrastructure-at-any-size.md) | Accepted | Batteries included: replication, election and storage ship inside the library, and no external infrastructure is required at any size |
| [0004](0004-the-product-is-named-coppiz.md) | Accepted | The product is named coppiz |
| [0005](0005-join-order-is-slot-position.md) | Accepted | Join order is slot position: a `join` is a chain entry written by the admitter, and seniority is its slot, so it cannot be forged |
| [0006](0006-the-library-is-apache-2-0-licensed.md) | Accepted | The library is Apache-2.0 licensed |
| [0007](0007-the-library-is-the-primary-surface.md) | Accepted | The library is the primary surface; the node binary is its wrapper |
