---
description: Draft a checkable implementation plan before non-trivial work.
argument-hint: "[feature, fix, or change]"
tags: planning
---

Plan the implementation of: {{args}}

1. Define the outcome, acceptance criteria, scope, and deliberate non-goals.
2. Identify existing instructions, PRDs, ADRs, roadmap items, and relevant
   code or configuration that constrain the work.
3. List numbered, independently checkable file-level changes. For each, name
   the reason, expected behavior, and any decision that needs an ADR.
4. Cover risks, edge cases, compatibility, rollout, or migration where they
   apply.
5. Define focused and broader verification. State assumptions and only the
   questions that materially block execution.

Use `docs/plans/TEMPLATE.md` for a plan that needs to survive the current
session. Keep the route actionable, but do not turn it into a premature patch.
If the plan is too big for one execution pass, keep it as the parent contract
with an "Execution phases" table and create each phase plan with
`project-kit.py new-doc plan --series <series-slug> <title>` (deterministic
`phase-NN` naming, enforced by docs-check).
