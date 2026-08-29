# Investigation - verification of the test-build speedup reports and their remaining open topics

## TL;DR

- **Question:** are the six investigation reports on speeding up the test
  build accurate, and are their proposed solutions implemented and valid?
- **Finding:** all six verify. The 12 same-semantics runtime fixes of the
  2026-08-29 sweep are present in the code and the gate is green; the one
  proposed-but-not-implemented solution - RFC 0003's fsync policy (Option A)
  - is valid, its unverified mechanism claim (3 fsync barriers per append,
  the queue ignoring the knob) is confirmed by strace, and it is implemented
  here: 3/2/2 barriers per knob became 2/1/0.
- **Resolution:** implemented - [RFC 0003](../../rfcs/0003-append-durability-fsync-policy.md)
  is decided via [ADR 0008](../../adrs/0008-storage-fsync-governs-the-queue.md)
  (this stack's PR 1); the flaky `status` test's invisibility is closed by
  capturing the spawned serves' stderr (PR 2).

## Status

Resolved for the verified and implemented subset. OQ 62 (the cluster e2e
CPU spin) and the process-level `status` flake remain open with updated
evidence and tooling (serve stderr capture, fewer fsyncs).

## Trigger and scope

Tasked with reading the six investigation reports on speeding up the test
build, verifying their findings, evaluating the proposed solutions, and
implementing the valid ones. The six: the original
[2026-08-28 - making `zig build test` faster without dropping tests](2026-08-28-test-suite-quick-wins.md)
and the five-part
[2026-08-29 runtime sweep](2026-08-29-runtime-sweep-findings.md).

## Evidence

### Verification of the implemented items (all six reports)

Each of the sweep's 12 implemented fixes was spot-checked in the code at
`main` @ `953d6a2` (worktree `pass5`):

| Report | Claimed fix | Verified at |
|---|---|---|
| settings and checkpoint | `schema.keyIndex` comptime (`inline for`) + `keyIndexRuntime` | `settings/schema.zig:349-357` |
| same | `encodeCanonical` in place, no scratch alloc | same report's code |
| same | `expiry.canRemoveAnything` guard | `journal/expiry.zig` |
| journal read | `readRange` walks `store.scanFrom` | `journal/journal.zig:817` |
| journal read | `Store.firstRecordKind` discovery | `journal/store.zig` |
| queue and wire | `Store.appendRecord` verbatim follower append | `journal/store.zig:265` |
| queue and wire | `Queue.remove` raw-span copy | `journal/queue.zig:165` |
| queue and wire | `sendForward` one allocation; `pushFramed`; empty-queue early exit | `cluster/node.zig`, `net/transport.zig` |
| sim and micro | id→index `node_by_id` map | `sim/sim.zig:79` |
| sim and micro | 64 KiB TCP send buffer | `net/transport.zig:121` |

Gate on this machine: 23/23 steps, 261/261 tests, exit 0, ~21 s before this
stack's changes (lib_tests ~20 s - the e2e waits, per the 2026-08-28
measurements).

### RFC 0003 - the one proposed solution not yet implemented

The sweep's item 13 (append pays 3 fsyncs; the queue ignores the knob; the
drain barrier is redundant) pointed at [RFC 0003](../../rfcs/0003-append-durability-fsync-policy.md),
whose Option A was recommended but unverified ("barrier count per knob not
strace-verified"). Strace on this machine (serve + one wire append) before
the change:

- `.every`: **3** fsyncs per append
- `.batched`: **2** (the queue's two barriers ignored the knob)
- `.never`: **2** (same)

The RFC's mechanism text named the third barrier `clear`; the cluster
append path actually drains via the per-entry `Queue.remove` (the
single-member path uses `clear`). Both are drains of already-slotted
entries, so the same idempotency argument covers both: a lost trim
redelivers an entry the fold dedups (verified: `setLength` atomic, torn
tail truncates at open, replay skips slotted ids).

After implementing Option A (queue honors the knob; `remove` and `clear`
never sync): `.every` **2**, `.batched` **1**, `.never` **0** fsyncs per
append.

### The flaky `status` test (sweep environment finding)

The sweep recorded the process-level `status` test intermittently failing
under `zig build test` on its machine, with the serves' stderr sent to
/dev/null - a serve crash would be invisible. This stack captures each
serve's stderr to a log and dumps it on a wait timeout, so the next
occurrence is diagnosable; the fsync-contention hypothesis is directly
addressed by the RFC 0003 implementation (PR 1).

### OQ 62 (the cluster e2e CPU spin)

The sweep's machine reproduced the spin once inside a gate run (a lib_tests
binary at 112% CPU for 9+ minutes); the earlier correlation (~20 clean
direct runs since the busy-spin removal) stands. No stack was captured; the
spin remains open. This stack adds no new reproduction attempts.

## Hypotheses and tests

- **Hypothesis A - the sweep's implemented fixes are present and the gate
  is green.** Spot-checked each fix's site; gate green (261/261 before this
  stack, 262/262 after, the extra test being the queue knob test).
  *Result:* supported.
- **Hypothesis B - RFC 0003's barrier claim holds and Option A is valid.**
  Strace 3/2/2 before, 2/1/0 after; the idempotency argument verified by
  reading. *Result:* supported; implemented.
- **Hypothesis C - the `status` flake is fsync-contention.** Not directly
  testable on this machine (no flake in ~15 gate runs here); the fsync load
  is reduced and the crash path is now visible. *Result:* unproven, now
  diagnosable.

## Finding

All six reports verify. The only proposed-but-unimplemented solution - RFC
0003 Option A - was valid and is now implemented (ADR 0008), removing the
queue's two unconditional barriers and making `storage.fsync` mean the same
thing everywhere. The remaining open items are the OQ 62 spin (undiagnosed
for want of a stack) and the `status` flake (now diagnosable via the serve
logs).

## Resolution or handoff

- PR 1 (this stack): RFC 0003 Option A - queue honors the knob; drain
  barriers (`remove`/`clear`) never sync; barrier-count verified 2/1/0 per
  knob; ADR 0008 records the decision; RFC 0003 status Decided.
- PR 2 (this stack): serve-stderr capture + wait-timeout dump, closing the
  flake's invisibility.
- PR 3 (this stack): this record plus the sweep report's item-13
  disposition and OQ 62's status update.
- OQ 62: still open; the next reproduction should capture stacks (the
  gdb-as-parent approach used on 2026-08-28) and check whether the
  busy-spin removal changed the trigger.

## References

- The six reports verified: the 2026-08-28 quick wins and the 2026-08-29
  runtime-sweep series (findings, journal read, queue and wire, settings
  and checkpoint, sim and micro)
- [RFC 0003](../../rfcs/0003-append-durability-fsync-policy.md),
  [ADR 0008](../../adrs/0008-storage-fsync-governs-the-queue.md)
- Code: `src/journal/queue.zig`, `src/journal/journal.zig`,
  `src/main.zig` (`BinTest`)
- OQ 62 (the spin); strace runs on this machine, 2026-08-29
