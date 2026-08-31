# Bug - Pre-failover journal `settings`/`checkpoint` records refuse on replay: `Node.open` fails after a failover

## TL;DR

- **What failed:** On reopen, a data journal's records from a *past* term (pre-failover data a follower kept) fold against the later control fold; a journal-scoped `settings` or `checkpoint` record from that term is authored by the *old* leader and refused (`checkAuthorIsLeader`), which propagates out of `foldAll` and fails `Node.open`.
- **Impact:** A follower that had journal-scoped settings/checkpoints written before a failover cannot reopen its own store - permanent refusal to start, no recovery path.
- **Resolution:** Fixed 2026-08-31. The refusal was gone before that (see *Correction*), but the record was being dropped instead of folded; a journal-scoped `settings`/`checkpoint` is now authorized against the leader of the term its own slot names.

## Status

Resolved.

## Symptom and impact

`applyData` explicitly blesses past-term data: "a *past* term's record is the pre-failover data a follower kept when a new leader was elected - it stays valid and folds against the later control" (`chain.zig:397-399`). `foldJournal` skips only *future*-term records (`journal.zig:691-692`). But a past-term `.settings` record routes to `applyJournalSettings`, whose `checkAuthorIsLeader` compares the author against the *current* epoch's leader (`chain.zig:655`) - the old leader is not it → `NotLeader` → `foldJournal` errors → `foldAll` → `Node.open` fails. `.checkpoint` (`:690`) has the same check. `.stale` can refuse under a changed `stale.enforce` (`:671`).

## Reproduction

Not dynamically reproduced (needs a failover with journal-scoped settings/checkpoints); statically certain. Sequence: leader writes a journal-scoped settings change (or a checkpoint under enforcement) → leader dies → a new leader is elected → the follower restarts → its open re-folds the control chain (new epoch) then the data journal → the past-term settings record refuses.

## Root cause

The pre-failover replay rule (past-term data folds) was implemented for `.data` but not for the journal-control kinds, whose authorization still demands the current leader - the same class of gap as the merge data re-slots (reported 2026-08-29), on the replay path instead of the merge path.

## Correction - what was checked, 2026-08-31

`8893ae1` ("docs(reports): mark the sweep fixes resolved (#116)") flipped this
report to `Resolved.` and credited a fix that does not exist: it named a
`pre_failover` flag on `applyData`, "the author is checked against the
record's own slot leader", and a "regression test added".

- `grep -rn 'pre_failover\|preFailover' src/` finds nothing, and
  `git log --all -S'pre_failover'` names only two commits, both docs-only:
  `95791c1` (this report) and `8893ae1` itself. No such flag was ever
  written.
- `8893ae1` touched 29 documentation files and no source file
  (`git show --stat 8893ae1`).

The reported refusal had nevertheless stopped happening, by a route this
report did not name. `d5f3af2` (PR #199,
`2026-08-31-data-reslot-cannot-be-replayed`) taught the live data path to
infer a merge re-slot from authorship - `en.author != cluster.epoch.?.leader`
- and to fold what it infers as a no-op. A pre-failover `settings` or
`checkpoint` matched that test, so `foldJournal` stopped erroring and
`Node.open` stopped failing.

It stopped failing by dropping the record. That is a different defect on the
same records, and worse in one respect - it is silent:

- A member that restarts after a failover reverts the journal's settings to
  the cluster defaults, while every member that did not restart keeps them.
  Two members then disagree about `journal.max_entry_bytes`,
  `journal.allow_append`, `ttl.*` and the rest, which is exactly what "the
  chain is the only source of what the journal knows about itself" exists to
  prevent.
- The same drop applies to a pre-failover `checkpoint`, so the restarted
  member keeps entries its peers have already expired.

The soundness argument in the code was that "an entry the live rule accepts
is leader-authored, so it never matches". That holds on the *control* chain,
where the epoch entries are folded in chain order and `self.epoch` is
therefore the epoch in force at each record. It does not hold for a data
journal: `foldJournal` folds one against `node.control` as it stands at the
*end* of the control chain (`journal.zig`), so every record of every past
term is judged against the newest leader.

