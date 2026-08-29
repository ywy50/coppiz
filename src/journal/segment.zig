//! The segment file format: slots and entries in chain order (PRD 0001
//! *Storage*).
//!
//! This module is the pure format knowledge — byte layouts, CRCs, hashes —
//! with no file I/O, so it unit-tests and fuzzes like the other codecs.
//! `store.zig` drives real files through it.
//!
//! Layout (all integers little-endian):
//!
//!   header:  "CPSG" 4 | version u16 | journal id 16 | group id 32
//!   record:  len u32 | crc32 u32 | body
//!            body = slot 168 + entry header 164 + payload
//!   seal:    "CPST" 4 | version u16 | segment hash 32   (sealed segments only)
//!
//! `len` covers the body; the CRC covers the body too, so a torn tail write
//! fails the CRC at open and the store truncates there — the entries lost
//! were never acknowledged past `local`. A sealed segment's hash covers the
//! record region; it is the unit parity works on (PRD 0006).

const std = @import("std");
const entry = @import("entry.zig");
const slot = @import("slot.zig");

pub const header_magic: [4]u8 = "CPSG".*;
pub const seal_magic: [4]u8 = "CPST".*;
pub const version: u16 = 1;

pub const header_len = 4 + 2 + 16 + 32;
pub const seal_len = 4 + 2 + 32;
/// Every record starts with len + crc.
pub const record_prefix_len = 8;

/// What a segment header names: the journal whose chain it holds and the
/// group that sequenced it (the group's genesis hash), so a segment is
/// self-describing when it moves between groups (PRD 0006).
pub const Header = struct {
    journal_id: [16]u8,
    group_id: [32]u8,
};

pub fn encodeHeader(header: Header, buf: *[header_len]u8) void {
    buf[0..4].* = header_magic;
    std.mem.writeInt(u16, buf[4..6], version, .little);
    buf[6..22].* = header.journal_id;
    buf[22..54].* = header.group_id;
}

/// Refuses a wrong magic or an unknown version rather than misreading.
pub fn decodeHeader(bytes: *const [header_len]u8) error{ BadMagic, UnsupportedVersion }!Header {
    if (!std.mem.eql(u8, bytes[0..4], &header_magic)) return error.BadMagic;
    const v = std.mem.readInt(u16, bytes[4..6], .little);
    if (v != version) return error.UnsupportedVersion;
    return .{ .journal_id = bytes[6..22].*, .group_id = bytes[22..54].* };
}

/// Encoded size of one record: prefix + slot + entry header + payload.
pub fn recordSize(sl: *const slot.Slot, en: *const entry.Entry) usize {
    _ = sl; // the slot is fixed-size; the signature keeps the caller honest
    return record_prefix_len + slot.encoded_len + entry.header_len + en.payload.len;
}

/// Encoded size of a slot-only record (`retain = none` compaction).
pub fn slotOnlyRecordSize() usize {
    return record_prefix_len + slot.encoded_len;
}

/// Encoded size of a header-only record (`retain = header` compaction).
pub fn headerOnlyRecordSize() usize {
    return record_prefix_len + slot.encoded_len + entry.header_len;
}

/// Encodes a header-only record (len | crc | slot | entry header) into
/// `buf`, which must hold `headerOnlyRecordSize`. The entry's payload bytes
/// are gone, but its signed header — payload_len and payload_hash included —
/// is preserved byte-for-byte, so `entry_hash` and the author's signature
/// still verify after compaction (PRD 0002 *retain*).
pub fn encodeHeaderOnlyRecord(sl: *const slot.Slot, en: *const entry.Entry, buf: []u8) void {
    std.mem.writeInt(u32, buf[0..4], @intCast(buf.len - record_prefix_len), .little);
    var tmp_slot: [slot.encoded_len]u8 = undefined;
    slot.encode(sl, &tmp_slot);
    @memcpy(buf[8 .. 8 + slot.encoded_len], &tmp_slot);
    var tmp_header: [entry.header_len]u8 = undefined;
    entry.encodeHeader(en, &tmp_header);
    @memcpy(buf[8 + slot.encoded_len ..], &tmp_header);
    const crc = std.hash.crc.Crc32.hash(buf[8..]);
    std.mem.writeInt(u32, buf[4..8], crc, .little);
}

/// Encodes a slot-only record (len | crc | slot) into `buf`, which must
/// hold `slotOnlyRecordSize`.
pub fn encodeSlotOnlyRecord(sl: *const slot.Slot, buf: []u8) void {
    std.mem.writeInt(u32, buf[0..4], @intCast(buf.len - record_prefix_len), .little);
    var tmp_slot: [slot.encoded_len]u8 = undefined;
    slot.encode(sl, &tmp_slot);
    @memcpy(buf[8..], &tmp_slot);
    const crc = std.hash.crc.Crc32.hash(buf[8..]);
    std.mem.writeInt(u32, buf[4..8], crc, .little);
}

