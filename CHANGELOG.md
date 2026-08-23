# Changelog

This file records consumer-visible changes. It follows Keep a Changelog; version
numbers follow the policy in [RELEASES.md](RELEASES.md).

## [Unreleased]

### Fixed

- The test-registration lint gate now matches real `@import` calls on each
  root's token stream instead of text after comment-stripping. The textual
  matcher admitted one false-pass direction beyond the multiline-string one
  fixed earlier: the literal characters `@import("sub/x.zig")` inside an
  ordinary string literal counted as registration while importing nothing,
  leaving that module's tests silently never run behind a green build. And
  stripping cut at the first `//` anywhere in a line, so an import sharing
  a line with an earlier `//` inside a string literal failed loudly though
  it was real. The tokenizer decides both directions: comments and every
  kind of string literal register nothing, a real import counts whatever
  shares its line, and a different builtin taking the same path
  (`@embedFile`) is not registration.

### Changed

- Spec-currency pass: ADR 0002's claim that a setting gates each mutation
  cause is reconciled with PRD 0002's actual schema, which turns the `stale`
  cause off nowhere (`stale.cleanup` governs only removal) — registered as
  OQ 57 and cross-cited from the ADR instead of silently contradicting an
  accepted record; RFC 0002's admitter-discretion open question is
  registered as OQ 58 and cited from the RFC; OQ 46–47 move to the
  register's Embedding section, where its own placement rule puts them; the
  ADR inventory row for 0003 matches that ADR's title exactly.

- Documentation audit: PRD 0002's `ttl.max_ms` prose no longer calls the cap
  advisory under `per_entry` (its own table clamps there too) and states
  header retention as 164 bytes per removed entry, the exact sum of PRD
  0001's draft header layout; PRD 0006 no longer cites acceptance criterion
  G6 for the dead-owner blast radius and no longer lists resolved OQ 49
  among its undecided dependencies; the ADR inventory row for 0002 matches
  that ADR's title.

- PRD 0001 pins byte order once for every fixed layout: "all integers
  little-endian" lived only in the entry-header parenthetical, leaving the
  slot table and the segment record prefix, header and index silent — a codec
  written from those sections alone had nothing ruling out the writing host's
  native order. A Byte order note now covers entry, slot and segment layouts.
