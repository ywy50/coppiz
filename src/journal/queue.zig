//! The unslotted queue: a member's durable list of entries it authored or
//! received that have no slot yet (PRD 0001 *Write path*).
//!
//! An append writes the entry to this file first (durably, so a crash does
//! not lose an acknowledged-as-accepted write), forwards it to the leader,
//! and removes it once the slot lands. At the single-member milestone the
//! leader is the local member, so the queue is written and drained within
//! one append call; its replay on restart is what makes the crash-then-reslot
//! path safe (a redelivered entry is idempotent in the fold).
//!
//! The file is a header plus length-prefixed CRC-checked records of entry
//! bytes, bounded by `sync.unslotted_max_bytes` (local config, provisional
//! default in the node): an append past the bound refuses with
//! `queue_full` rather than evicting anything (OQ 55 overflow behaviour
//! choice). A torn tail is truncated at open — an unacknowledged entry.

const std = @import("std");
const entry = @import("entry.zig");

pub const magic: [4]u8 = "CPPQ".*;
pub const version: u16 = 1;
pub const header_len = 4 + 2;
pub const record_prefix_len = 8; // len u32 | crc u32

pub const QueueError = error{
    QueueFull,
    OutOfMemory,
    Corrupt,
    Truncated,
    BadMagic,
    UnsupportedVersion,
    InputOutput,
};

pub const Queue = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
    /// Bytes currently queued (records only, excluding the header).
    queued_bytes: u64,
    max_bytes: u64,

    /// Opens (or creates) the queue file and recovers a torn tail.
    pub fn open(
        allocator: std.mem.Allocator,
        io: std.Io,
        dir: std.Io.Dir,
        max_bytes: u64,
    ) anyerror!Queue {
        // truncate=false: an existing queue must survive an open. The
        // created file is opened read-write (createFile's `read` flag is
        // about access, not mode; an existing file is reopened read-write).
        const file = dir.createFile(io, "unslotted.queue", .{
            .read = true,
            .truncate = false,
        }) catch |err| blk: {
            if (err != error.PathAlreadyExists) return err;
            break :blk try dir.openFile(io, "unslotted.queue", .{ .mode = .read_write });
        };
        errdefer file.close(io);

        var len = try file.length(io);
        if (len < header_len) {
            // A brand-new (or truncated-before-the-header) file: write the
            // header and treat the file as empty.
            try file.setLength(io, header_len);
            var header: [header_len]u8 = undefined;
            writeHeader(&header);
            try file.writePositionalAll(io, &header, 0);
            len = header_len;
        } else {
            var header: [header_len]u8 = undefined;
            const n = try file.readPositionalAll(io, &header, 0);
            if (n != header.len) return error.Truncated;
            if (!std.mem.eql(u8, header[0..4], &magic)) return error.BadMagic;
            if (std.mem.readInt(u16, header[4..6], .little) != version) {
                return error.UnsupportedVersion;
            }
        }

        // Scan records; a torn tail is truncated.
        const records_len = len - header_len;
        const records = try allocator.alloc(u8, @intCast(records_len));
        defer allocator.free(records);
        const m = try file.readPositionalAll(io, records, header_len);
        if (m != records.len) return error.Truncated;
        var off: usize = 0;
        var good: usize = 0;
        while (off < records.len) {
            const rec_len = scanRecord(records[off..]) catch break;
            off += rec_len;
            good = off;
        }
        if (off != records.len) {
            try file.setLength(io, header_len + good);
        }
        if (len != header_len + good) try file.sync(io);

        return .{
            .allocator = allocator,
            .io = io,
            .file = file,
            .queued_bytes = good,
            .max_bytes = max_bytes,
        };
    }

    pub fn deinit(self: *Queue) void {
        self.file.close(self.io);
        self.* = undefined;
    }

    /// Appends one entry to the queue; refuses `queue_full` past the bound.
    pub fn append(self: *Queue, en: *const entry.Entry) !void {
        const size = recordSize(en);
        if (self.queued_bytes + size > self.max_bytes) return error.QueueFull;
        const buf = try self.allocator.alloc(u8, size);
        defer self.allocator.free(buf);
        encodeRecord(en, buf);
        const offset = header_len + self.queued_bytes;
        try self.file.writePositionalAll(self.io, buf, offset);
        self.queued_bytes += size;
        try self.file.sync(self.io);
    }

    /// Iterates the queued entries (for replay at open and after a crash).
    pub fn scan(
        self: *Queue,
        ctx: anytype,
        comptime on_entry: fn (@TypeOf(ctx), *const entry.Entry) anyerror!void,
    ) !void {
        const len = try self.file.length(self.io);
        const records_len = len - header_len;
        const records = try self.allocator.alloc(u8, @intCast(records_len));
        defer self.allocator.free(records);
        const n = try self.file.readPositionalAll(self.io, records, header_len);
        if (n != records.len) return error.Truncated;
        var off: usize = 0;
        while (off < records.len) {
            const rec_len = try scanRecord(records[off..]);
            var en = try entry.decode(records[off + record_prefix_len .. off + rec_len]);
            try on_entry(ctx, &en);
            off += rec_len;
        }
    }

    /// Removes one queued entry by its journal and id — its slot landed. A
    /// missing entry is a no-op (already trimmed). The queue file is
    /// rewritten without it; record bytes are re-encoded identically.
    pub fn remove(self: *Queue, journal_id: [16]u8, id: entry.Id) !void {
        const Ctx = struct {
            allocator: std.mem.Allocator,
            list: *std.ArrayListUnmanaged(u8),
            journal_id: [16]u8,
            id: entry.Id,
        };
        var kept = std.ArrayListUnmanaged(u8).empty;
        defer kept.deinit(self.allocator);
        var ctx = Ctx{
            .allocator = self.allocator,
            .list = &kept,
            .journal_id = journal_id,
            .id = id,
        };
        try self.scan(&ctx, struct {
            fn cb(c: *Ctx, en: *const entry.Entry) anyerror!void {
                if (std.mem.eql(u8, &en.journal, &c.journal_id) and
                    std.mem.eql(u8, &en.author, &c.id.author) and
                    en.author_seq == c.id.author_seq) return;
                const buf = try c.allocator.alloc(u8, recordSize(en));
                defer c.allocator.free(buf);
                encodeRecord(en, buf);
                try c.list.appendSlice(c.allocator, buf);
            }
        }.cb);
        if (kept.items.len == @as(usize, @intCast(self.queued_bytes))) return; // nothing to trim
        try self.file.writePositionalAll(self.io, kept.items, header_len);
        try self.file.setLength(self.io, header_len + kept.items.len);
        self.queued_bytes = @intCast(kept.items.len);
        try self.file.sync(self.io);
    }

    /// Empties the queue (all queued entries have been slotted).
    pub fn clear(self: *Queue) !void {
        try self.file.setLength(self.io, header_len);
        self.queued_bytes = 0;
        try self.file.sync(self.io);
    }
};

