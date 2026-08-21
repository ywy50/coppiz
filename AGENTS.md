# spine — project conventions

spine is a replicated, append-only ledger in **Zig 0.16.0**, standard
library only ([ADR 0001](docs/adrs/0001-zig-0-16-standard-library-only-for-the-core.md)).
It is in the design phase: read [docs/README.md](docs/README.md) before
touching anything, and [docs/open-questions.md](docs/open-questions.md)
before deciding anything.

## Build & test

- `zig build` builds the `spine` node; `zig build run` runs it; `zig build
  test` runs unit tests. Read Zig's exit code directly, never through a pipe.
- Zig 0.16 runs `test` blocks only from a test module's root file: every new
  `src/` module must be referenced from the `comptime` block in
  `src/root.zig` (or from `src/main.zig` for CLI-only code) or its tests
  silently never run.
- Write the failing test first, beside the shipped function, and confirm it
  fails for the intended reason. Pure logic (codecs, fold, election, merge,
  expiry) stays I/O-free so it can be unit-tested and later driven by a
  deterministic simulator (OQ 27). Untrusted-input decoders get a fuzz test.
- New code is `zig fmt` clean.

## Records

The docs taxonomy is clanker's, on purpose; [docs/README.md](docs/README.md)
is its source. A PRD is what a feature is meant to be; an RFC is a decision
still open (≥ 2 candidates, the status quo, one out-of-the-box option, a
recommendation with confidence 0–10); an ADR is a decision made (title is the
choice, never edited to reverse — supersede and link forward); research is
evidence with read dates. Neither RFC nor research requires the other.

- Every unknown goes in [docs/open-questions.md](docs/open-questions.md) with
  a stable number; PRDs and RFCs cite `OQ n`. Resolving one adds a
  **Resolved** line; it is never deleted.
- Every term is defined once in [docs/glossary.md](docs/glossary.md); a new
  term lands there in the same commit that introduces it.
- Inventories (`docs/*/README.md`) are hand-maintained until tooling exists
  (OQ 41): creating a record means adding its row.
- **Write only what you checked.** A record is read as fact by someone who
  cannot tell verified from inferred. Give the mechanism and the command;
  mark unverified as unverified, or omit it. Claims carried from clanker's
  research keep clanker's read date and say they were not reopened here.

## Finishing a change

- `CHANGELOG.md` under `## [Unreleased]` for every consumer-visible change.
- `build.zig.zon` is the single source of truth for the version
  ([RELEASES.md](RELEASES.md)).
- When a turn surfaces a build gotcha, a design caveat, or a failure mode
  worth remembering, fold the smallest true addition into this file or the
  record it belongs to before the turn ends; tighten a stale sentence rather
  than stacking a new one beside it.