- The lint gates no longer depend on the working directory `zig build` was
  invoked from: they read files and ran `zig fmt` relative to the process
  cwd, while the build runner walks up from a subdirectory to find
  `build.zig` without changing directory — so `zig build test` run anywhere
  under the project failed all three gates with FileNotFound. Every gate is
  now anchored to the build root (`fmt --check` via the run step's cwd, the
  other two via the build root's directory handle).
- The test-registration lint gate now matches its own test-root list
  regardless of platform: `src/root.zig` and `src/main.zig` were compared
  byte-for-byte against paths joined with the platform separator, so on
  Windows (`src\root.zig`) neither root was recognized — both were checked
  as ordinary modules nothing imports, and every module would have failed
  the gate. The walked path's separators are normalized before the
  comparison; unit-tested via the host-target module compiled from
  `build.zig`.
- The test-registration lint gate now matches import paths in `/` form
  regardless of platform: it compared filesystem paths from
  `std.fs.path.join` (backslash-separated on Windows) against
  `@import("sub/x.zig")` strings, which are always slash-separated, so on
  Windows every module would have failed the gate once the first submodule
  existed. Separators are translated before matching; unit-tested via the
  host-target module compiled from `build.zig`.
- Two cross-reference repairs in the design records: PRD 0002's
  per-entry-expiry-action non-goal cited OQ 6, which is the question of who
  may mark stale beyond the author — no registered question covers per-entry
  overrides, so the false citation is dropped; PRD 0003's epoch paragraph
  called epoch numbers unique per leader change in the sentence explaining
  how two branches end up with the same number, and now says each branch
  advances its own counter.
- The two file-covering lint gates (`zig fmt --check --ast-check` and the
  100-column cap) now derive their checked-path set from one shared list in
  `build.zig`, where each previously wrote its own: adding a source file or
  directory meant editing both lists, and missing one left the new file
  outside a gate silently. Coverage over the current tree is unchanged.
- The library's version test now pins `spine.version` to the exact version
  declared in `build.zig.zon` — passed through to the module as a
  `version_text` build option alongside the parsed value — where it only
  checked that the major number was 0, so a build that stopped sourcing the
  version from the zon file (its single source of truth, per RELEASES.md)
  would have gone unnoticed.
- Test-registration lint gate no longer counts `@import("...")` mentions
  inside comments: roots are matched with line comments stripped, so a
  commented-out reference cannot mask a module whose tests never run. The
  stripping only removes text, so the failure mode stays loud (a real
  import sharing a line after a `//` fails the gate until it gets its own
  line). The gate's matching logic now carries unit tests of its own, run
  by `zig build test` via a host-target test module compiled from
  `build.zig`.
- The same gate also drops multiline-string lines before matching:
  `@import("...")` written as text inside a `\`-string literal counted as
  registration while importing nothing — the false-pass direction, unlike
  every other stripping artifact. Unit-tested with the gate's own tests.

### Added

- Spec-consistency fourth pass: PRD 0001's duplicate acceptance-criterion id
  (two criteria labelled G3) is renumbered — the forgery negative test is now
  G7, and the roadmap's single-member gate cites G3–G7; PRD 0001's
  "No multi-cluster federation" non-goal is scoped to v1 with a cross-reference
  to PRD 0006, whose federation overlay it previously contradicted outright;
  OQ 3's layer note now records accurately where `write.ack` is called a
  setting (PRDs 0001 and 0006) versus assumed (PRD 0003) or passed per call
  (PRD 0005).
- Spec-consistency pass over the design records: PRD 0002's effective-TTL
  table and state diagram now match their own prose (`ttl.max_ms` clamps
  under `per_entry` too; author-staled entries remove only under
  `stale.cleanup = delete`); PRD 0004's empty-`authorities[]` validation rule
  carves out PRD 0003's one-member case; and PRD 0001 G6's unnamed bounds get
  keys (`cluster.max_ledgers`, `sync.unslotted_max_bytes`) with values parked
  as OQ 55. A follow-up pass repaired research 0001's broken admission row
  (unescaped pipes split the Markdown table) and aligned ADR 0003's
  growth-path consequence with PRD 0006 and the roadmap (groups past 32,
  topology inside large groups; quorum stays a later mode option). A second
  pass corrected PRD 0001's `storage.fsync` classification (local config per
  PRD 0004's layer rule, not a chain setting) and the test-registration
  guidance in `src/root.zig`/`build.zig` (either test root counts), and made
  the PRD inventory row for 0003 match its title exactly.
- Spec-consistency follow-up: the `sync.*` knobs named across PRDs 0001–0003
  (`sync.page_bytes`, `sync.lag_slots`, `sync.gap_timeout_ms`) are now cited
  to a registered unknown (OQ 56) instead of silently lacking a layer and a
  default; PRD 0005's CLI list gains `settings` and `migrate` (named by PRD
  0004 and PRD 0005's own failure modes); RFC 0002 no longer claims PRD 0003
  documents the admitter-ordering caveat (that is the RFC's own open
  question); docs/README's planned source layout lists `src/config/`,
  `src/cli/` and `src/api/`.
- Spec-consistency third pass: ADR 0002's Decision names the `expired`
  transition (`live → expired → removed` under `ttl.action = delete`) that
  PRD 0002's diagram and the glossary already define; the `write.ack` layer
  (setting in PRDs 0001/0003/0006, per-call argument in PRD 0005's sketch)
  is registered in OQ 3 instead of silently ambiguous; and the glossary
  defines `cursor`, `follow`, `snapshot` and `control ledger`, which PRDs
  0001/0004/0005/0006 used undefined.
- Lint gates wired into `zig build test` (and a standalone `zig build lint`
  step): canonical formatting via `zig fmt --check --ast-check`, run with the
  toolchain executing the build, a hard 100-column cap over `src/`,
  `build.zig` and `build.zig.zon`, and a test-registration check that fails
  when a `src/` module is not imported from a test root (its tests would
  otherwise silently never run). What CI gates once it exists stays open as
  OQ 45; until then the tests are the blocking entry point.
- Repository founded: Zig 0.16 skeleton (`spine` library module and node
  binary, both placeholders), clanker's documentation taxonomy under `docs/`,
  draft PRDs 0001–0005, RFCs 0001–0002, ADRs 0001–0002, research note 0001,
  the open-questions register and the glossary.
- OQ 49 resolved: groups use the same leadership modes and concurrency
  model as members; no uneven group count is required. PRD 0006 gains the
  two federation rules that follow (representative validated against the
  group's own chain; federation suspect timeout exceeds group election time).
- PRD 0006 (scaling 1 → n → groups: recursive groups, ownership and
  sharding, parity) with the list of what the core must get right now;
  scale tiers in the roadmap; OQ 48–54; federation settings scope reserved
  in PRD 0004; chain-per-ledger and self-describing sealed segments in PRD
  0001.
- ADR 0003 (batteries included, no external infrastructure at any size),
  after the brief was clarified to be general-purpose; PRD 0005 reframed
  with clanker as a worked example host rather than the target; OQ 46–47.
- `.gitattributes` declaring LF for all text files, working trees included:
  `zig fmt --check` inside `zig build test` compares bytes and fails a
  CRLF checkout or commit, so the policy the build enforces is now pinned
  where checkouts and commits are made.
