# Plan - <Change>

**Date:** YYYY-MM-DD  
**Status:** Draft / In progress / Completed  
**Related:**

<related item: PRD, ADR, issue, or review record; end this description line
with two trailing spaces so the URL below stays on its own line>  
<the item's bare URL>

<further related items follow as the same block, one blank line in between>

## Outcome

State the observable end state (what "done" means), readable without running
any checks. With more than one result, use a bullet list, one result per item.
Phrase each result so it is obvious what check would prove it, but keep the
checks themselves in Verification; duplicating them here invites drift.

## Scope and constraints

Name the files, interfaces, compatibility limits, and deliberate non-goals.

## Decisions and unknowns

Record settled choices and only the questions that genuinely block execution.
Move a consequential technical choice to an ADR rather than burying it here.

## Steps

Numbered, independently checkable steps. Name concrete files to create or
edit, the behavior each step changes, and the verification that follows it.

## Verification

List the focused regression check first, then broader relevant checks. Include
manual or runtime evidence when automation cannot establish the result. Each
check should trace to an Outcome result or guard a regression.

## Completion notes

Record material deviations from the plan, evidence produced, and links to the
review or follow-up work. Do not leave the final result only in chat history.
