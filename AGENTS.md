# spine — project conventions

spine is a replicated, append-only ledger in **Zig 0.16.0**, standard
library only ([ADR 0001](docs/adrs/0001-zig-0-16-standard-library-only-for-the-core.md)).
It is in the design phase: read [docs/README.md](docs/README.md) before
touching anything, and [docs/open-questions.md](docs/open-questions.md)
before deciding anything.

spine is general-purpose. clanker is the first host and the origin, and its
constraints (static musl binary, sandboxed guests, no second daemon) are kept
in view because they are the strictest known — but nothing under `src/` may
know about clanker or any other host, and no API shape may exist only to suit
one ([PRD 0005](docs/prds/0005-embedding-the-library-as-the-product.md),
[ADR 0003](docs/adrs/0003-batteries-included-no-external-infrastructure-at-any-size.md)).

## Build & test

- `zig build` builds the `spine` node; `zig build run` runs it; `zig build
  test` runs unit tests plus the lint gates (`zig build lint` runs them
  alone). Read Zig's exit code directly, never through a pipe.
- Zig checks `build.zig.zon`'s `minimum_zig_version` only when spine is
  fetched as a dependency, never for a tree built directly; the build script
  enforces the floor itself, so the gates always run under declared
  toolchain semantics.
- Zig 0.16 collects `test` blocks from every module a test root
  (`src/root.zig`, `src/main.zig`, `build.zig` — each compiles as its own
  test binary) reaches through *analyzed* imports —
  transitively, so a helper imported only by another module has its tests
  run; but an unreferenced module's tests silently never run, and neither do
  those of a module imported only by a never-analyzed declaration (an unused
  container-level `const`). Register each new module from the `comptime`
  block in `src/root.zig` (or from `src/main.zig` for CLI-only code); the
  lint gate fails when no chain of real `@import`s reaches it. A `.zig`
  file outside `src/` (gate coverage forces any such file into
  `checked_paths`) can never be registered that way — Zig refuses an
  `@import` out of a module's root — so it needs its own test root in
  build.zig plus a `test_roots` entry; until then the registration gate
  names it on every run. Zig also
  analyzes a declaration only once something references it, so each
  registered module gets a line in the root's "all public declarations
  analyze" test — an unreferenced `pub` declaration is otherwise compiled
  into nothing and checked by nothing. The lint gate enforces that pairing
  too: a test-root import no `refAllDecls` call wraps fails the build, so
  registration without declaration analysis can no longer hide behind a
  green run.
- The gates cover exactly the paths in `checked_paths` (build.zig); a
  coverage-completeness gate fails any other `.zig` file — or near-miss
  spelling of one (`Legacy.ZIG`, `root.zig~`; `.zon` manifests exempt) — in
  the tree (leading-dot tooling entries and `zig-out/` excepted), so a new
  source location joins `checked_paths` instead of going silently
  unformatted, uncapped and untested.
- Write the failing test first, beside the shipped function, and confirm it
  fails for the intended reason. Pure logic (codecs, fold, election, merge,
  expiry) stays I/O-free so it can be unit-tested and later driven by a
  deterministic simulator (OQ 27). Untrusted-input decoders get a fuzz test.
- New code is `zig fmt` clean, and every line in `src/`, `build.zig` and
  `build.zig.zon` fits in 100 columns; `zig build test` enforces both.

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
