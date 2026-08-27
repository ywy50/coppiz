# ADR 0001 — The core is Zig 0.16 with the standard library only

## Status

Accepted — 2026-08-21.

## Context

The brief (2026-08-21) states the language: Zig. The first and designing
consumer, clanker, is a Zig 0.16 musl static binary that deliberately pins two
fetched dependencies (`zwasm`, `vaxis`) and vendors its TOML parser rather
than fetch a third; its RFC 0019 counts coppiz as "a third fetched dependency
against constraint 2's budget". A store that itself fetched dependencies
would multiply that cost for every host, and a store that linked libc or a
C library would break the single static binary clanker keeps on purpose.

Everything the core needs is in Zig 0.16's standard library: Ed25519 and
SHA-256 (`std.crypto`), CRC (`std.hash.crc`), file and socket I/O
(`std.Io`), JSON (`std.json`). The one thing it does not have is a TOML
parser, which only the node binary's local config needs.

## Decision

The library (`src/root.zig` and everything under `src/journal/`,
`src/cluster/`, `src/settings/`, `src/net/`) targets Zig 0.16.0, uses the
standard library only, links no libc beyond what the host links, and
declares no fetched dependencies in `build.zig.zon`. The node binary may
vendor (not fetch) a TOML parser under `vendor/` for `coppiz.toml`
([OQ 35](../open-questions.md)); nothing under the library may import it.

## Consequences

- A host pays exactly one dependency for the whole store, and a static musl
  build stays static.
- The toolchain pin is a compatibility promise: a Zig minor bump is a
  breaking change for hosts on the old pin until they move, and the library
  API churns with `std` pre-1.0 (RFC 0001 names this as its main sink).
- Cryptography is limited to what `std.crypto` ships; a primitive it lacks
  (a different signature scheme, an AEAD for wire encryption) is either in
  `std` or is not available — [OQ 23](../open-questions.md) is bounded by
  this.
- No SQLite, no LMDB, no RocksDB: the storage engine is our own append-only
  segment format (PRD 0001), which is the right shape for a log but means
  owning torn-write recovery and compaction ourselves.
- Reversing this — fetching a dependency into the library — is a visible
  `build.zig.zon` change and needs a superseding ADR naming what it buys.