fn writeHeader(buf: *[header_len]u8) void {
    buf[0..4].* = magic;
    std.mem.writeInt(u16, buf[4..6], version, .little);
}

fn recordSize(en: *const entry.Entry) usize {
    return record_prefix_len + entry.header_len + en.payload.len;
}

fn encodeRecord(en: *const entry.Entry, buf: []u8) void {
    std.mem.writeInt(u32, buf[0..4], @intCast(buf.len - record_prefix_len), .little);
    var header: [entry.header_len]u8 = undefined;
    entry.encodeHeader(en, &header);
    @memcpy(buf[record_prefix_len .. record_prefix_len + entry.header_len], &header);
    @memcpy(buf[record_prefix_len + entry.header_len ..], en.payload);
    const crc = std.hash.crc.Crc32.hash(buf[record_prefix_len..]);
    std.mem.writeInt(u32, buf[4..8], crc, .little);
}

/// Validates one record's prefix and CRC, returning its total length.
fn scanRecord(bytes: []const u8) error{ Truncated, BadCrc }!usize {
    if (bytes.len < record_prefix_len) return error.Truncated;
    const body_len = std.mem.readInt(u32, bytes[0..4], .little);
    if (body_len < entry.header_len) return error.BadCrc;
    if (record_prefix_len + body_len > bytes.len) return error.Truncated;
    const body = bytes[record_prefix_len .. record_prefix_len + body_len];
    const want_crc = std.mem.readInt(u32, bytes[4..8], .little);
    if (std.hash.crc.Crc32.hash(body) != want_crc) return error.BadCrc;
    return record_prefix_len + body_len;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const test_alloc = std.testing.allocator;
const tio = std.testing.io;

const TestEnv = struct {
    tmp: std.testing.TmpDir,

    fn init() TestEnv {
        return .{ .tmp = std.testing.tmpDir(.{}) };
    }

    fn deinit(self: *TestEnv) void {
        self.tmp.cleanup();
    }
};

fn testEntry(payload: []const u8) entry.Entry {
    return .{
        .kind = .data,
        .journal = "0123456789abcdef".*,
        .author = "fedcba9876543210".*,
        .author_seq = 1,
        .author_ts_ms = 0,
        .ttl_ms = 0,
        .payload_hash = entry.payloadHash(payload),
        .payload_len = @intCast(payload.len),
        .payload_omitted = false,
        .signature = [_]u8{0} ** 64,
        .payload = payload,
    };
}

test "queue appends, scans, clears and survives reopen" {
    var env = TestEnv.init();
    defer env.deinit();

    {
        var queue = try Queue.open(test_alloc, tio, env.tmp.dir, 1 << 20);
        defer queue.deinit();
        const one = testEntry("one");
        try queue.append(&one);
        const two = testEntry("two");
        try queue.append(&two);

        var seen: usize = 0;
        try queue.scan(&seen, struct {
            fn cb(c: *usize, en: *const entry.Entry) anyerror!void {
                try std.testing.expectEqualStrings(if (c.* == 0) "one" else "two", en.payload);
                c.* += 1;
            }
        }.cb);
        try std.testing.expectEqual(@as(usize, 2), seen);

        try queue.clear();
        try std.testing.expectEqual(@as(u64, 0), queue.queued_bytes);
    }

    // Reopen: the cleared queue stays empty.
    var queue = try Queue.open(test_alloc, tio, env.tmp.dir, 1 << 20);
    defer queue.deinit();
    var seen: usize = 0;
    try queue.scan(&seen, struct {
        fn cb(c: *usize, _: *const entry.Entry) anyerror!void {
            c.* += 1;
        }
    }.cb);
    try std.testing.expectEqual(@as(usize, 0), seen);
}

test "the queue bound refuses with queue_full and a test trips it (G6)" {
    var env = TestEnv.init();
    defer env.deinit();
    // One 70-byte-payload record is 242 bytes; 250 fits exactly one.
    var queue = try Queue.open(test_alloc, tio, env.tmp.dir, 250);
    defer queue.deinit();

    var big_payload = [_]u8{0x41} ** 70;
    const one = testEntry(&big_payload);
    try queue.append(&one);
    const two = testEntry(&big_payload);
    try std.testing.expectError(error.QueueFull, queue.append(&two));
    // The queue is unchanged by the refusal.
    try std.testing.expectEqual(@as(u64, 242), queue.queued_bytes);
}

test "a torn tail in the queue is truncated at open" {
    var env = TestEnv.init();
    defer env.deinit();
    {
        var queue = try Queue.open(test_alloc, tio, env.tmp.dir, 1 << 20);
        const one = testEntry("one");
        try queue.append(&one);
        const two = testEntry("two");
        try queue.append(&two);
        queue.deinit();
    }

    // Corrupt the tail by truncating the file mid-record.
    const file = try env.tmp.dir.openFile(tio, "unslotted.queue", .{ .mode = .read_write });
    defer file.close(tio);
    const len = try file.length(tio);
    try file.setLength(tio, len - 10);

    var queue = try Queue.open(test_alloc, tio, env.tmp.dir, 1 << 20);
    defer queue.deinit();
    var seen: usize = 0;
    try queue.scan(&seen, struct {
        fn cb(c: *usize, _: *const entry.Entry) anyerror!void {
            c.* += 1;
        }
    }.cb);
    try std.testing.expectEqual(@as(usize, 1), seen);
}

test "an unknown queue version is refused" {
    var env = TestEnv.init();
    defer env.deinit();
    {
        var queue = try Queue.open(test_alloc, tio, env.tmp.dir, 1 << 20);
        queue.deinit();
    }
    const file = try env.tmp.dir.openFile(tio, "unslotted.queue", .{ .mode = .read_write });
    defer file.close(tio);
    var version_buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &version_buf, version + 1, .little);
    try file.writePositionalAll(tio, &version_buf, 4);

    try std.testing.expectError(
        error.UnsupportedVersion,
        Queue.open(test_alloc, tio, env.tmp.dir, 1 << 20),
    );
}

