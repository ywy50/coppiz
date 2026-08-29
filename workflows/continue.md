---
description: Resume work from durable repository context without redoing settled decisions.
llm-description: Resume a task by reading durable instructions, TODOs, roadmap, docs, and evidence first.
argument-hint: "[task, session, or area to resume]"
tags: resume, coordination
---

Resume this work: {{args}}

1. Read applicable `AGENTS.md` instructions and the local TODO board.
2. Read the roadmap and any related PRD, ADR, plan, review, and handover.
3. Summarize the current state, settled decisions, verified evidence, remaining
   work, and any active ownership claim before editing anything.
4. If work is unclaimed and will be concurrent, generate a new session ID and
   claim the specific TODO item. Do not take over a fresh claim without an
   explicit handoff.
5. Continue with the smallest verified next action. Do not re-open a documented
   decision unless new evidence contradicts it.

If durable records do not make the next action clear, state the blocking
question and the evidence consulted rather than guessing at the task.
