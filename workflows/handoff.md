---
description: Create a durable handoff so another agent can continue safely.
llm-description: Capture current state, verification evidence, next action, and blockers for a fresh agent session.
argument-hint: "[work item or receiving agent]"
tags: handoff, coordination
---

Prepare a handoff for: {{args}}

Read the active TODO claim, current Git status, related plan/PRD/ADR/review,
and verification output. Create a dated file in `docs/handovers/` using its
template. Include the session ID, exact current state, evidence run and skipped,
one smallest next action, and blockers or ownership conflicts.

Update the TODO item to reflect whether it remains claimed, is released, or is
complete. Do not bury essential continuation information only in chat.
