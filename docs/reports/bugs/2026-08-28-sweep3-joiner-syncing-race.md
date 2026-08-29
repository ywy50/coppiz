# Bug - A chainless joiner whose first tick fires before admission never backfills and can never join

## TL;DR

- **What failed:** `init` sets `syncing = true` for a chainless member; `driveBackfill` clears it on the first tick whenever the cursor map is empty - and it is empty until the first `hello_ack` seeds it. The seed is gated on `syncing`, so a joiner whose first tick (100 ms) beats its handshake stays `syncing = false` forever with no cursor and never syncs.
- **Impact:** A permanent, silent join failure - the member connects, but never folds genesis, never becomes leader-eligible, and never forwards. Exactly the "admitter comes up late" case the seed-retry design documents.
- **Resolution:** Still open. Statically validated (corroborated by two independent reviews).

## Status

Resolved.

## Symptom and impact

A fresh joiner starts `syncing = true` (`node.zig:337`, `control.head == null`). `driveBackfill` runs on every tick (`onTick` → `:896`) and, when `sync_cursors` is empty, falls through to `self.syncing = false` (`:966`). The only control-cursor seed is `onHelloAck` (`:1438-1446`), and it is guarded by `if (self.syncing)`. Order of events when the dial → hello → hello_ack round trip takes longer than the first 100 ms tick (admitter down at startup, loaded link, or any handshake > 100 ms):

1. Tick 1: `syncing` → false (empty cursors = "at head").
2. `hello_ack` arrives: the seed is skipped (`syncing` false).
3. `driveBackfill`'s own guard (`!self.syncing`, `:946`) now blocks the only sync driver.
4. Nothing re-arms `syncing` for a joiner - the only other `syncing = true` sites are the two merge-loser paths (`:2136`, `:2158`).

The joiner sits at epoch 0, re-dialing every ~2 s, re-hitting the same guard on every admission. A restart re-hits the same race. The e2e tests never see it because the hub transport round trip is microseconds.

## Reproduction

Not dynamically reproduced (timing race); statically complete. All `syncing` and cursor-seed sites enumerated (grep): `init:337`, `driveBackfill:966`, `onHelloAck:1440` (guarded), `onSyncPage:2025/2035` (post-page), loser paths - no re-arm exists.

## Root cause

The "at head" decision treats an empty cursor map as "nothing left to sync", but for a chainless member the empty map means "the sync was never started". The seed that starts it is conditional on the very flag the empty-map path just cleared.

## Resolution

Fixed: `driveBackfill` no longer clears `syncing` for a chainless joiner whose first tick beats its handshake - the hello_ack still seeds the backfill cursor.

## Verification

- Static: every `syncing` write and cursor seed read; the fall-through path confirmed reachable on tick 1 for an empty fold (`control.journal_id = [0]*16`, empty `journals`).

## Follow-up

Related join-path defects reported separately: the follower-admitter failure (2026-08-28-sweep3-follower-admitter-join-fails) and the phantom-member block (noted there).

## References

- Code: `src/cluster/node.zig:337` (`init`), `:945-967` (`driveBackfill`), `:1438-1446` (`onHelloAck`)
- Fix: none
