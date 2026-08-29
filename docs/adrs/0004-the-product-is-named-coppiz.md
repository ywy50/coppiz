# ADR 0004 - The product is named coppiz

## Status

Accepted - 2026-08-27.

## Context

The working name `spine` came from clanker's RFC 0019 ("the spine"). It is
generic enough to collide on package indexes and search, and OQ
16 blocked the first public release on choosing a
name before publishing: the `.name` in `build.zig.zon` and the module name
change with it.

The name has to survive TTL reclaim (a rolling window can shrink what a
consumer sees, and under `retain = none` the payload bytes too) and the
10⁵-instance story. Growth-only words (`accrete`) and miniature-only words
(`bonsai`) fail one of those. `coppice` - woodland cut on a rotation so the
stools resprout - maps onto the product: the stool is the chain, the poles
are payloads harvested by TTL and checkpoint, and a woodland can be one
stool or many acres. The English spelling is taken as a live Mac notes app
(coppiceapp.com, App Store 2026). The Zig-looking spelling `coppiz` had no
package on GitHub, crates.io, npm, or in the Zig namespace.

Spoken English will say it as *copies* (`/ˈkɒpiz/`), not COP-iss; German
`z` is `/ts/`. Those costs were accepted.

## Decision

The product is named `coppiz`. The library module, the node binary, the
package `.name` in `build.zig.zon`, and the local-config file
(`coppiz.toml`) use that identifier. Clanker's RFC 0019 phrase "the spine"
stays as the origin quote, not as a second name.

## Consequences

- A host writes `@import("coppiz")` and runs `coppiz`; search for the
  identifier is not the Mac app and is not a generic "spine".
- Callers will hear *copies*. The docs teach the coppice metaphor; they do
  not claim the pronunciation of `coppice`.
- Reversing the name is a superseding ADR and another rename of the
  package, module, binary and config file.
