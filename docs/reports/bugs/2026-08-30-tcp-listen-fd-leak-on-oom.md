# Bug - `tcpListen` leaks the listening socket when the listener allocation fails

## TL;DR

- **What failed:** `tcpListen` (transport.zig) opens the listening socket and
  then allocates the `TcpListener`; if the allocation fails, the socket is
  dropped without `deinit` - an fd leak.
- **Impact:** One leaked listening fd per failed `listen` under OOM. The node
  listens once at startup, so severity is low, but it is the same class the
  repo already fixed for the dial and accept sides (bug
  2026-08-29-tcp-conn-fd-leak-on-oom), and a long-lived process that
  re-listens after failures would leak one fd per attempt.
- **Resolution:** Resolved - an errdefer closes the server socket before the
  allocation.

## Status

Resolved.

## Symptom and impact

`tcpListen` (src/net/transport.zig):

```zig
var server = try addr.listen(io, .{ .mode = .stream, .reuse_address = true });
const l = try allocator.create(TcpListener);
errdefer allocator.destroy(l);
l.* = .{ .allocator = allocator, .server = server };
```

`allocator.create(TcpListener)` failing returns with the OS listening socket
open and unowned. The sibling functions were fixed for exactly this class
(`TcpListener.acceptFn` and `TcpTransport.connectFn` both errdefer their
streams), and the fix for bug 2026-08-29-tcp-conn-fd-leak-on-oom named the
family - `tcpListen` was missed.

## Reproduction

Not dynamically reproduced; statically certain. Fail the `TcpListener`
allocation (e.g. with a `FailingAllocator`) and count open fds: one fd per
failed `listen` leaks.

## Root cause

The socket is created before its owning object; nothing closes it on the
allocation error path.

## Resolution

Fixed: `errdefer server.deinit(io)` runs before the allocation, so a create
failure closes the socket; the errdefer is inert once the listener owns it.

## Verification

- Full `zig build test` (tests + lint gates) green, `EXIT=0`.

## Follow-up

None.

## References

- Code: src/net/transport.zig (`tcpListen`)
- Fix: this report's resolving commit
