# RFC 0024 - backup and restore

## Status

Discussion - opened 2026-08-29. Addresses OQ 39 (the
register keeps the stable pointer).

An RFC is a *request for comment*: it presents the options and a recommendation
so a decision can be made, and it is not itself the decision record. When it is
decided, set the status, then write the [ADR](../adrs/) that records the choice
and link it from References.

## Overview

A data directory copied while the node runs may hold a torn tail (recovered
at open). The open questions: is `cp -r` a supported backup, or does
`coppiz export` exist - and how does a restore avoid resurrecting a
`leave` or forking the chain?

**Decision to make.** What is the supported backup and restore procedure,
and what tooling (if any) does it need?

**Why now.** Backup is a first-release requirement (RELEASES.md names it);
the chain makes a forked restore *detectable*, but detection is not the
same as a procedure.

**Drivers.** Any acceptable option must:

- make a restore detectable if not impossible: restoring an old copy
  after a `leave` must not silently resurrect the member;
- not require stopping the cluster for a routine backup;
- keep the chain the arbiter: a restored member that forks is caught by
  `prev_slot_hash` on its first sync (PRD 0001).

**Out of scope.** Off-site replication (that is the cluster itself).
Encryption at rest (PRD 0001 non-goals).

## Current state

`open` recovers a torn tail at startup (PRD 0001 G4). A copy made while
the node runs is therefore openable, but the copy's recency is the
operator's problem: a member restored from an old copy that missed a
`leave` (its own or another's) will rejoin with stale membership and
either be refused (its key was left) or fork (its head is behind) - both
detectable by the chain. There is no `coppiz export` and no runbook.

## Options considered

### Option A - `cp -r` of a stopped (or quiesced) directory; the chain detects the rest (out-of-the-box)

- **What it is:** the supported backup is a file-level copy. Two
  variants: (1) offline - stop the node, copy, restart (always clean);
  (2) online - copy while running, accepting that the tail may be torn
  and the copy may be mid-write (open recovers the tail, but the copy is
  only as consistent as the moment it captured). Restoring is: put the
  copy in place, start, and let the fold + chain verification either
  accept it or refuse it (a restored member behind the cluster backfills;
  one whose key was `leave`d is refused).
- **Pros:** zero tooling; the chain already arbitrates; the procedure is
  short.
- **Cons:** the online copy has no defined consistency point (the
  operator must accept "as of roughly when the copy finished"); no
  verification before restore (the operator learns the copy is bad at
  first sync).
- **Cost to adopt:** the runbook (offline and online variants).
- **Cost to leave:** no procedure at all.
- **Evidence:** the torn-tail recovery (PRD 0001 G4); the chain
  verification.

### Option B - `coppiz export` / `coppiz import`

- **What it is:** a command that snapshots the directory consistently
  (quiesce the writer, copy the relevant files, resume) and an import
  that verifies before swapping.
- **Pros:** a defined consistency point; import-time verification (the
  operator learns a stale copy is stale *before* putting it in place).
- **Cons:** a new command pair and its failure modes; the consistency
  point is the same as "stop the node briefly" - the value over A is
  verification, not the copy.
- **Cost to adopt:** the commands, tests, and the runbook.
- **Cost to leave:** none.
- **Evidence:** the write path's quiesce point (the loop's stop).

### Option C - rely on cluster replication as the backup

- **What it is:** the backup is another member; a restore is a fresh
  join and backfill.
- **Pros:** no local copy at all; always consistent (backfill is
  chain-verified).
- **Cons:** it protects against a lost member, not against a corrupted
  or deleted directory on *all* members (the offline-backup case); a
  cluster that loses every member loses everything.
- **Cost to adopt:** none.
- **Cost to leave:** the all-members-lost case.
- **Evidence:** the backfill path.

## Implications by horizon

### Short term (first release)

- **If A:** the runbook ships; backups are file copies.

### Medium term

- **If B is wanted:** the export/import pair lands when a consumer
  actually needs import-time verification.

## Recommendation

**Recommended option:** A for the first release - file-level copy with
the offline variant as the documented safe path and the online variant
documented with its "as of" caveat; the chain arbitrates restores. B
(export/import with import-time verification) is the ergonomic addition
if a consumer needs to verify before restore. C is complementary, not a
replacement.

**Confidence:** 7/10

**Why this confidence.** A is zero-tooling and the chain's arbitration is
already shipped. What would move it: a consumer whose restore has to
succeed first-try, arguing for B's import-time check.

**Rationale.** The chain is the arbiter either way; A just states the
procedure, B adds verification at tooling cost. C protects a different
failure (lost member, not lost cluster).

**Reversibility.** A to B is additive.

## Open questions

- Does the online copy need the node's lock released first, or is the
  copy of a locked directory safe (the node only appends)? (implementation;
  the torn-tail recovery suggests it is safe, but the runbook should say
  so explicitly)

## Next steps / action items

- [ ] Write the backup/restore runbook (offline and online variants).
- [ ] Write the ADR once decided; update OQ 39's status.

## References

- OQ 39 (historical) - the question this RFC addresses.
- [PRD 0001](../prds/0001-journal-core.md) - torn-tail recovery and the
  chain's arbitration.
- [RELEASES.md](../../RELEASES.md) - the first-release list that names the
  backup runbook.
