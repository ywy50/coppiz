# Changelog

This file records consumer-visible changes. It follows Keep a Changelog; version
numbers follow the policy in [RELEASES.md](RELEASES.md).

## [Unreleased]

### Added

- A fifth lint gate, coverage completeness: the analysis gates cover an
  explicit allowlist (`checked_paths` in build.zig) that fails loudly when a
  listed path stops existing but stayed silent about its complement — a
  stray or newly added `.zig` file outside those paths reached no formatter,
  no column cap and no test binary while `zig build test` stayed green. The
  new step walks the build root (skipping leading-dot tooling entries and
  the root-level `zig-out` install prefix; a linked directory is rejected
  like the covering gates' walks) and fails naming each uncovered file, so
  coverage can only change by editing `checked_paths`.
- Declaration-analysis enforcement in the test-registration lint gate: a
  `src/` module a test root imports but that root never wraps in a
  `std.testing.refAllDecls` (or `refAllDeclsRecursive`) call fails the build
  with the module and root named. Registration alone collects a module's
  tests; its unreferenced `pub` declarations are compiled into nothing and
  checked by nothing, so registering without the refAllDecls line hid a
  whole public surface from every semantic check behind a green `zig build
  test` (the gap the "all public declarations analyze" tests closed by hand,
  now gated). The gate constrains only the two test roots, where the
  documented convention puts both halves, and ignores imports resolving to
  no walked module (`std`, `build_options`, the `spine` package).
- Two boundary pins in the lint-gate tests: the column-cap test now feeds its
  second over-limit line as the file's last line with no trailing '\n' (a
  file not ending in a newline must still have that final line checked),
  and the toolchain-floor test pins the metadata mirror on the floor side —
  a plain toolchain satisfies a floor carrying build metadata.
- Two more lint-gate test repairs: the import-cycle classification test now
  also pins that modules reachable only through an unreachable importer are
  reported beside it (the walk seeds from test roots only), and
  importBetween's climb-out is checked two directories deep — one "../" per
  level left under the importing file's directory.
- Two coverage repairs in the lint-gate tests: the toolchain-floor test now
  pins the complementary prerelease boundary (a release toolchain satisfies
  a prerelease floor of the same release; build metadata orders equal), and
  the test-registration gate's decision core is exercised on an import
  cycle — two reachable modules importing each other are both classified as
  reached, the walk terminates, and the orphan outside the cycle is still
  the only module reported.

### Fixed

- The test-registration and declaration-analysis gates now match `@import`
  strings in their resolved form instead of byte-for-byte. Zig accepts
  spellings the exact comparison rejected or mismatched — a comptime
  `_ = @import("./sub/x.zig")` from a test root collected the target's
  tests (verified on 0.16.0 with a deliberately failing probe test) while
  the registration gate failed the tree as "not reachable from a test
  root"; a wrapper spelled `refAllDecls(@import(".//a.zig"))` did not
  silence a bare `@import("a.zig")` beside it; and interior `"name/.."`
  pairs matched nothing. Import strings are canonicalized where they enter
  the gates (`collectImports`' recorded paths, `importBetween`'s computed
  ones): empty components ("a//b"), "." components and resolvable "name/.."
  pairs collapse; leading ".." runs survive, there being no parent above
  them to pop into.

- Two accuracy repairs from this audit: docs/README no longer says every PRD
  cites the brief — PRD
  [0006](docs/prds/0006-scaling-to-groups-sharding-and-parity.md) postdates
  the clarification and does not quote it — and the `lint` step's changelog
  entry no longer pins its description at "four checks", a count the fifth
  gate's arrival had already made stale.
- The gate-coverage walk's failures now name the entry they stopped on
  (`cannot walk 'tools/vendor': LinkedDirectoryNotWalked`, not a bare
  `cannot walk the project tree: …`): a linked directory rejected by the
  walk or a symlink that no longer resolves failed the step with an error
  name alone, leaving the operator to find which of every walked entry was
  at fault — the same repair `checkedFiles` already made for its gate-path
  enumeration failures.
