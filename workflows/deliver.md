---
description: Carry a non-trivial change from context through verification, review, and durable handoff.
llm-description: Execute a complete delivery lifecycle: orient, plan or fix, verify, review, document, and hand off.
argument-hint: "[feature, fix, or outcome]"
tags: delivery, planning, verification
---

Deliver this outcome: {{args}}

Follow `docs/WORKFLOW.md` and applicable repository instructions.

1. Orient from the TODO board, roadmap, related PRD/ADR, plans, reviews, and
   handovers. Claim the work with a session ID when concurrency applies.
2. Classify the work. For a defect, establish a baseline failure and use the
   fix flow. For non-trivial work, create or update a plan. Create a PRD or ADR
   only when the scope or decision needs a durable record.
3. Implement the smallest change that meets the stated acceptance criteria.
4. Verify focused behavior first, then broader relevant checks.
5. Review the final diff against boundaries and documented decisions. Record
   material findings or coverage limits.
6. Update durable documentation, regenerate `docs/INDEX.md`, resolve the TODO
   claim, and create a handover if another session may continue.

Report the evidence, remaining risks, and next action plainly. Do not claim
completion without the proof named by the task or project instructions.
