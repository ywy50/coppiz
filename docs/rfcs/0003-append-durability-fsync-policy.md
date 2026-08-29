# RFC 0003 - what does `storage.fsync` govern?

## Status

Discussion - opened 2026-08-29.

An RFC is a *request for comment*: it presents the options and a recommendation
so a decision can be made, and it is not itself the decision record. When it is
decided, set the status, then write the
[ADR](../adrs/) that records the choice and link it from References. A later
reversal supersedes that ADR; this file keeps the reasoning that produced it.

## Overview

The append hot path issues three fsync barriers per write, and two of them are
unconditional: the `storage.fsync` local-config knob (`every` | `batched` |
`never`) is threaded into the store only, while the unslotted queue fsyncs on
every `append` and on every `clear` regardless of the knob.

**Decision to make.** Which durability barrier should an acknowledged append
actually pay, and which component owns the decision?

**Why now.** The write path is the runtime hot path (PRD 0001 *Write path*).
The 2026-08-29 sweep measured the mechanism: three barriers per tier-0 append
(`queue.append` → `store.append` → `queue.clear`, all fsync), with the queue's
two barriers ignoring the knob - a user setting `fsync = "never"` (or
`"batched"`) still pays queue fsyncs, so the knob does not mean what it says
for a third of the write path. On this machine the gate's cluster e2e tests
also run at ~3.5 min and the process-level `status` test flakes intermittently;
the fsync count is the leading suspect (every e2e append pays all three
barriers under `.every`, the default).

**Drivers.** Any acceptable option must:

- preserve PRD 0001 G3 - an acknowledged write is durable - under `.every`,
  the default and the single-member/leader configuration;
- make the knob mean the same thing on every component it governs (a
  durability setting that is silently ignored is a trap);
- keep crash-then-reslot safe: the queue is the redo record that survives a
  crash between forward and slot, and its replay is idempotent
  (`journal.zig:719-729`, queue.zig:1-9);
- not change the on-disk format of the queue or the store.

**Out of scope.** The queue *drain* shape - the whole-file rewrite per
`remove`, O(k²) I/O on a burst - is a separate format decision (tombstones,
watermarks, batched drains) and is deliberately not decided here; see the
sweep findings report. The per-frame decode-ownership contract
(`message.zig:6-8`) is likewise separate.

## Current state

`storage.fsync` is parsed in `src/config/local.zig:196-207` and threaded
through `main.zig` into `Node.open` options (`journal.zig:47-48, 108`), which
passes it to `Store.open` only. The store honors it: `append` syncs under
`.every` (`store.zig:250`), `sealHead` syncs under anything but `.never`
(`store.zig:266, 286`). The queue (`Queue.open`, `journal.zig:110`) takes no
fsync option; `Queue.append` and `Queue.clear` sync unconditionally
(`queue.zig:133, 197`). So:

- under `.every`: 3 barriers per append (queue append, store append, queue
  clear);
- under `.batched` and `.never`: 2 barriers per append (queue append, queue
  clear), and the store's records are un-fsynced until a seal - the knob's
  durability contract is already accepted by the user, but the queue still
  refuses to participate;
- the `clear` barrier is redundant even under `.every`: the entry is removed
  from the queue only after the slot is stored (`journal.zig:594-597`), the
  ack follows that, and a crash that loses the truncate just replays an
  idempotent no-op.

## Options considered

### Option A - the knob governs the queue; `clear` never syncs

- **What it is:** thread `fsync` into `Queue.open`; `append` syncs under
  `.every` (and, when a batch window exists, `.batched`); `clear` truncates
  without syncing, because a lost truncate replays idempotently. Under
  `.every`, an append pays 2 barriers instead of 3; under `.batched`/`.never`,
  it pays 0 on the queue and the knob means the same thing everywhere.
- **Maturity:** no new machinery - the policy already exists, the replay
  idempotency is already the design (`queue.zig:1-9`).