test "remove trims exactly one queued entry by journal and id" {
    var env = TestEnv.init();
    defer env.deinit();
    var queue = try Queue.open(test_alloc, tio, env.tmp.dir, 1 << 20);
    defer queue.deinit();

    const jid = "0123456789abcdef".*;
    const other_jid = "fedcba9876543210".*;
    var one = testEntry("one");
    one.journal = jid;
    one.author_seq = 1;
    var two = testEntry("two");
    two.journal = jid;
    two.author_seq = 2;
    // A second journal can carry the same (author, author_seq) pair; the
    // journal is part of the key.
    var other = testEntry("other");
    other.journal = other_jid;
    other.author_seq = 2;
    try queue.append(&one);
    try queue.append(&two);
    try queue.append(&other);

    try queue.remove(jid, one.id());
    var seen = std.ArrayListUnmanaged([]const u8).empty;
    defer {
        for (seen.items) |item| test_alloc.free(item);
        seen.deinit(test_alloc);
    }
    try queue.scan(&seen, struct {
        fn cb(list: *std.ArrayListUnmanaged([]const u8), en: *const entry.Entry) anyerror!void {
            try list.append(test_alloc, try test_alloc.dupe(u8, en.payload));
        }
    }.cb);
    try std.testing.expectEqual(@as(usize, 2), seen.items.len);
    try std.testing.expectEqualStrings("two", seen.items[0]);
    try std.testing.expectEqualStrings("other", seen.items[1]);

    // Removing again is a no-op; the same id in the other journal survives.
    try queue.remove(jid, one.id());
    var count: usize = 0;
    try queue.scan(&count, struct {
        fn cb(c: *usize, _: *const entry.Entry) anyerror!void {
            c.* += 1;
        }
    }.cb);
    try std.testing.expectEqual(@as(usize, 2), count);
}
