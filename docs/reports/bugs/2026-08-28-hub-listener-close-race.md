# Bug — `HubListener.closeFn` writes `endpoint.closed` without the endpoint mutex (data race, latent)

## TL;DR

- **What failed:** `HubListener.closeFn` sets `self.endpoint.closed = true` and posts the semaphore **without** `Endpoint.mutex`, while `pushConn`/`acceptConn` read `closed` under the mutex. Teardown of a listener racing an accept/dial is a data race (UB).
- **Impact:** Latent: the shipped code stops loops before closing listeners, so nothing exercises the race today; but the hub is the test/simulator transport, and nothing enforces the ordering.
- **Resolution:** Still open. Statically validated.

## Status

Open (latent).

## Symptom and impact

`transport.zig:547-555`:

```zig
fn closeFn(ctx: *anyopaque, io: std.Io) void {
    const self: *HubListener = @ptrCast(@alignCast(ctx));
    if (self.closed) return;
    self.closed = true;
    self.endpoint.closed = true;   // :551 — no mutex
    self.endpoint.sem.post(io);    // :552
    ...
}
```

while `pushConn` (`:402-416`) and `acceptConn` (`:418-431`) read `self.closed` under `self.mutex`. The unsynchronized write is a C-level data race against those reads.

## Reproduction

Not reproduced; statically certain. A listener closed concurrently with an in-flight dial (`connectFn` → `pushConn`) or accept on the same endpoint races the `closed` field.

## Root cause

`closeFn` bypasses the endpoint's own locking discipline; `Direction.close` and `push` (the sibling primitives) both take the mutex.

## Resolution

Not yet fixed. Suggested fix: take `self.endpoint.mutex` around the `closed = true` write (and re-check `closed` under it, like `push`). A regression test would need a concurrent close/accept loop — hard to make deterministic; a `zig build test` under ThreadSanitizer would flag it once reachable.

## Verification

- Static: `closeFn` vs. `pushConn`/`acceptConn` lock usage verified line-by-line.

## Follow-up

None. Low priority until a caller closes a listener while accepts/dials are in flight.

## References

- Code: `src/net/transport.zig:547-555` (`HubListener.closeFn`), `:402-431` (`pushConn`/`acceptConn`)
- Fix: none
