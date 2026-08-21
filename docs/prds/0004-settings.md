# PRD 0004 — Settings: the ledger configures itself through its own chain

## Status

Draft — 2026-08-21. Depends on [PRD 0001](0001-ledger-core.md) (`genesis`
and `settings` control kinds; fold). Consumed by [PRD 0002](0002-ttl-and-staleness.md)
and [PRD 0003](0003-membership-and-leadership.md), which define the keys.
Source of truth once shipped: `src/settings/` (schema, validation, fold) and
`docs/configuration.md` (the operator reference, which must mirror the
schema — a mismatch is a bug in the doc).

## Problem

The brief asks for settings that govern behaviour on *every* member —
TTL enforcement, expiry action, leadership mode, whether leadership may
change at runtime. If each member read those from its own config file, two
members could run different rules on the same ledger: one deleting expired
entries, another keeping them, one electing by seniority, another by a list.
Every such disagreement is a silent fork. The settings that define a ledger's
behaviour must therefore be *part of the ledger*, agreed by the same
mechanism as the data, so that a member cannot be running a rule the others
are not.

At the same time, a member needs *some* local configuration before it has a
ledger to read settings from: where its data lives, its key, whom to dial,
and — for the founder — the initial settings to put in `genesis`.

## Goals

1. Every setting that affects what a member accepts, removes, or elects is
   stored in the chain and folded identically on every member.
2. Local configuration is limited to bootstrap: paths, identity, peers, and
   (founder only) the initial settings.
3. Each setting declares whether it is live-changeable, and a `settings`
   entry that touches a frozen key is refused by every member.
4. A settings change is validated as a whole (the new settings state must be
   valid, not just each key), and takes effect at a defined slot.
5. The full schema — keys, types, defaults, live-changeability, scope — is
   generated from one source in code and rendered to `docs/configuration.md`.

## Non-goals

- **No per-member overrides of ledger settings.** A member cannot opt out of
  a ledger's TTL or leadership rule; that is the point.
- **No settings history API in v1.** The chain *is* the history; reading
  past settings means folding to an earlier slot, which the read API can do
  (`at_slot`), but there is no diff/audit view yet.
- **No secrets in settings.** Keys, tokens, and passwords never go in the
  chain (it is replicated to every member and tamper-evident, not
  confidential). Local config is where secrets live.

## Design

**Two layers, named.**

| Layer | Where | Who reads it | Examples |
|---|---|---|---|
| **local config** | `<data_dir>/spine.toml` (or flags / env) | this member only | `data_dir`, `member.key_file`, `listen`, `[[peers]]`, `log.level`, `storage.fsync` |
| **ledger settings** | `genesis` + `settings` entries in the chain | every member, by fold | `ttl.*`, `stale.*`, `checkpoint.*`, `leadership.*`, `cluster.*`, `membership.*`, `merge.*`, `ledger.max_entry_bytes` |

The test for which layer a knob belongs to: *if two members disagreed on it,
would they diverge?* If yes, it is a ledger setting. `storage.fsync` is local
(a member that fsyncs less is only risking its own tail); `ttl.action` is a
ledger setting (members that disagree hold different ledgers).

**Scope.** A ledger setting is **cluster-scoped** (one value for the
cluster: everything under `leadership.*`, `cluster.*`, `membership.*`,
`merge.*`), **ledger-scoped** (one value per ledger: `ttl.*`, `stale.*`,
`checkpoint.*`, `ledger.*`), or — reserved now, populated by
[PRD 0006](0006-scaling-to-groups-sharding-and-parity.md) —
**federation-scoped** (the ownership map and federation leadership). The
third scope is in the schema from the first release so that federating later
is a new set of keys, not a schema break. A `settings` entry names its scope and, for
ledger scope, the ledger. Cluster-scoped settings live in the cluster's
control ledger — see [open question 7](../open-questions.md) on whether that
is a separate chain or the first ledger.

**Bootstrap.** The founder's local config carries `[genesis]` with the initial
settings; `spine init` validates them against the schema, writes the
`genesis` entry, and from then on the local `[genesis]` table is ignored (and
`spine doctor` warns if it drifts from the chain, so an operator editing the
wrong file finds out). A joining member carries no settings at all; it gets
them by backfilling the chain. A local config key that *looks* like a ledger
setting (`ttl.action` in `spine.toml`) is a startup error, not a silent
ignore — the failure mode where a loader ignores unknown keys and a typo'd
grant fails only at runtime is one clanker documents having been bitten by,
and the schema here is closed.

