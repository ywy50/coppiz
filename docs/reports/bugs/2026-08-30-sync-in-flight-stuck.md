# Bug - a lost sync response strands the member's catch-up forever

## TL;DR

- **What failed:** `sync_in_flight` gates every sync request (`requestSync`
  is a silent no-op while it is set) and is cleared only by the response
  arriving or the conn dying. A sync page lost to a conn race - no response,
  no conn death - left the flag set forever.
- **Impact:** the member's catch-up was stranded: `driveBackfill` skipped
  the journal, the heartbeat gap catch-up's `requestSync` was a no-op, and
  the member served a stale chain indefinitely. The loop sim exposed it
  intermittently: after a three-member heal, the losing followers stopped
  at the common tail, five records short of the survivor's head, with no
  recovery.
- **Resolution:** Resolved - the tick releases a sync that has been in
  flight longer than `sync_response_timeout_ms` (5 s), so the next request
  retries; overlapping pages are idempotent.

## Status

Resolved.

## Symptom and impact

`requestSync` (node.zig):

```zig
if (self.sync_in_flight) return false;
self.sync_in_flight = true;
...send sync_req...
```

`onSyncPage` clears the flag; `onPeerGone` clears it on a dead conn. There
is no third path: a response lost to a conn race (the page never delivered,
the conn not yet noticed dead) left the flag set forever. The loop sim
reproduced the consequence deterministically enough: after a three-member
merge, the losing followers sat at the common tail - `syncing=false`,
connected, naming the survivor as leader - while the survivor's head was
five records ahead. The heartbeat gap catch-up called `requestSync` every
tick and got `false` every time.

## Reproduction

Intermittent. The `LoopWorld` three-member scenario (sim.zig) with the
threaded io: sometimes the losing followers strand at the common tail after
the heal.

## Root cause

The in-flight flag has no timeout. The sync protocol is request/response
over a live conn; a response can be lost without the conn dying, and
nothing ever releases the flag for a retry.

## Resolution

Fixed: `requestSync` records when it sent the request, and `onTick`
releases a sync in flight for longer than `sync_response_timeout_ms`
(5 s). The next request - the backfill's cursor, or the heartbeat gap
catch-up - retries from the same position, and a page applied twice is a
no-op (the fold's dedup and the at-or-behind-head skip).

## Verification

- Regression test "a timed-out sync response releases the in-flight flag"
  (node.zig): an old in-flight sync is cleared by the tick; a recent one
  stays.
- The `LoopWorld` three-member scenario, which intermittently caught the
  stall, converges in repeated full-suite runs.
- Full `zig build test` (tests + lint gates) green, `EXIT=0`.

## Follow-up

The lost response's root cause - the conn race that drops a page without
killing the conn - is not established; the watchdog makes it self-healing
rather than permanent.

## References

- Code: src/cluster/node.zig (`requestSync`, `onSyncPage`, `onTick`)
- Fix: this report's resolving commit
