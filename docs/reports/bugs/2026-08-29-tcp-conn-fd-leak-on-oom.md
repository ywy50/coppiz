# Bug - TCP accept/connect leak the OS socket when the `TcpConn` allocation fails

## TL;DR

- **What failed:** `TcpListener.acceptFn` and `TcpTransport.connectFn` create the socket (`accept`/`connect`) before allocating `TcpConn`; on allocation failure the stream is dropped without `close` - an fd leak (and a dangling peer connection on the accept side).
- **Impact:** OOM-only, but repeated pressure exhausts fds; the hub paths got the allocate-before-insert fix in the sweep, the TCP paths did not.
- **Resolution:** Still open. Statically validated.

## Status

Open.

## Symptom and impact

`src/net/transport.zig:158-165` (accept) and `:184-198` (connect):

```zig
const stream = try self.server.accept(io);        // socket open
const conn = try self.allocator.create(TcpConn);  // OOM here — stream dropped unclosed
errdefer self.allocator.destroy(conn);
```

The `errdefer` covers only the destroy; nothing closes `stream`. On the accept side the peer's connection also dangles until the listener dies.

## Reproduction

Not dynamically reproduced (needs an allocator failure at exactly that point); statically certain.

## Root cause

The sweep-1 fix ("allocate before container insert") was applied to the hub paths only; the TCP paths still open the OS resource before the allocation that can fail.

## Resolution

Not yet fixed. Suggested fix: `errdefer stream.close(io);` after the accept/connect (before the create). A regression test should fail the `TcpConn` allocation and assert the fd count is unchanged (or drive it under `FailingAllocator`).

## Verification

- Static: both functions read; the missing `close` on the error path is unambiguous.

## Follow-up

None. Low priority.

## References

- Code: `src/net/transport.zig:158-165` (`acceptFn`), `:184-198` (`connectFn`)
- Fix: none
