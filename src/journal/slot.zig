//! The slot: where the journal put an entry (PRD 0001).
//!
//! A slot is `(epoch, seq)`, assigned and signed by the leader of that
//! epoch, hash-chained to the previous slot through `prev_slot_hash`. The
//! chain is over slots, so it covers order and content (via `entry_hash`)
//! and who ordered it. Unlike the entry, the slot has no magic: it only
//! exists inside a segment record (or on the wire), whose framing supplies
//! the context.
//!
//! Layout (draft sizes from PRD 0001), all integers little-endian:
//!
//!   epoch 8 | seq 8 | slot_ts_ms 8 | entry_hash 32 | prev_slot_hash 32 |
//!   leader 16 | signature 64
//!
//! The signature covers offsets 0..104; `slot_hash` is SHA-256 of all 168
//! bytes.

const std = @import("std");
const crypto = std.crypto;

/// Slot format version; a reader refuses any other value.
pub const version: u16 = 1;

/// Fixed encoded size in bytes: 8+8+8+32+32+16+64 = 168 (PRD 0001).
pub const encoded_len = 168;

/// Bytes the leader's signature covers: everything before the signature.
pub const signed_region_len = 104;

/// `prev_slot_hash` of a journal's first slot: no previous slot, all zeros.
pub const genesis_prev: [32]u8 = [_]u8{0} ** 32;

/// A position: `(epoch, seq)` within one journal's chain. `seq` restarts at
/// 1 every epoch, so a position never identifies a slot across epochs; the
/// chain and the segment index key by the pair.
pub const Position = struct {
    epoch: u64,
    seq: u64,

    pub fn order(a: Position, b: Position) std.math.Order {
        if (a.epoch < b.epoch) return .lt;
        if (a.epoch > b.epoch) return .gt;
        return std.math.order(a.seq, b.seq);
    }

    /// The position one past `self`, for half-open slot ranges.
    pub fn next(self: Position) Position {
        return .{ .epoch = self.epoch, .seq = self.seq + 1 };
    }

    /// `{f}` renders as `epoch:seq`, the text cursor form (glossary). The
    /// 0.16 writer convention passes only the writer; `{}` keeps the default
    /// struct rendering.
    pub fn format(self: @This(), writer: anytype) !void {
        try writer.print("{d}:{d}", .{ self.epoch, self.seq });
    }
};

pub const Slot = struct {
    epoch: u64,
    seq: u64,
    slot_ts_ms: u64,
    entry_hash: [32]u8,
    prev_slot_hash: [32]u8,
    leader: [16]u8,
    signature: [64]u8,

    pub fn position(self: *const Slot) Position {
        return .{ .epoch = self.epoch, .seq = self.seq };
    }
};

/// Encodes the 168-byte slot, signature field included, into `buf` (which
/// must be exactly `encoded_len`). The signed region is offsets 0..104 and
/// never depends on `slot.signature`.
pub fn encode(slot: *const Slot, buf: *[encoded_len]u8) void {
    std.mem.writeInt(u64, buf[0..8], slot.epoch, .little);
    std.mem.writeInt(u64, buf[8..16], slot.seq, .little);
    std.mem.writeInt(u64, buf[16..24], slot.slot_ts_ms, .little);
    buf[24..56].* = slot.entry_hash;
    buf[56..88].* = slot.prev_slot_hash;
    buf[88..104].* = slot.leader;
    buf[104..168].* = slot.signature;
}

/// Decodes a slot from exactly `encoded_len` bytes.
pub fn decode(bytes: *const [encoded_len]u8) Slot {
    return .{
        .epoch = std.mem.readInt(u64, bytes[0..8], .little),
        .seq = std.mem.readInt(u64, bytes[8..16], .little),
        .slot_ts_ms = std.mem.readInt(u64, bytes[16..24], .little),
        .entry_hash = bytes[24..56].*,
        .prev_slot_hash = bytes[56..88].*,
        .leader = bytes[88..104].*,
        .signature = bytes[104..168].*,
    };
}

/// Signs the slot's fields with the leader's key. The signature is not part
/// of the signed region, so the caller fills `slot.signature` from the
/// result before encoding.
pub fn sign(kp: crypto.sign.Ed25519.KeyPair, slot: *const Slot) !crypto.sign.Ed25519.Signature {
    var buf: [encoded_len]u8 = undefined;
    encode(slot, &buf);
    return crypto.sign.Ed25519.KeyPair.sign(kp, buf[0..signed_region_len], null);
}

/// Verifies `slot.signature` over the slot's fields against the leader's
/// public key.
pub fn verify(public_key: crypto.sign.Ed25519.PublicKey, slot: *const Slot) !void {
    var buf: [encoded_len]u8 = undefined;
    encode(slot, &buf);
    const sig = crypto.sign.Ed25519.Signature.fromBytes(slot.signature);
    try sig.verify(buf[0..signed_region_len], public_key);
}

