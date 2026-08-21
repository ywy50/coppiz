# Glossary

Terms are defined once, here, and used with exactly these meanings in every
record. When a PRD needs a new term, add it here in the same commit.

| Term | Meaning | Defined in |
|---|---|---|
| **cluster** | the set of members that share ledgers; created by one `genesis` entry | PRD 0003 |
| **member** | a node admitted to the cluster: an Ed25519 keypair, a member id derived from the public key, and an address | PRD 0003 |
| **node** | one running process holding a data directory; a node that has been admitted is a member | PRD 0005 |
| **founder** | the member whose `genesis` created the cluster; seniority 0 | PRD 0003 |
| **ledger** | one named, append-only sequence of slots with its own settings ("schema"); a cluster holds many | PRD 0001 |
| **entry** | what an author writes: a fixed, author-signed header plus an opaque payload; immutable; identified by `(author, author_seq)` | PRD 0001 |
| **entry id** | `(author, author_seq)`; stable forever, across merges and restarts | PRD 0001 |
| **author** | the member that signed an entry | PRD 0001 |
| **author_seq** | the author's per-ledger counter; gives the entry its id | PRD 0001 |
| **payload** | the bytes a consumer stores; spine never interprets them | PRD 0001 |
| **slot** | where the ledger put an entry: `(epoch, seq)`, leader-signed, hash-chained to the previous slot | PRD 0001 |
| **position** | synonym for a slot's `(epoch, seq)` | PRD 0001 |
| **chain** | the sequence of slots linked by `prev_slot_hash`; one per ledger as drafted (OQ 7) | PRD 0001 |
| **fold** | the deterministic computation of state (members, settings, leader, stale/expired sets) from the chain alone | PRD 0001 |
| **control entry** | an entry whose kind is not `data`: `genesis`, `join`, `leave`, `epoch`, `merge`, `settings`, `stale`, `checkpoint` | PRD 0001 |
| **validation** | the pure rule every member applies to a `(slot, entry)` before accepting it; a refusal names its reason | PRD 0001 |
| **unslotted queue** | a member's durable list of entries it authored or received that have no slot yet | PRD 0001 |
| **backfill** | a member fetching slots it lacks from any member, verified against the chain | PRD 0001 |
| **head** | a member's latest verified slot | PRD 0001 |
| **leader** | the member that assigns slots in the current epoch | PRD 0003 |
| **epoch** | a leadership term; opened by an `epoch` control entry; `seq` restarts at 1 | PRD 0003 |
| **election** | the pure function `leader(mode, settings, members, liveness)`; there is no vote | PRD 0003 |
| **seniority** | a member's join position: the slot of its `join` (or `genesis`) entry; earlier = more senior | PRD 0003, RFC 0002 |
| **authorities** | the operator's ordered list of leader candidates under `configured`/`combined` | PRD 0003 |
| **tiebreak** | how `combined` orders eligible authorities: `seniority` or `freshest` | PRD 0003 |
| **freshest** | the eligible member with the highest acknowledged head at election time | PRD 0003, OQ 12 |
| **fallback** | what `configured`/`combined` do with no live authority: `stall` or `seniority` | PRD 0003 |
| **reconfigurable** | the setting that allows `leadership.*` to change by a live `settings` entry | PRD 0003, PRD 0004 |
| **admission** | the receiver-side decision to let a dialing node join: `allowlist`, `prompt`, `open` | PRD 0003 |
| **member state** | `joining` → `syncing` → `member` ↔ `unreachable` → `left` | PRD 0003 |
| **syncing** | admitted and slotted but not yet at head; never leader-eligible | PRD 0003 |
| **partition** | members that disagree on liveness; each side may elect its own leader | PRD 0003 |
| **branch** | the slots one side of a partition produced in its own epoch | PRD 0003 |
| **merge** | the control entry and rule by which the surviving branch re-slots the losing branch's entries after it | PRD 0003 |
| **re-slot** | giving an unchanged entry a new slot after a merge; its entry id does not change | PRD 0003 |
| **TTL** | an entry's time to live in ms; 0 = none | PRD 0002 |
| **effective TTL** | the TTL after the ledger's `ttl.enforce`/`default`/`max` are applied | PRD 0002 |
| **expiry instant** | `slot_ts_ms + effective TTL`; computed from the slot, never from the author's clock | PRD 0002 |
| **stale** | hidden from default reads but physically present; by author mark or by TTL under `mark_stale` | PRD 0002 |
| **expired** | past its expiry instant under `ttl.action = delete`; hidden, awaiting a checkpoint | PRD 0002 |
| **removed** | payload (and under `retain = none`, header) dropped by a checkpoint; the slot stays | PRD 0002 |
| **checkpoint** | the leader's control entry that makes removal deterministic: "drop everything expired/stale through slot X" | PRD 0002 |
| **retain** | what a removal keeps: `header` or `none` | PRD 0002 |
| **grace** | read-side skew tolerance in ms; affects visibility on one member, never bytes | PRD 0002 |
| **settings** | ledger or cluster behaviour stored in the chain via `genesis`/`settings` entries; never per-member | PRD 0004 |
| **local config** | `spine.toml`: paths, identity, peers, fsync — things whose disagreement cannot fork the ledger | PRD 0004 |
| **scope** | whether a setting is cluster-wide or per ledger | PRD 0004 |
| **live-changeable** | a setting that a `settings` entry may alter; may depend on other settings | PRD 0004 |
| **host** | any program that links the spine library; the `spine` binary, the examples and clanker's `serve` are instances | PRD 0005 |
| **service API** | the optional HTTP surface over the library for non-Zig hosts and operators | PRD 0005, RFC 0001 |
| **observer** | a possible non-authoring client that speaks the replication protocol | RFC 0001 option D |
| **OQ n** | open question *n* in [open-questions.md](open-questions.md) | — |
