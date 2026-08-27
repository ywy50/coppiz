# ADR 0006 — The library is Apache-2.0 licensed

## Status

Accepted

## Context

[Open question 18](../open-questions.md) — no licence chosen — blocks the
first public exposure of the repository. clanker's research tracked the
licences of every surveyed store (BUSL, CSL, Apache, MIT) as a selection
criterion, and the brief's comparison set (SQLite, dqlite, rqlite) are
libraries meant to be embedded and "just used". Three families were
considered:

- **Copyleft** (GPL, AGPL, LGPL): GPL/AGPL force a host that links the
  library to license its entire program under the same terms — fatal for
  the "embed it in your product" pitch. LGPL allows proprietary hosts but
  only for *dynamic* linking; Zig hosts link statically, which triggers
  LGPL's relinkable-object-file obligation on every adopter.
- **Source-available** (BUSL, CSL): designed for open-core business models;
  nothing in the brief or the PRDs suggests one, and a non-OSI-approved
  licence contradicts "unambiguous from the first public commit".
- **Permissive** (MIT, Apache-2.0): both let anyone use, modify, sell and
  embed the code, with attribution and no warranty.

## Decision

The library is licensed **Apache-2.0**, shipped as the `LICENSE` file and
the `license` field in `build.zig.zon` (which also carries `LICENSE` in its
`.paths`, so a host that fetches coppiz as a dependency receives the
licence). Apache-2.0 is permissive like MIT, and adds three written-down
clauses MIT leaves implicit: an explicit patent grant (storage and
replication are patent-dense; the grant is defensive — it terminates for a
licensee that sues over patents), an inbound = outbound contribution term
(the first external contribution, [OQ 45](../open-questions.md), is
licensed without a CLA), and trademark protection for the coppiz name and
mark. TigerBeetle, the replicated Zig store whose simulator discipline this
project copies, made the same choice.

## Consequences

- Any host may embed coppiz in a proprietary product and redistribute it
  under any terms, retaining the notice. This is the property the brief
  asked for ("just use it like SQLite").
- External contributors need no CLA: a submitted contribution is licensed
  under Apache-2.0 by [Section 5](https://www.apache.org/licenses/LICENSE-2.0.txt).
- The licence's conventions apply: modified files carry prominent change
  notices, a `NOTICE` file (currently none) is retained if ever added, and
  the coppiz name/logo may not be used to imply endorsement.
- MIT would have been simpler (~170 words instead of ~11 KB) but left
  patents, contributions and trademarks implicit; the difference matters
  for an embeddable storage library. Reversing this decision later is
  possible only with the consent of every contributor (Section 5 makes
  inbound licensing non-exclusive), so it is effectively permanent — which
  is the point of choosing before the first public commit.
