# RFC 0019 - journal lifecycle: creation is leader-only; there is no drop

## Status

Discussion - opened 2026-08-29. Addresses OQ 34 (the
register keeps the stable pointer).

An RFC is a *request for comment*: it presents the options and a recommendation
so a decision can be made, and it is not itself the decision record. When it is
decided, set the status, then write the [ADR](../adrs/) that records the choice
and link it from References.

## Overview

OQ 34 is partially resolved: `create_journal` is
leader-only in v1 (PRD 0001's status records the decision; the enforcement
has an open bypass, tracked as a bug). The remaining half: can a journal
be *dropped* - the only non-chain deletion - or only frozen (no further
appends) and expired away?

**Decision to make.** Is there a drop operation at all, or is a journal's
end state "frozen, then removed by retention"?

**Why now.** The answer decides whether the chain gains a destructive
control kind - a permanent decision about what the chain may express.

**Drivers.** Any acceptable option must:

- keep "everything the journal knows about itself is in the chain" (PRD
  0001's rule): a drop that deletes storage without a chain record would
  fork members that missed the deletion;
- keep every member's fold deterministic: a dropped journal's absence
  must be a foldable fact, not a local one;
- not confuse removal with the existing cleanup (PRD 0002's checkpoint
  removal is per-entry, never per-journal).

**Out of scope.** Journal *creation* policy (resolved: leader-only, with
the enforcement bug tracked separately). Multi-group ownership of a
journal (PRD 0006 - a drop there is an ownership-map question).

## Current state

Journals are created by a leader-authored `create_journal` control entry
(leader-only in v1; the enforcement bypass is bug
2026-08-29-live-create-journal-bypass). There is no drop: the only
removal is PRD 0002's checkpoint payload drop, which never removes a
slot or a journal. The chain has no "journal ended" fact.

## Options considered

### Option A - no drop; freeze and expire (status quo)

- **What it is:** a journal's end state is *frozen* - no further appends
  (a `settings` change or a new control kind marks it read-only) - and
  its entries expire by the normal retention. The journal id stays in the
  registry; the chain keeps its history.
- **Pros:** no destructive chain fact; every member's fold stays
  deterministic; the history remains verifiable; nothing is deleted that
  a re-slot or a merge might need.
- **Cons:** a long-dead journal's id lingers in the registry (the
  `cluster.max_journals` seat is taken); "frozen" needs a representation
  (a setting is the natural one).
- **Cost to adopt:** the freeze representation; no format change beyond a
  setting.
- **Cost to leave:** none.
- **Evidence:** the chain's append-only rule (ADR 0002); PRD 0001's
  control-entry model.

### Option B - drop as a control entry

- **What it is:** a `drop_journal` control kind: the leader marks the
  journal dropped, every member folds the drop and may then delete the
  journal's storage locally.
- **Pros:** a real delete; the seat frees.
- **Cons:** the only destructive chain fact - a bug in the drop rule
  deletes data on every member; the storage deletion is per-member local
  cleanup that must tolerate a member being down (it re-folds the drop
  and deletes late); "dropped" must survive in the registry to refuse
  re-creation with the same name; the archived-branch and parity
  interactions (PRD 0006) are unstudied.
- **Cost to adopt:** a new control kind, its validation, the storage
  deletion path, and the late-deleter case.
- **Cost to leave:** high after the format freezes (the kind is permanent
  once emitted).
- **Evidence:** design reasoning; the complexity is exactly the kind ADR
  0002's append-only rule exists to avoid.

### Option C - drop as operator-only, out-of-band

- **What it is:** a drop is an operator action outside the chain: stop
  the cluster, delete the journal's storage on every member.
- **Pros:** no chain change; an operator who wants a hard delete has a
  path.
- **Cons:** the registry still holds the id (the fold does not know the
  drop); the chain and the storage disagree until every member's directory
  is edited identically - the fork risk the chain exists to prevent.
- **Cost to adopt:** a runbook.
- **Cost to leave:** the registry seat stays taken.
- **Evidence:** the offline-procedure pattern (RFC 0014).

## Implications by horizon

### Short term (this release / 0-3 months)

- **If A:** the freeze representation is added; nothing else changes.

### Medium term (3-12 months)

- **If A and a consumer truly needs deletion:** B is revisited as a
  designed, tested control kind - the decision here is that it is not the
  v1 shape.

## Recommendation

**Recommended option:** A - no drop. A journal freezes (a read-only
setting) and its entries expire by retention; the id and its history stay
in the chain. B (a `drop_journal` control kind) is documented as the
future shape if a consumer's registry pressure makes the seat cost real;
C is rejected (it forks the chain and storage).

**Confidence:** 8/10

**Why this confidence.** A preserves the append-only rule that the whole
design rests on (ADR 0002) and the freeze is a small addition. What would
move it: a consumer showing that a long-dead journal's registry seat is
genuinely costly. What would sink A: a requirement that journals be
deleted for privacy/erasure reasons - which B would then serve, with its
complexity accepted.

**Rationale.** Drop is the one operation that breaks "everything is in the
chain" (a storage deletion on every member that must tolerate members
being down). B's cost is real and its benefit is a registry seat; the
freeze covers the actual need (stop the journal) and retention covers the
bytes.

**Reversibility.** A to B is additive before the format freezes (the kind
would be new); after, B is a versioned addition.

## Open questions

- Does "frozen" need a distinct state or is it `journal.allow_append =
  false`? (implementation; the setting is the natural form)
- Does the open `create_journal` enforcement bypass change this
  recommendation? (no - the bug is about who may create, not whether a
  drop exists)

## Next steps / action items

- [x] Add the freeze representation (a read-only journal setting) - done
      2026-08-30: `journal.allow_append` (bool, journal scope, default
      true, live-changeable). The fold refuses a `data` entry with
      `journal_frozen` and still folds `settings`, `stale` and
      `checkpoint`, so a frozen journal can expire its entries away and be
      unfrozen. The drop half of OQ 34 - whether option B is ever built -
      is what keeps this RFC open.
- [ ] Write the ADR once decided; update OQ 34's status (the drop half).

## References

- OQ 34 (historical) - the question this RFC addresses.
- [PRD 0001](../prds/0001-journal-core.md) - the control-entry model and
  the registry.
- [ADR 0002](../adrs/0002-entries-are-immutable-ttl-and-author-staleness-are-the-only-mutations.md) -
  the append-only rule a drop would be the exception to.
- [PRD 0002](../prds/0002-ttl-and-staleness.md) - the retention that
  removes the bytes.
