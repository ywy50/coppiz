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
pub const max_body_bytes: u32 = 8 * 1024 * 1024;

pub const ReadError = error{ EndOfStream, OversizedFrame, OutOfMemory } || std.Io.Reader.Error;

/// Writes one frame: the 4-byte length prefix, then the body verbatim.
pub fn writeFrame(writer: *std.Io.Writer, body: []const u8) !void {
    if (body.len > max_body_bytes) return error.OversizedFrame;
    var hdr: [len_bytes]u8 = undefined;
    std.mem.writeInt(u32, &hdr, @intCast(body.len), .little);
    try writer.writeAll(&hdr);
    try writer.writeAll(body);
}

/// Reads one frame body into a freshly allocated buffer (the caller frees
/// it — typically by resetting the frame arena it was allocated from).
/// `error.EndOfStream` means the peer closed before a full frame arrived.
pub fn readFrame(allocator: std.mem.Allocator, reader: *std.Io.Reader) ReadError![]u8 {
    var hdr: [len_bytes]u8 = undefined;
    reader.readSliceAll(&hdr) catch |err| switch (err) {
        error.EndOfStream => return error.EndOfStream,
        else => return err,
    };
    const len = std.mem.readInt(u32, &hdr, .little);
    if (len > max_body_bytes) return error.OversizedFrame;
    const body = try allocator.alloc(u8, len);
    errdefer allocator.free(body);
    reader.readSliceAll(body) catch |err| switch (err) {
        error.EndOfStream => return error.EndOfStream,
        else => return err,
    };
    return body;
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
        if (self.pos == self.data.len) return 0; // EOF
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
