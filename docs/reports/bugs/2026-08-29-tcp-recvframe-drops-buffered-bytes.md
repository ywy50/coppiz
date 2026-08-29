# Bug - `TcpConn.recvFrame` throws away every byte the socket read past the current frame

## TL;DR

- **What failed:** `recvFrame` built a 4 KiB read buffer and a `Stream.Reader` over it *per call*, both function-local. A socket read is greedy, so bytes that arrived after the current frame were consumed from the kernel and then discarded when the call returned.
- **Impact:** TCP coalesces frames freely - the leader's tick writes a heartbeat and a slot broadcast back to back - so the discarded bytes are routinely the next frame. A whole frame lost is silent replication loss; a partial frame lost desynchronizes the connection, because the next read takes four arbitrary body bytes for a length prefix.
- **Resolution:** Fixed. The buffer and the reader belong to the `TcpConn` and survive across calls.

## Status

Resolved.

## Symptom and impact

`src/net/transport.zig`, before the fix:

```zig
fn recvFrame(ctx: *anyopaque, io: std.Io, allocator: std.mem.Allocator) framing.ReadError![]u8 {
    const self: *TcpConn = @ptrCast(@alignCast(ctx));
    var buf: [4096]u8 = undefined;
    var reader = self.stream.reader(io, &buf);
    return framing.readFrame(allocator, &reader.interface);
}
```

`buf` and `reader` are stack locals and die at the `return`.

The read is not exact. `framing.readFrame` asks for four header bytes;
`std.Io.Reader.readSliceAll` reaches `net.Stream.Reader.readVec`, which builds
an iovec of *both* the caller's slice and the reader's own buffer, and then:

```zig
if (n > data_size) {
    r.interface.end += n - data_size;
    return data_size;
}
```

Everything past the requested bytes is already out of the kernel socket buffer
and sitting in `buf`. `readFrame` takes the current frame's body from there and
returns; the rest goes out of scope.

The consequences differ by how much was over-read. A whole extra frame is lost
silently: the follower never sees that slot, its chain gains a gap, and the
next broadcast fails `BadPrevHash` and drives it into the divergence and merge
path. A partial frame is worse: the next `recvFrame` starts mid-body and reads
four payload bytes as a length prefix, which yields `OversizedFrame`, a
multi-megabyte allocation, or a garbage `message.decode`.

`PipeConn.recvFrame`, the hub path every in-process test uses, pops whole
bodies from a queue and has no such buffer, which is why the suite never saw
this. Only real TCP does.

## Reproduction

New test `a TCP conn keeps the bytes its socket read past the current frame`
in `src/net/transport.zig`. A client dials the real `tcpListen` listener and
writes two frames with a single flush, so the kernel delivers both in one read;
the server calls `recv` twice.

- Expected: `frame-one`, then `frame-two`.
- Actual, before the fix, from a control run with the fix reverted:

```
error: 'net.transport.test.a TCP conn keeps the bytes its socket read past the current frame' failed:
       .../lib/std/Io/Reader.zig:662:26: in readSliceAll
           if (n != buffer.len) return error.EndOfStream;
       .../src/net/framing.zig:49:30: in readFrame
       .../src/net/transport.zig: in recvFrame
       .../src/net/transport.zig: in test ... (the `second` recv)
```

The first frame arrives; the second is gone, so the socket is at end of stream.

## Root cause

The buffer's lifetime was scoped to a call, but the thing it holds - the
stream's unread remainder - is a property of the connection. The `Conn`
abstraction had no field for it, so there was nowhere for the remainder to
live and nothing pointed out that it was being dropped.

The write side of the same struct was reasoned about correctly: `sendFrame`
carries an explicit comment about flushing the stream writer because a small
frame would otherwise never leave the stack buffer. The read side needed the
same care and did not get it.

## Resolution

`TcpConn` owns the buffer and the reader:

```zig
read_buf: [4096]u8 = undefined,
reader: ?net.Stream.Reader = null,
```

`recvFrame` builds the reader on first use - that is the first call with an
`Io` in hand - and reuses it after. `TcpConn` is always heap-allocated (both
`TcpListener.acceptFn` and `TcpTransport.connectFn` `create` it, and `closeFn`
`destroy`s it), so `read_buf`'s address is stable for the reader that points
into it.

Nothing else changed: the same framing, the same 4 KiB, the same errors.

## Verification

- New test above, over real loopback TCP.
- Control: with the owned reader reverted and the test kept, the second `recv`
  fails with `error.EndOfStream`.
- `zig build test --summary all` green.

## Follow-up

The reader is now per-connection, which also means a `TcpConn` costs 4 KiB
more than it did. That is bounded by the member count and was already the
per-call cost, so it is not a new bound - noted only because the allocation
moved from the stack to the connection.

## References

- Code: `src/net/transport.zig` (`TcpConn`), `src/net/framing.zig` (`readFrame`), `std.Io.net` (`Stream.Reader.readVec`, the over-read)
- Fix: this change
