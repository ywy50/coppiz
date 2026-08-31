# Bug - TCP accept/connect leak the OS socket when the `TcpConn` allocation fails

## TL;DR

- **What failed:** `TcpListener.acceptFn` and `TcpTransport.connectFn` create the socket (`accept`/`connect`) before allocating `TcpConn`; on allocation failure the stream is dropped without `close` - an fd leak (and a dangling peer connection on the accept side).
- **Impact:** OOM-only, but repeated pressure exhausts fds; the hub paths got the allocate-before-insert fix in the sweep, the TCP paths did not.
- **Resolution:** Fixed in `773af4d` (2026-08-29). Statically validated; the fix is confirmed present in the tree by the 2026-08-31 audit below.

## Status

Resolved 2026-08-29 (audited 2026-08-31).

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

Fixed: `TcpListener.acceptFn` and `TcpTransport.connectFn` close the OS stream via errdefer when the `TcpConn` allocation fails.

## Correction - what the 2026-08-31 audit checked

`8893ae1` ("docs(reports): mark the sweep fixes resolved", 2026-08-29) flipped
this report's `## Status` to `Resolved` and rewrote its `## Resolution` in a
commit that touched 29 report files and no source. It left the `## TL;DR`
resolution bullet reading "Still open" and the `- Fix:` reference reading
"none", so the record contradicted itself and gave a reader no way to tell
whether the fix existed. Five other reports flipped by that commit were
audited on 2026-08-31 and found to have no fix in the tree at all.

This one does. Audited 2026-08-31 by reading the shipped code and the history
of the symbol the resolution credits. The fix landed in `773af4d`, whose
subject ("fix(wire): a read of an unknown journal refuses with a named error
(#90)") names only the last of the twelve fixes it carries. `8893ae1` has that
commit as an ancestor, so its status flip was right - only the two metadata
lines were left behind.

Both `TcpListener.acceptFn` and `TcpTransport.connectFn` now carry `errdefer
stream.close(io);` between the accept or connect and the `TcpConn` allocation,
on the real vtable functions rather than on unreachable code. No test covers
it - the trigger is an allocator failure at exactly that point, and no
fault-injecting allocator in the suite reaches the accept path - so this is a
code read, not a test result.

Only the `## TL;DR` resolution bullet, the `## Status` line and the `- Fix:`
reference were corrected; the symptom, reproduction, root cause and resolution
are unchanged.

## Verification

- Static: both functions read; the missing `close` on the error path is unambiguous.

## Follow-up

None. Low priority.

## References

- Code: `src/net/transport.zig:158-165` (`acceptFn`), `:184-198` (`connectFn`)
- Fix: `773af4d` (PR #90)
