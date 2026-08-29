# Research notes

Evidence gathered before a decision: what exists, how mature it is, and how
confident each finding is. A research note answers a question; it does not
choose. The choice belongs in an [RFC](../rfcs/), and the decision that comes
out of it in an [ADR](../adrs/).

## Quick start

Open a new note from the template, numbered after the last in the inventory:

```bash
cp docs/research/TEMPLATE.md "docs/research/0002-<slug>.md"
```

Every claim traces to an evidence-log row with the date it was read. Internet
text is a lead until opened at its source; a finding carried from another
project's research says so and keeps that project's read date.

## Inventory

| # | Status | Question |
|---|---|---|
| [0001](0001-evidence-carried-from-the-state-store-survey.md) | Draft | What clanker's state-store survey established that coppiz inherits |
| [0002](0002-comparison-benchmarks.md) | Draft (re-read 2026-08-29) | Which stores to benchmark coppiz against, which workloads and metrics make it fair, and the current state of each candidate |
