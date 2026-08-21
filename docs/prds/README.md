# PRDs

Product requirement docs for spine. Schema and quality bar:
[`TEMPLATE.md`](TEMPLATE.md). Roadmap narrative and Done/Planned index:
[`../ROADMAP.md`](../ROADMAP.md). Architecture decisions that constrain
PRDs: [`../adrs/`](../adrs/). Unknowns every PRD points into:
[`../open-questions.md`](../open-questions.md).

## Quick start

Open a new PRD from the template, numbered after the last in the inventory:

```bash
cp docs/prds/TEMPLATE.md docs/prds/0007-<slug>.md
```

A Draft counts as planned only when its Design names dependencies and
implementation phases with file paths, and every build blocker is settled in
Design rather than parked under Open questions. Goals and acceptance criteria
must cover each other. A bug belongs in Known issues, never in Open
questions. `status → Shipped` names the source files that are now the source
of truth.

## Inventory

Unfinished work first.

| # | Status | Title |
|---|---|---|
| [0001](0001-ledger-core.md) | Draft | Ledger core: append-only entries, slots, and the hash chain |
| [0002](0002-ttl-and-staleness.md) | Draft | TTL and staleness: the only two mutations |
| [0003](0003-membership-and-leadership.md) | Draft | Membership and leadership: seniority, configured authorities, scaling 1 → n |
| [0004](0004-settings.md) | Draft | Settings: the ledger configures itself through its own chain |
| [0005](0005-embedding-the-library-as-the-product.md) | Draft | Embedding: the library as the product, the node binary, and hosts (clanker first) |
| [0006](0006-scaling-to-groups-sharding-and-parity.md) | Draft (later work; names what the core must get right now) | Scaling 1 → n → groups: recursive groups, sharding, and parity |
