# spine

A replicated, append-only ledger you can embed like SQLite and grow from one
process to a fleet without a quorum, a redeploy, or an odd member count.
Written in Zig 0.16 with the standard library only.

**Status: design phase.** Nothing stores anything yet. The repository holds a
building skeleton and the design records; `spine` is a working codename
([OQ 16](docs/open-questions.md)).

## Quick start

Build and run the tests:

```bash
zig build test
```

Run the placeholder binary:

```bash
zig build run
```

Read the design, in order:

```bash
cat docs/README.md
```

Everything below is detail.

## What it is meant to be

- **Append-only entries**, author-signed and hash-chained, replicated in full
  to every member. No update, no delete; the only mutations are TTL expiry
  and an author marking *its own* entries stale, both opt-in per ledger
  ([ADR 0002](docs/adrs/0002-entries-are-immutable-ttl-and-author-staleness-are-the-only-mutations.md)).
- **TTL with policy**: enforcement off, per entry, or for every entry in the
  ledger; expiry marks stale or deletes; deletion is deterministic across
  members because it is itself a ledger event
  ([PRD 0002](docs/prds/0002-ttl-and-staleness.md)).
- **Leadership without quorum**: by seniority (earliest join, unspoofable
  because join order *is* chain position), by an operator's authority list
  (name one of two members, or an odd subset of six), or both combined —
  well-defined at 1, 2, and any even number of members; switchable at
  runtime when the cluster allows it
  ([PRD 0003](docs/prds/0003-membership-and-leadership.md),
  [RFC 0002](docs/rfcs/0002-how-join-order-is-made-unspoofable.md)).
- **Settings live in the ledger**, not in per-member config files, so two
  members cannot run different rules on one ledger
  ([PRD 0004](docs/prds/0004-settings.md)).
- **Embeddable first**: a Zig library a host links, with the standalone
  `spine` node built from the same tree; clanker is the first host
  ([PRD 0005](docs/prds/0005-embedding-and-clanker-plugin.md),
  [RFC 0001](docs/rfcs/0001-library-first-or-service-first.md)).

## Where things are

| Path | What |
|---|---|
| [docs/README.md](docs/README.md) | architecture overview and the documentation taxonomy |
| [docs/prds/](docs/prds/) | what each part is meant to be |
| [docs/rfcs/](docs/rfcs/) | decisions still open, with recommendations |
| [docs/adrs/](docs/adrs/) | decisions made |
| [docs/research/](docs/research/) | evidence, with read dates |
| [docs/open-questions.md](docs/open-questions.md) | the numbered register of what is unsettled |
| [docs/glossary.md](docs/glossary.md) | every term, defined once |
| [docs/ROADMAP.md](docs/ROADMAP.md) | what ships in what order |
| [CHANGELOG.md](CHANGELOG.md), [RELEASES.md](RELEASES.md) | consumer-visible changes; version and release policy |
| `src/` | `root.zig` is the library, `main.zig` the node; placeholders today |

## Origin

spine was founded from clanker's
[RFC 0019](https://github.com/maci0/clanker/blob/main/docs/rfcs/0019-shared-state-store.md),
which surveyed seventeen stores, found no general-purpose Zig-native
replicated store, and recorded the decision to build one as a standalone
public project. What that survey established, and what spine inherits from
it, is in [research 0001](docs/research/0001-evidence-carried-from-clanker-rfc-0019.md).
