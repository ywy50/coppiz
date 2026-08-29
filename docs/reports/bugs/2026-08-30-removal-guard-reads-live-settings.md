# Bug - the removal-set fast path reads live settings, so turning TTL off strands expired entries forever

## TL;DR

- **What failed:** `expiry.canRemoveAnything` decided "nothing can ever be
  removed" from the journal's *current* `ttl.enforce` / `stale.cleanup`,
  while `removalSet` decides per entry from the `expires_at` and
  `ttl_action` stamped when that entry was slotted.
- **Impact:** a journal that had TTL enforcement on and then turned it off
  kept every already-stamped entry hidden from default reads as expired,
  never removed it, never reclaimed its bytes, and emitted no checkpoint at
  all for that journal - because the removal set it would have emitted was
  never computed.
- **Resolution:** fixed. The fold tracks whether any entry carries a stamp
  a checkpoint could act on, and the guard answers from those stamps.

## Status

Resolved - 2026-08-30. Found by reading. It corrects a claim made in
[the 2026-08-29 settings/checkpoint runtime sweep](../investigations/2026-08-29-runtime-sweep-settings-checkpoint.md),
which introduced the guard and recorded it as semantics-preserving.

## Symptom and impact

PRD 0002's state machine is `live --ttl reached, action=delete-->
expired --checkpoint--> removed`. After the settings change the second
arrow never fires:

- `journal.visible()` hides the entry, because `isExpired` reads the
  entry's stamped `expires_at`/`ttl_action`, which the settings change does
  not revise;
- `Node.checkpointForBroadcast` asks `removalIds` for the set, `removalIds`
  takes the fast path and answers `&.{}`, and the G7 rule ("never emit an
  empty removal set") then returns `null` - so the leader's checkpoint
  cadence emits nothing for that journal at all;
- `FoldState.applyCheckpoint` short-circuits the same way, so even a
  checkpoint arriving from elsewhere would mark nothing removed.

The bytes stay on disk for the life of the journal and the entry is
invisible to every default read. Nothing logs, and nothing refuses: the
journal simply stops making progress on removal.

## Reproduction

`an entry stamped delete is still removable after ttl.enforce goes back to
off` in `src/journal/journal.zig`:

1. `ttl.enforce = all`, `ttl.action = delete`, `ttl.default_ms = 1000` at
   t=2000;
2. append one entry - stamped `expires_at = 3000`, `ttl_action = delete`;
3. `ttl.enforce = off` at t=2500;
4. checkpoint at t=4000.

- Expected: the entry is marked `removed` and the head advances.
- Actual, before the fix: `removed` is false and the head does not move.
  Confirmed by restoring the old guard body and running `zig build test`
  (exit 1, failure at `journal.zig:1590`).

## Root cause

`chain.registerEntry` stamps each entry once, at slot time:

```zig
const expires_at = if (en.kind == .data)
    expiry.expiresAt(sl.slot_ts_ms, en.ttl_ms, &self.settings) else null;
const ttl_action = if (en.kind == .data) expiry.action(&self.settings) else .mark_stale;
```

`expiry.removalSet` then matches on those stamps
(`se.ttl_action == .delete and se.expires_at.? <= checkpoint_ts_ms`). The
guard, however, read the settings table:

```zig
pub fn canRemoveAnything(settings: *const schema.SettingsState) bool {
    if (std.mem.eql(u8, settings.getEnum(k_stale_cleanup), "delete")) return true;
    return !std.mem.eql(u8, settings.getEnum(k_ttl_enforce), "off");
}
```

The two are equivalent only for a journal whose settings never changed.
`ttl.enforce` has `live_rule = always`, so changing it is ordinary,
supported operation.

## Resolution

`FoldState` gains two monotone booleans, maintained where the stamps are
written:

- `may_expire_delete` - some entry is stamped `ttl_action = delete` with an
  expiry instant. Such an entry is removable whatever the settings say now.
- `may_remove_stale` - some entry is author-marked stale (set in
  `applyStale`), or is stamped `mark_stale` with an instant. Those are
  removable only under `stale.cleanup = delete`, which the removal set
  reads live, so the guard reads it live too.

`canRemoveAnything(settings, may_expire_delete, may_remove_stale)` is now
exact in both directions: it never skips a pass that would find something,
and it still skips every pass on a journal that never had a TTL - the
default configuration the fast path exists for, which the regression test
pins as its second half.

The flags are derived from the entries table, so they are deliberately not
part of `FoldState.hash`, and `refold`/`FoldState.init` rebuild them.
Monotonicity costs at most a redundant candidates pass on a journal whose
removable entries have all been removed already.

## Verification

- The two new tests (`expiry.zig` unit, `journal.zig` end to end) pass with
  the fix and both fail with the old guard body restored (`zig build test`
  exit 1).
- The second half of the journal test pins the fast path still holds: a
  journal that never had a TTL emits no checkpoint.
- Full gate `zig build test` exit 0 on the branch.

## Follow-up

`expiryCandidates` does not carry `EntryInfo.removed` into the candidate
set, so an already-removed entry is re-selected by every later checkpoint.
That is a separate defect, not fixed here.

## References

- Investigation: [2026-08-29 - settings key resolution and checkpoint removal sets](../investigations/2026-08-29-runtime-sweep-settings-checkpoint.md)
  (introduced the guard; corrected in place)
- Code: `src/journal/expiry.zig` (`canRemoveAnything`,
  `stampCanExpireDelete`, `stampCanBecomeStale`), `src/journal/chain.zig`
  (`FoldState`, `registerEntry`, `applyStale`, `applyCheckpoint`),
  `src/journal/journal.zig` (`removalIds`)
- Spec: [PRD 0002](../../prds/0002-ttl-and-staleness.md)
