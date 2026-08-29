---
description: Review a change for correctness, security, regressions, and missing proof.
argument-hint: "[file, diff, PR, or scope]"
tags: review
---

Review the following scope: {{args}}

First read applicable repository instructions, plans, PRDs, ADRs, and prior
review records. Then inspect the implementation and run safe, relevant checks.

Check for:

- incorrect behavior, boundary cases, error handling, resource lifetime, and
  regressions;
- security and authorization boundaries appropriate to the project;
- compatibility, maintainability, and project conventions;
- missing or misleading verification, tests, documentation, or acceptance
  evidence.

Report findings first, ordered by impact. For every finding provide the exact
location, observed behavior, impact, and evidence. Distinguish confirmed
defects from risks and coverage limits. Do not invent findings. End with one
verdict: pass, needs work, or blocked; name the highest-priority next action.
