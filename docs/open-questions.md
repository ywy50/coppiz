# Open questions

The cross-cutting register of what the design does not yet settle. Every
PRD and RFC points here by number (`OQ n`); numbers are stable — a resolved
question keeps its number and gets a **Resolved** line naming the record
that settled it (an ADR, a PRD Design section, or a measurement), never a
deletion. Add new questions at the end of the section they belong to.

Ordering inside each section is by what blocks implementation first.
"Blocks" names the phase that cannot start until the answer exists.

## A. Trust and product stance

1. **What is the trust model — crash faults only, or misbehaving members?**
   The brief requires join order to be unspoofable "by any member", which is
   a partial-distrust requirement, while clanker's research rejected BFT on a
   single-operator premise. The design as drafted authenticates every member
   (signatures, chain) and defends against a member lying about *others* or
   about *history*, but not against a member that follows the protocol and
   writes garbage, nor against a coalition. Is that the line? If a stronger
   guarantee is wanted, what is the threat: a compromised host, a buggy
   build, a second operator? *Blocks:* nothing yet; shapes PRD 0003 merge and
   any future `quorum` mode. *Answer from:* the operator.
2. **At n = 2 under `seniority`, is AP-with-merge the right default?** Two
   leaders during a partition, healed by deterministic re-slotting (PRD
   0003), versus `configured` + `stall` where the non-authority side refuses
   writes. The brief's "2 instances … define a specific one who is the
   leader" suggests the second is what an operator reaches for at n = 2; the
   drafted default mode is `seniority`. *Blocks:* PRD 0003 settings defaults.
   *Answer from:* the operator.
3. **Default `write.ack`: `local` or `slotted`?** `local` keeps a partitioned
   member writing (AP); `slotted` waits for a position (CP-ish, and even then
   a position can move once at merge unless the mode forbids two leaders).
   *Blocks:* PRD 0001 phase 4 API defaults. *Answer from:* the operator; also
   clanker's RFC 0019 open question 1 ("stall or keep working").
38. **Service API auth.** If RFC 0001 keeps a service API, what authenticates
    a caller off loopback — a static token, member keys, mTLS? v1 drafts
    loopback-only with a warning. *Blocks:* PRD 0005 phase 3.
40. **Public claims need reopening.** Everything in research 0001 is carried
    from clanker's reading dates; before the README or a release cites an
    external fact, reopen it. *Blocks:* first public release.

## B. Ordering, epochs and merge

7. **One chain per ledger, or one per cluster?** Per ledger (as drafted)
   keeps ledgers independently prunable and lets a consumer follow one
   stream cheaply; per cluster gives a single `(epoch, seq)` for everything
   and one place for cluster-scoped settings. The compromise — a control
   ledger for cluster-scoped entries plus per-ledger data chains — doubles
   the fold. *Blocks:* PRD 0001 phase 2 (fold). *Answer from:* design; decide
   before the on-disk format freezes.
8. **Per-ledger or cluster-level leadership?** Drafted cluster-level (one
   leader sequences all ledgers). Per-ledger leadership spreads load and
   isolates a hot ledger, at the cost of N elections and N failure detectors.
   *Blocks:* PRD 0003 phase 2. *Answer from:* measurement, after a single
   leader is shown to saturate.
11. **An `author_seq` gap that never fills; refused entries consume a seq.**
    A member that crashes after assigning `author_seq = n` locally but before
    forwarding leaves a permanent hole; a refused entry (e.g. a `stale` for
    someone else's entry) also burns a number. Options: allow gaps (dense
    becomes monotone; dedup still works), or make the author re-announce its
    head on reconnect so the leader can close the gap. *Blocks:* PRD 0001
    phase 2 validation.
