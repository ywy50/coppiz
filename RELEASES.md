# Release and compatibility policy

spine has no published releases. Development happens at the version declared
in `build.zig.zon`; that value alone does not make a release. A version is
published only when an immutable `vMAJOR.MINOR.PATCH` Git tag and a matching
dated `CHANGELOG.md` section exist for the same commit.

`build.zig.zon` is the single source of truth for the program version. The
build reads it (`build.zig`) and exposes it to the library as `spine.version`;
the node binary imports the library and prints that value in its startup
banner (the placeholder in `src/main.zig`; flag parsing, including a real
`--version`, lands with the CLI). The build rejects values that are not valid
Semantic Versioning.

## Compatibility contract

spine uses Semantic Versioning with the following explicit pre-1.0 policy:

- `0.MINOR.0` may make breaking changes. Release notes must label each break
  and give a concrete migration.
- `0.MINOR.PATCH` is backward compatible and contains fixes only.
- From `1.0.0`, incompatible public changes require a major release,
  compatible features a minor, compatible fixes a patch.

The public contract includes more than Zig declarations: the library API in
`src/root.zig`; documented CLI commands, flags and output; the schema of
ledger settings and local config and their defaults; the on-disk entry, slot,
segment and snapshot formats (each carries a version a reader refuses when
unknown); and the replication wire protocol once RFC 0001 decides whether it
is public. A signature-preserving change to results, errors, defaults, side
effects, wire data, or persisted data can therefore be breaking.

Persisted and wire formats add one rule the Zig API does not have: a cluster
may run two adjacent versions during a rolling upgrade, the leader is
upgraded last, and the procedure is a runbook before the first release that
needs it (OQ 26).

Anything described as experimental or internal in documentation is outside
the stable API. A source-file location or absence from the README does not by
itself make a reachable surface private.

## Deprecation and migration

A stable surface is deprecated before removal. The deprecation names its
replacement, emits a warning where practical, and stays for at least one minor
release. On-disk format changes ship with `spine migrate`, never with an
implicit rewrite at open.
