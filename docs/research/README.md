# Research notes

Evidence gathered before a decision: what exists, how mature it is, and how
confident each finding is. A research note answers a question; it does not
choose. The choice belongs in an [RFC](../rfcs/), and the decision that comes
out of it in an [ADR](../adrs/).

## Quick start

Open a new note from the template, numbered after the last in the inventory:

```bash
cp docs/research/TEMPLATE.md "docs/research/0004-<slug>.md"
```

Every claim traces to an evidence-log row with the date it was read. Internet
text is a lead until opened at its source; a finding carried from another
project's research says so and keeps that project's read date.

## Inventory

| # | Status | Question |
|---|---|---|
| [0001](0001-evidence-carried-from-the-state-store-survey.md) | Draft | What clanker's state-store survey established that coppiz inherits |
| [0002](0002-comparison-benchmarks.md) | Draft (re-read 2026-08-29) | Which stores to benchmark coppiz against, which workloads and metrics make it fair, and the current state of each candidate |
| [0003](0003-fsync-default-measurement.md) | Resolved (OQ 14) | Is `storage.fsync = every` on the leader acceptable at clanker's write rates? |
| [0004](0004-ttl-grace-default.md) | Open - measurement pending (OQ 9) | What should `ttl.grace_ms` default to, and can it be derived from observed skew? |
| [0005](0005-checkpoint-cadence-defaults.md) | Open - measurement pending (OQ 10) | What are the right `checkpoint.every_ms` / `pending_bytes` defaults? |
| [0006](0006-max-entry-size.md) | Open - measurement pending (OQ 36) | Is 16 MiB the right `journal.max_entry_bytes`, and when does the blob shape become necessary? |
| [0007](0007-tier-number-measurements.md) | Open - measurement pending (OQ 54) | Which measurements replace the intent tier numbers? |
| [0008](0008-merge-settle-default.md) | Open - measurement pending (OQ 60) | What is the right `merge.settle_ms` default? |
| [0009](0009-memory-bound.md) | Open - measurement pending (OQ 61) | What bounds per-process memory, and what does a member do at the bound? |
