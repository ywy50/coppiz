//! The entry: the immutable, author-signed unit of a journal (PRD 0001).
//!
//! An entry is what an author writes. Its bytes never change on any member;
//! it is identified by `(author, author_seq)` and referenced from a slot by
//! `entry_hash` — the SHA-256 of the whole header *including* the signature,
//! which is what makes a `stale` mark able to name a target by id while the
//! chain still pins its bytes. This module owns the wire/on-disk codec and
//! signature rules; which `(slot, entry)` pairs are valid lives in
//! `chain.zig`.
//!
//! Layout (draft sizes from PRD 0001; this module is the source of truth
//! once the format freezes). All integers little-endian, encoded field by
//! field — a native struct is never cast onto the bytes:
//!
//!   magic 4 | version 2 | kind 2 | journal 16 | author 16 | author_seq 8 |
//!   author_ts_ms 8 | ttl_ms 8 | payload_len 4 | payload_hash 32 |
//!   signature 64 | payload
//!
//! The signature covers every field before it (offsets 0..100); the payload
//! is covered by `payload_hash`, which is inside the signed region.

const std = @import("std");
const crypto = std.crypto;

/// 4-byte format marker. Product-derived (ADR 0004); the entry format is
/// versioned independently of the product name, so a future rename need not
/// touch it.
pub const magic: [4]u8 = "CPPZ".*;

/// Entry format version; a reader refuses any other value.
pub const version: u16 = 1;

/// Fixed header size in bytes: 4+2+2+16+16+8+8+8+4+32+64 = 164 (PRD 0001).
pub const header_len = 164;

/// Bytes of the header the author's Ed25519 signature covers: everything
/// before the signature field.
pub const signed_region_len = 100;

/// Control kinds follow PRD 0001's table, in table order; `data` is first.
/// `join`/`leave`/`epoch`/`merge` belong to PRD 0003: the values exist for
/// format stability, but chain validation refuses them until then.
pub const Kind = enum(u16) {
    data = 0,
    genesis = 1,
    create_journal = 2,
    join = 3,
    leave = 4,
    epoch = 5,
    merge = 6,
    settings = 7,
    stale = 8,
    checkpoint = 9,

    pub fn isControl(self: Kind) bool {
        return self != .data;
    }

    /// Lowercase name for refusal messages and the CLI.
    pub fn name(self: Kind) []const u8 {
        return switch (self) {
            .data => "data",
            .genesis => "genesis",
            .create_journal => "create_journal",
            .join => "join",
            .leave => "leave",
            .epoch => "epoch",
            .merge => "merge",
            .settings => "settings",
            .stale => "stale",
            .checkpoint => "checkpoint",
        };
    }
};

/// An entry id: `(author, author_seq)`, stable forever — across merges and
/// restarts (glossary). A `stale` mark names its target by this, never by
/// entry hash, because the id carries the author.
pub const Id = struct {
    author: [16]u8,
    author_seq: u64,
};

/// A decoded entry. `payload` borrows from the bytes handed to `decode`; an
/// entry built for encoding owns its payload slice.
///
/// `payload_len` is the signed header field, preserved even when the payload
/// bytes have been dropped by a checkpoint compaction (`payload_omitted`):
/// the header — and therefore `entry_hash` and the author's signature —
/// never changes, so a compacted chain still verifies (PRD 0002 *retain*).
pub const Entry = struct {
    kind: Kind,
    journal: [16]u8,
    author: [16]u8,
    author_seq: u64,
    author_ts_ms: u64,
    ttl_ms: u64,
    payload_hash: [32]u8,
    signature: [64]u8,
    /// The signed `payload_len` header field. For a live entry this equals
    /// `payload.len`; for a compacted entry the payload is empty but the
    /// original length survives so the header is byte-identical.
    payload_len: u32,
    /// True when the payload bytes were dropped by a checkpoint compaction.
    payload_omitted: bool,
    payload: []const u8,

    pub fn id(self: *const Entry) Id {
        return .{ .author = self.author, .author_seq = self.author_seq };
    }

    pub fn isControl(self: *const Entry) bool {
        return self.kind.isControl();
    }
};

