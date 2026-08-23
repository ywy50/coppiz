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
   Its *layer* is also unsettled: PRDs 0001 and 0006 call it a setting
   (`write.ack = local | slotted`, honoured by the owning group), PRD 0003
   assumes a writer can ask for `slotted` without saying where the choice
   lives, while PRD 0005's API sketch passes `.ack` per `append` call.
   Disagreement cannot fork the ledger, which
   suggests local config or a call parameter with a configured default.
   *Blocks:* PRD 0001 phase 4 API defaults. *Answer from:* the operator; also
   clanker's RFC 0019 open question 1 ("stall or keep working").
38. **Service API auth.** If RFC 0001 keeps a service API, what authenticates
    a caller off loopback — a static token, member keys, mTLS? v1 drafts
    loopback-only with a warning. *Blocks:* PRD 0005 phase 4.
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
58. **Ordering of concurrent `join`s within one batch.** The admitter decides
    *when* to write a `join`, so it can order concurrent admissions — never
    ahead of an already-slotted member, which is the bound RFC 0002 accepts
    (its option A). Ordering same-batch joins by newcomer id instead of
    receipt order would remove that discretion entirely, at the cost of one
    fold rule. Cheap to decide while the format is unfrozen.
    *Blocks:* PRD 0003 phase 1 (membership fold). *Answer from:* the
    operator.

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
57. **Is author-marked staleness itself switchable per ledger?** [ADR
    0002](adrs/0002-entries-are-immutable-ttl-and-author-staleness-are-the-only-mutations.md)
    records that *whether either cause is active … [is] a per-ledger
    setting*, and its title calls both mutations opt-in. But the schema
    drafted in [PRD 0002](prds/0002-ttl-and-staleness.md) has no setting
    that turns the `stale` cause off: `stale.who` names who may mark
    (always `author` in v1) and `stale.cleanup` only decides what happens
    *after* a mark. The brief reads both ways ("a toggle to allow mutability
    for automatic cleanup via TTL **or** marking entries stale"). Options:
    add a `stale.enforce`-style key (and define what `off` means for an
    entry already marked), or narrow the accepted record's claim to TTL
    enforcement when it is next touched. Must settle before the settings
    schema is generated ([PRD 0004](prds/0004-settings.md) phase 1).
    *Blocks:* PRD 0004 phase 1, not the core. *Answer from:* the operator.

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
55. **Size bounds still without values.** PRD 0001 G6 requires the ledger cap
    (`cluster.max_ledgers`) and the unslotted-queue bound
    (`sync.unslotted_max_bytes`) enforced with a test that trips each, but
    neither has a default or an overflow behaviour yet: what `append` returns
    when the queue is full (refuse locally? evict the oldest unslotted
    entry?), and what hitting the ledger cap refuses (creation only, or
    `genesis` too?). Siblings of OQ 36 for the two
    bounds the core cannot ship without. *Blocks:* PRD 0001 phase 3–4
    defaults.
56. **The `sync.*` knobs have no layer and no values.** Three settings are
    named in the PRDs but appear in no settings table: `sync.page_bytes`
    (backfill page bound, PRD 0001 *Backfill*), `sync.lag_slots` (when a
    `syncing` member counts as at head, and so leader-eligible, PRD 0003
    *Member states*), and `sync.gap_timeout_ms` (when a held gap is refused
    `unknown_target`, PRD 0002 failure modes). For each: is it local config
    or a chain setting — disagreeing on `lag_slots` could elect different
    leaders, which suggests chain; a page size only risks its own tail,
    which suggests local — and what is the default? Sibling of OQ 55.
    *Blocks:* PRD 0001 phase 3 (backfill), PRD 0003 phase 1 (member
    states).

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
    0005 phase 5. *Answer from:* the operator, jointly with clanker's RFC
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
    PRD 0005 phase 3.
32. **Clock assumptions.** `slot_ts_ms` is the leader's wall clock; TTL
    depends on it; nothing depends on monotonic time except failure
    detection. Document the assumption (NTP-disciplined, skew in seconds not
    hours) and what breaks outside it (early/late visibility only, never
    divergence). *Blocks:* nothing; documentation.
41. **Record-store tooling.** clanker maintains its `docs/` stores with
    sandboxed tools (`clanker rfc`, `clanker adr`, …) that write
    compare-and-swap and keep the inventories in sync. spine's stores are
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
59. **Does the fetchable package carry the design docs?** The `.paths` list
    in `build.zig.zon` — the declaration of what the package contains —
    names only `CHANGELOG.md`, `README.md`, `RELEASES.md`, `build.zig`,
    `build.zig.zon` and `src/`. Every design record lives under `docs/`,
    and PRD 0001 says a document "is the spec" until code replaces it, so a
    host that adds spine as a dependency gets a library whose spec is not in
    the package (SQLite and dqlite ship theirs). Excluding
    [qnd-notes.md](../qnd-notes.md) is clearly right; excluding `docs/` was
    never stated as a decision. Decide either way before the first host
    fetches spine ([PRD 0005](prds/0005-embedding-the-library-as-the-product.md)
    phase 5) or the first public release. *Blocks:* PRD 0005 phase 5.
    *Answer from:* the operator.

## I. Scaling past one group (PRD 0006)

48. **Grouping unit and range key.** Ownership by whole ledger is the
    drafted unit; the drafted split key is the author-id prefix so each
    author's stream stays in one group. Is that enough for hosts whose
    ledgers have many authors and one hot range, or is a payload-derived
    key needed (which breaks `author_seq` density)? *Blocks:* PRD 0006
    phase 3. *Answer from:* OQ 46's host shapes; measurement.
49. **When does the group count need to be uneven?** Under `seniority`,
    `configured` and `combined` a federation of 2 or 4 groups elects like 2
    or 4 members do; only a majority-vote (`quorum`) mode at the federation
    level needs an odd count.
    **Resolved 2026-08-21** (operator confirmed): groups use the same
    leadership modes and the same concurrency model as members — election is
    a pure function over an abstract member type, and a group supplies the
    same five inputs (identity = genesis hash, seniority = its `join` slot in
    the federation ledger, address, liveness and sync via its current
    representative). An uneven group count is therefore **not** a
    requirement; it would become one only if a `quorum` mode were chosen at
    the federation level, which is roadmap and not designed. Recorded in
    [PRD 0006](prds/0006-scaling-to-groups-sharding-and-parity.md) (*A group
    is the system*). Two consequences of the derived liveness are design
    rules there: federation validation checks a representative against its
    group's own chain, and federation `suspect_after_ms` must exceed a
    group's internal election time.
50. **Parity code and reconstruction cost.** Reed–Solomon over GF(2⁸) in
    `std`-only Zig is feasible; k, m defaults, fragment size, and what a
    read of a parity range costs (k network fetches + decode) against a
    follower copy are unmeasured. Also: does parity apply to the chain's
    *slots* or only to payloads, given `ttl.retain`? *Blocks:* PRD 0006
    phase 4.
51. **Cross-group routing and read semantics.** Forwarding an append to the
    owner is drafted; a read of a non-owned ledger either forwards (one
    round-trip, fresh) or hits a follower copy (local, lagging). Which is the
    default, and does `write.ack` mean "owner slotted" or "local forwarded"?
    Relates to OQ 3 and OQ 31. *Blocks:* PRD 0006 phase 2.
52. **What group identity must the core headers carry now?** Drafted:
    segment headers carry ledger id + sequencing group id; entry and slot
    headers carry neither (the slot's `leader` member id implies the group
    via that group's chain). Is the implication enough for a verifier in
    another group, or should the slot carry the group id explicitly (16 more
    bytes per slot, forever)? *Blocks:* PRD 0001 phase 1 — the format freeze.
53. **Membership and discovery at 10⁵.** A new instance must find *a*
    member of *some* group: seed lists in local config (drafted), a
    directory ledger in the federation, or DNS. Which, and how does an
    instance choose a group to join (operator-assigned, nearest, smallest)?
    *Blocks:* PRD 0006 phase 1.
54. **Measurements that replace the tier numbers.** 32 per group and
    ~1,000 / ~100,000 per tier are intent. The first measurement set: size-1
    append latency; per-member connection count and memory at 8, 16, 32
    members; append-to-visible p50/p99 across one group; join/backfill time
    for a 1 GB ledger; then the same at 3 × 8 and 10 × 8 in two groups of
    groups. Where is the harness and what hardware counts? *Blocks:*
    promoting any tier number from intent to claim.

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
- **Locality and placement** — which group a consumer's appends go to when
  several could own a new ledger; geography-aware placement is a federation
  policy nobody has specified.
- **Cross-group stale marks and checkpoints** — a `stale` is authored where
  the author lives, but the ledger lives in its owning group; forwarding
  makes it work, but the checkpoint cadence is the owner's clock.
