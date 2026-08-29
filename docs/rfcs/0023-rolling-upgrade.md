# RFC 0023 - format versioning and rolling upgrade

## Status

Discussion - opened 2026-08-29. Addresses OQ 26 (the
register keeps the stable pointer).

An RFC is a *request for comment*: it presents the options and a recommendation
so a decision can be made, and it is not itself the decision record. When it is
decided, set the status, then write the [ADR](../adrs/) that records the choice
and link it from References.

## Overview

Entry, slot, segment, snapshot and wire each carry a version; a reader
refuses a newer version. The question is whether a cluster can run two
binary versions during an upgrade - and if so, the exact procedure.

**Decision to make.** Is rolling upgrade (two versions in one cluster)
supported, with the leader upgraded last, and what is the written,
tested procedure?

**Why now.** The answer is a first-release requirement: no published
release can ship without knowing how the next one lands.

**Drivers.** Any acceptable option must:

- keep the "reader refuses a newer version" rule (PRD 0001's goal 5) -
  misreading is never allowed;
- keep the leader's writes the last thing to change: the leader writes
  slots, so an old leader writing a new format would be refused by
  everyone (and a new leader writing an old format is the actual
  upgrade shape);
- be testable: the procedure must have a test, not just prose.

**Out of scope.** The snapshot format itself (RFC 0022). Downgrades (a
newer cluster reading an older node is not a supported shape; the
procedure is upgrade-only).

## Current state

Every format carries a version and readers refuse unknown versions (PRD
0001). There is no written procedure, no test, and no release yet.

## Options considered

### Option A - rolling upgrade: readers first, leader last (out-of-the-box)

- **What it is:** upgrade the followers to the new binary first (they
  read the old leader's format and write nothing of consequence), then
  upgrade the leader last (its writes are then the new format, which the
  upgraded followers read). The window where two versions coexist is
  bounded by the followers' upgrade, and the only mixed read is "new
  follower reads old leader" - which the reader-refuses-newer rule
  permits in this direction (the old leader's format is *older* than the
  new follower's reader).
- **Pros:** no downtime; the version rule needs no change; the procedure
  is simple enough to test.
- **Cons:** the mixed window is real: a new follower must tolerate the
  old leader's format for the window (it does - it reads older
  versions), and the failure detector must not see the upgrades as
  churn.
- **Cost to adopt:** the written procedure and the test (upgrade
  followers, upgrade leader, assert the chain stays valid through the
  window).
- **Cost to leave:** first release without a procedure.
- **Evidence:** the shipped version rule; the release policy (RELEASES.md
  already names this procedure as a pre-release runbook).

### Option B - no rolling upgrade; stop-the-cluster upgrades

- **What it is:** every upgrade stops the cluster, upgrades all members,
  restarts.
- **Pros:** no mixed-version window at all.
- **Cons:** downtime on every upgrade - the opposite of the
  availability the design promises.
- **Cost to adopt:** none.
- **Cost to leave:** the availability cost.
- **Evidence:** the design's availability claims.

### Option C - compatibility promises per minor

- **What it is:** declare that a minor release reads all previous minors'
  formats, so the rolling window is "any two adjacent minors".
- **Pros:** the broadest mixed window.
- **Cons:** a compatibility promise is a test burden (every format
  change must keep reading every prior minor); premature before the
  format is exercised.
- **Cost to adopt:** the compatibility test matrix.
- **Cost to leave:** none.
- **Evidence:** RELEASES.md's pre-1.0 policy (0.MINOR may break).

## Implications by horizon

### Short term (first release)

- **If A:** the procedure and its test ship with the first release.

### Medium term

- **If A then C:** the adjacent-minor promise is added when the format
  stabilizes.

## Recommendation

**Recommended option:** A - rolling upgrade with the leader last, written
and tested. B is rejected (downtime on every upgrade); C is deferred
until the format stabilizes (its test matrix is premature pre-1.0).

**Confidence:** 7/10

**Why this confidence.** A uses the version rule as-is and is simple
enough to pin with a test. What would move it: the first real format
change exercising the procedure. What would sink it: a format change
that breaks the "new follower reads old leader" direction - which would
force B for that release.

**Rationale.** The reader-refuses-newer rule makes the mixed window
one-directional by construction; A rides that property. C's promise is
the right long-term shape but its cost is only justified once the format
has proven stable.

**Reversibility.** A to B is a procedure change; the version rule is
untouched.

## Open questions

- Does the failure detector need a grace for the upgrade window (upgraded
  followers restarting look like churn)? (implementation; the suspect
  window is likely enough, but the test decides)

## Next steps / action items

- [ ] Write the rolling-upgrade runbook (RELEASES.md's pre-release item).
- [ ] Add the upgrade test to the suite.
- [ ] Write the ADR once decided; update OQ 26's status.

## References

- OQ 26 (historical) - the question this RFC addresses.
- [PRD 0001](../prds/0001-journal-core.md) - the version rule.
- [RELEASES.md](../../RELEASES.md) - the release policy that names this
  procedure.
