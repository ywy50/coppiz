# Configuration

The journal configures itself through its own chain: every setting
that affects what a member accepts, removes, or elects is stored in
`genesis` and `settings` entries and folded identically on every
member (PRD 0004). This page is generated from the schema table in
`src/settings/schema.zig` - `zig build docs` regenerates it, and
the test suite fails when it is stale.

Local configuration is limited to bootstrap: paths, identity, peers
and fsync. A local-config key that *looks* like a journal setting
is a startup error, not a silent ignore.

## Scopes

- **cluster** - one value for the cluster (leadership, membership,
  admission).
- **journal** - one value per journal (TTL, staleness, checkpoints,
  entry size).
- **federation** - reserved for PRD 0006; no keys yet, so federating
  later is a new set of keys, not a schema break.

## Keys

Live-changeability: `always` = changeable by a `settings` entry;
`requires_reconfigurable` = only while `leadership.reconfigurable`
is true; `turnoff_only` = can only be flipped from true to false
live. Defaults marked *(provisional)* are placeholders awaiting the
operator's values (OQ 36, OQ 55).
| Key | Scope | Type | Default | Live | Description |
|---|---|---|---|---|---|
| `leadership.mode` | cluster | enum | seniority | if reconfigurable | which member leads: earliest join, an authority list, or tiebreak-filtered |
| `leadership.authorities` | cluster | string list | [] | if reconfigurable | ordered leader candidates under configured/combined: ids or addresses |
| `leadership.tiebreak` | cluster | enum | seniority | if reconfigurable | how combined orders eligible authorities |
| `leadership.fallback` | cluster | enum | stall | if reconfigurable | what configured/combined do with no live authority: stall or degrade |
| `leadership.reconfigurable` | cluster | bool | true | true → false only | whether leadership.* may change live; false freezes it until offline |
| `cluster.admission` | cluster | enum | allowlist | always | how a dialing node is admitted: allowlist key, prompt, or open |
| `cluster.max_members` | cluster | u16 | 32 | always | full-mesh membership cap per group; past it, grow by more groups |
| `cluster.max_journals` | cluster | u32 | 1024 *(provisional)* | always | journal cap for a cluster; past it, creation refuses (provisional, OQ 55) |
| `cluster.heartbeat_ms` | cluster | u64 | 1000 | always | failure-detector heartbeat cadence between members (placeholder, OQ 37) |
| `cluster.suspect_after_ms` | cluster | u64 | 5000 | always | a member missed for this long is unreachable (placeholder, OQ 37) |
| `membership.evict_after_ms` | cluster | u64 | 0 | always | convert an unreachable member to a leave after this long; 0 = never |
| `merge.settle_ms` | cluster | u64 | 30000 | always | no checkpoint for slots newer than a merge until this passes (OQ 60) |
| `journal.max_entry_bytes` | journal | u64 | 16777216 *(provisional)* | always | largest payload an append may carry; refused too_large (OQ 36 provisional) |
| `ttl.enforce` | journal | enum | off | always | which entries expire: none, only TTL-carrying ones, or every entry |
| `ttl.default_ms` | journal | u64 | 0 | always | TTL for entries without one under enforce=all; 0 there is an error |
| `ttl.max_ms` | journal | u64 | 0 | always | cap on a requested TTL; a larger ask is clamped to it; 0 = unbounded |
| `ttl.action` | journal | enum | mark_stale | always | what expiry does at the instant: mark stale, or mark expired |
| `ttl.retain` | journal | enum | header | always | what a removal keeps: the entry header or only the slot |
| `ttl.grace_ms` | journal | u64 | 0 | always | read-side skew tolerance; hides once now passes expiry + grace |
| `stale.enforce` | journal | enum | off | always | whether author-marked staleness is on; a stale entry is refused while off |
| `stale.who` | journal | enum | author | always | who may mark when enabled; author is the only value in v1 |
| `stale.cleanup` | journal | enum | keep | always | whether checkpoints remove stale entries; removal needs delete explicitly |
| `checkpoint.every_ms` | journal | u64 | 60000 | always | leader checkpoint cadence (placeholder, OQ 10) |
| `checkpoint.pending_bytes` | journal | u64 | 67108864 | always | early trigger once this much removable payload accumulated (OQ 10) |
