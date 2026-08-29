# RFC 0013 - seniority on rejoin: only a leave resets it

## Status

Discussion - opened 2026-08-29. Addresses [OQ 4](../open-questions.md) (the
register keeps the stable pointer).

An RFC is a *request for comment*: it presents the options and a recommendation
so a decision can be made, and it is not itself the decision record. When it is
decided, set the status, then write the [ADR](../adrs/) that records the choice
and link it from References.

## Overview

Seniority is the slot of a member's `join` entry (RFC 0002, ADR 0005). The
drafted rule: only a `leave` entry resets seniority - a crash or network
absence keeps it. The question is whether a long absence
(`membership.evict_after_ms`) should convert to a `leave`, which changes
the leader order.

**Decision to make.** Is "seniority resets only on `leave`" the rule, with
eviction (`evict_after_ms`) as the deliberate leave that changes leader
order - and is that change the point, not a surprise?

**Why now.** The fold rule is shipped ("only a `leave` resets seniority");
the open part is the semantics of eviction-as-leave and whether it should
be the default.

**Drivers.** Any acceptable option must:

- keep seniority a chain fact (RFC 0002): nothing may reset it except a
  chain entry;
- keep eviction deliberate: a timer that silently reorders leadership is
  either the point of eviction or a trap - the docs must say which;
- keep the default safe: with `evict_after_ms = 0` (default), nothing
  ever evicts.

**Out of scope.** Who evicts (OQ 20, RFC 0015). Key rotation (OQ 22, RFC
0017).

## Current state

The fold resets seniority only on `leave`; a rejoin after `leave` gets a
new `join` slot (newest seniority). The leader writes a `leave` for a
member `unreachable` for `evict_after_ms` (default 0 = never) - the
shipped eviction mechanism (PRD 0003). A crash or absence without
eviction keeps the member's seniority and its seat.

## Options considered

### Option A - the drafted rule, documented (status quo)

- **What it is:** seniority resets only on `leave`; eviction
  (`evict_after_ms > 0`) is the leader writing that `leave`, so eviction
  changes leader order by construction. Default 0 = never evicts.
- **Pros:** the shipped fold rule; eviction is an explicit chain event;
  nothing is silent.
- **Cons:** the leader-order change may surprise an operator who enabled
  eviction for hygiene, not leadership - the documentation must call it
  out.
- **Cost to adopt:** documentation.
- **Cost to leave:** none.
- **Evidence:** the shipped fold and eviction path (PRD 0003).

### Option B - eviction frees the seat but preserves seniority

- **What it is:** a long absence removes the member's seat in
  `max_members` but keeps its seniority if it rejoins.
- **Pros:** eviction no longer reorders leadership.
- **Cons:** a departed member's seniority ranks it ahead of live members
  forever if it rejoins; the chain has no slot for "absent but senior" -
  it would need a new fact, against RFC 0002's simplicity; and the
  definition of seniority (a slot position) has no way to express it.
- **Cost to adopt:** a new chain concept.
- **Cost to leave:** none.
- **Evidence:** RFC 0002's "seniority is the slot position" definition.

### Option C - absence never converts; eviction is manual only

- **What it is:** drop the timer; eviction is an explicit operator action
  (a `settings` change or a command), never automatic.
- **Pros:** zero surprise; the operator names the moment.
- **Cons:** a dead member keeps its seat and seniority until an operator
  acts - the availability cost the timer exists to avoid.
- **Cost to adopt:** remove the timer path (small; it shipped).
- **Cost to leave:** none.
- **Evidence:** the shipped timer.

## Implications by horizon

### Short term (this release / 0-3 months)

- **If A:** the docs state that eviction reorders leadership - the point
  of eviction.

### Medium term (3-12 months)

- **If A:** a dead member that must not reorder leadership is handled by
  not evicting it (the default) - the operator's choice is explicit.

## Recommendation

**Recommended option:** A - seniority resets only on `leave`; eviction is
the leader writing that `leave`, so it reorders leadership, and the docs
say so explicitly. Default remains 0 = never evicts.

**Confidence:** 8/10

**Why this confidence.** A is the shipped, chain-fact-clean rule; B
contradicts RFC 0002's definition of seniority; C removes the only
automatic recovery for a dead member. What would move it: a consumer
showing that automatic eviction surprises operators more than it helps.

**Rationale.** Seniority is a slot position; the only chain facts are
`join` and `leave`. Eviction-as-leave is the honest expression of "this
member is gone"; hiding that it reorders leadership would be the trap
OQ 4 exists to name.

**Reversibility.** A to C is removing the timer; A to B would need a new
chain concept - effectively irreversible without a format change.

## Open questions

- None beyond the documentation wording.

## Next steps / action items

- [ ] State in PRD 0003 that eviction reorders leadership.
- [ ] Write the ADR once decided; update OQ 4's status.

## References

- [OQ 4](../open-questions.md) - the register entry this RFC addresses.
- [RFC 0002](../rfcs/0002-how-join-order-is-made-unspoofable.md) / ADR 0005 -
  seniority as slot position.
- [PRD 0003](../prds/0003-membership-and-leadership.md) - the leave and
  eviction rules.