**The `settings` entry.** Payload: scope, optional ledger id, and a list of
`(key, value)` pairs. Authored by the leader only (it is a sequencing
decision; a follower that wants a change asks the leader through the API,
which forwards like any append). Validation, on every member:

1. Every key exists in the schema and the value parses to its type.
2. Every key is live-changeable *in the current folded state* — a key's
   live-changeability can depend on another setting, which is exactly how
   `leadership.*` is frozen by `leadership.reconfigurable = false` (PRD 0003).
3. The *resulting* settings state is valid as a whole (`ttl.enforce = all`
   requires `ttl.default_ms > 0`; `authorities[]` may be empty only under
   `seniority` or with `fallback = seniority`; and so on). Cross-key rules
   live in one place, `src/settings/validate.zig`, and are table-tested.
4. The change takes effect for slots *after* the `settings` slot. A rule that
   needs a new epoch to apply (leadership) says so, and the leader appends
   the `epoch` immediately after.

A refused `settings` entry is refused by every member; the leader that tried
to append it learns the refusal from its own validator before it ever
broadcasts (the leader validates against the same pure function), so in
practice a bad change never reaches the wire.

**Schema as code.** `src/settings/schema.zig` is a comptime table: key,
scope, type, default, live-changeability (a boolean or a predicate over the
folded state), and a one-line description. `spine settings schema` prints it;
`zig build docs` renders it into `docs/configuration.md`; a test pins that the
rendered file matches the table, so the reference cannot drift the way a
hand-maintained one does.

**Reading settings.** The library exposes `node.settings()` (cluster scope)
and `ledger.settings()` (merged: cluster + ledger scope), both from the fold
at the current head, and `…settingsAt(slot)` for the historical view.

**Dependencies.** PRD 0001 (fold, `genesis`, `settings` kinds). Defines the
mechanism that PRD 0002 and PRD 0003 populate.

**Implementation.**

1. `src/settings/schema.zig` — the table and its types, with the PRD 0002 /
   0003 keys; a test that every key has a default that validates.
2. `src/settings/validate.zig` — per-key and cross-key validation, the
   live-changeability predicates; table tests including `leadership frozen`.
3. `src/settings/fold.zig` — apply `genesis` and `settings` entries in chain
   order; `at_slot`.
4. `src/config/local.zig` — `spine.toml` parsing with a closed key set
   (unknown key = error naming the key and, when it matches a ledger
   setting, saying which layer it belongs to). TOML parser is [open
   question 35](../open-questions.md) (vendor clanker's, or hand-roll the
   subset).
5. `zig build docs` → `docs/configuration.md`, pinned by a test.

## Failure modes

| Condition | Behaviour |
|---|---|
| Unknown key in `settings` entry | refused, `unknown_setting: <key>` |
| Known key, wrong type | refused, `invalid_settings: <key> expects <type>` |
| Frozen key | refused, naming the freezing rule (`leadership frozen by reconfigurable=false`) |
| Valid keys, invalid combination | refused, naming the cross-key rule |
| Ledger setting found in local config | startup error naming the key and the layer it belongs to |
| Local `[genesis]` differs from the chain after init | ignored; `spine doctor` warns |
| Two leaders append conflicting `settings` during a partition | both slotted on their branches; after merge the surviving branch's value wins for the merged chain *and* the losing branch's `settings` entries are re-slotted as no-ops — re-applying them is [open question 33](../open-questions.md) |

## Acceptance criteria

- [ ] (G1) Two members with different local configs fold identical settings
  from the same chain (hash-equal).
- [ ] (G2) A joining member with an empty local config beyond identity and
  peers ends up with the cluster's settings.
- [ ] (G3) A `settings` entry touching `leadership.mode` is refused on every
  member when `reconfigurable = false`, accepted when `true`.
- [ ] (G4) Every cross-key rule has a refusing test and an accepting test.
- [ ] (G5) `docs/configuration.md` is generated and a test fails when it is
  stale.

## Open questions / future work

- Where cluster-scoped settings live ([OQ 7](../open-questions.md)).
- Merge semantics for conflicting `settings` on two branches ([OQ 33]).
- TOML parser choice ([OQ 35]).
- Whether settings should be signed by an operator key distinct from member
  keys, so a compromised member cannot reconfigure the cluster even as
  leader ([OQ 22]).