- Three accuracy repairs from a documentation audit: PRD 0001's control-entry
  table now names the `epoch` reason list PRD 0003 defines (`leader_lost`,
  `mode_change`, `merge`, `manual`) where it paraphrased three of the four
  values under different spellings, and its `checkpoint` row no longer
  describes removal as covering only TTL-expired payloads — author-staled
  entries join the same removal set when `stale.cleanup = delete`
  ([PRD 0002](docs/prds/0002-ttl-and-staleness.md), the glossary); and PRD
  0002's Status drops an ambiguous "host tested" qualifier from its
  `src/ledger/expiry.zig` source-of-truth line.
- Three accuracy repairs from a documentation audit: the README's
  append-only bullet now scopes full replication to a member's group (the
  same unscoped claim an earlier pass fixed in docs/README's architecture
  summary, and contradicted by
  [PRD 0006](docs/prds/0006-scaling-to-groups-sharding-and-parity.md)'s
  ownership-and-routing overlay); `src/main.zig`'s doc comment no longer
  calls the file a placeholder "until RFC 0001 is decided" — that decision
  only picks which surface leads
  ([PRD 0005](docs/prds/0005-embedding-the-library-as-the-product.md)), and
  the placeholder ends when the library API and node CLI land; and PRD
  0003's Status reads "the design the RFC recommends", restoring a dropped
  article.
- The `lint` step's description names its gates again instead of stopping at
  "test registration": the string behind `zig build --help` still read
  "test registration" as the last gate after declaration-analysis enforcement
  joined it (the coverage-completeness entry under Added extends the same
  string).
- Two accuracy repairs from a documentation audit: docs/README's
  architecture summary now scopes full replication to the group — the
  unscoped "every member holds every ledger in full" contradicted both
  [PRD 0001](docs/prds/0001-ledger-core.md)'s own constraint wording and
  the ownership-and-routing overlay of
  [PRD 0006](docs/prds/0006-scaling-to-groups-sharding-and-parity.md)
  described later in the same section; and the registration guidance in
  `src/root.zig` no longer says the lint gate fails *only* when no import
  chain reaches a module — it also fails a test-root import no refAllDecls
  call wraps, which that comment's next paragraph, `src/main.zig`'s, and
  build.zig already state.
- The 100-column cap's enumeration failure now names the checked path it
  stopped on (`cannot enumerate 'src': FileNotFound`, not a bare
  `FileNotFound`): `checkedFiles` can fail on any of its three entries, and
  every other file-access failure in the gates already reported which file
  it was reading.
- Symlink handling in the two file-covering lint gates: directory iteration
  reports a link as `.sym_link` — the walker never resolves it (verified on
  0.16.0: Linux's `getdents64` `d_type` reaches the filter untouched), so a
  symlinked `.zig` file under a checked path was silently outside both gates
  while they stayed green, and a symlinked directory's subtree went unwalked,
  against build.zig's own claim that "a linked-in source tree is analyzed
  like a real one". A walked entry that is a link is now resolved through
  `statFile`, which follows it (a linked `.zig` file is collected like a
  real one), and a linked directory fails both gates loudly instead of
  half-checking — following it would need cycle protection no current tree
  justifies.

- PRD 0003's `merge.settle_ms` default (30 s) is now registered as a
  placeholder with its bounds stated both ways (OQ 60) and cited from the
  settings table and PRD 0002's settle rule, matching every other timing
  default in the PRDs, each of which already named its open question.

- "All public declarations analyze" tests in both test roots
  (`src/root.zig`, `src/main.zig`): Zig's analyzer is lazy, so an
  unreferenced `pub` declaration was compiled into nothing and checked by
  nothing — a type error inside one reached a green build (demonstrated:
  an unreferenced function assigning a string to a `u32` passed
  `zig build test`). The tests reference every public declaration through
  `std.testing.refAllDecls`; each module registered for test collection now
  also gets a line there, so its declarations are semantically checked too.

- Toolchain-floor enforcement in the build: `zig build` now fails loudly when
  the running Zig is older than `minimum_zig_version` in build.zig.zon. Zig
  checks that field only for consumers fetching spine as a dependency, never
  for a tree built directly, so every analysis gate (`zig fmt --check`,
  the 100-column cap, test registration — the latter lexing with
  `std.zig.Tokenizer`) could otherwise run under undeclared toolchain
  semantics.
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

- PRD 0002's open-questions list now cites [OQ
  57](docs/open-questions.md), which concerns that PRD's own schema — whether
  the `stale` cause is switchable per ledger as ADR 0002 records — but was
  reachable only from the ADR and the register, not from the schema it is
  about.

