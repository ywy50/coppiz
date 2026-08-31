# Bug - a frame body is committed from its header, before any of it arrives

## TL;DR

- **What failed:** `readFrame` allocated the whole body length the 4-byte
  header declared - up to `max_body_bytes`, 17 MiB - and only then began
  reading the body.
- **Impact:** a connection that announces a large frame and then delivers
  nothing holds that memory until it is closed. A peer that dies mid-frame
  costs what a complete frame would have cost, on every connection it had.
- **Resolution:** fixed - the body is read a chunk at a time and the buffer
  grown as chunks arrive, so what a connection commits follows what it has
  delivered.

## Status

Resolved 2026-08-31. Found by reading; no occurrence in a log is known.

## Symptom and impact

A frame is a 4-byte little-endian length followed by the body. The reader
took the length as an instruction to allocate:

```
const len = std.mem.readInt(u32, &hdr, .little);
if (len > max_body_bytes) return error.OversizedFrame;
const body = try allocator.alloc(u8, len);
errdefer allocator.free(body);
reader.readSliceAll(body) catch ...
```

`readSliceAll` then blocks until the body arrives or the peer goes away. Four
bytes therefore decide a commitment of up to 17 MiB held for as long as the
peer keeps the connection open without finishing the frame.

The header is read before the connection has a role: `frameAllowed` is
applied to the *decoded message*, two steps later, so this happens for any
connection that reaches the listener. It should not be read as a defence
against a hostile peer - coppiz's trust model is crash faults and tamper
evidence, not BFT ([RFC 0009](../../rfcs/0009-trust-model.md)) - the
proportion is what is wrong: a truncated, stalled or dead connection cost
exactly what a complete one would.

`max_body_bytes` is deliberately large and stays so: an accepted entry has
to fit in one frame or it can never be replicated (bug
2026-08-28-sweep3-oversized-entry-unreplicable). The bound is right; taking
it as the size to allocate up front is what was wrong.

## Reproduction

`src/net/framing.zig`, test *a frame body is committed as it arrives, not as
it is announced*: a header declaring `max_body_bytes` followed by no body at
all, read through an allocator with `4 * read_chunk_bytes` to give out.

Expected: `error.EndOfStream` - the peer is gone, which is what the loop
acts on. Before the fix the allocator is asked for 17 MiB first and the
answer is `error.OutOfMemory`, an error the caller does not treat as a dead
connection.

## Root cause

The declared length was used as an allocation size before any of the data it
described had been seen - the same shape as the settings change count
reported in
[2026-08-31-settings-count-before-bounds](2026-08-31-settings-count-before-bounds.md),
at a larger scale, and here with no cheap way to validate it in advance: the
only evidence a length is honest is the bytes turning up.

## Resolution

The body is read in `read_chunk_bytes` (64 KiB) pieces into a list that
grows as each piece lands. A peer that announces 17 MiB and sends nothing
holds one chunk. A peer that sends the whole thing gets the whole thing;
the returned slice is unchanged, so no caller changes.

The buffer grows geometrically, so the peak is within a factor of two of the
bytes actually delivered rather than of the bytes declared.

## Verification

- The test above fails before the fix with `expected error.EndOfStream,
  found error.OutOfMemory` and passes after it.
- A second test covers the reassembly: a body of `3 * read_chunk_bytes + 17`
  delivered in 7000-byte pieces, so no chunk boundary lines up with a
  delivery boundary, comes back byte-identical.
- The existing round-trip, empty-body and split-delivery tests are unchanged
  and still pass.
- `zig build test` green on the branch: `Build Summary: 25/25 steps
  succeeded; 342/342 tests passed`.

The truncated-frame test also caught a latent defect in the file's own test
helper, fixed here. `ChunkedReader.stream` returned `0` when its data ran
out, and `Reader.readSliceShort` loops on the vtable until the buffer fills
or an error arrives - a zero-length "success" spins forever. The first run
of the new test hung the suite at 100% CPU rather than failing. No test had
ever read past the end of a `ChunkedReader` before, so nothing had exercised
it; `stream` now returns `error.EndOfStream`.

## Follow-up

The chunk size is a constant (`read_chunk_bytes`) rather than a setting: it
trades a syscall count against a commit size and neither side of that has
been measured, so it is not offered as a knob.

`PipeConn.recvFrame` in `src/net/transport.zig` is a second framing
implementation - the hub transport does not call `readFrame` - and it still
allocates the declared body up front (`const body = try allocator.alloc(u8,
len)`). It carries the same disproportion, on the in-memory fabric rather
than on TCP. Not fixed here: the right change is to stop having two
implementations of one format, which is larger than this fix and should not
ride along with it.
