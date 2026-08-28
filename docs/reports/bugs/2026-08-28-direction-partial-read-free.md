# Bug — `Direction.readInto` frees an interior pointer on a partial read (latent)

## TL;DR

- **What failed:** When a queued chunk is longer than the read destination, the remainder is stored back as an interior slice (`chunks.items[0] = chunk[n..]`); a later read that fully consumes it calls `allocator.free` on that interior pointer — an invalid free / heap corruption for any real allocator.
- **Impact:** Latent: no current caller drives a partial read (`PipeConn.recvFrame` always reads with destinations exactly matching chunk sizes), but `Direction` is a `pub` API and the simulator's building block.
- **Resolution:** Still open. Statically validated.

## Status

Open (latent).

## Symptom and impact

`readInto` (`transport.zig:269-291`):

```zig
const chunk = self.chunks.items[0];
const n = @min(chunk.len, dest.len);
...
if (n == chunk.len) {
    const taken = self.chunks.orderedRemove(0);
    self.mutex.unlock(io);
    self.allocator.free(taken);      // :279 — taken is the ORIGINAL slice, fine
} else {
    self.chunks.items[0] = chunk[n..];  // :281 — interior slice stored
    ...
}
```

The next time the remainder is fully consumed, `orderedRemove(0)` returns the interior slice `&alloc[4..]` and `allocator.free` is called on it — an invalid free for any allocator that can't derive the original allocation (GPA panics; release allocators corrupt the heap). Currently unreachable: every pushed chunk is exactly 4 (frame header) or `len` (frame body) bytes and every read destination in `recvFrame` is the same size, so a partial read never occurs. It becomes live the moment `Direction` is read with a smaller destination — e.g. a future simulator or test helper.

## Reproduction

Not reproduced; statically certain. Sketch (once reachable): `dir.push(io, "hello"); dir.readInto(io, &[4]u8); dir.readInto(io, &[4]u8);` — the second call frees `&buf[4]` of the original allocation.

Related latent defect in the same function: a pushed empty body (a 0-length frame) is returned as `n == 0`, which `recvFrame` misreads as `EndOfStream`, killing the connection.

## Root cause

The partial-read branch stores a slice derived from the allocation instead of re-basing ownership; the full-consumption branch assumes the stored slice is allocation-owned.

## Resolution

Not yet fixed. Suggested direction: on a partial read, copy the remainder into a fresh allocation (or keep the original allocation and track an offset), so every `free` is on an allocation start. A regression test should push a chunk and read it in two smaller pieces under `std.testing.allocator`.

## Verification

- Static: both branches verified line-by-line; reachability analysis confirms no current caller takes the partial path.

## Follow-up

None. Related hub defects reported separately (errdefer double-free, duplicate-address listen).

## References

- Code: `src/net/transport.zig:269-291` (`Direction.readInto`), `:247-257` (`push`), `:340-347` (sendFrame chunk sizes)
- Fix: none