12. **`tiebreak = freshest` semantics.** "Highest acknowledged `(epoch,
    seq)`" across epochs is not totally ordered after a merge; the draft
    freezes the evaluation at election. Is the extra mode worth its
    definition cost, given `syncing` members are already excluded? *Blocks:*
    PRD 0003 phase 2. *Answer from:* the operator (it was in the brief as a
    "perhaps").
31. **Read consistency.** Reads are local. Is "read your own writes" enough,
    or do consumers need a linearizable read (ask the leader for its head
    and wait for it)? clanker's board fold is tolerant; a claim/lease
    consumer would not be. *Blocks:* nothing in v1; shapes the read API.
33. **Conflicting `settings` on two branches.** After a merge the surviving
    branch's value wins and the losing branch's `settings` entries are
    re-slotted as no-ops (PRD 0004). Should they instead re-apply in order
    (last writer wins by merged position)? *Blocks:* PRD 0003 phase 3.
37. **Failure-detector timings and leader lease.** Heartbeat 1 s, suspect at
    5 s are placeholders. Is there a leader *lease* (the old leader stops
    slotting when it cannot hear a majority of its last-known members), or
    does it keep slotting until it sees a newer epoch? Without a lease, a
    leader that is partitioned from everyone keeps writing on its own
    branch — which is the AP behaviour, so this is OQ 2 again from the
    leader's side. *Blocks:* PRD 0003 phase 5.

## C. Membership

4. **Seniority on rejoin.** Drafted: only a `leave` entry resets seniority; a
   crash or network absence keeps it. Should a long absence
   (`evict_after_ms`) convert to a `leave`? That makes eviction change the
   leader order, which is either the point or a surprise. *Blocks:* PRD 0003
   phase 1.
5. **Changing leadership settings when `reconfigurable = false`.** Drafted as
   an offline procedure (`spine reconfigure` on one stopped member, others
   backfill it). Is "stop everything" acceptable, or is a signed operator
   override (OQ 22) wanted so the lock can be lifted live by someone who is
   not a member? *Blocks:* PRD 0003 phase 5 and the CLI.
20. **Eviction of dead members.** Default never. An evicted member's entries
    stay; only its seniority and its seat in `max_members` go. Who evicts
    under `configured` when the leader is the dead one? *Blocks:* PRD 0003
    phase 5.
21. **How the allowlist learns a newcomer's key.** Out of band — the operator
    copies the public key into `[[peers]]` — or a one-time join token the
    founder prints and the newcomer presents, after which the key is bound.
    clanker's mesh binds identity to a TLS pin in its phase 2. *Blocks:*
    PRD 0003 phase 5 admission.
22. **Key rotation and compromise; an operator key.** A member's key is its
    identity; rotating it is a `leave` + `join` (new seniority) as drafted,
    which is punitive for routine rotation. And should *operator* actions
    (settings, reconfigure, evict) be signed by a key that is not any
    member's, so a compromised leader cannot reconfigure the cluster?
    *Blocks:* nothing in v1; must be decided before 1.0 because it changes
    the `join` payload.
25. **Topology past 32 members.** Full mesh is O(n²) connections. Options:
    leader-star (followers connect only to the leader; backfill from any),
    gossip (SWIM-style membership with fan-out trees). clanker's research
    named 32 as the point where "the surveyed products earn their weight".
    *Blocks:* nothing until a cluster approaches it.

## D. TTL, staleness and retention

6. **Who may mark stale beyond the author.** The brief is explicit that only
   the author may; the schema key `stale.who` exists so `leader` or an
   operator role can be added. Is there a use case (cleaning up after a dead
   member) strong enough to add it? *Blocks:* nothing in v1.
9. **`ttl.grace_ms` default and derivation.** Read-side skew tolerance.
   Could be derived from the observed offset between local clock and the
   leader's `slot_ts_ms` at the head. *Blocks:* PRD 0002 phase 1 defaults.
10. **Checkpoint cadence defaults.** 60 s / 64 MiB are placeholders. Too
    frequent spams control entries on every member; too rare delays reclaim.
    *Blocks:* PRD 0002 phase 4.
24. **Slot count grows forever.** Under `retain = none` a removed entry still
    costs one slot (~170 bytes) forever, because removing a slot breaks the
    chain. A long-lived high-churn ledger needs an *archival checkpoint*: a
    leader-signed root over a prefix that lets members drop the slots
    behind it while keeping verifiability from the root. That is a second
    chain-level mechanism and is out of v1. When does it become necessary?
    *Blocks:* nothing in v1; measure slot growth on the first consumer.
43. **What "full state" means under `retain = none`.** A member that joined
    after a checkpoint never sees removed payloads; it has the full *chain*
    but not every byte that ever existed. PRD 0003's "definitely has the
    full state" should be defined as "at head of the chain", and the docs
    should say so. *Blocks:* PRD 0003 phase 1 wording.

## E. Storage and format

13. **Does `author_ts_ms` belong in the signed header?** It is informational,
    never used for order or expiry; removing it shrinks every entry by 8
    bytes and removes a field consumers might wrongly trust. *Blocks:* PRD
    0001 phase 1 (cheap before the format freezes).
14. **`fsync` defaults.** `every` on the leader and `batched` on followers as
    drafted. A follower that loses its tail re-backfills, so `batched` is
    safe for it; is `every` on the leader acceptable at the write rates
    clanker needs (tens per second, not thousands)? *Blocks:* PRD 0001 phase
    3. *Answer from:* measurement.
17. **Snapshot format.** A verified fold at a slot, so restart and join do
    not replay from genesis. Is it a serialized fold state (versioned
    struct) or a compacted copy of the chain? When may a member serve a
    snapshot to a joiner instead of slots? *Blocks:* PRD 0001 phase 3.
26. **Format versioning and rolling upgrade.** Entry, slot, segment, snapshot
    and wire each carry a version. Can a cluster run two binary versions
    during an upgrade? Drafted: a reader refuses a newer version, so the
    leader must be upgraded *last* (it writes). Needs a written procedure
    and a test. *Blocks:* first release.
36. **Maximum entry size and large payloads.** `ledger.max_entry_bytes`
    default is unset. clanker's streams are 1–2 KB lines; sessions are up to
    1.75 MB and are explicitly *not* a first consumer. A blob shape (chunked
    entries, or content-addressed side storage) is roadmap. *Blocks:* PRD
    0001 phase 4 defaults.
39. **Backup and restore.** A data directory copied while the node runs may
    hold a torn tail (recovered at open) — is `cp -r` a supported backup, or
    does `spine export` exist? Restoring a member from backup must not
    resurrect a `leave` or fork the chain; the chain makes this detectable,
    but the procedure needs a runbook. *Blocks:* first release.

## F. Transport and wire

19. **Replication wire: own binary framing or HTTP?** clanker's spike used
    HTTP because it was there; a member-to-member protocol with heartbeats,
    streaming slots and backfill pages is more naturally a length-prefixed
    binary stream over one TCP connection. If RFC 0001's option D (observer
    clients) is to stay possible, the protocol must be specified. *Blocks:*
    PRD 0003 phase 4.
23. **Wire encryption.** Plain TCP on loopback/RFC1918 for v1 (clanker's mesh
    made the same call); for anything else, TLS — Zig `std` has a TLS client
    but no server — or a Noise-style handshake over the member keys we
    already have, using `std.crypto`'s X25519 + ChaCha20-Poly1305. ADR 0001
    bounds this to what `std` ships. *Blocks:* any non-private deployment.
28. **Backpressure.** A slow follower under a fast leader: does the leader
    buffer (bounded by what?), drop to backfill mode for that follower, or
    slow every writer? Drafted nowhere yet. *Blocks:* PRD 0003 phase 4.

## G. Embedding, API and clanker

15. **Library-first or service-first.** [RFC 0001](rfcs/0001-library-first-or-service-first.md).
    *Blocks:* PRD 0005 phases 1 and 3.
30. **Integration path with clanker.** clanker's RFC 0019 stage-1 spike is
    specified in clanker's tree and unrun. Run it there first (throwaway) and
    then build spine, or build spine's core and make the spike *use* spine?
    The second avoids building the cursor logic twice; the first gives
    clanker an answer without waiting. Which code survives? *Blocks:* PRD
    0005 phase 4. *Answer from:* the operator, jointly with clanker's RFC
    0019 next steps.
34. **Ledger lifecycle.** Who may create a ledger (any member? leader only?
    a setting?), and can one be *dropped* — which would be the only
    non-chain deletion — or only frozen (no further appends) and expired
    away? *Blocks:* PRD 0001 phase 4 (`node.ledger(name)` semantics).
35. **TOML parser for `spine.toml`.** Vendor clanker's (same toolchain,
    already patched for 0.16) or hand-roll the subset the local config
    needs. ADR 0001 allows vendoring, not fetching. *Blocks:* PRD 0004
    phase 4.
42. **Cursor and id encoding for consumers.** `epoch:seq` text cursors and
    `author:author_seq` ids are drafted; is a single opaque token better for
    an HTTP API, and should ids be exposed to consumers at all or only
    cursors? *Blocks:* PRD 0005 phase 1 API.

## H. Project, process and quality

16. **The name.** `spine` is the codename from clanker's RFC 0019 ("the
    spine") and is generic enough to collide on package indexes and search.
    Decide before publishing; check the Zig package namespace, GitHub, and
    crates/npm for collisions. Candidates so far: `spine`, `ledgerlet`,
    `zledger`, `tally`, `quill`, `rostrum`. *Blocks:* first public release
    (the `.name` in `build.zig.zon` and the module name change with it).
18. **Licence.** Not chosen. clanker's research tracked licences of every
    surveyed store (BUSL, CSL, Apache, MIT) as a selection criterion; spine
    should be unambiguous from the first public commit. *Blocks:* first
    public commit; also a `LICENSE` path in `build.zig.zon`.
27. **Testing strategy: deterministic simulation.** TigerBeetle's VOPR-style
    simulator (a seeded, single-threaded run of many nodes with injected
    partitions, crashes, clock skew and message reorder) is the one testing
    discipline clanker's research named worth copying. PRD 0001–0003's
    "pure fold, pure election, pure merge" split is what makes it possible.
    Decide early: is the simulator phase 0 of the cluster work, or a later
    addition? *Blocks:* PRD 0003 phase 1 (it changes how the node loop is
    written).
29. **Observability.** `spine status` / `node.status()`: leader, epoch, head,
    members and states, lag per follower, pending checkpoint bytes, last
    merge. Metrics format (Prometheus text?) and where logs go. *Blocks:*
    PRD 0005 phase 2.
32. **Clock assumptions.** `slot_ts_ms` is the leader's wall clock; TTL
    depends on it; nothing depends on monotonic time except failure
    detection. Document the assumption (NTP-disciplined, skew in seconds not
    hours) and what breaks outside it (early/late visibility only, never
    divergence). *Blocks:* nothing; documentation.
41. **Record-store tooling.** clanker maintains its `docs/` stores with
    sandboxed tools (`clanker rfc`, `clanker adr`, …) that write
    compare-and-swap and keep the inventories in sync. Spine's stores are
    hand-maintained for now; inventories drift the way clanker's did before
    its tools existed. Reuse clanker's tools pointed at this tree, or accept
    hand maintenance until the project is bigger? *Blocks:* nothing.
44. **Determinism of fold under merge *with* checkpoints.** PRD 0002's rule
    (each branch's checkpoint removes only what its own fold names; no
    checkpoint within `merge.settle_ms` of a merge) is reasoned, not
    tested. The simulator (OQ 27) is where it gets tested; until then it is
    the most likely place for a subtle divergence. *Blocks:* PRD 0002 phase
    5 acceptance.
45. **CI and toolchain pin.** Which Zig build to pin in CI (0.16.0 release),
    whether to test on musl and glibc targets, and whether `zig fmt --check`
    and a lint step gate merges as clanker's `gate` does. *Blocks:* first PR
    after the initial commit.

46. **Which non-clanker hosts are the design targets?** spine is
    general-purpose by brief (clarified 2026-08-21), but every concrete
    constraint so far comes from one host. Naming two or three other host
    shapes — a CLI tool that runs in short processes, a long-lived service on
    a few machines, an embedded/edge fleet with flaky links — would show
    which API shapes are general and which are clanker's. A second example
    host in `examples/` is the roadmap's way of keeping this honest. *Blocks:*
    nothing; shapes PRD 0005's API before it freezes. *Answer from:* the
    operator.
47. **Several processes on one data directory, SQLite-style.** SQLite lets
    N processes open one file (file locks, busy timeout); clanker relies on
    that today for its session databases, with `run`/`repl` processes
    writing beside `serve`. spine v1 flocks the directory to one process and
    expects short-lived processes to talk to the long-lived one. Supporting
    multi-process opens natively would mean: one process holds the listener
    and leader role, others append through a local IPC the library provides
    (unix socket in the data dir) — still no external infrastructure, but a
    second transport to own. Is the SQLite habit important enough to hosts
    to make this v1? *Blocks:* PRD 0005 phase 1 (`open` semantics). *Answer
    from:* the operator; OQ 46's host shapes.
## What else might be missing

Things no PRD has a home for yet; promote to a numbered question when one
becomes concrete:

- **Multi-tenancy / namespacing** across unrelated consumers sharing one
  cluster — or is "one cluster per consumer" the rule?
- **Quota and fairness** between authors (a runaway writer filling every
  member's disk).
- **Ledger-level access control** — may every member append to every ledger?
- **Time travel API** (`at_slot`) exposure and cost.
- **Entry payload validation hooks** — a host-supplied predicate the leader
  runs before slotting, so a consumer can enforce its own schema at the
  ledger boundary (would make refusal a chain-wide rule only if every member
  runs the same hook, which brings the OQ 1 trust question back).
- **Migration story off JSONL** for clanker's existing streams (import with
  original timestamps preserved in `author_ts_ms`?).
- **Graceful shutdown and drain** — a leaving leader hands over *before*
  exiting, so no epoch churn on a planned restart.
- **Windows/macOS support** — `std.Io` covers them; flock semantics and
  fsync guarantees differ; untested.
