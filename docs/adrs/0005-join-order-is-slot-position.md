# ADR 0005 - Join order is slot position; seniority is unforgeable by the chain

## Status

Accepted

## Context

The brief (2026-08-21) makes "whoever joined earliest leads" a first-class
election mode - `seniority` - precisely because it works at n = 1 and n = 2
where quorum does not, and requires that a member cannot falsify its join
date. Leadership is the most valuable thing a member can gain by lying, so
the mechanism that orders joins is the security core of the mode.

The
candidates are argued in [RFC 0002](../rfcs/0002-how-join-order-is-made-unspoofable.md):
a chain entry (A), leader-issued certificates with timestamps (B), timestamp
gossip with agreement (C), an external authority list (D), self-reported
join time (E), and a verifiable delay function (F). Every alternative except
A depends on a clock - which a liar controls - or on an authority, which
`configured` mode already is. At n = 2, witness medians (C) and certificates
(B) are incomparable by construction, so a partition merge has no
deterministic rule under them.

## Decision

A member's `join` is a control entry in the same hash chain as data, written
by an existing member (the admitter) after admission, and seniority is the
slot position `(epoch, seq)` of that entry; the founder's is the `genesis`
slot. Time plays no part: no join timestamp is recorded, reported or
trusted.

A member cannot write its own `join` (no member holds its key until
the `join` is slotted), cannot move the `join` earlier (that needs a chain
prefix every other member's `prev_slot_hash` contradicts), and a minority
cannot help it (their copies are contradicted by the majority's). The rule
is validated by every member's fold, so a forged join is refused, not
noticed after the fact. RFC 0002 is decided; PRD 0003 phases 1–3 implement
this.

## Consequences

- Seniority costs nothing beyond the journal that already exists: election
  is one fold lookup, and join validation is one control-entry rule.
- The admitter decides *when* to write a `join`, so it can order concurrent
  joins (never ahead of an already-slotted member). That discretion is
  [OQ 58](../open-questions.md), open with the drafted default (receipt
  order); removing it is one fold rule.
- A member admitted on the losing side of a partition ends up junior to
  everyone admitted on the winning side during it: the merge re-slots the
  losing branch's joins after the survivor's. Deterministic, documented in
  PRD 0003, and the accepted cost of having no clocks.
- After 1.0, seniority semantics are a compatibility promise; reversing this
  decision later means changing what a `join` slot means, which the format
  freeze must carry.