- The test-registration lint gate now follows imports transitively. Zig
  0.16 collects a module's tests whenever a chain of analyzed imports
  reaches it from a test root, not only when a root imports it directly
  (verified on 0.16.0: with `src/root.zig` importing `a.zig` importing
  `b.zig`, `zig build test` runs b's tests), but the gate compared only
  direct root imports — a helper imported solely by another module failed
  the build as "no test root imports it" although its tests ran, and each
  such module had to be registered twice for no effect. The gate now walks
  real `@import` calls from the roots across every walked module, resolving
  import strings relative to the importing file's directory (`b.zig`
  beside the importer, `../other/x.zig` across branches); the report names
  the surviving failure precisely: "not reachable from a test root".

- Documentation-currency pass: PRD 0002's Design no longer opens with
  "three states" — its own diagram, the glossary and ADR 0002 all carry four
  (`live`, `stale`, `expired`, `removed`), so the prose now does too;
  seniority is no longer described as "position 0" for the founder —
  *position* is defined as `(epoch, seq)` and no slot has `seq = 0`, so both
  mentions say seniority rank 0; PRD 0001 counts clanker's survey as
  seventeen *candidates*, matching README and research 0001; ROADMAP's
  founding line lists five draft PRDs and two accepted ADRs (PRD 0006 and
  ADR 0003 landed after founding); the roadmap schedules the RFC 0001
  decision before PRD 0001 phase 4, the deadline RFC 0001's own comment
  period sets; OQ 29/30/38 cite the PRD 0005 phases that actually contain
  their work (3, 5 and 4, not 2, 4 and 3); PRD 0006's dependency list names
  OQ 48 alongside its siblings and its G1 cites OQ 54's measurement set
  instead of a roadmap section that does not exist; research 0001's status
  no longer promises an evidence-log row for every claim (the findings table
  traces to the Scope-and-method sources) and References names clanker ADR
  0033, which the findings table cites; the glossary defines *sharding* and
  *instance*, used across PRD 0006 and the roadmap without definition; RFC
  0002's driver 5 concedes merge's deterministic re-slotting, which its own
  option-A cons describe.

- Documentation audit: the codename is lowercase everywhere, sentence start
  included, as every other record writes it — four sentences in research 0001
  and OQ 41 capitalized it.
- PRD 0001's segment index is keyed by position `(epoch, seq)`, not bare
  `seq`: the slot layout makes `seq` dense within an epoch and restarting at
  1, so any segment spanning an `epoch` boundary holds two `seq = 1…k` runs
  and a `seq`-keyed index is ambiguous — against the glossary's own
  definition of *position*.
- Documentation-currency pass: PRD 0001 no longer says a `stale` mark names
  the `entry_hash` — [PRD 0002](docs/prds/0002-ttl-and-staleness.md) defines
  the payload as naming the target entry id `(author, author_seq)`, whose
  author field is what every member validates against; and its write-path
  step 4 clears the unslotted queue on receivers too, not only the author
  (the glossary defines the queue as holding received entries, and the
  optimistic-accept paragraph depends on that).
