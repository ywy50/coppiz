# Open questions

The cross-cutting register of what the design does not yet settle. Every
PRD and RFC points here by number (`OQ n`); numbers are stable - a resolved
question keeps its number and gets a **Resolved** [RESOLVED] line naming the record
that settled it (an ADR, a PRD Design section, or a measurement), never a
deletion. Add new questions at the end of the section they belong to.

Ordering inside each section is by what blocks implementation first.
"Blocks" names the phase that cannot start until the answer exists.
Numbers are stable IDs assigned as questions were raised; sections
order them by blocking priority, so the numbers are not sequential
within a section. Every entry is anchored (`#oq-n`) for direct links
and tagged `OPEN`, `RESOLVED` (with the record that settled it) or
`PARTIAL`.

## A. Trust and product stance

<a id="oq-1"></a>
1. **What is the trust model - crash faults only, or misbehaving members?** [OPEN]
    The decision is explored in
    [RFC 9](rfcs/0009-trust-model.md) (Discussion); this entry is the
    stable pointer. *Blocks:* nothing yet; the merge rule and any future `quorum` mode read against it.
<a id="oq-2"></a>
2. **At n = 2 under `seniority`, is AP-with-merge the right default?** [RESOLVED] Two
   leaders during a partition, healed by deterministic re-slotting (PRD
   0003), versus `configured` + `stall` where the non-authority side refuses
   writes. The brief's "2 instances … define a specific one who is the
   leader" suggests the second is what an operator reaches for at n = 2; the
   drafted default mode is `seniority`. *Blocks:* none - the drafted default
   shipped with PRD 0003.
   **Resolved 2026-08-29** (operator): `seniority` stays the default - the
   AP-with-merge posture at n = 2 is accepted, with `configured` + `stall`
   available per cluster as the CP alternative.
<a id="oq-3"></a>
3. **Default `write.ack`: `local` or `slotted`?** [OPEN] `local` keeps a partitioned
   member writing (AP); `slotted` waits for a position (CP-ish, and even then
   a position can move once at merge unless the mode forbids two leaders).
   The shipped write path acknowledges at the slot everywhere - `node.append`,
   the wire append and `cluster.ClusterNode.localAppend` all block until the
   slot folds back (`localAppend`'s docstring names a `write.ack = local`
   variant as this open question) - so what is open is a `local` ack option
   and its *layer*: PRDs 0001 and 0006 call `write.ack` a setting
   (`local | slotted`, honoured by the owning group), PRD 0003 assumes a
   writer can ask for `slotted` without saying where the choice lives.

   Disagreement cannot fork the journal, which
   suggests local config or a call parameter with a configured default.
   *Blocks:* none (the slot-ack write path shipped); the `local` variant and
   its layer stay open. *Answer from:* the operator; also
   clanker's RFC 0019 open question 1 ("stall or keep working").
<a id="oq-38"></a>
38. **Service API auth.** [OPEN]
    What authenticates a service-API caller off loopback? The decision is
    explored in [RFC 0007](rfcs/0007-service-api-auth.md) (Discussion);
    this entry is the stable pointer. *Blocks:* PRD 0005 phase 4 (the
    deferred wrapper).
<a id="oq-40"></a>
40. **Public claims need reopening.** [RESOLVED] Everything in research 0001 is carried
    from clanker's reading dates; before the README or a release cites an
    external fact, reopen it.
    **Resolved 2026-08-27** (operator): the external claims the public README
    cites were reopened at their sources in this repo - etcd, rqlite,
    dqlite, TigerBeetle, and the Zig-store-gap search - and are marked
    "reopened" in [research 0001](research/0001-evidence-carried-from-the-state-store-survey.md)'s
    evidence log with read dates of 2026-08-27. The remaining rows of that
    note stay flagged as carried from clanker and are not cited by the
    README. *Blocks:* first public release.

## B. Ordering, epochs and merge

<a id="oq-7"></a>
7. **One chain per journal, or one per cluster?** [RESOLVED] Per journal (as drafted)
   keeps journals independently prunable and lets a consumer follow one
   stream cheaply; per cluster gives a single `(epoch, seq)` for everything
   and one place for cluster-scoped settings. The compromise - a control
   journal for cluster-scoped entries plus per-journal data chains - doubles
   the fold. *Blocks:* PRD 0001 phase 2 (fold). *Answer from:* design; decide
   before the on-disk format freezes.
   **Resolved 2026-08-27** (design, at the format freeze): one chain per
   journal, with the cluster's control journal its own chain carrying
   `genesis`, `create_journal`, cluster-scoped `settings`, and (with PRD
   0003) membership and epochs. Recorded in PRD 0001's status.
<a id="oq-8"></a>
8. **Per-journal or cluster-level leadership?** [OPEN]
    The decision is explored in
    [RFC 10](rfcs/0010-per-journal-leadership.md) (Discussion); this entry is the
    stable pointer. *Blocks:* none - v1 shipped cluster-level leadership; the reopen trigger is a measured single-leader saturation.
