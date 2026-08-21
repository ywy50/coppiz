# Roadmap

The Done/Planned narrative over the PRDs. A PRD says what a feature is meant
to be; this file says what has shipped and in what order the rest is meant
to land. Update it when a PRD changes status.

## Done

- **Repository founded** (2026-08-21) — Zig 0.16 skeleton that builds and
  tests (`zig build test`), clanker's docs taxonomy, five draft PRDs, two
  RFCs in discussion, two accepted ADRs, one carried research note, the
  open-questions register and the glossary. No store logic exists.

## Planned

In dependency order. Each line names the PRD whose Implementation section has
the phases.

1. **Ledger core, single member** — [PRD 0001](prds/0001-ledger-core.md)
   phases 1–4: codecs, chain validation, segment storage with torn-tail
   recovery, the library API at size 1. Gate: acceptance criteria G3–G6 on
   one member.
2. **Settings in the chain** — [PRD 0004](prds/0004-settings.md): schema as
   code, validation, fold, `docs/configuration.md` generated and pinned.
3. **TTL and staleness** — [PRD 0002](prds/0002-ttl-and-staleness.md): pure
   expiry predicates, `stale` and `checkpoint` rules, payload drop. Testable
   on one member (it is its own leader).
4. **Decide RFC 0002** (join order) and **RFC 0001** (library/service) —
   before the cluster work starts; both have recommendations.
5. **Deterministic simulator** — [OQ 27](open-questions.md): seeded
   multi-node run with partitions, crashes, skew and reorder, over the pure
   fold/election/merge functions. Placed *before* the node loop so the loop
   is written to be driven by it.
6. **Membership and leadership** — [PRD 0003](prds/0003-membership-and-leadership.md):
   membership fold, election function, epochs and merge, wire protocol
   ([OQ 19](open-questions.md)), node loop, admission, reconfigure
   handover. Gate: e2e (a)–(e).
7. **Embedding and the node binary** — [PRD 0005](prds/0005-embedding-the-library-as-the-product.md):
   public library API, `examples/` (single, cluster, sidecar), the `spine`
   CLI, `doctor`, `status`.
8. **First host integration (clanker)** — PRD 0005 phase 5: a clanker branch
   with `ck_state` over spine, one stream replicated between two instances,
   measured against its spike note's three journeys. A second, unrelated
   host example follows to keep the API general ([OQ 46](open-questions.md)).
9. **First public release** — name ([OQ 16](open-questions.md)), licence
   ([OQ 18]), reopened claims ([OQ 40]), CI ([OQ 45]), rolling-upgrade
   procedure ([OQ 26]), backup runbook ([OQ 39]).

## Later

- `quorum` leadership mode (Raft-style) as a fourth `leadership.mode` value,
  for clusters at n ≥ 3 that want a strict single sequencer without stalling.
- Archival chain checkpoints so slot count can be bounded ([OQ 24]).
- Service API and/or observer clients (RFC 0001 options B/D), C ABI.
- Leader-star or gossip topology past 32 members ([OQ 25]).
- Wire encryption off private networks ([OQ 23]).
- Blob shape (chunked or content-addressed) for large payloads ([OQ 36]).