- Documentation-currency pass: PRD 0002's soft-expiry sentence no longer
  calls a TTL-reached entry "expired" under `mark_stale` — its own state
  diagram routes live → stale there, and *expired* is defined for
  `ttl.action = delete`; PRD 0003 cites OQ 43 where the brief's "definitely
  has the full state" is made a state; PRD 0004 gains criterion G6 for goal
  2's founder clause (`spine init` validates the initial settings),
  closing the goals↔criteria gap; the glossary defines `archived branch`,
  which PRD 0003 and RFC 0002 used without definition; research 0001 no
  longer claims every row carries its read date (the findings table does
  not; the evidence log does, and now says so); the README counts clanker's
  survey as seventeen *candidates*, matching research 0001, whose option
  list includes libraries that are not stores.
- Spec-currency pass: PRD 0003's `epoch` entry shape now says its
  `reason` list (`leader_lost | mode_change | merge | manual`) is tier-1's
  and that [PRD 0006](docs/prds/0006-scaling-to-groups-sharding-and-parity.md)
  extends it with `ownership_transfer`, which the PRD used without noting the
  extension; and the failure-detector defaults (`cluster.heartbeat_ms` 1 s,
  `cluster.suspect_after_ms` 5 s) now carry their inline citation to
  [OQ 37](docs/open-questions.md), where they are registered as placeholders —
  every other placeholder default in the PRDs already named its open question.
- Spec-currency pass: PRD 0004's acceptance criteria now cover the second
  half of its goal 4 — that a settings change takes effect at a defined slot
  (G4 also asserts effect from the slot after the `settings` entry, per its
  Design validation rule 4), closing the goals↔criteria gap the PRD template
  flags; and RFC 0002's option-A cons paragraph lost a stray three-space
  indent that broke its bullet's continuation alignment.
- Documentation-currency pass: the slot-growth mechanism parked at [OQ
  24](docs/open-questions.md) was named three ways across records — *chain
  checkpoint* (PRD 0002), *archival chain checkpoint* (ADR 0002, the
  roadmap) and *archival checkpoint* (the register). Every mention now says
  *archival checkpoint*, and the glossary defines it: four records used the
  term and none defined it, against the define-once rule. A `build.zig`
  test comment also stopped saying "the textual matcher admits" in the
  present tense — the matcher it means is the text-stripping one the
  tokenizer gate removed, so the present tense read as if the current gate
  were textual.
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

- The test-registration lint step enumerates `src/` through the same
  dispatcher as the 100-column cap (`checkedFiles`) instead of carrying its
  own copy of the enumerate-and-read scaffolding, and its failures now name
  what they stopped on like the column cap's (`cannot enumerate 'src': …`,
  `cannot read 'x.zig': …`, not "the src/ modules"). No gate outcome
  changes.

- The lint gates' file-access failures now name what they were reading: a
  checked path that could not be read surfaced as a bare OS error
  (`FileNotFound`) with no path, leaving the operator to re-derive the gate's
  file list by hand before the failure could be fixed. Each failure point in
  the 100-column-cap and test-registration steps reports the operation, the
  path and the OS error instead; both gates still fail loudly, never skip a
  file silently.

- Spec-currency pass: clanker's RFC 0019 was reopened at source (2026-08-24)
  and the claims README and PRD 0001 cite from it hold — the survey scope
  (17 candidates at Draft 4 plus R/S/T at Draft 5), option T *Packaging*
  naming this project, the still-unrun stage-1 spike, the port-blind
  `networkAllowed`, and the improve-ledger rewrite. Research 0001's evidence
  log now carries that row with its read date, so the "seventeen stores"
  figure is traceable in-repo instead of resting on the carried note alone
  ([OQ 40](docs/open-questions.md) stays open for the remaining rows); the
  glossary defines `genesis` and `segment`, which every record used and only
  their derivatives (`founder`, `sealed segment`) defined.

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
