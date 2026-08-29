# Bug - four `closeFn`s guard against a second close with a flag that lives in the allocation the first close freed (latent)

## TL;DR

- **What failed:** `TcpConn`, `TcpListener`, `PipeConn` and `HubListener`
  each began `closeFn` with `if (self.closed) return; self.closed = true;`
  and ended it with `allocator.destroy(self)`. The flag is inside what the
  destructor frees, so on a second call it is read out of freed memory.
- **Impact:** Latent - no caller in the tree closes any of the four twice
  (audited below). Were one to, the result is not the intended no-op: it
  depends on what the allocator did with the block. A recycled block reads
  `false` and the second close frees it again, over the new owner. This was
  reproduced.
- **Resolution:** Fixed by removing the four flags and stating the
  exactly-once contract on `Conn.close` and `Listener.close`. This does not
  make a second close safe - nothing can, for a destructor that frees its
  own storage - it removes a guard that read as if it did.

## Status

Resolved.

## Symptom and impact

Before the fix, all four had this shape:

```zig
fn closeFn(ctx: *anyopaque, io: std.Io) void {
    const self: *TcpConn = @ptrCast(@alignCast(ctx));
    if (self.closed) return;
    self.closed = true;
    self.stream.close(io);
    self.allocator.destroy(self);
}
```

The first call frees `self`. The second call dereferences that pointer to
read `self.closed`, which is a use-after-free whose answer the allocator
decides:

- Under a safe-build `DebugAllocator`, `free` overwrites the block with
  `undefined` (`0xaa`), and `if (self.closed)` on `0xaa` takes the early
  return. The guard appears to work, by accident.
- Once the block is recycled, the guard reads whatever its new owner wrote.
  A zero there sends the second close through `stream.close` on a dangling
  descriptor and `destroy` on memory the new owner holds.

Neither is the documented behaviour, and which one happens is not a
property of the transport.

`Direction` and `Hub.Endpoint` keep their `closed` flags: their close marks
state without freeing the struct (the hub owns both), so those reads are
from live memory.

## Reproduction

Reproducible on demand, with a throwaway test in `src/net/transport.zig`
(not committed - it is a demonstration of misuse, not a regression check).
It builds a `PipeConn`, closes it, asks the same allocator for another
`PipeConn` so the freed block is handed back, and closes the first `Conn`
again:

```
CONTROL: first block 0x103260000, recycled block 0x103260000, same=true
Segmentation fault at address 0x103269188
lib/std/heap/debug_allocator.zig:885:23: in free
            if (bucket.canary != config.canary) @panic("Invalid free");
src/net/transport.zig:1050:23: in test.CONTROL a second close ...
    test_alloc.destroy(other);
error: the following test command terminated with signal ABRT
```

`std.testing.allocator` returned the identical address for the next
same-sized request, so the second close read a live `closed = false`, ran to
completion and destroyed the recycled block. The crash is the *new owner's*
own `destroy` afterwards, hitting a bucket whose canary the double free had
already broken.

Expected: the second close is a no-op, which is what the guard reads as
promising. Actual: a second free of a block another owner holds.

## Root cause

A destructor that frees its own storage cannot be idempotent by inspecting
its own storage. There is nowhere for the flag to live: after the first
call, every field of the object is freed memory. The four flags were
written as if `close` were a state transition on a long-lived object, which
is what `Direction.close` and the endpoint's close actually are.

The `Conn` contract already said as much without saying it exactly once:
"The sole destructor; only safe once the reader task has exited." The
`shutdown` / `close` split exists precisely so the loop can wake a blocked
reader without freeing anything, and the reader's `peer_gone` notice is the
single close.

## Audit: is anything double-closing today?

No. Every close site was read:

- `ClusterNode.onPeerGone` closes the conn and then removes it from
  `conns`, so the map cannot hand it out again.
- `acceptMain` and `dialMain` close only a conn the mailbox refused, which
  the loop therefore never took ownership of.
- `Endpoint.pushConn` closes a dial that arrived at a closed endpoint;
  `Endpoint.deinit` closes those still pending. A conn is on exactly one of
  those paths.
- `HubDialer.connectFn` builds two `PipeConn`s, one per side, so the two
  ends never alias.

That is why this is filed as latent: the defect is in what the code
promises, not in an observed failure.

## Resolution

The four flags are gone, and the two vtable-level destructors say the
contract:

```zig
/// The sole destructor; only safe once the reader task has exited, and
/// safe exactly once. It frees the connection, so a second call is a
/// use-after-free rather than a no-op - a `closed` flag on the
/// connection cannot say otherwise, because the flag is inside what the
/// first call freed.
pub fn close(self: *const Conn, io: std.Io) void {
```

Be clear about what this does and does not buy. It does not make a second
close safe; that is not achievable here. It removes a guard whose apparent
protection came from an allocator's poison byte, and it makes the misuse
fail the same way every time instead of depending on allocation reuse -
which is the difference between a bug a test can catch and one that shows
up in production.

## Verification

- New test `no self-freeing closer keeps its guard inside the allocation it
  frees` in `src/net/transport.zig`. It asserts the four types have no
  `closed` field and that `Direction` and `Hub.Endpoint` still do, so
  re-adding the false guard - or deleting a real one - fails the build.
- Control for that test: with `closed` put back on `TcpConn` alone it fails
  with `TestUnexpectedResult`; with the fix it passes.
- Control for the defect: the throwaway test quoted above, run on the
  pre-fix tree, output as shown.
- `zig build test` green (see the PR).

## Follow-up

None. The remaining `closed` flags are on hub-owned objects whose close does
not free them, and the structural test pins that split.

## References

- Investigation: none
- Code: `src/net/transport.zig` (`Conn.close`, `Listener.close`, `TcpConn`,
  `TcpListener`, `PipeConn`, `HubListener`, `Direction`, `Hub.Endpoint`),
  `src/cluster/node.zig` (`onPeerGone`, `acceptMain`, `dialMain`)
- Related: [2026-08-28-hub-listener-close-race.md](2026-08-28-hub-listener-close-race.md)
  fixed the other half of `HubListener.closeFn` - the endpoint flag written
  without the endpoint mutex.
- Fix: this change