/// `slot_hash` = SHA-256 of the whole slot, signature included; the value
/// the next slot's `prev_slot_hash` references.
pub fn slotHash(slot: *const Slot) [32]u8 {
    var buf: [encoded_len]u8 = undefined;
    encode(slot, &buf);
    var out: [32]u8 = undefined;
    crypto.hash.sha2.Sha256.hash(&buf, &out, .{});
    return out;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn testSlot(seq: u64) Slot {
    return .{
        .epoch = 1,
        .seq = seq,
        .slot_ts_ms = 1_700_000_000_000,
        .entry_hash = [_]u8{0xAB} ** 32,
        .prev_slot_hash = genesis_prev,
        .leader = "fedcba9876543210".*,
        .signature = [_]u8{0} ** 64,
    };
}

test "round trip: encode then decode returns every field" {
    var buf: [encoded_len]u8 = undefined;
    const src = testSlot(3);
    encode(&src, &buf);
    const got = decode(&buf);
    try std.testing.expectEqual(src.epoch, got.epoch);
    try std.testing.expectEqual(src.seq, got.seq);
    try std.testing.expectEqual(src.slot_ts_ms, got.slot_ts_ms);
    try std.testing.expectEqualSlices(u8, &src.entry_hash, &got.entry_hash);
    try std.testing.expectEqualSlices(u8, &src.prev_slot_hash, &got.prev_slot_hash);
    try std.testing.expectEqualSlices(u8, &src.leader, &got.leader);
    try std.testing.expectEqualSlices(u8, &src.signature, &got.signature);
}

test "slot hash covers the signature and pins the position" {
    var io_state = std.Io.Threaded.init(std.testing.allocator, .{});
    const kp = crypto.sign.Ed25519.KeyPair.generate(io_state.io());
    var slot = testSlot(1);
    slot.signature = (try sign(kp, &slot)).toBytes();
    const h1 = slotHash(&slot);
    slot.seq = 2;
    const h2 = slotHash(&slot);
    try std.testing.expect(!std.mem.eql(u8, &h1, &h2));
    // The hash includes the signature bytes, so a re-signed slot re-hashes.
    slot.seq = 1;
    slot.signature = (try sign(kp, &slot)).toBytes();
    try std.testing.expect(std.mem.eql(u8, &h1, &slotHash(&slot)));
}

test "signature verifies under the leader's key and fails under another" {
    var io_state = std.Io.Threaded.init(std.testing.allocator, .{});
    const io = io_state.io();
    const leader = crypto.sign.Ed25519.KeyPair.generate(io);
    const other = crypto.sign.Ed25519.KeyPair.generate(io);
    var slot = testSlot(2);
    slot.signature = (try sign(leader, &slot)).toBytes();

    try verify(leader.public_key, &slot);
    try std.testing.expectError(
        error.SignatureVerificationFailed,
        verify(other.public_key, &slot),
    );

    var corrupt = slot;
    corrupt.entry_hash[0] ^= 1;
    try std.testing.expectError(
        error.SignatureVerificationFailed,
        verify(leader.public_key, &corrupt),
    );
}

test "position orders by epoch then seq" {
    const P = Position;
    try std.testing.expectEqual(.lt, P.order(.{ .epoch = 1, .seq = 9 }, .{ .epoch = 2, .seq = 1 }));
    try std.testing.expectEqual(.lt, P.order(.{ .epoch = 2, .seq = 1 }, .{ .epoch = 2, .seq = 2 }));
    try std.testing.expectEqual(.gt, P.order(.{ .epoch = 2, .seq = 2 }, .{ .epoch = 2, .seq = 1 }));
    try std.testing.expectEqual(.eq, P.order(.{ .epoch = 3, .seq = 4 }, .{ .epoch = 3, .seq = 4 }));
}

test "position formats as epoch:seq" {
    var buf: [32]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{f}", .{Position{ .epoch = 7, .seq = 42 }});
    try std.testing.expectEqualStrings("7:42", text);
}

const FuzzCtx = struct {
    fn fuzzOne(_: @This(), smith: *std.testing.Smith) anyerror!void {
        // A slot has no magic and a fixed size, so the decoder is total:
        // any 168 bytes decode. The property to hold is that encode(decode(b))
        // returns exactly b — the codec must be an involution on bytes.
        var buf: [encoded_len]u8 = undefined;
        smith.bytes(&buf);
        const slot = decode(&buf);
        var re: [encoded_len]u8 = undefined;
        encode(&slot, &re);
        try std.testing.expectEqualSlices(u8, &buf, &re);
    }
};

test "slot codec fuzzes as an involution over 168-byte inputs" {
    try std.testing.fuzz(FuzzCtx{}, FuzzCtx.fuzzOne, .{});
}