/// SHA-256 of a payload; the field the signed header pins.
pub fn payloadHash(payload: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    crypto.hash.sha2.Sha256.hash(payload, &out, .{});
    return out;
}

/// Encodes the 164-byte header, signature field included, into `header`.
/// The signed region is offsets 0..100 and never depends on `entry.signature`.
pub fn encodeHeader(entry: *const Entry, header: *[header_len]u8) void {
    header[0..4].* = magic;
    std.mem.writeInt(u16, header[4..6], version, .little);
    std.mem.writeInt(u16, header[6..8], @intFromEnum(entry.kind), .little);
    header[8..24].* = entry.journal;
    header[24..40].* = entry.author;
    std.mem.writeInt(u64, header[40..48], entry.author_seq, .little);
    std.mem.writeInt(u64, header[48..56], entry.author_ts_ms, .little);
    std.mem.writeInt(u64, header[56..64], entry.ttl_ms, .little);
    std.mem.writeInt(u32, header[64..68], entry.payload_len, .little);
    header[68..100].* = entry.payload_hash;
    header[100..164].* = entry.signature;
}

/// The bytes the author signs: the header up to (not including) the
/// signature field.
pub fn signedRegion(header: *const [header_len]u8) []const u8 {
    return header[0..signed_region_len];
}

/// Signs the header fields with the author's key. The signature itself is
/// not part of the signed region, so the caller fills `entry.signature` from
/// the result before encoding.
pub fn sign(kp: crypto.sign.Ed25519.KeyPair, entry: *const Entry) !crypto.sign.Ed25519.Signature {
    var header: [header_len]u8 = undefined;
    encodeHeader(entry, &header);
    return crypto.sign.Ed25519.KeyPair.sign(kp, signedRegion(&header), null);
}

/// Verifies `entry.signature` over the header fields against the author's
/// public key. Refusal names the reason; the entry must be rejected as a
/// whole — a bad signature means the bytes are not what the author wrote.
pub fn verify(public_key: crypto.sign.Ed25519.PublicKey, entry: *const Entry) !void {
    var header: [header_len]u8 = undefined;
    encodeHeader(entry, &header);
    const sig = crypto.sign.Ed25519.Signature.fromBytes(entry.signature);
    try sig.verify(signedRegion(&header), public_key);
}

/// `entry_hash` = SHA-256 of the whole header including the signature; this
/// is what a slot references and what the chain pins.
pub fn entryHash(entry: *const Entry) [32]u8 {
    var header: [header_len]u8 = undefined;
    encodeHeader(entry, &header);
    var out: [32]u8 = undefined;
    crypto.hash.sha2.Sha256.hash(&header, &out, .{});
    return out;
}

/// Encodes the full record — header then payload — into `buf`, which must be
/// exactly `header_len + payload.len` bytes.
pub fn encode(entry: *const Entry, buf: []u8) !void {
    if (buf.len != header_len + entry.payload.len) return error.BufferWrongSize;
    encodeHeader(entry, buf[0..header_len]);
    @memcpy(buf[header_len..], entry.payload);
}