## Resolution

Fixed 2026-08-31: the discriminator is the record's own term, not the current
leader.

- `chain.FoldState` keeps `epoch_leaders`, the `(number, leader)` of every
  term the control chain has opened, appended from the two places that open
  one - `applyGenesis` and a folded `epoch` entry. It is derived from the
  chain, so every member that folded the chain agrees on it, and it is not
  part of `hash`.
- The live data path folds a journal-scoped `settings`/`checkpoint` when
  `en.author == cluster.leaderOfEpoch(sl.epoch)`, and treats anything else as
  a merge re-slot no-op. `doMergeData` stamps a re-slot with the *survivor's
  current* epoch and leaves the losing branch's author alone, so a re-slot
  still never matches; a record a follower wrote in an earlier term does.
- A term this fold has no epoch entry for stays a no-op - the conservative
  side, and what the current-leader test did for it.

Comparing against the record's own `sl.leader` instead - what `8893ae1`
credited - was rejected: `sl.leader` on a data slot is only checked to be *a*
member, so any member could self-sign a slot and author its own journal
settings. `leaderOfEpoch` names only a member that actually led a term of
this chain.

`.stale` is unchanged. This report also noted that `applyStale` can refuse
under a changed `stale.enforce`; that is a settings-history problem rather
than a leader-authority one and was not touched here.

## Verification

- Regression test, `src/journal/chain.zig`, "a pre-failover journal settings
  record still folds when it is replayed": folds a journal-scoped
  `ttl.default_ms = 2000` as the epoch-1 leader, opens epoch 2 under a second
  member, then replays the same `(slot, entry)` into a fresh data fold
  against the post-failover control fold, as `foldJournal` does on reopen.
  On the parent it fails `expected 2000, found 0` - the record folded as a
  no-op and the setting reverted. With the fix it passes.
- The existing "a re-slotted data entry folds journal
  settings/checkpoint/stale as no-ops" test built its re-slot at epoch 1
  while the survivor was at epoch 2. `doMergeData` re-slots into the
  survivor's current term, so the fixture now uses epoch 2 and records that
  term's leader; the no-op assertion then holds for the reason the merge rule
  gives rather than by accident.
- `zig build test --summary all` from the branch worktree:
  `Build Summary: 25/25 steps succeeded; 373/373 tests passed`, exit 0.
  Baseline on the base commit `c6983b9`:
  `Build Summary: 25/25 steps succeeded; 372/372 tests passed`, exit 0.
  Gated again after merging `ed78c69` (`origin/main` had moved):
  `Build Summary: 25/25 steps succeeded; 375/375 tests passed`, exit 0.
- Not reproduced end to end through a real failover of a running cluster;
  the reproduction is at the fold layer, which is where the rule lives.

- Static, from the original report: `foldJournal` skip guard, the
  `applyJournalSettings`/`applyCheckpoint` author checks, and `applyData`'s
  past-term comment all read.

## Follow-up

Related replay-path defect: the merge re-slot refusals (2026-08-29-merge-data-reslot-refusals) - same checks, merge path.

Still open, and argued rather than reproduced: a data journal is folded
against the *final* control fold rather than the control fold as of each data
slot. `epoch_leaders` closes that gap for leader authority only. Any other
rule a data record is judged by that reads cluster-scoped state - the
`stale.enforce` refusal this report noted, and `merge.settle_ms` - has the
same shape and is not covered.

## References

- Code: `src/journal/journal.zig` (`foldJournal`), `src/journal/chain.zig`
  (`applyDataChecked`, `applyJournalSettings`, `applyCheckpoint`,
  `leaderOfEpoch`, `epoch_leaders`)
- Fix: `src/journal/chain.zig` on branch `fix/pre-failover-journal-settings-term`;
  the refusal itself had already been removed incidentally by `d5f3af2`
  (PR #199)
- Falsely credited: `8893ae1` - docs-only, `pre_failover` never existed
