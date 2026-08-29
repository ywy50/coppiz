---
description: Diagnose a bug or failing test and propose the smallest causal fix.
argument-hint: "[error, symptom, or failing test]"
tags: debugging, fix
---

Diagnose and propose the minimal fix for: {{args}}

1. Reproduce or locate the failure. Name the exact symptom and the relevant
   file, test, log, or runtime evidence. Search `docs/reports/` first - a
   matching bug report or investigation has the reproduction already.
2. State the root cause in one concise paragraph. Distinguish evidence from an
   assumption that still needs confirmation.
3. Propose the smallest causal patch: exact files, edits, and why the change
   fixes the cause rather than masking the symptom.
4. Verify the focused regression first, then the broader relevant checks.
5. Record changed feature behavior, known issues, or durable decisions in the
   owning PRD or ADR when applicable. A defect worth a durable record gets a
   bug report (`new-doc bug`) with its resolution and verification filled in.

Do not refactor beyond the fix. If the evidence cannot establish a cause, stop
with the next discriminating check instead of guessing at a patch.