- **How it would fit:** `Queue` gains a `fsync` field; `journal.zig` passes
  `options.fsync`; `Queue.append`/`clear` consult it. No format change.
- **Pros:** the knob becomes honest; every acknowledged write keeps PRD 0001
  G3 under `.every` (the store barrier is unchanged); the redundant third
  barrier disappears; a user who chooses `.never` gets the latency they asked
  for.
- **Cons:** under `.batched` there is currently no batching point in the loop
  (the store only syncs on seal), so `.batched` and `.never` stay identical on
  the append path until a flush point exists; the queue's append under
  `.batched` must choose a side (sync per append, or wait for a future flush
  point).
- **Cost to adopt:** small - one field, three call sites, plus tests that
  assert the barrier count per knob value (strace or an injected fsync
  counter).
- **Cost to leave:** trivial - the change is internal; nothing on disk or the
  wire changes.
- **Evidence:** the 2026-08-29 sweep reports measure the mechanism
  ([write-path data flow](../reports/investigations/2026-08-29-runtime-sweep-queue-wire.md),
  [settings and checkpoint paths](../reports/investigations/2026-08-29-runtime-sweep-settings-checkpoint.md));
  the queue's replay idempotency is documented at `queue.zig:1-9` and
  `journal.zig:719-729`; the 3-barrier path was verified by reading
  `journal.zig:229-268` (append) and `queue.zig:124-134, 194-198`. The
  barrier count per knob has not been strace-verified on this machine -
  `unverified`.

### Option B - keep the queue always-durable; document the gap

- **What it is:** the status quo plus a comment/README note that
  `storage.fsync` governs the store only and the queue is always synced.
- **Pros:** zero code change; the queue's 2 barriers stay even under
  `.never`, which is the safest reading of "the queue is the redo record".
- **Cons:** the knob stays a lie for the queue; a latency-sensitive
  single-member deploy (`fsync = "never"`) still pays 2 barriers per append
  and cannot get what the knob promises; the redundant `clear` barrier stays.
- **Cost to adopt:** none now; the misconfiguration trap and the redundant
  barrier persist.
- **Cost to leave:** none.
- **Evidence:** same mechanism evidence as Option A.

### Option C - policy-aware acks (out-of-the-box): the ack contract states its own durability

- **What it is:** instead of one knob governing barriers, the *ack* carries
  the durability level: under `.never` the leader may ack before the store
  write (the write is enqueued), under `.batched` the ack covers the batch
  window, under `.every` the ack is the current barrier. The wire ack gains a
  durability field (or the semantics are documented per cluster setting).
- **Maturity:** new protocol surface; the ack shape is wire-format
  (`message.zig`), so this is a versioned change.
- **How it would fit:** ack encoding/decoding change, loop changes, client
  changes; the sync page and read paths are unaffected.
- **Pros:** the client can *know* what an ack meant - the honest end of the
  durability contract; opens batching as a real latency win.
- **Cons:** wire format change (version bump), larger blast radius, and the
  same "where is the batching point" question as Option A - it solves the
  contract, not the missing flush point; overkill while `.batched` has no
  batch to point at.
- **Cost to adopt:** the largest of the three - wire + client + loop.
- **Cost to leave:** a versioned wire field is the point of no return; it can
  be reverted only with a version negotiation.
- **Evidence:** the ack is encoded/decoded at `message.zig:264-293`; no
  durability level exists on it today (verified by reading).

## Implications by horizon

### Short term (this release / 0–3 months)

- **If A:** append latency drops one barrier under `.every` and two under
  `.never`/`.batched`; the knob becomes trustworthy; the e2e suite (which runs
  under `.every`) pays one fewer fsync per append - directly testable on this
  machine's flaky/slow gate.
- **If B:** nothing changes; the gap stays documented.
- **If C:** a wire change lands for a promise no batching point delivers yet.

