# Research - how reliable is a report's `Status` line?

## Status

Resolved - measured 2026-08-31 by auditing all 29 reports that
[`8893ae1`](https://github.com/ywy50/coppiz/pull/116) marked resolved.

Research is evidence, not a decision: it records what exists, how good it is,
and how confident the finding is. The decision that follows belongs in an
[RFC](../rfcs/) - here [RFC 0040](../rfcs/0040-gating-record-accuracy-and-flaky-tests.md) -
and, once made, an [ADR](../adrs/).

## Question

For a report in `docs/reports/bugs/`, how much does its `Status` line predict
whether the defect is actually absent from the tree? And is the
"TL;DR still says *Still open* while Status says *Resolved*" contradiction a
usable signal for finding the ones that lie?

Both are answerable by reading 29 records against the code they name.

## TL;DR

- **A `Resolved.` status is wrong about 31% of the time - in both
  directions.** Of the 29 records `8893ae1` flipped, **9 were stale** (the
  defect was still live) and **20 were genuinely fixed**. `high` confidence -
  every one checked by reading the named symbol and `git log --all -S`.
- **The self-contradiction tell has no specificity and must not be used.**
  All 29 records carry a TL;DR reading "Still open" and/or References reading
  `Fix: none`, including all 20 that were correctly resolved. Selecting on it
  yields a 69% false-positive rate. `high` confidence.
- **The cause is squashed commits, not carelessness about the code.**
  [`773af4d`](https://github.com/ywy50/coppiz/pull/90) carries **twelve**
  fixes behind a subject naming only the last one, and `2761a64` carries
  another behind a subject naming a different fix. `git log -S<symbol>` finds
  the fix while the commit message denies it. `8893ae1` followed those real
  fixes by about ten minutes and updated only the `Status` line. `high`
  confidence.
- **Four credited fixes name a symbol that has never existed** in any commit:
  `pre_failover`, `storeThenFold`, `advanceHead`, `firstLive`. `high`
  confidence - `git log --all -S` returns nothing for each.
- **One credited fix would have been actively harmful if implemented as
  written.** `sweep3-pre-failover-settings-replay` credited comparing
  `sl.leader`; a data slot's leader is only checked to be *a* member, so that
  would let any member self-sign a slot and author journal settings. `high`
  confidence - stated and rejected in that report's Correction.
- **Records drift in the other direction too.** `live-create-journal-bypass`
  claimed `onForward` excepted joins, which was false until
  [#237](https://github.com/ywy50/coppiz/pull/237) the same day;
  `sweep3-test-waits-cross-thread-race` had its root-cause mechanism wrong
  (`getEnum` returns a comptime schema string, not an interior slice). `high`
  confidence.

## Scope and method

- **Searched:** the local tree only. For each of the 29 records: read the
  `## Resolution`, extracted the symbol/helper/guard it credits, then
  `grep -rn '<symbol>' src/`, then `git log --all -S'<symbol>' -- <path>`, then
  `git show <sha> -- <path>` on any candidate commit to confirm it touches the
  named code rather than trusting its subject line.
- **Not searched:** anything external. This question is entirely internal.
- **Split:** three independent auditors took disjoint slices by the file a fix
  would land in (12 `src/cluster/`, 6 `src/journal/`, 6
  `src/config`+`src/settings`+`src/net`+`src/main.zig`), plus 5 checked earlier
  in the day. They did not compare notes, which is why the per-slice rates
  below are worth reading separately.

### Per-slice result

| Slice | Stale | Fix present |
|---|---|---|
| Checked first, ad hoc | 5 | 0 |
| `src/cluster/` | 3 | 9 |
| `src/journal/` | 1 | 5 |
| `src/config`/`settings`/`net`/CLI | 0 | 6 |
| **Total** | **9** | **20** |

The first five were all stale, which produced a 5/5 reading that did not
survive contact with the other 24. **An early base rate from a
non-randomly-chosen sample was the single most misleading number in this
audit**, and it was used to brief the later auditors - they were told the rate
and told explicitly not to assume it, which is the only reason it did not
propagate into their verdicts.

## Findings

### The nine that were stale

Fixed for real in
[#218](https://github.com/ywy50/coppiz/pull/218),
[#224](https://github.com/ywy50/coppiz/pull/224),
[#225](https://github.com/ywy50/coppiz/pull/225),
[#227](https://github.com/ywy50/coppiz/pull/227),
[#232](https://github.com/ywy50/coppiz/pull/232),
[#234](https://github.com/ywy50/coppiz/pull/234),
[#237](https://github.com/ywy50/coppiz/pull/237),
[#238](https://github.com/ywy50/coppiz/pull/238),
and one reopened without a patch in
[#241](https://github.com/ywy50/coppiz/pull/241) because the fix needs an
undecided policy question answered first.

Two of the nine were worse than "not fixed":

- `sweep3-follower-admitter-join-fails` - the tree had gained the **opposite**
  change after the record was flipped (`onForward` closing the connection for
  any non-`.data` kind), so the claimed behaviour was further away than when
  the report was written.
- `wire-read-drops-compacted-slots` - the fix is *present but unreachable*.
  `readWhere` drops slot-only records before any callback fires, so the arms
  that were supposed to render them are dead code. A grep for the symbol
  would have found it and concluded "fixed"; only reading the call path shows
  otherwise.

### What a correct check costs

Reading the symbol is not sufficient (the dead-code case above) and neither is
reading the commit subject (the squashed-commit case). The check that held up
was: symbol exists, a commit demonstrably touches it (`git show <sha> -- <path>`),
**and** the behaviour is reachable from a caller. That is a code review per
record, which is why 29 records took three agents.

## Evidence log

| Claim | Source | Read on | Confidence |
|---|---|---|---|
| `8893ae1` changed 29 report files and 0 source files | `git show --stat 8893ae1` | 2026-08-31 | high |
| 9 of 29 stale, 20 fixed | the 29 records vs `src/`, three disjoint audits | 2026-08-31 | high |
| All 29 carry the "Still open" / `Fix: none` contradiction | `grep` over the 29 files | 2026-08-31 | high |
| `773af4d` carries 12 fixes behind a one-fix subject | `git show --stat 773af4d`, `git log -1 773af4d` | 2026-08-31 | high |
| `pre_failover`, `storeThenFold`, `advanceHead`, `firstLive` never existed | `git log --all -S<symbol>` per symbol | 2026-08-31 | high |
| The `sl.leader` credited fix would let a member self-sign a slot | `docs/reports/bugs/2026-08-28-sweep3-pre-failover-settings-replay.md` Correction | 2026-08-31 | high |
| `wire-read-drops-compacted-slots`' fix is unreachable | `readWhere` call path, `src/cluster/node.zig` | 2026-08-31 | high |

## Open questions

- **Does this generalise past `8893ae1`?** Every record audited here was
  flipped by that one commit. Records resolved individually, in the same commit
  as their fix, were not sampled and may be far more reliable. Unmeasured.
- **Is the 31% rate stable?** It is one census of one batch, not a sample from
  a process. It should not be quoted as a general error rate for the store.

All 29 records now carry a `Verified in the tree 2026-08-31` note naming the
symbol read ([#235](https://github.com/ywy50/coppiz/pull/235),
[#236](https://github.com/ywy50/coppiz/pull/236),
[#239](https://github.com/ywy50/coppiz/pull/239)), so this audit should not
need repeating for them.

## References

- [RFC 0040](../rfcs/0040-gating-record-accuracy-and-flaky-tests.md) - what, if
  anything, the gate should do about this
- [RFC 0035](../rfcs/0035-record-store-tooling.md) - the record store has no
  tool maintaining it, which is the standing cause
- [reports inventory](../reports/README.md)