/// Encodes one record (len | crc | slot | entry) into `buf`, which must
/// hold `recordSize`.
pub fn encodeRecord(sl: *const slot.Slot, en: *const entry.Entry, buf: []u8) void {
    std.mem.writeInt(u32, buf[0..4], @intCast(buf.len - record_prefix_len), .little);
    // The body is written in place: slot at 8..176, entry header then
    // payload after it.
    var tmp_slot: [slot.encoded_len]u8 = undefined;
    slot.encode(sl, &tmp_slot);
    @memcpy(buf[8 .. 8 + slot.encoded_len], &tmp_slot);
    var tmp_header: [entry.header_len]u8 = undefined;
    entry.encodeHeader(en, &tmp_header);
    @memcpy(buf[8 + slot.encoded_len .. 8 + slot.encoded_len + entry.header_len], &tmp_header);
    const payload_off = 8 + slot.encoded_len + entry.header_len;
    @memcpy(buf[payload_off..], en.payload);
    const crc = std.hash.crc.Crc32.hash(buf[8..]);
    std.mem.writeInt(u32, buf[4..8], crc, .little);
}

/// A decoded record. `entry.payload` borrows from the bytes handed to
/// `decodeRecord`. `entry` is null for a compacted record under
/// `ttl.retain = none`, which keeps only the slot (PRD 0002): the entry's
/// author and id are no longer readable locally, only its hash.
pub const Record = struct {
    slot: slot.Slot,
    entry: ?entry.Entry,
    /// Offset just past this record, for sequential scanning.
    next_offset: usize,
};

pub const RecordError = error{
    Truncated,
    BadCrc,
    BadMagic,
    UnsupportedVersion,
    UnknownKind,
    TrailingBytes,
};

/// Decodes one record from `bytes` (the whole record region from its start
/// offset). Verifies the length prefix and the CRC; a torn tail surfaces as
/// `Truncated` (length overruns) or `BadCrc` (partial body). A body of
/// exactly one slot is the `retain = none` compacted shape (entry dropped).
pub fn decodeRecord(bytes: []const u8) RecordError!Record {
    if (bytes.len < record_prefix_len) return error.Truncated;
    const body_len = std.mem.readInt(u32, bytes[0..4], .little);
    if (body_len < slot.encoded_len) return error.BadCrc;
    // usize arithmetic: record_prefix_len is a comptime_int, so a bare
    // `record_prefix_len + body_len` computes in u32 and a body_len near
    // max u32 wraps the sum, passes the bounds check, and slices with a
    // start past the end (bug 2026-08-28-sweep3-record-length-overflow).
    const total = @as(usize, body_len) + record_prefix_len;
    if (total > bytes.len) return error.Truncated;
    const body = bytes[record_prefix_len..total];
    const want_crc = std.mem.readInt(u32, bytes[4..8], .little);
    if (std.hash.crc.Crc32.hash(body) != want_crc) return error.BadCrc;
    const sl = slot.decode(body[0..slot.encoded_len]);
    if (body_len == slot.encoded_len) {
        return .{ .slot = sl, .entry = null, .next_offset = total };
    }
    if (body_len < slot.encoded_len + entry.header_len) return error.BadCrc;
    const en = try entry.decode(body[slot.encoded_len..]);
    return .{ .slot = sl, .entry = en, .next_offset = total };
}

/// The hash a sealed segment records: SHA-256 over the whole record region.
pub fn recordsHash(records: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(records, &out, .{});
    return out;
}

pub fn encodeSeal(hash: [32]u8, buf: *[seal_len]u8) void {
    buf[0..4].* = seal_magic;
    std.mem.writeInt(u16, buf[4..6], version, .little);
    buf[6..38].* = hash;
}

