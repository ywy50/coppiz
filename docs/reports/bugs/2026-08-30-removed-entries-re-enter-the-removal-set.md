# Bug - an already-removed entry re-enters every later removal set, so an idle journal emits a checkpoint per interval

## TL;DR

- **What failed:** `FoldState.expiryCandidates` does not copy
  `EntryInfo.removed` into `expiry.SlottedEntry`, and `expiry.removalSet`
  has no such field. Removal leaves an entry's position, expiry instant and
  action untouched, so an entry an earlier checkpoint reclaimed matches
  every test in `removalSet` forever.
- **Impact:** PRD 0002 G7 ("a checkpoint is never emitted with an empty
  removal set") stops holding the moment one entry has ever been removed.
  The leader's cadence then emits a checkpoint per interval on a journal
  with no new data, each one re-running `store.compact` over ids whose
  payloads are already gone, and `checkpoint.pending_bytes` counts those
  reclaimed bytes as still pending. `FoldState.checkpoints` grows by 16
  bytes per emission and is never trimmed.
- **Resolution:** open. The correct fix is small, but it changes behaviour
  an e2e in `src/cluster/node.zig` currently depends on - see *Why it is
  still open*.

## Status

Open - 2026-08-30. Found by reading; the mechanism was then confirmed by
building the fix and observing which test it breaks.

## Symptom and impact

`Node.checkpointForBroadcast` decides whether to emit by asking
`removalIds` for the set and returning `null` when it is empty
(`journal.zig`, the G7 rule). `removalIds` feeds `expiryCandidates` into
`removalSet`.

`applyCheckpoint` marks removal by setting `info.removed = true` on the
fold's `EntryInfo` and changes nothing else - not the position, not
`expires_at_ms`, not `ttl_action`, not `payload_len`. `expiryCandidates`
copies seven fields into `SlottedEntry` and `removed` is not one of them.
So on the next checkpoint the entry still satisfies all three of
`removalSet`'s tests: its position is at or before `expire_through` (which
only moves forward), its instant is at or before the stamp (which only
grows), and its action is still `delete`.

Consequences, in order of how much they cost:

- the cadence emits a checkpoint every `checkpoint.every_ms` on a journal
  nobody is writing to - each one a slot, a store write and a broadcast;
- each emission calls `compactRemoved` → `store.compact` over ids whose
  payloads were already dropped, rewriting the segments;
- `removableBytes` (`node.zig`) sums `info.payload_len`, which removal does
  not zero, so the `checkpoint.pending_bytes` early trigger fires on bytes
  that are not there;
- `FoldState.checkpoints` grows unboundedly (it is appended per checkpoint,
  never trimmed, and is read only by tests).

Under `ttl.retain = none` a restart masks it: the records come back
slot-only and never re-enter `entries`. Under the default
`retain = header` they do, so it survives a reopen.

## Reproduction

With `ttl.enforce = all`, `ttl.action = delete`: append one entry, let a
checkpoint remove it, then ask for another checkpoint at a later stamp with
nothing appended in between.

- Expected: `checkpointForBroadcast` returns `null` (G7) and the head does
  not move.
- Actual: a second checkpoint is emitted naming the same, already-removed
  entry.

Not committed as a test, because the fix it would pin is not committed
either.

## Root cause

`chain.zig`, `expiryCandidates`:

```zig
candidates[index] = .{
    .id = kv.key_ptr.*,
    .position = info.position,
    .slot_ts_ms = info.slot_ts_ms,
    .expires_at = info.expires_at_ms,
    .ttl_action = info.ttl_action,
    .stale_marked = info.stale_marked,
    .stale_position = info.stale_position,
};                       // info.removed is not carried
```

`removed` is the only record that an entry has already been reclaimed, and
it is the one field the removal rule cannot see.

## Why it is still open

The fix is to carry `removed` into `SlottedEntry` and skip on it - but only
for the caller asking "is there anything left to do?". The other caller
must not skip: `applyReplicated` folds a peer's checkpoint (marking the
entries removed) and *then* calls `compactAfterCheckpoint`, which recomputes
the set to know which bytes to drop. Filtering there reclaims nothing. So
the parameter has to be threaded per caller - `checkpointForBroadcast`
filtered, `compactAfterCheckpoint` unfiltered.

That was built and gated on 2026-08-30. The gate is then red at one test:
`e2e (G4): three members remove the same set at the same checkpoint slot,
both retain values` in `src/cluster/node.zig`, at its `pending_removed`
assertion. The test appends a four-entry burst with a 300 ms TTL under a
600 s cadence and waits 10 s for all four to be removed. That only works
today because each emitted checkpoint moves the head, which re-arms the
pending-bytes probe, which emits another checkpoint - the spam loop this
defect creates. Remove the loop and the last two entries of the burst wait
for the 600 s cadence, which is the designed behaviour and longer than the
test's window.

So the fix needs the e2e's expectation changed with it. That file is
another agent's territory in the session that found this, which is why the
finding is recorded rather than shipped.

## Resolution

Not fixed. The change needed, in one place each:

1. `expiry.SlottedEntry` gains `removed: bool`; `expiryCandidates` copies
   `info.removed`.
2. `expiry.removalSet` gains a `skip_removed` parameter and skips on it.
3. `journal.removalIds` forwards it: `true` from
   `checkpointForBroadcast` (the G7 question), `false` from
   `compactAfterCheckpoint` (the reclaim question), and `false` from
   `checkpointRemovalSet`, whose caller is the byte probe.
4. The G4 e2e's pending-bytes phase stops relying on a checkpoint being
   emitted for entries that expire after the last append.

Step 4 is the one that needs deciding: either the burst test waits on the
cadence, or the pending-bytes probe re-arms on time as well as on data -
which is a design question, not a mechanical fix.

## Verification

- The mechanism is confirmed by reading `expiryCandidates`, `removalSet`
  and `applyCheckpoint`.
- The dependency of the G4 e2e on the spam loop is confirmed by
  experiment: with the fix applied, `zig build test` fails only at
  `node.zig`'s `pending_removed` assertion, 324/325 tests passing.
- Not verified: the wall-clock cost of the extra checkpoints and
  compactions on a real deployment. No measurement was taken.

## Follow-up

`FoldState.checkpoints` is unbounded independently of this defect - nothing
trims it, it is not part of `FoldState.hash`, and its only readers are
tests. Worth a decision of its own once the cadence is not emitting on an
idle journal.

## References

- Investigation: none
- Code: `src/journal/chain.zig` (`expiryCandidates`, `applyCheckpoint`),
  `src/journal/expiry.zig` (`SlottedEntry`, `removalSet`),
  `src/journal/journal.zig` (`removalIds`, `checkpointForBroadcast`,
  `compactAfterCheckpoint`), `src/cluster/node.zig` (`driveCheckpoints`,
  `removableBytes`, the G4 e2e)
- Spec: [PRD 0002](../../prds/0002-ttl-and-staleness.md) G7 and the
  checkpoint cadence
- Related: [2026-08-30 - the removal-set fast path reads live settings](2026-08-30-removal-guard-reads-live-settings.md),
  found in the same pass and named this as its follow-up