/// Decodes an entry from either a full record (header + `payload_len` bytes)
/// or a compacted record whose payload was dropped by a checkpoint (header
/// only, `payload_omitted` set, payload empty — the original `payload_len`
/// survives in the signed header). `payload` borrows from `bytes`. Refuses a
/// wrong magic, an unknown version, an unknown kind, and any length that is
/// neither of the two shapes.
pub fn decode(
    bytes: []const u8,
) error{ BadMagic, UnsupportedVersion, UnknownKind, Truncated, TrailingBytes }!Entry {
    if (bytes.len < header_len) return error.Truncated;
    if (!std.mem.eql(u8, bytes[0..4], &magic)) return error.BadMagic;
    const v = std.mem.readInt(u16, bytes[4..6], .little);
    if (v != version) return error.UnsupportedVersion;
    const kind_int = std.mem.readInt(u16, bytes[6..8], .little);
    const max_kind = @intFromEnum(std.meta.tags(Kind)[std.meta.tags(Kind).len - 1]);
    const kind: Kind =
        if (kind_int > max_kind) return error.UnknownKind else @enumFromInt(kind_int);
    const payload_len = std.mem.readInt(u32, bytes[64..68], .little);
    if (bytes.len == header_len and payload_len > 0) {
        // The compacted shape: header only, payload dropped by a checkpoint.
        return .{
            .kind = kind,
            .journal = bytes[8..24].*,
            .author = bytes[24..40].*,
            .author_seq = std.mem.readInt(u64, bytes[40..48], .little),
            .author_ts_ms = std.mem.readInt(u64, bytes[48..56], .little),
            .ttl_ms = std.mem.readInt(u64, bytes[56..64], .little),
            .payload_hash = bytes[68..100].*,
            .signature = bytes[100..164].*,
            .payload_len = payload_len,
            .payload_omitted = true,
            .payload = &.{},
        };
    }
    if (bytes.len != header_len + payload_len) {
        return if (bytes.len < header_len + payload_len) error.Truncated else error.TrailingBytes;
    }
    return .{
        .kind = kind,
        .journal = bytes[8..24].*,
        .author = bytes[24..40].*,
        .author_seq = std.mem.readInt(u64, bytes[40..48], .little),
        .author_ts_ms = std.mem.readInt(u64, bytes[48..56], .little),
        .ttl_ms = std.mem.readInt(u64, bytes[56..64], .little),
        .payload_hash = bytes[68..100].*,
        .signature = bytes[100..164].*,
        .payload_len = payload_len,
        .payload_omitted = false,
        .payload = bytes[header_len..],
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn testEntry(comptime kind: Kind, payload: []const u8) Entry {
    return .{
        .kind = kind,
        .journal = "0123456789abcdef".*,
        .author = "fedcba9876543210".*,
        .author_seq = 7,
        .author_ts_ms = 1_700_000_000_000,
        .ttl_ms = 0,
        .payload_hash = payloadHash(payload),
        .payload_len = @intCast(payload.len),
        .payload_omitted = false,
        .signature = [_]u8{0} ** 64,
        .payload = payload,
    };
}

test "round trip: encode then decode returns every field" {
    const payload = "the payload bytes a consumer stores";
    var buf: [header_len + payload.len]u8 = undefined;
    const src = testEntry(.data, payload);
    try encode(&src, &buf);
    const got = try decode(&buf);
    try std.testing.expectEqual(src.kind, got.kind);
    try std.testing.expectEqualSlices(u8, &src.journal, &got.journal);
    try std.testing.expectEqualSlices(u8, &src.author, &got.author);
    try std.testing.expectEqual(src.author_seq, got.author_seq);
    try std.testing.expectEqual(src.author_ts_ms, got.author_ts_ms);
    try std.testing.expectEqual(src.ttl_ms, got.ttl_ms);
    try std.testing.expectEqualSlices(u8, &src.payload_hash, &got.payload_hash);
    try std.testing.expectEqualSlices(u8, &src.signature, &got.signature);
    try std.testing.expectEqualSlices(u8, payload, got.payload);
}

test "encode is deterministic for identical entries" {
    var a: [header_len + 4]u8 = undefined;
    var b: [header_len + 4]u8 = undefined;
    try encode(&testEntry(.data, "abcd"), &a);
    try encode(&testEntry(.data, "abcd"), &b);
    try std.testing.expectEqualSlices(u8, &a, &b);
}

test "entry hash covers the signature and differs across kinds" {
    var io_state = std.Io.Threaded.init(std.testing.allocator, .{});
    const kp = crypto.sign.Ed25519.KeyPair.generate(io_state.io());
    var entry = testEntry(.data, "hash me");
    entry.signature = (try sign(kp, &entry)).toBytes();
    const h1 = entryHash(&entry);
    entry.signature[0] ^= 1;
    const h2 = entryHash(&entry);
    try std.testing.expect(!std.mem.eql(u8, &h1, &h2));
}

test "signature verifies under the author's key and fails under another" {
    var io_state = std.Io.Threaded.init(std.testing.allocator, .{});
    const io = io_state.io();
    const author = crypto.sign.Ed25519.KeyPair.generate(io);
    const stranger = crypto.sign.Ed25519.KeyPair.generate(io);
    var entry = testEntry(.data, "signed payload");
    entry.signature = (try sign(author, &entry)).toBytes();

    try verify(author.public_key, &entry);
    try std.testing.expectError(
        error.SignatureVerificationFailed,
        verify(stranger.public_key, &entry),
    );

    // A flip inside the signed region breaks verification.
    var corrupt = entry;
    corrupt.author_seq += 1;
    try std.testing.expectError(
        error.SignatureVerificationFailed,
        verify(author.public_key, &corrupt),
    );
}

test "payload is pinned by the signed payload_hash" {
    var io_state = std.Io.Threaded.init(std.testing.allocator, .{});
    const kp = crypto.sign.Ed25519.KeyPair.generate(io_state.io());
    var entry = testEntry(.data, "original");
    entry.signature = (try sign(kp, &entry)).toBytes();
    try verify(kp.public_key, &entry);

    // The signature still verifies if the payload is swapped, because the
    // payload is not signed directly — its hash is. Chain validation must
    // therefore compare payload_hash before trusting any decoded payload.
    const tampered = Entry{
        .kind = entry.kind,
        .journal = entry.journal,
        .author = entry.author,
        .author_seq = entry.author_seq,
        .author_ts_ms = entry.author_ts_ms,
        .ttl_ms = entry.ttl_ms,
        .payload_hash = entry.payload_hash,
        .payload_len = entry.payload_len,
        .payload_omitted = false,
        .signature = entry.signature,
        .payload = "tampered",
    };
    try verify(kp.public_key, &tampered); // signature passes...
    try std.testing.expect(
        !std.mem.eql(u8, &payloadHash(tampered.payload), &entry.payload_hash),
    ); // ...hash does not
}

test "unsupported version, wrong magic, and bad lengths are refused by name" {
    const payload = "x";
    var buf: [header_len + 1]u8 = undefined;
    try encode(&testEntry(.data, payload), &buf);

    var v2 = buf;
    std.mem.writeInt(u16, v2[4..6], version + 1, .little);
    try std.testing.expectError(error.UnsupportedVersion, decode(&v2));

    var bad_magic = buf;
    bad_magic[0] = 'X';
    try std.testing.expectError(error.BadMagic, decode(&bad_magic));

    try std.testing.expectError(error.Truncated, decode(buf[0 .. header_len - 1]));
    var trailing = [_]u8{0} ** 2;
    try std.testing.expectError(error.TrailingBytes, decode(buf ++ &trailing));
}

test "unknown kind value is refused, not misread" {
    const payload = "x";
    var buf: [header_len + 1]u8 = undefined;
    try encode(&testEntry(.data, payload), &buf);
    const max_kind = @intFromEnum(std.meta.tags(Kind)[std.meta.tags(Kind).len - 1]);
    std.mem.writeInt(u16, buf[6..8], max_kind + 1, .little);
    try std.testing.expectError(error.UnknownKind, decode(&buf));
}

const FuzzCtx = struct {
    fn fuzzOne(_: @This(), smith: *std.testing.Smith) anyerror!void {
        var buf: [512]u8 = undefined;
        const len = smith.slice(&buf);
        // Any error is acceptable; the decoder must never crash or read out
        // of bounds, and a successful decode must consume exactly the
        // declared record.
        const got = decode(buf[0..len]) catch return;
        try std.testing.expectEqual(header_len + got.payload.len, buf.len);
    }
};

test "entry decoder fuzzes over untrusted bytes" {
    try std.testing.fuzz(FuzzCtx{}, FuzzCtx.fuzzOne, .{});
}