<a id="oq-11"></a>
11. **An `author_seq` gap that never fills; refused entries consume a seq.** [RESOLVED]
    A member that crashes after assigning `author_seq = n` locally but before
    forwarding leaves a permanent hole; a refused entry (e.g. a `stale` for
    someone else's entry) also burns a number. Options: allow gaps (dense
    becomes monotone; dedup still works), or make the author re-announce its
    head on reconnect so the leader can close the gap. *Blocks:* PRD 0001
    phase 2 validation.

    **Resolved 2026-08-27** (design): gaps allowed - `author_seq` is
    monotone per (author, journal), and the fold dedups redeliveries by
    looking the entry id up in its table (an entry at or below the author's
    last seq is accepted only when byte-identical to the recorded one), so
    the unslotted-queue replay after a crash is idempotent. Recorded in PRD
    0001's status.
<a id="oq-12"></a>
12. **`tiebreak = freshest` semantics.** [RESOLVED] "Highest acknowledged `(epoch,
    seq)`" across epochs is not totally ordered after a merge; the draft
    freezes the evaluation at election. Is the extra mode worth its
    definition cost, given `syncing` members are already excluded? *Blocks:*
    none - the mode shipped with the `seniority` default and election-time
    freezing.
    **Resolved 2026-08-29** (operator): `freshest` stays a selectable
    `tiebreak` value with the shipped election-time semantics.
<a id="oq-31"></a>
31. **Read consistency.** [OPEN]
    The decision is explored in
    [RFC 18](rfcs/0018-read-consistency.md) (Discussion); this entry is the
    stable pointer. *Blocks:* nothing in v1; shapes the read API.
<a id="oq-33"></a>
33. **Conflicting `settings` on two branches.** [RESOLVED] After a merge the surviving
    branch's value wins and the losing branch's `settings` entries are
    re-slotted as no-ops (PRD 0004). Should they instead re-apply in order
    (last writer wins by merged position)?
    **Resolved 2026-08-27** (operator): no-op re-slot, as drafted - the
    survivor's value wins; the losing side's `settings` entries re-slot as
    no-ops. Re-applying in order stays a merge-rule change away. Recorded in
    PRD 0003's status.
    *Blocks:* PRD 0003 phase 3.
<a id="oq-37"></a>
37. **Failure-detector timings and leader lease.** [OPEN] Heartbeat 1 s, suspect at
    5 s are placeholders. Is there a leader *lease* (the old leader stops
    slotting when it cannot hear a majority of its last-known members), or
    does it keep slotting until it sees a newer epoch? Without a lease, a
    leader that is partitioned from everyone keeps writing on its own
    branch - which is the AP behaviour, so this is OQ 2 again from the
    leader's side. *Blocks:* PRD 0003 phase 5.
<a id="oq-60"></a>
60. **`merge.settle_ms` default.** [OPEN] 30 s is a placeholder, on the record like
    the failure-detector timings above (OQ 37):
    [PRD 0002](prds/0002-ttl-and-staleness.md) bars a checkpoint for slots
    newer than the last `merge` until it passes, so the value must exceed the
    clock skew between the two leaders over the partition (or the surviving
    side computes an expiry instant the losing side never meant) while not
    stalling cleanup after every heal. Nothing bounds or derives it yet;
    its siblings are `cluster.suspect_after_ms` and `checkpoint.every_ms`.
    *Blocks:* PRD 0002 phases 4–5, PRD 0003 phase 3 (merge). *Answer from:*
    measurement, against the same skew data OQ 9 wants.

## C. Membership

<a id="oq-4"></a>
4. **Seniority on rejoin.** [OPEN]
    The decision is explored in
    [RFC 13](rfcs/0013-seniority-on-rejoin.md) (Discussion); this entry is the
    stable pointer. *Blocks:* none - phase 1 shipped with 'only a `leave` resets seniority'.
<a id="oq-5"></a>
5. **Changing leadership settings when `reconfigurable = false`.** [OPEN]
    The decision is explored in
    [RFC 14](rfcs/0014-offline-reconfigure.md) (Discussion); this entry is the
    stable pointer. *Blocks:* none in the shipped surface; `coppiz reconfigure` is not a command yet.
<a id="oq-20"></a>
20. **Eviction of dead members.** [OPEN]
    The decision is explored in
    [RFC 15](rfcs/0015-eviction.md) (Discussion); this entry is the
    stable pointer. *Blocks:* none - eviction shipped (`membership.evict_after_ms`, default 0).
<a id="oq-21"></a>
21. **How the allowlist learns a newcomer's key.** [OPEN]
    The decision is explored in
    [RFC 16](rfcs/0016-allowlist-key-learning.md) (Discussion); this entry is the
    stable pointer. *Blocks:* none - admission shipped; the key-learning mechanism is this RFC's answer.
<a id="oq-22"></a>
22. **Key rotation and compromise; an operator key.** [OPEN]
    The decision is explored in
    [RFC 17](rfcs/0017-key-rotation-operator-key.md) (Discussion); this entry is the
    stable pointer. *Blocks:* nothing in v1; must be decided before 1.0 because it changes the `join` payload / adds a control entry.
<a id="oq-25"></a>
25. **Topology past 32 members.** [OPEN]
    The decision is explored in
    [RFC 11](rfcs/0011-topology-past-32.md) (Discussion); this entry is the
    stable pointer. *Blocks:* nothing until a cluster approaches the cap.
<a id="oq-58"></a>
58. **Ordering of concurrent `join`s within one batch.** [RESOLVED] The admitter decides
    *when* to write a `join`, so it can order concurrent admissions - never
    ahead of an already-slotted member, which is the bound RFC 0002 accepts
    (its option A). Ordering same-batch joins by newcomer id instead of
    receipt order would remove that discretion entirely, at the cost of one
    fold rule. Cheap to decide while the format is unfrozen.
    **Resolved 2026-08-27** (operator): slot order - the admitter's receipt
    order is the chain's order, which makes the fold deterministic by
    construction; ordering same-batch joins by newcomer id remains a
    one-fold-rule change. Recorded in PRD 0003's status.
    *Blocks:* PRD 0003 phase 1 (membership fold). *Answer from:* the
    operator.

## D. TTL, staleness and retention

<a id="oq-6"></a>
6. **Who may mark stale beyond the author.** [OPEN] The brief is explicit that only
   the author may; the schema key `stale.who` exists so `leader` or an
   operator role can be added. Is there a use case (cleaning up after a dead
   member) strong enough to add it? *Blocks:* nothing in v1.
<a id="oq-9"></a>
9. **`ttl.grace_ms` default and derivation.** [OPEN] Read-side skew tolerance.
   Could be derived from the observed offset between local clock and the
   leader's `slot_ts_ms` at the head. *Blocks:* none - the default (0)
   shipped; derivation from observed skew stays open.
<a id="oq-10"></a>
10. **Checkpoint cadence defaults.** [OPEN] 60 s / 64 MiB are placeholders. Too
    frequent spams control entries on every member; too rare delays reclaim.
    *Blocks:* PRD 0002 phase 4.
<a id="oq-24"></a>
24. **Slot count grows forever.** [OPEN] Under `retain = none` a removed entry still
    costs one slot (~170 bytes) forever, because removing a slot breaks the
    chain. A long-lived high-churn journal needs an *archival checkpoint*: a
    leader-signed root over a prefix that lets members drop the slots
    behind it while keeping verifiability from the root. That is a second
    chain-level mechanism and is out of v1. When does it become necessary?
    *Blocks:* nothing in v1; measure slot growth on the first consumer.
<a id="oq-43"></a>
43. **What "full state" means under `retain = none`.** [OPEN] A member that joined
    after a checkpoint never sees removed payloads; it has the full *chain*
    but not every byte that ever existed. PRD 0003's "definitely has the
    full state" should be defined as "at head of the chain", and the docs
    should say so. Reachable since the leader's checkpoint cadence landed
    (PRD 0002 phases 4–5): the sync path refuses compacted records
    (`onSyncPage` closes the connection on a record with no entry), so a
    journal that has checkpointed cannot be joined or backfilled until this
    is answered. *Blocks:* PRD 0003 phase 1 wording; the sync path's
    refusal is the current behaviour.
<a id="oq-57"></a>
57. **Is author-marked staleness itself switchable per journal?** [RESOLVED] [ADR
    0002](adrs/0002-entries-are-immutable-ttl-and-author-staleness-are-the-only-mutations.md)
    records that *whether either cause is active … [is] a per-journal
    setting*, and its title calls both mutations opt-in. But the schema
    drafted in [PRD 0002](prds/0002-ttl-and-staleness.md) has no setting
    that turns the `stale` cause off: `stale.who` names who may mark
    (always `author` in v1) and `stale.cleanup` only decides what happens
    *after* a mark.

    The brief reads both ways ("a toggle to allow mutability
    for automatic cleanup via TTL **or** marking entries stale"). Options:
    add a `stale.enforce`-style key (and define what `off` means for an
    entry already marked), or narrow the accepted record's claim to TTL
    enforcement when it is next touched.

    Must settle before the settings
    schema is generated ([PRD 0004](prds/0004-settings.md) phase 1).
    **Resolved 2026-08-27** (operator): the `stale` cause is switchable per
    journal, matching ADR 0002. [PRD 0002](prds/0002-ttl-and-staleness.md)'s
    settings table gains `stale.enforce = off | author` (default `off`; a
    `stale` entry is refused while `off`) and defaults `stale.cleanup` to
    `keep`. Both removal causes are now a hard opt-in per journal, off by
    default, live-changeable and prospective - a `settings` entry takes
    effect only for entries slotted after it ([PRD
    0004](prds/0004-settings.md)).
    *Blocks:* PRD 0004 phase 1, not the core. *Answer from:* the operator.

## E. Storage and format

<a id="oq-13"></a>
13. **Does `author_ts_ms` belong in the signed header?** [RESOLVED] It is informational,
    never used for order or expiry; removing it shrinks every entry by 8
    bytes and removes a field consumers might wrongly trust. *Blocks:* PRD
    0001 phase 1 (cheap before the format freezes).
    **Resolved 2026-08-27** (by the format freeze): the field shipped in the
    signed entry header - the codec, fold and PRD 0001 all carry it; removing
    it now is a format break, not the cheap change the draft called it.
<a id="oq-14"></a>
14. **`fsync` defaults.** [RESOLVED] `every` on the leader and `batched` on followers as
    drafted. A follower that loses its tail re-backfills, so `batched` is
    safe for it; is `every` on the leader acceptable at the write rates
    clanker needs (tens per second, not thousands)? *Blocks:* none - phase 3
    shipped with `storage.fsync = every` as the local-config default
    (followers may set `batched`). *Answer from:* measurement.

    **Resolved 2026-08-29** (measurement): yes - per-append write+fsync
    measured ~5-10 ms p50-p99 on btrfs/NVMe, so the leader's serial write
    path sustains ~100-200 durable appends/s and clanker's tens-per-second
    rate uses a fraction of it. `every` on the leader stands
    ([research 0003](research/0003-fsync-default-measurement.md)). What the
    knob governs is [ADR 0008](adrs/0008-storage-fsync-governs-the-queue.md).
<a id="oq-17"></a>
17. **Snapshot format.** [OPEN]
    The decision is explored in
    [RFC 22](rfcs/0022-snapshot-format.md) (Discussion); this entry is the
    stable pointer. *Blocks:* none - phase 3 shipped without snapshots; the join-cost trigger is in OQ 54.
<a id="oq-26"></a>
26. **Format versioning and rolling upgrade.** [OPEN]
    The decision is explored in
    [RFC 23](rfcs/0023-rolling-upgrade.md) (Discussion); this entry is the
    stable pointer. *Blocks:* first release.
<a id="oq-36"></a>
36. **Maximum entry size and large payloads.** [PARTIAL] `journal.max_entry_bytes`
    default is unset. clanker's streams are 1–2 KB lines; sessions are up to
    1.75 MB and are explicitly *not* a first consumer. A blob shape (chunked
    entries, or content-addressed side storage) is roadmap. *Blocks:* PRD
    0001 phase 4 defaults.
    **Resolved in part 2026-08-27** (provisional default): 16 MiB ships in
    the schema, marked provisional (OQ 36); the right value from measurement
    stays open. *Blocks:* none - phase 4 shipped with the provisional
    default.
    **Resolved 2026-08-29** (operator): the value stays operator-configurable
    - the key is a live-changeable journal setting - and the provisional
    16 MiB default stands until measurement replaces it.
<a id="oq-39"></a>
39. **Backup and restore.** [OPEN]
    The decision is explored in
    [RFC 24](rfcs/0024-backup-restore.md) (Discussion); this entry is the
    stable pointer. *Blocks:* first release.
<a id="oq-55"></a>
55. **Size bounds: defaults shipped, overflow behaviour settled.** [RESOLVED] PRD 0001
    G6 requires the journal cap (`cluster.max_journals`) and the
    unslotted-queue bound (`sync.unslotted_max_bytes`) enforced with a test
    that trips each. Provisional defaults now ship for all three bounds
    (`cluster.max_journals` 1024, `sync.unslotted_max_bytes` 64 MiB,
    `journal.max_entry_bytes` 16 MiB - the last at OQ 36), and the overflow
    behaviour is settled by code: `append` refuses `queue_full` when the
    queue bound is hit, a too-large payload refuses `too_large`, and journal
    creation refuses past the cap.

    What remains open: whether those values
    and refusals are the right ones, and whether `genesis` is refused too
    when the cluster is already at the cap. Sibling of OQ 36. *Blocks:*
    none - the bounds shipped and G6 trips them; the values stay
    provisional.

    **Resolved 2026-08-29** (operator): the bounds are operator-configurable
    - the journal cap and entry size are chain settings, the queue bound a
    local-config key - and the provisional defaults stand until measurement.
    The `genesis`-at-cap refusal question stays open.
<a id="oq-56"></a>
56. **The `sync.*` knobs have no layer and no values.** [OPEN] Three settings are
    named in the PRDs but appear in no settings table: `sync.page_bytes`
    (backfill page bound, PRD 0001 *Backfill*), `sync.lag_slots` (when a
    `syncing` member counts as at head, and so leader-eligible, PRD 0003
    *Member states*), and `sync.gap_timeout_ms` (when a held gap is refused
    `unknown_target`, PRD 0002 failure modes). `sync.page_bytes` got a
    provisional local value (64 KiB, `provisional_page_bytes` in node.zig)
    and `sync.unslotted_max_bytes` a local-config key (OQ 55); the other two
    still have no layer and no value.

    For each: is it local config
    or a chain setting - disagreeing on `lag_slots` could elect different
    leaders, which suggests chain; a page size only risks its own tail,
    which suggests local - and what is the default? Sibling of OQ 55.
    *Blocks:* none - backfill and member states shipped with the provisional
    values.
    (Operator, 2026-08-29: `sync.page_bytes` must be operator-configurable,
    not a hardcoded constant - a local-config key replaces
    `provisional_page_bytes`; that is a code change. `lag_slots` and
    `gap_timeout_ms` stay open.)

<a id="oq-61"></a>
61. **What bounds per-process memory?** [OPEN] [PRD 0001](prds/0001-journal-core.md)
    goal 6 requires entry size, journal count *and per-process memory* to be
    bounded by settings, but only the first two have keys
    (`journal.max_entry_bytes`, `cluster.max_journals`; the unslotted queue adds
    `sync.unslotted_max_bytes`, OQ 55) - no memory bound exists anywhere in
    the drafted schema, and no acceptance criterion covers the clause. What
    is the knob (a fold/snapshot cache cap, a per-journal page budget,
    nothing before measurement?), and what does a member do at the bound?
    Sibling of OQs 36 and 55.
    *Blocks:* none - phases 3–4 shipped without a memory bound; the knob and
    the behaviour at the bound stay open. *Answer from:* measurement, like
    OQ 54.

<a id="oq-62"></a>
62. **What makes the cluster e2e spin a core for minutes, intermittently?** [OPEN]
    Running a test binary directly (not through `zig build test`'s protocol)
    stuck three times at ~100% CPU for 10+ minutes in three io worker
    threads - twice at `e2e (G4)` (node.zig:3118) and once at the journal
    member-key test - while the gate runs stayed green (3/3). The loop,
    mailbox and hub transport are all semaphore-based (no busy-poll found by
    reading; stacks could not be captured, ptrace blocked). If a node loop
    livelocks, the same path could burn a production core. *Answer from:* a
    repro under a tracer (strace/perf on the spinning threads), or a bisect
    of the checkpoint/TTL path G4 exercises.

    *Trigger:* the investigation 2026-08-28 (test-build speedup) - see its
    resolution.
    *Status:* still open. Two gdb-launched repro attempts ran the direct
    binary to completion without the spin; no reproduction in ~20 direct
    runs since the pass-2 busy-spin removal (the 3/3 original was observed
    with the busy-spins still in) - consistent with that change having
    removed the trigger, but no root cause established.
    The 2026-08-29 sweep reproduced it once inside a gate run (112% CPU,
    9+ minutes; no stack) - the only gate-run reproduction to date.

    *2026-08-29 - first stack captured.* Reproduced twice in the same day
    under `zig build test` on a machine running the suite twice concurrently
    (an overlapping run duplicated the command): a lib_tests binary at
    112–146% CPU for 8–18 minutes at `e2e (G4)`. SIGABRT + systemd-coredump
    + gdb (no ptrace needed on the core) captured the spinning thread: an io
    worker in `Store.rebuildIndex` → `jd.index.put` (the position→IndexEntry
    AutoHashMap) inside `Store.compact` ← `compactRemoved` ←
    `checkpointForBroadcast` ← `driveCheckpoints` ← `onTick` ← `loopMain`
    (the G4 TTL-trio leader, teardown in progress: main thread in
    `waitForStop`).

    `std.hash_map`'s probe loop is bounded by table
    capacity, so a long `put` means an overfull table (every probe walks the
    whole capacity) - the observed burn is consistent with the index map's
    `available` accounting going wrong under repeated
    `clearRetainingCapacity` + refill (compaction rebuilds the index on
    every checkpoint), degrading each insert to O(capacity). The compact/
    rebuildIndex path is unchanged by the 2026-08-29 speedup PRs; the
    original 3/3 observations were also at G4.

    Next: a repro script that
    runs the G4 test under doubled load, then a bisect of
    `clearRetainingCapacity`/`available` accounting or a switch of the
    store index to `ensureTotalCapacity`-pre-sized rebuilds with an
    explicit assertion that `available` is never exhausted mid-rebuild.

    *2026-08-29 (follow-up) - the state-carrying path removed defensively.*
    `Store.rebuildIndex` now deinitializes and re-initializes the position
    map instead of `clearRetainingCapacity`-and-refill, eliminating the
    cross-rebuild state-carrying path the captured stack implicated
    ([investigation](reports/investigations/2026-08-29-oq62-index-rebuild-hardening.md) - linked
    from the sweep findings). This is hardening, not a claimed fix: the
    root cause is still unconfirmed.

    The second captured stack (an io
    worker in `checkpointForBroadcast` → `Store.append` → `fsync`) was
    checked and reads as the G4 leader's normal checkpoint cadence under
    load, not a second spin mechanism. The repro + bisect above still
    stands as the way to close the question.

## F. Transport and wire

<a id="oq-19"></a>
19. **Replication wire: own binary framing or HTTP?** [RESOLVED] clanker's spike used
    HTTP because it was there; a member-to-member protocol with heartbeats,
    streaming slots and backfill pages is more naturally a length-prefixed
    binary stream over one TCP connection. If RFC 0001's option D (observer
    clients) is to stay possible, the protocol must be specified. *Blocks:*
    PRD 0003 phase 4.

    **Resolved 2026-08-27** (design, at PRD 0003 phase 4): own binary
    framing over one TCP connection - 4-byte little-endian length prefix,
    then a body whose first byte is the wire version and second the message
    kind (all other integers little-endian, as in every coppiz format).
    The slot/entry records inside `slot`, `sync_page` and `read_page` reuse
    the on-disk segment record codec, so one codec serves disk and wire.

    The transport is a thin seam (`Conn`/`Listener`/`Transport` in
    `src/net/transport.zig`) with two implementations: TCP, and an
    in-memory hub whose directed edges `drop` and `heal` - the same loop
    code runs under both, which is the OQ 27 shape. Recorded in PRD 0003's
    status and implemented in `src/net/`.
<a id="oq-23"></a>
23. **Wire encryption.** [OPEN]
    What protects member-to-member traffic off a private network? The
    decision is explored in [RFC 0008](rfcs/0008-wire-encryption.md)
    (Discussion); this entry is the stable pointer. *Blocks:* any
    non-private deployment.
<a id="oq-28"></a>
28. **Backpressure.** [OPEN]
    The decision is explored in
    [RFC 12](rfcs/0012-backpressure.md) (Discussion); this entry is the
    stable pointer. *Blocks:* none - the transport shipped; the slow-follower policy is this RFC's answer.
<a id="oq-15"></a>
15. **Library-first or service-first.** [RESOLVED] [RFC 0001](rfcs/0001-library-first-or-service-first.md).
    *Blocks:* PRD 0005 phases 1 and 3.
    **Resolved 2026-08-28** (operator): option A - library-first. The library
    is the primary surface, the node binary its wrapper, and the service API
    stays deferred as a wrapper module behind the first non-Zig consumer.
    Recorded in [ADR 0007](adrs/0007-the-library-is-the-primary-surface.md);
    PRD 0005's steps 1–3 shipped with the decision.
<a id="oq-30"></a>
30. **Integration path with clanker.** [OPEN] clanker's RFC 0019 stage-1 spike is
    specified in clanker's tree and unrun. Run it there first (throwaway) and
    then build coppiz, or build coppiz's core and make the spike *use* coppiz?
    The second avoids building the cursor logic twice; the first gives
    clanker an answer without waiting. Which code survives? *Blocks:* PRD
    0005 phase 5. *Answer from:* the operator, jointly with clanker's RFC
    0019 next steps.
<a id="oq-34"></a>
34. **Journal lifecycle.** [PARTIAL]
    The decision is explored in
    [RFC 19](rfcs/0019-journal-lifecycle.md) (Discussion); this entry is the
    stable pointer. *Blocks:* none - phase 4 shipped with leader-only creation; the drop half is this RFC's answer.
<a id="oq-35"></a>
35. **TOML parser for `coppiz.toml`.** [RESOLVED] Vendor clanker's (same toolchain,
    already patched for 0.16) or hand-roll the subset the local config
    needs. ADR 0001 allows vendoring, not fetching. *Blocks:* PRD 0004
    phase 4.
    **Resolved 2026-08-27** (implementation): hand-rolled subset parser in
    `src/config/local.zig` - a closed key set, quote-aware since the
    2026-08-29 TOML fixes; no `vendor/` directory exists, so ADR 0001's
    vendor allowance went unused.
<a id="oq-42"></a>
42. **Cursor and id encoding for consumers.** [OPEN]
    The decision is explored in
    [RFC 20](rfcs/0020-cursor-id-encoding.md) (Discussion); this entry is the
    stable pointer. *Blocks:* none - the API shipped; the HTTP encoding is decided at wrapper time.
<a id="oq-46"></a>
46. **Which non-clanker hosts are the design targets?** [OPEN]
    The decision is explored in
    [RFC 21](rfcs/0021-host-shapes.md) (Discussion); this entry is the
    stable pointer. *Blocks:* nothing; shapes PRD 0005's API before it freezes.
<a id="oq-47"></a>
47. **Several processes on one data directory, SQLite-style.** [OPEN]
    Is the SQLite habit - several processes opening one data directory
    natively - important enough to hosts to make it a v1 property? The
    decision is explored in
    [RFC 0006](rfcs/0006-multi-process-one-data-directory.md) (Discussion);
    this entry is the stable pointer and its status follows the RFC's.
    *Blocks:* none - v1 shipped the flock + wire-fallback model ("the
    long-lived process owns the directory").

## H. Project, process and quality

<a id="oq-16"></a>
16. **The name.** [RESOLVED] `spine` is the codename from clanker's RFC 0019 ("the
    spine") and is generic enough to collide on package indexes and search.
    Decide before publishing; check the Zig package namespace, GitHub, and
    crates/npm for collisions. Candidates considered: `spine`, `journallet`,
    `zjournal`, `tally`, `quill`, `rostrum`, `accrete`, `crescent`,
    `creszent`, `bonsai`, `bonzai`, `coppice`, `tabula`, `weir`, `coppiz`.

    **Resolved 2026-08-27** (operator): the product is named `coppiz` -
    [ADR 0004](adrs/0004-the-product-is-named-coppiz.md). The library
    module, node binary, `build.zig.zon` `.name` and `coppiz.toml` use
    that identifier. Spoken English lands on *copies*; the coppice
    metaphor (stools persist, poles harvested) is the one the spelling
    carries, not the COP-iss pronunciation.
    *Blocks:* none; was first public release.
<a id="oq-18"></a>
18. **Licence.** [RESOLVED] Not chosen. clanker's research tracked licences of every
    surveyed store (BUSL, CSL, Apache, MIT) as a selection criterion; coppiz
    should be unambiguous from the first public commit.
    **Resolved 2026-08-27** (operator): Apache-2.0 - [ADR
    0006](adrs/0006-the-library-is-apache-2-0-licensed.md); the `LICENSE`
    file and the `license` field in `build.zig.zon` (with `LICENSE` in its
    `.paths`) ship it. *Blocks:* first public commit; also a `LICENSE` path
    in `build.zig.zon`.
<a id="oq-27"></a>
27. **Testing strategy: deterministic simulation.** [RESOLVED] TigerBeetle's VOPR-style
    simulator (a seeded, single-threaded run of many nodes with injected
    partitions, crashes, clock skew and message reorder) is the one testing
    discipline clanker's research named worth copying. PRD 0001–0003's
    "pure fold, pure election, pure merge" split is what makes it possible.
    Decide early: is the simulator phase 0 of the cluster work, or a later
    addition?
    **Resolved 2026-08-27** (operator): now, before the node loop - the
    simulator over the pure fold/election/merge functions ships with PRD
    0003 phases 1–3, and the node loop is written to be drivable by it.
    Recorded in PRD 0003's status.
    *Blocks:* PRD 0003 phase 1 (it changes how the node loop is written).
<a id="oq-29"></a>
29. **Observability.** [OPEN] `coppiz status` / `node.status()`: leader, epoch, head,
    members and states, lag per follower, pending checkpoint bytes, last
    merge. Metrics format (Prometheus text?) and where logs go. *Blocks:*
    none - `coppiz status`/`members`/`doctor` shipped; the metrics format
    and log destination stay open.
<a id="oq-32"></a>
32. **Clock assumptions.** [RESOLVED] `slot_ts_ms` is the leader's wall clock; TTL
    depends on it; nothing depends on monotonic time except failure
    detection. Document the assumption (NTP-disciplined, skew in seconds not
    hours) and what breaks outside it (early/late visibility only, never
    divergence). *Blocks:* nothing; documentation.
    **Resolved 2026-08-29** (documentation): the assumption is stated in PRD
    0001's *Slot layout* (Clock assumptions) - NTP-disciplined, skew in
    seconds not hours; outside it the consequences are early/late visibility
    only, never divergence, and a backwards jump is clamped so expiry is
    delayed, never advanced. Failure detection is the one monotonic-time
    path, as the question noted.
<a id="oq-41"></a>
41. **Record-store tooling.** [OPEN] clanker maintains its `docs/` stores with
    sandboxed tools (`clanker rfc`, `clanker adr`, …) that write
    compare-and-swap and keep the inventories in sync. coppiz's stores are
    hand-maintained for now; inventories drift the way clanker's did before
    its tools existed. Reuse clanker's tools pointed at this tree, or accept
    hand maintenance until the project is bigger? *Blocks:* nothing.
<a id="oq-44"></a>
44. **Determinism of fold under merge *with* checkpoints.** [RESOLVED] PRD 0002's rule
    (each branch's checkpoint removes only what its own fold names; no
    checkpoint within `merge.settle_ms` of a merge) is reasoned, not
    tested. The simulator (OQ 27) is where it gets tested; until then it is
    the most likely place for a subtle divergence. *Blocks:* none - phase 5
    acceptance shipped; the determinism claim is still reasoned, not pinned
    by a merge-with-checkpoints scenario.
    **Resolved 2026-08-29** (operator): schedule the merge-with-checkpoints
    scenario in the simulator (OQ 27's second half); the determinism claim is
    pinned by that scenario when it lands.
<a id="oq-45"></a>
45. **CI and toolchain pin.** [OPEN] Which Zig build to pin in CI (0.16.0 release),
    and whether to test musl and glibc targets there. The merge-gate half of
    this question is settled in-tree rather than in CI: `zig build test` runs
    the lint gates - formatting, the 100-column cap, test registration,
    declaration analysis, gate coverage; `zig build lint` runs them alone -
    and build.zig names this question for the CI half that remains open.
    *Blocks:* the first external contribution; the repository's own commits
    are gated locally by `zig build test` today.
<a id="oq-59"></a>
59. **Does the fetchable package carry the design docs?** [OPEN]
    The decision is explored in
    [RFC 25](rfcs/0025-docs-in-package.md) (Discussion); this entry is the
    stable pointer. *Blocks:* the first host fetch (PRD 0005 phase 5) and the first public release.
<a id="oq-48"></a>
48. **Grouping unit and range key.** [OPEN] Ownership by whole journal is the
    drafted unit; the drafted split key is the author-id prefix so each
    author's stream stays in one group. Is that enough for hosts whose
    journals have many authors and one hot range, or is a payload-derived
    key needed (which breaks `author_seq` density)? *Blocks:* PRD 0006
    phase 3. *Answer from:* OQ 46's host shapes; measurement.
<a id="oq-49"></a>
49. **When does the group count need to be uneven?** [RESOLVED] Under `seniority`,
    `configured` and `combined` a federation of 2 or 4 groups elects like 2
    or 4 members do; only a majority-vote (`quorum`) mode at the federation
    level needs an odd count.

    **Resolved 2026-08-21** (operator confirmed): groups use the same
    leadership modes and the same concurrency model as members - election is
    a pure function over an abstract member type, and a group supplies the
    same five inputs (identity = genesis hash, seniority = its `join` slot in
    the federation journal, address, liveness and sync via its current
    representative).

    An uneven group count is therefore **not** a
    requirement; it would become one only if a `quorum` mode were chosen at
    the federation level, which is roadmap and not designed. Recorded in
    [PRD 0006](prds/0006-scaling-to-groups-sharding-and-parity.md) (*A group
    is the system*). Two consequences of the derived liveness are design
    rules there: federation validation checks a representative against its
    group's own chain, and federation `suspect_after_ms` must exceed a
    group's internal election time.
<a id="oq-50"></a>
50. **Parity code and reconstruction cost.** [OPEN] Reed–Solomon over GF(2⁸) in
    `std`-only Zig is feasible; k, m defaults, fragment size, and what a
    read of a parity range costs (k network fetches + decode) against a
    follower copy are unmeasured. Also: does parity apply to the chain's
    *slots* or only to payloads, given `ttl.retain`? *Blocks:* PRD 0006
    phase 4.
<a id="oq-51"></a>
51. **Cross-group routing and read semantics.** [OPEN] Forwarding an append to the
    owner is drafted; a read of a non-owned journal either forwards (one
    round-trip, fresh) or hits a follower copy (local, lagging). Which is the
    default, and does `write.ack` mean "owner slotted" or "local forwarded"?
    Relates to OQ 3 and OQ 31. *Blocks:* PRD 0006 phase 2.
<a id="oq-52"></a>
52. **What group identity must the core headers carry now?** [OPEN] Drafted:
    segment headers carry journal id + sequencing group id; entry headers
    carry the journal id but no group id ([PRD
    0001](prds/0001-journal-core.md)), and slot headers carry neither (the
    slot's `leader` member id implies the group via that group's chain).
    Is the implication enough for a verifier in another group, or should
    the slot carry the group id explicitly (16 more bytes per slot,
    forever)? *Blocks:* PRD 0001 phase 1 - the format freeze.
<a id="oq-53"></a>
53. **Membership and discovery at 10⁵.** [OPEN] A new instance must find *a*
    member of *some* group: seed lists in local config (drafted), a
    directory journal in the federation, or DNS. Which, and how does an
    instance choose a group to join (operator-assigned, nearest, smallest)?
    *Blocks:* PRD 0006 phase 1.
<a id="oq-54"></a>
54. **Measurements that replace the tier numbers.** [OPEN] 32 per group and
    ~1,000 / ~100,000 per tier are intent. The first measurement set: size-1
    append latency; per-member connection count and memory at 8, 16, 32
    members; append-to-visible p50/p99 across one group; join/backfill time
    for a 1 GB journal; then the same at 3 × 8 and 10 × 8 in two groups of
    groups. Where is the harness and what hardware counts? *Blocks:*
    promoting any tier number from intent to claim.

## What else might be missing

Things no PRD has a home for yet; promote to a numbered question when one
becomes concrete:

- **Multi-tenancy / namespacing** across unrelated consumers sharing one
  cluster - or is "one cluster per consumer" the rule?
- **Quota and fairness** between authors (a runaway writer filling every
  member's disk).
- **Journal-level access control** - may every member append to every journal?
- **Time travel API** (`at_slot`) exposure and cost.
- **Entry payload validation hooks** - a host-supplied predicate the leader
  runs before slotting, so a consumer can enforce its own schema at the
  journal boundary (would make refusal a chain-wide rule only if every member
  runs the same hook, which brings the OQ 1 trust question back).
- **Migration story off JSONL** for clanker's existing streams (import with
  original timestamps preserved in `author_ts_ms`?).
- **Graceful shutdown and drain** - a leaving leader hands over *before*
  exiting, so no epoch churn on a planned restart.
- **Windows/macOS support** - `std.Io` covers them; flock semantics and
  fsync guarantees differ; untested.
- **Locality and placement** - which group a consumer's appends go to when
  several could own a new journal; geography-aware placement is a federation
  policy nobody has specified.
- **Cross-group stale marks and checkpoints** - a `stale` is authored where
  the author lives, but the journal lives in its owning group; forwarding
  makes it work, but the checkpoint cadence is the owner's clock.
