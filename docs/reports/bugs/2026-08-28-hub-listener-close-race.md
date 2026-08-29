# Bug - `HubListener.closeFn` writes `endpoint.closed` without the endpoint mutex (data race, latent)

## TL;DR

- **What failed:** `HubListener.closeFn` sets `self.endpoint.closed = true` and posts the semaphore **without** `Endpoint.mutex`, while `pushConn`/`acceptConn` read `closed` under the mutex. Teardown of a listener racing an accept/dial is a data race (UB).
- **Impact:** Latent: the shipped code stops loops before closing listeners, so nothing exercises the race today; but the hub is the test/simulator transport, and nothing enforces the ordering.
- **Resolution:** Still open. Statically validated.

## Status

Resolved - `closeFn` writes `endpoint.closed` under the endpoint mutex,
matching the locking discipline of `pushConn`/`acceptConn`.

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

Fixed as suggested: `closeFn` takes `self.endpoint.mutex` around the
`closed = true` write and the semaphore post (the mutex pointer is
captured before `self` is destroyed, so the deferred unlock stays
valid). `pushConn`/`acceptConn` read `closed` under the same lock, so
the race is gone. A deterministic regression test would need a
concurrent close/accept loop, which is hard to make deterministic; the
fix is the same locking discipline the sibling primitives already use.

## Verification

- Static: `closeFn` vs. `pushConn`/`acceptConn` lock usage verified line-by-line.

## Follow-up

None. Low priority until a caller closes a listener while accepts/dials are in flight.

## References

- Code: `src/net/transport.zig:547-555` (`HubListener.closeFn`), `:402-431` (`pushConn`/`acceptConn`)
- Fix: `src/net/transport.zig` (`HubListener.closeFn`). `zig build test` green.