pub fn decodeSeal(bytes: *const [seal_len]u8) error{ BadMagic, UnsupportedVersion }![32]u8 {
    if (!std.mem.eql(u8, bytes[0..4], &seal_magic)) return error.BadMagic;
    const v = std.mem.readInt(u16, bytes[4..6], .little);
    if (v != version) return error.UnsupportedVersion;
    return bytes[6..38].*;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const test_alloc = std.testing.allocator;

fn testSlot(seq: u64) slot.Slot {
    return .{
        .epoch = 1,
        .seq = seq,
        .slot_ts_ms = 1000,
        .entry_hash = [_]u8{0xAB} ** 32,
        .prev_slot_hash = [_]u8{0} ** 32,
        .leader = "fedcba9876543210".*,
        .signature = [_]u8{0} ** 64,
    };
}

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

test "header round-trips and refuses wrong magic or version" {
    var buf: [header_len]u8 = undefined;
    const header = Header{ .journal_id = [_]u8{1} ** 16, .group_id = [_]u8{2} ** 32 };
    encodeHeader(header, &buf);
    const got = try decodeHeader(&buf);
    try std.testing.expectEqualSlices(u8, &header.journal_id, &got.journal_id);
    try std.testing.expectEqualSlices(u8, &header.group_id, &got.group_id);

    var bad_magic = buf;
    bad_magic[0] = 'X';
    try std.testing.expectError(error.BadMagic, decodeHeader(&bad_magic));

    var v2 = buf;
    std.mem.writeInt(u16, v2[4..6], version + 1, .little);
    try std.testing.expectError(error.UnsupportedVersion, decodeHeader(&v2));
}

test "record round-trips and the CRC pins the body" {
    const payload = "a payload";
    const sl = testSlot(3);
    const en = testEntry(payload);
    const buf = try test_alloc.alloc(u8, recordSize(&sl, &en));
    defer test_alloc.free(buf);
    encodeRecord(&sl, &en, buf);

    const rec = try decodeRecord(buf);
    try std.testing.expectEqual(@as(u64, 3), rec.slot.seq);
    try std.testing.expectEqualStrings(payload, rec.entry.?.payload);
    try std.testing.expectEqual(buf.len, rec.next_offset);

    // A slot-only record decodes with entry == null.
    const slot_buf = try test_alloc.alloc(u8, slotOnlyRecordSize());
    defer test_alloc.free(slot_buf);
    encodeSlotOnlyRecord(&sl, slot_buf);
    const rec2 = try decodeRecord(slot_buf);
    try std.testing.expect(rec2.entry == null);
    try std.testing.expectEqual(@as(u64, 3), rec2.slot.seq);

    // A flip anywhere in the body fails the CRC.
    var corrupt = try test_alloc.dupe(u8, buf);
    defer test_alloc.free(corrupt);
    corrupt[corrupt.len - 1] ^= 1;
    try std.testing.expectError(error.BadCrc, decodeRecord(corrupt));

    // A length prefix overrunning the buffer is a torn tail.
    var torn = try test_alloc.dupe(u8, buf);
    defer test_alloc.free(torn);
    std.mem.writeInt(u32, torn[0..4], @intCast(buf.len + 100), .little);
    try std.testing.expectError(error.Truncated, decodeRecord(torn));

    // A length prefix underrunning the fixed parts cannot be a valid record.
    var short = try test_alloc.dupe(u8, buf);
    defer test_alloc.free(short);
    std.mem.writeInt(u32, short[0..4], 10, .little);
    try std.testing.expectError(error.BadCrc, decodeRecord(short));
}

test "seal round-trips and version-gates" {
    var buf: [seal_len]u8 = undefined;
    const hash = [_]u8{0x42} ** 32;
    encodeSeal(hash, &buf);
    try std.testing.expectEqualSlices(u8, &hash, &(try decodeSeal(&buf)));

    var v2 = buf;
    std.mem.writeInt(u16, v2[4..6], version + 1, .little);
    try std.testing.expectError(error.UnsupportedVersion, decodeSeal(&v2));
}

test "recordsHash is stable and sensitive" {
    const sl = testSlot(1);
    const en = testEntry("x");
    const buf = try test_alloc.alloc(u8, recordSize(&sl, &en));
    defer test_alloc.free(buf);
    encodeRecord(&sl, &en, buf);
    const h1 = recordsHash(buf);
    try std.testing.expectEqualSlices(u8, &h1, &recordsHash(buf));
    buf[0] ^= 1;
    const h2 = recordsHash(buf);
    try std.testing.expect(!std.mem.eql(u8, &h1, &h2));
}

const FuzzCtx = struct {
    fn fuzzOne(_: @This(), smith: *std.testing.Smith) anyerror!void {
        // The record decoder is the untrusted-input surface (a segment may
        // arrive from a peer): any error is acceptable, a success must
        // consume exactly one well-formed record, and the payload must
        // round-trip through the entry codec.
        var buf: [1024]u8 = undefined;
        const len = smith.slice(&buf);
        const rec = decodeRecord(buf[0..len]) catch return;
        if (rec.entry) |en| {
            try std.testing.expectEqual(@as(usize, rec.next_offset), recordSize(&rec.slot, &en));
        } else {
            try std.testing.expectEqual(@as(usize, rec.next_offset), slotOnlyRecordSize());
        }
    }
};

test "record decoder fuzzes over untrusted bytes" {
    try std.testing.fuzz(FuzzCtx{}, FuzzCtx.fuzzOne, .{});
}

test "a length prefix near max u32 is Truncated, not a wrap-around slice" {
    // Bug 2026-08-28-sweep3-record-length-overflow: the sum computed in
    // u32, so body_len = 0xFFFFFFF8 wrapped past the bounds check and the
    // slice had a start past its end — a panic in safe modes. It must be
    // refused like any over-long record.
    var buf: [record_prefix_len + slot.encoded_len + 8]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], 0xFFFF_FFF8, .little);
    try std.testing.expectError(error.Truncated, decodeRecord(&buf));
}
