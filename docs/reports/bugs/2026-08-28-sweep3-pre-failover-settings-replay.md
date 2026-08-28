# Bug — Pre-failover journal `settings`/`checkpoint` records refuse on replay: `Node.open` fails after a failover

## TL;DR

- **What failed:** On reopen, a data journal's records from a *past* term (pre-failover data a follower kept) fold against the later control fold; a journal-scoped `settings` or `checkpoint` record from that term is authored by the *old* leader and refused (`checkAuthorIsLeader`), which propagates out of `foldAll` and fails `Node.open`.
- **Impact:** A follower that had journal-scoped settings/checkpoints written before a failover cannot reopen its own store — permanent refusal to start, no recovery path.
- **Resolution:** Still open. Statically validated.

## Status

Open.

## Symptom and impact

`applyData` explicitly blesses past-term data: "a *past* term's record is the pre-failover data a follower kept when a new leader was elected — it stays valid and folds against the later control" (`chain.zig:397-399`). `foldJournal` skips only *future*-term records (`journal.zig:691-692`). But a past-term `.settings` record routes to `applyJournalSettings`, whose `checkAuthorIsLeader` compares the author against the *current* epoch's leader (`chain.zig:655`) — the old leader is not it → `NotLeader` → `foldJournal` errors → `foldAll` → `Node.open` fails. `.checkpoint` (`:690`) has the same check. `.stale` can refuse under a changed `stale.enforce` (`:671`).

## Reproduction

Not dynamically reproduced (needs a failover with journal-scoped settings/checkpoints); statically certain. Sequence: leader writes a journal-scoped settings change (or a checkpoint under enforcement) → leader dies → a new leader is elected → the follower restarts → its open re-folds the control chain (new epoch) then the data journal → the past-term settings record refuses.

## Root cause

The pre-failover replay rule (past-term data folds) was implemented for `.data` but not for the journal-control kinds, whose authorization still demands the current leader — the same class of gap as the merge data re-slots (reported 2026-08-29), on the replay path instead of the merge path.

## Resolution

Not yet fixed. Suggested direction: fold pre-failover journal `settings`/`checkpoint`/`stale` records with the re-slot semantics (survivor-wins no-op for settings, checkpoint as its own fold) rather than the live author check — or treat them like the merge path. A regression test should write a journal-scoped settings entry, fail over, restart the follower, and expect a clean open.

## Verification

- Static: `foldJournal` skip guard (`journal.zig:691-692`), `applyJournalSettings`/`applyCheckpoint` author checks (`chain.zig:655, 690`), and `applyData`'s past-term comment (`:397-399`) all read.

## Follow-up

Related replay-path defect: the merge re-slot refusals (2026-08-29-merge-data-reslot-refusals) — same checks, merge path. A unified "journal-control records from a non-current leader" rule would cover both.

## References

- Code: `src/journal/journal.zig:680-697` (`foldJournal`), `src/journal/chain.zig:397-399, 649-667, 684-690`
- Fix: none
