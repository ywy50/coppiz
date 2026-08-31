//! Wire framing (PRD 0003 phase 4; OQ 19 decided: own binary framing over
//! one TCP connection, not HTTP).
//!
//! A frame is a 4-byte little-endian length prefix followed by the body
//! verbatim. The body's first byte is the wire version, the second the
//! message kind (message.zig); a reader refuses an unknown version and an
//! oversized frame before reading the body. All integers little-endian, as
//! in every other coppiz format (PRD 0001).
//!
//! The loop treats `error.EndOfStream` from `readFrame` as "the peer is
//! gone": it is returned both for a clean close between frames and for a
//! close mid-frame, and both mean the connection is dead.

const std = @import("std");

/// Wire format version; a reader refuses any other value (the versioning
/// discipline of OQ 26, applied to the wire from the first byte).
pub const version: u8 = 1;

/// A frame's length prefix, in bytes.
pub const len_bytes = 4;

/// Upper bound on a frame body. Provisional, like the queue bound and the
/// other OQ 55/36 sizes; a larger frame is refused, never buffered.
///
/// Must exceed `journal.max_entry_bytes` (16 MiB default) by the record
/// and message overhead: an accepted entry has to fit in one frame, or it
/// can never be replicated (bug
/// 2026-08-28-sweep3-oversized-entry-unreplicable).
pub const max_body_bytes: u32 = 16 * 1024 * 1024 + 1024 * 1024;

pub const ReadError = error{ EndOfStream, OversizedFrame, OutOfMemory } || std.Io.Reader.Error;

/// Writes one frame: the 4-byte length prefix, then the body verbatim.
pub fn writeFrame(writer: *std.Io.Writer, body: []const u8) !void {
    if (body.len > max_body_bytes) return error.OversizedFrame;
    var hdr: [len_bytes]u8 = undefined;
    std.mem.writeInt(u32, &hdr, @intCast(body.len), .little);
    try writer.writeAll(&hdr);
    try writer.writeAll(body);
}

/// How much of a body is read, and committed, at a time.
pub const read_chunk_bytes: usize = 64 * 1024;

/// Reads one frame body into a freshly allocated buffer (the caller frees
/// it — typically by resetting the frame arena it was allocated from).
/// `error.EndOfStream` means the peer closed before a full frame arrived.
///
/// The body is read a chunk at a time and the buffer grown as the chunks
/// arrive, so what a connection commits follows the bytes delivered rather
/// than the length its 4-byte header claims. Allocating `len` up front let
/// a peer that announced a `max_body_bytes` frame and then sent nothing
/// hold 17 MiB for as long as it kept the connection open, and the header
/// is read before the connection has a role — `frameAllowed` is applied to
/// the decoded message, which is two steps later. That is not a defence
/// against a hostile peer, which the trust model does not claim (RFC 0009);
/// it keeps a truncated or dead connection from costing what a complete one
/// would.
pub fn readFrame(allocator: std.mem.Allocator, reader: *std.Io.Reader) ReadError![]u8 {
    var hdr: [len_bytes]u8 = undefined;
    reader.readSliceAll(&hdr) catch |err| switch (err) {
        error.EndOfStream => return error.EndOfStream,
        else => return err,
    };
    const len = std.mem.readInt(u32, &hdr, .little);
    if (len > max_body_bytes) return error.OversizedFrame;
    var body = try std.ArrayListUnmanaged(u8).initCapacity(
        allocator,
        @min(len, read_chunk_bytes),
    );
    errdefer body.deinit(allocator);
    while (body.items.len < len) {
        const start = body.items.len;
        const want = @min(len - start, read_chunk_bytes);
        try body.resize(allocator, start + want);
        reader.readSliceAll(body.items[start..]) catch |err| switch (err) {
            error.EndOfStream => return error.EndOfStream,
            else => return err,
        };
    }
    return body.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const test_alloc = std.testing.allocator;

/// A reader that delivers the underlying bytes in chunks of at most
/// `max_chunk`, so frame reading is exercised across delivery boundaries
/// (a socket can hand a frame over any number of reads).
const ChunkedReader = struct {
    reader: std.Io.Reader,
    data: []const u8,
    pos: usize,
    max_chunk: usize,

    fn init(data: []const u8, max_chunk: usize) ChunkedReader {
        var self = ChunkedReader{
            .reader = undefined,
            .data = data,
            .pos = 0,
            .max_chunk = max_chunk,
        };
        self.reader = .{
            .vtable = &.{ .stream = stream },
            .buffer = &.{},
            .seek = 0,
            .end = 0,
        };
        return self;
    }

    fn stream(
        io_r: *std.Io.Reader,
        io_w: *std.Io.Writer,
        limit: std.Io.Limit,
    ) std.Io.Reader.StreamError!usize {
        const self: *ChunkedReader = @fieldParentPtr("reader", io_r);
        // A `stream` that has nothing left must say so, not return 0.
        // `Reader.readSliceShort` loops on its vtable until the buffer is
        // full or an error arrives, so a zero-length "success" spins
        // forever. Nothing had read past the end of a ChunkedReader before
        // the truncated-frame test below, which is why it never showed.
        if (self.pos == self.data.len) return error.EndOfStream;
        const dest = limit.slice(try io_w.writableSliceGreedy(1));
        const chunk = @min(@min(self.max_chunk, self.data.len - self.pos), dest.len);
        @memcpy(dest[0..chunk], self.data[self.pos..][0..chunk]);
        self.pos += chunk;
        io_w.advance(chunk);
        return chunk;
    }
};

fn roundTrip(body: []const u8) ![]u8 {
    var out_buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&out_buf);
    try writeFrame(&writer, body);
    const frame = writer.buffered();
    var reader = std.Io.Reader.fixed(frame);
    return readFrame(test_alloc, &reader);
}