### Medium term (3–12 months)

- **If A:** when a batching/flush point lands in the loop (a periodic seal or
  an explicit flush), `.batched` becomes real with no further knob changes.
- **If B:** `.batched` stays decorative; anyone who reads the knob will still
  be wrong about the queue.
- **If C:** the durability field is already on the wire and batching can hook
  into it.

### Long term (12+ months)

- **If A:** the durability story is "one knob, every component, ack = the
  knob's level"; an ack-level field remains possible later if hosts need it
  (PRD 0005 embedding).
- **If B:** the queue's unconditional barriers become a permanent
  performance-tax line item under every setting.
- **If C:** the ack field is load-bearing and versioned; hosts that pinned the
  old ack shape need the negotiation path.

## Recommendation

**Recommended option:** A - the knob governs the queue; `clear` never syncs.

**Confidence:** 7/10

**Why this confidence.** The mechanism is verified by reading (3 barriers;
queue ignores the knob; replay idempotent; `clear` redundant). What would move
it up: a strace/`fsync`-count measurement per knob value on this machine
(planned as the acceptance test), and a decision on the `.batched` append
behavior (sync-per-append until a flush point exists - the RFC's default).
What would sink it: a crash-recovery test showing a *surviving* queue entry is
ever required after the slot landed - the idempotency argument says it never
is, but the fuzz/replay test suite is the proof.

**Rationale.** Against the drivers: A keeps G3 under `.every` (the store
barrier is untouched), makes the knob mean the same thing on every component,
preserves crash-then-reslot (idempotent replay), and changes no format. It
beats B because B keeps a documented lie and a redundant barrier; it beats C
because C spends a wire change on a batching promise the loop does not yet
have. The `.batched` append side is the one open sub-choice: sync per append
until a flush point exists is the conservative default.

**Reversibility.** Fully reversible - the change is internal (one field, three
call sites). There is no format, wire, or API point of no return.

## Open questions

- Under `.batched`, should the queue's append sync per append (safe, defeats
  batching) or wait for a future flush point (needs the flush point to exist)?
  *Answerable by:* whoever lands the batching work; default = sync per append.
- Does the test suite already cover crash-during-clear? The replay-idempotency
  claim rests on the fold's dedup; a direct test of "queue truncated between
  slot and clear" would settle it. *Answerable by:* the fuzz/replay tests.

## Next steps / action items

- [ ] If accepted: thread `fsync` into `Queue.open`, gate `append`, drop the
      `clear` sync, and add a barrier-count test (strace or an injected
      counter) per knob value.
- [ ] Re-run the gate on this machine and compare the e2e flake rate and
      duration.
- [ ] Write the ADR once the decision is made.

## References

- Investigation reports (the evidence this RFC rests on):
  - [2026-08-29 - write-path data flow](../reports/investigations/2026-08-29-runtime-sweep-queue-wire.md)
  - [2026-08-29 - settings key resolution and checkpoint removal sets](../reports/investigations/2026-08-29-runtime-sweep-settings-checkpoint.md)
  - [2026-08-29 - range reads and open-time discovery](../reports/investigations/2026-08-29-runtime-sweep-journal-read.md)
  - [2026-08-29 - simulator leader evaluation and TCP page writes](../reports/investigations/2026-08-29-runtime-sweep-sim-micro.md)
  - [2026-08-29 - runtime speedup sweep findings](../reports/investigations/2026-08-29-runtime-sweep-findings.md)
- Code: `src/config/local.zig` (knob parse), `src/main.zig` (threading),
  `src/journal/journal.zig` (append, options), `src/journal/queue.zig`,
  `src/journal/store.zig` (fsync policy)
- Prior RFCs: [0001 - library-first or service-first](../rfcs/0001-library-first-or-service-first.md),
  [0002 - how join order is made unspoofable](../rfcs/0002-how-join-order-is-made-unspoofable.md)
