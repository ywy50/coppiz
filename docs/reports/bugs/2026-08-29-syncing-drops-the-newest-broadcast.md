# Bug - a backfilling member drops the newest broadcast and never asks for it again

## TL;DR

- **What failed:** `onSlot` drops every broadcast while `syncing` is set, and
  `syncing` is cleared a tick *after* the last sync cursor drains. A record
  slotted inside that window is dropped by a member whose backfill has
  already passed it, and nothing ever re-requests it.
- **Impact:** the member stays one record behind for good and serves silently
  stale reads. This is what the intermittent growth e2e failure was.
- **Resolution:** fixed. A broadcast dropped while backfilling now leaves a
  sync cursor at the missing position, so the next `driveBackfill` fetches it.

## Status

Resolved. It is the root cause of
[2026-08-29-growth-e2e-last-broadcast-timeout](2026-08-29-growth-e2e-last-broadcast-timeout.md),
which is where the symptom, its history, and the hypotheses that were ruled
out are recorded.

## Symptom and impact

A member that has finished backfilling a journal, but has not yet had the
tick that clears `syncing`, silently discards a replicated record. The
observable form is a follower whose `coppiz read` is permanently one record
short of the leader's while its `coppiz status` shows the same epoch and the
same leader, and no error anywhere.

Captured from a failing run of the growth e2e, with the leader (A), the
appending follower (B) and the joiner (C) all still alive:

```
[A(leader)] read code=0:
1:1 <a>:1 data m1
1:2 <b>:1 data m2
[B(appender)] read code=0:
1:1 <a>:1 data m1
1:2 <b>:1 data m2
[C(target)] read code=0:
1:1 <a>:1 data m1
[C(target)] status code=0:
epoch 1
leader <a>
[A] serve stderr: EMPTY
[B] serve stderr: EMPTY
[C] serve stderr: EMPTY
NEVER ARRIVED: m2 absent 120 s past the deadline
```

Three failing runs, all identical in shape. Nothing crashed, and 120 seconds
of extra polling past the test's own 20 s deadline never produced the record,
which is what rules out "C was slow".

## Reproduction

Two, at different levels.

*Deterministic, in-process*: the unit test
`a broadcast dropped while backfilling leaves a cursor behind` in
`src/cluster/node.zig` puts a node in exactly that window (`syncing` set, no
cursors) and delivers one `onSlot`. Before the fix the record was neither
folded nor recorded anywhere; the test fails with `NoCursor`.

*End to end, statistical*: build the growth e2e alone and run it in a loop.

```sh
zig build
zig test -lc --dep coppiz -Mroot=src/main.zig --dep build_options \
  -Mcoppiz=src/root.zig -Mbuild_options=<generated> \
  --test-filter "a live cluster grows" --test-no-exec -femit-bin=/tmp/growth
```

The generated `build_options` module needs only
`pub const version_text = "0.0.0";`. Run `/tmp/growth` from the worktree
root, which is where it looks for `zig-out/bin/coppiz`. The counts are in
*Verification*.

## Root cause

Three facts, each individually reasonable:

1. `onSlot` opens with `if (self.syncing or self.merging_from != null)
   return;`. Broadcasts are dropped while backfilling because sync pages are
   supposed to carry everything.
2. `syncing` is cleared only by `driveBackfill`, on a tick, once no journal
   has a sync cursor left. `onSyncPage` removes the last cursor when it is
   served an empty page but does not clear `syncing` itself. With the default
   `cluster.heartbeat_ms` of 1000, `updateTick` makes that tick 250 ms, so
   the window is up to a quarter of a second.
3. Nothing re-requests a dropped record. `onHeartbeat`'s gap catch-up
   compares only the control head, because `message.Heartbeat` carries only
   that one. `onSlot`'s `BadPrevHash` re-sync needs a *later* record on the
   same journal to arrive and fail the fold, so it never fires for the newest
   one. Both are noted in
   [2026-08-28-follower-data-gap-stale](2026-08-28-follower-data-gap-stale.md).

Together: the backfill asks for a journal from its head, is served an empty
page and drops that journal's cursor; the leader slots a record and
broadcasts it inside the next 250 ms; the member drops it because `syncing`
is still set; and no later record on that journal ever arrives to trip the
one recovery path that would have caught it.

The window is why the failure looks random, and why it always lands on the
*newest* record on a journal rather than a middle one.

## Resolution

`onSlot` splits the two conditions. The merge case still returns silently -
the loser is mid-branch and a sync will follow. The backfill case calls a new
`noteBackfillGap(journal_id)`, which puts a sync cursor at
`headFor(journal_id).next()` when the journal has none. The record is still
not folded out of order; it is turned into a pending backfill instead of
being forgotten.

Consequences that make it safe:

- An existing cursor is never moved. It is already at or behind that
  position, so rewinding it would re-fetch folded records.
- A journal the fold does not know is skipped. `driveBackfill` only walks the
  journals the fold lists, so a cursor for any other would never drain and
  `syncing` would never clear; the control chain's completion seeds those
  cursors anyway.
- `syncing` now stays set until the re-seeded cursor drains, which is
  correct: the member really is behind, and it is not leader-eligible until
  it is not.

## Verification

- The unit test above fails with `NoCursor` on the unfixed tree and passes
  with the fix.
- End to end, the growth e2e built alone and run in a loop, same machine,
  one run at a time, nothing else running:

  | tree | runs | failures |
  |---|---|---|
  | `origin/main` at 70c77ee | 20 | 16 |
  | the same tree with this fix | 20 | 0 |

  Of the 16 baseline failures, 14 were at `pollRead(&b, "m1")` and 2 at
  `pollRead(&c, "m2")`. That rate is far above the "three in roughly a dozen"
  the symptom report records for full `zig build test` runs, because running
  the test alone back to back keeps the timing tight; it is the same failure.

- `zig build test`: green.

## Follow-up

The recovery gap itself is untouched: a data-journal record lost for any
other reason still has no path back, because the heartbeat carries only the
control head. Widening it is a wire change (`message.Heartbeat`) and is not
attempted here.

## References

- Investigation: none
- Code: `src/cluster/node.zig` (`onSlot`, `noteBackfillGap`, `driveBackfill`,
  `onSyncPage`, `onHeartbeat`, `updateTick`), `src/main.zig` (the growth e2e)
- Related: [2026-08-29 - the 1 -> 2 -> 3 growth e2e intermittently times out waiting for the last replicated entry](2026-08-29-growth-e2e-last-broadcast-timeout.md),
  [2026-08-28 - a follower that misses one data-journal broadcast is permanently behind](2026-08-28-follower-data-gap-stale.md)
- Fix: this commit
