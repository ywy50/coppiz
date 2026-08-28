# ADR 0007 — The library is the primary surface; the node binary is its wrapper

## Status

Accepted — 2026-08-28.

## Context

The brief (2026-08-21) requires that a host pay nothing beside itself
([ADR 0003](0003-batteries-included-no-external-infrastructure-at-any-size.md)),
and the strictest known host, clanker, additionally forbids a second daemon
and cannot scope a sandboxed guest to a local port, so a service-first shape
is unusable by its first consumer. [RFC 0001](../rfcs/0001-library-first-or-service-first.md)
framed the choice — which integration surface, the embeddable Zig library or
the standalone node with a service API, is the primary contract whose design
drives the other — and recommended option A, library-first, with confidence
7/10.

The decision then took effect through implementation: PRD 0005's steps 1–3
are precisely option A's shape — the library API in `src/root.zig`, the
embedded-host examples in `examples/`, and the `coppiz` node binary wrapping
the library — and they shipped with commit 51caeb0 (2026-08-28), recorded in
the ROADMAP's Done section. The implementation landed without its record;
this record closes that gap.

## Decision

The library is the primary contract: `src/root.zig` is the product, and the
`coppiz` node binary is that library wrapped with configuration and a CLI —
never a second implementation of any rule. The service API is not built; when
it appears it lands as a wrapper module over the library, versioned
separately, motivated by the first non-Zig consumer. Option D (clients as
observer members) stays possible because the replication protocol is
specified, not incidental.

## Consequences

- A host adds one dependency and calls the library in-process; keys and
  sockets never leave the host; size-1 use is a function call.
- Non-Zig consumers wait for the service wrapper or a C ABI, both roadmap.
- The public contract is Zig declarations, which pre-1.0 toolchain churn
  makes fragile: hosts pin their toolchain and rebuild to pick up changes,
  and the library cannot be upgraded independently of its host.
- Adding the service wrapper later is cheap and is the planned path;
  inverting to service-first later is the expensive direction (I/O
  ownership flips), so this decision is effectively permanent.
- Reversing it is a superseding ADR naming what it buys — a stable
  cross-language contract — and needs a consumer to justify it.