test "a frame round-trips through write and read" {
    const body = "hello over the wire";
    const got = try roundTrip(body);
    defer test_alloc.free(got);
    try std.testing.expectEqualStrings(body, got);
}

test "an empty body round-trips" {
    const got = try roundTrip("");
    defer test_alloc.free(got);
    try std.testing.expectEqual(@as(usize, 0), got.len);
}

test "the frame reader delivers a body split across reads" {
    const body = "a frame that arrives in awkward chunks";
    var out_buf: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&out_buf);
    try writeFrame(&writer, body);
    const frame = writer.buffered();

    var chunked = ChunkedReader.init(frame, 3);
    const got = try readFrame(test_alloc, &chunked.reader);
    defer test_alloc.free(got);
    try std.testing.expectEqualStrings(body, got);
}

test "an oversized frame is refused by name, not buffered" {
    var hdr: [len_bytes]u8 = undefined;
    std.mem.writeInt(u32, &hdr, max_body_bytes + 1, .little);
    var chunked = ChunkedReader.init(&hdr, 1);
    try std.testing.expectError(error.OversizedFrame, readFrame(test_alloc, &chunked.reader));
}

test "a close mid-frame is EndOfStream, not a partial body" {
    const body = "truncated payload";
    var out_buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&out_buf);
    try writeFrame(&writer, body);
    const frame = writer.buffered();
    // Only the length prefix and half the body arrive.
    var reader = std.Io.Reader.fixed(frame[0 .. len_bytes + 4]);
    try std.testing.expectError(error.EndOfStream, readFrame(test_alloc, &reader));
}

test "a close between frames is EndOfStream too" {
    var empty = std.Io.Reader.fixed("");
    try std.testing.expectError(error.EndOfStream, readFrame(test_alloc, &empty));
}

test "a frame body is committed as it arrives, not as it is announced" {
    // The header announces the largest body the wire allows and the peer
    // then sends none of it - a connection that died mid-frame, or one
    // whose header was never honest. Reading the body up front meant that
    // header alone committed 17 MiB.
    var hdr: [len_bytes]u8 = undefined;
    std.mem.writeInt(u32, &hdr, max_body_bytes, .little);

    // Far less memory than the frame claims, and more than a chunk of it.
    var buf: [4 * read_chunk_bytes]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    var chunked = ChunkedReader.init(&hdr, len_bytes);

    // The answer is "the peer is gone", which is what the loop acts on -
    // not a failure to find room for bytes that never arrived.
    try std.testing.expectError(
        error.EndOfStream,
        readFrame(fba.allocator(), &chunked.reader),
    );
}

test "a body larger than one chunk still round-trips" {
    // The chunked read must reassemble a body that spans several chunks in
    // order, and hand back exactly it.
    const len = 3 * read_chunk_bytes + 17;
    const body = try test_alloc.alloc(u8, len);
    defer test_alloc.free(body);
    for (body, 0..) |*b, i| b.* = @truncate(i *% 31);

    const frame = try test_alloc.alloc(u8, len_bytes + len);
    defer test_alloc.free(frame);
    var writer = std.Io.Writer.fixed(frame);
    try writeFrame(&writer, body);

    // Delivered in awkward pieces, so no chunk boundary lines up.
    var chunked = ChunkedReader.init(writer.buffered(), 7000);
    const got = try readFrame(test_alloc, &chunked.reader);
    defer test_alloc.free(got);
    try std.testing.expectEqualSlices(u8, body, got);
}
