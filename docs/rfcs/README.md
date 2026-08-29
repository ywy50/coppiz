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
| [0013](0013-seniority-on-rejoin.md) | Discussion | Seniority on rejoin: only a leave resets it (OQ 4) |
| [0014](0014-offline-reconfigure.md) | Discussion | Changing leadership settings when reconfigurable = false (OQ 5) |
| [0015](0015-eviction.md) | Discussion | Eviction of dead members: the leader evicts, and the dead-leader case (OQ 20) |
| [0016](0016-allowlist-key-learning.md) | Discussion | How the allowlist learns a newcomer's key (OQ 21) |
| [0017](0017-key-rotation-operator-key.md) | Discussion | Key rotation and compromise; an operator key (OQ 22) |
| [0018](0018-read-consistency.md) | Discussion | Read consistency: local reads and the leader-head check (OQ 31) |
| [0019](0019-journal-lifecycle.md) | Discussion | Journal lifecycle: creation is leader-only; there is no drop (OQ 34) |
| [0020](0020-cursor-id-encoding.md) | Discussion | Cursor and id encoding for consumers (OQ 42) |
| [0021](0021-host-shapes.md) | Discussion | Which non-clanker hosts are the design targets? (OQ 46) |
| [0022](0022-snapshot-format.md) | Discussion | Snapshot format: a serialized fold, served to joiners behind a trigger (OQ 17) |
| [0023](0023-rolling-upgrade.md) | Discussion | Format versioning and rolling upgrade (OQ 26) |
| [0024](0024-backup-restore.md) | Discussion | Backup and restore (OQ 39) |
| [0025](0025-docs-in-package.md) | Discussion | Does the fetchable package carry the design docs? (OQ 59) |
| [0026](0026-grouping-unit-range-key.md) | Discussion | Grouping unit and range key (OQ 48) |
| [0027](0027-parity-code.md) | Discussion | Parity code and reconstruction cost (OQ 50) |
| [0028](0028-cross-group-routing.md) | Discussion | Cross-group routing and read semantics (OQ 51) |
| [0029](0029-group-identity-in-headers.md) | Discussion | What group identity the core headers carry now (OQ 52) |
| [0030](0030-membership-discovery.md) | Discussion | Membership and discovery at 10⁵ (OQ 53) |
