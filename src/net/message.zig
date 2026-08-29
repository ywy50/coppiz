//! The replication wire's messages (PRD 0003 phase 4; OQ 19 decided): the
//! typed bodies inside a frame. A body is `version u8 | kind u8 | payload`;
//! every integer little-endian.
//!
//! A decoder never trusts its input: bounds are checked before slicing,
//! unknown kinds and versions are refused by name, and everything
//! variable-length is copied into the allocator — a decoded message owns
//! what it names and borrows nothing from the frame body. The slot records
//! inside `slot`, `sync_page` and `read_page` reuse the segment record
//! codec, so disk and wire share one format (self-describing records, PRD
//! 0001): a record carries its own length and CRC and decodes to a slot
//! plus an entry (or a slot alone after compaction).

const std = @import("std");
const entry = @import("../journal/entry.zig");
const slot = @import("../journal/slot.zig");
const segment = @import("../journal/segment.zig");

/// The wire format version, repeated at the head of every body (the frame
/// itself has no version; the body's first byte is this).
pub const version: u8 = framing.version;

const framing = @import("framing.zig");

pub const Kind = enum(u8) {
    hello = 1,
    hello_ack = 2,
    append = 3,
    ack = 4,
    forward = 5,
    slot = 6,
    sync_req = 7,
    sync_page = 8,
    heartbeat = 9,
    read_req = 10,
    read_page = 11,
    settings = 12,
    /// The losing side of a healed partition tells the survivor to fetch
    /// and re-slot its branch (PRD 0003 *Partition and merge*). Carries the
    /// loser's branch leader and head so the survivor can verify the
    /// survivor computation before merging.
    merge_offer = 13,
    /// The survivor's "branch fetched and re-slotted" notice: the loser may
    /// now truncate its data branches and re-sync (the truncation must not
    /// beat the survivor's fetch, or the loser's data would be lost).
    merge_ack = 14,
    /// A member listing request from the CLI (no payload); the node answers
    /// with a `members_page` from its control fold.
    members_req = 15,
    members_page = 16,

    pub fn name(self: Kind) []const u8 {
        return switch (self) {
            .hello => "hello",
            .hello_ack => "hello_ack",
            .append => "append",
            .ack => "ack",
            .forward => "forward",
            .slot => "slot",
            .sync_req => "sync_req",
            .sync_page => "sync_page",
            .heartbeat => "heartbeat",
            .read_req => "read_req",
            .read_page => "read_page",
            .settings => "settings",
            .merge_offer => "merge_offer",
            .merge_ack => "merge_ack",
            .members_req => "members_req",
            .members_page => "members_page",
        };
    }
};

// -- helpers ---------------------------------------------------------------

fn writeU16(buf: []u8, v: usize) void {
    std.mem.writeInt(u16, buf[0..2], @intCast(v), .little);
}

fn writeU32(buf: []u8, v: usize) void {
    std.mem.writeInt(u32, buf[0..4], @intCast(v), .little);
}

fn writePosition(buf: []u8, p: slot.Position) void {
    std.mem.writeInt(u64, buf[0..8], p.epoch, .little);
    std.mem.writeInt(u64, buf[8..16], p.seq, .little);
}

fn readPosition(buf: []const u8) slot.Position {
    return .{
        .epoch = std.mem.readInt(u64, buf[0..8], .little),
        .seq = std.mem.readInt(u64, buf[8..16], .little),
    };
}

fn writeId(buf: []u8, id: entry.Id) void {
    buf[0..16].* = id.author;
    std.mem.writeInt(u64, buf[16..24], id.author_seq, .little);
}

fn readId(buf: []const u8) entry.Id {
    return .{
        .author = buf[0..16].*,
        .author_seq = std.mem.readInt(u64, buf[16..24], .little),
    };
}

// -- hello -----------------------------------------------------------------

/// The dial handshake: identity, key, and the cluster the dialer believes
/// it is in. The recipient admits per `cluster.admission` and replies with
/// a `hello_ack`.
pub const Hello = struct {
    member_id: [16]u8,
    public_key: [32]u8,
    /// The control journal's genesis entry hash — the cluster identity.
    genesis_hash: [32]u8,
    /// The dialer's advertised address (owned after decode); the admitter
    /// records it in the `join` entry.
    address: []const u8,
};

pub fn helloLen(h: Hello) usize {
    return 16 + 32 + 32 + 2 + h.address.len;
}

pub fn encodeHello(h: Hello, buf: []u8) void {
    buf[0..16].* = h.member_id;
    buf[16..48].* = h.public_key;
    buf[48..80].* = h.genesis_hash;
    writeU16(buf[80..82], h.address.len);
    @memcpy(buf[82..], h.address);
}

pub fn decodeHello(allocator: std.mem.Allocator, bytes: []const u8) DecodeError!Hello {
    if (bytes.len < 82) return error.InvalidLength;
    const addr_len: usize = std.mem.readInt(u16, bytes[80..82], .little);
    if (82 + addr_len != bytes.len) return error.InvalidLength;
    return .{
        .member_id = bytes[0..16].*,
        .public_key = bytes[16..48].*,
        .genesis_hash = bytes[48..80].*,
        .address = try allocator.dupe(u8, bytes[82..]),
    };
}

// -- hello_ack --------------------------------------------------------------

/// Why a hello was not admitted; `none` with `admitted = false` is unused.
pub const Refusal = enum(u8) {
    none = 0,
    /// The dialer's genesis hash names a different cluster.
    wrong_genesis = 1,
    /// `cluster.admission = allowlist` and the key is not in `[[peers]]`.
    not_allowlisted = 2,
    /// `cluster.admission = prompt`: queued for `coppiz admit`.
    prompt_pending = 3,
    /// The cluster is at `cluster.max_members`.
    max_members = 4,
};

pub const HelloAck = struct {
    admitted: bool,
    refusal: Refusal,
    /// The responder's member id — how a dialer learns who it reached
    /// before the fold knows the address.
    member_id: [16]u8,
    /// The responder's advertised address (owned after decode) — the
    /// dialer records it for redials.
    address: []const u8,
    /// The responder's cluster identity; useful to a dialer that guessed
    /// wrong (the chain's first entry is public).
    genesis_hash: [32]u8,
    epoch: u64,
    leader: [16]u8,
};

pub const hello_ack_fixed_len = 1 + 1 + 16 + 32 + 8 + 16;

pub fn helloAckLen(h: HelloAck) usize {
    return hello_ack_fixed_len + 2 + h.address.len;
}

pub fn encodeHelloAck(h: HelloAck, buf: []u8) void {
    buf[0] = @intFromBool(h.admitted);
    buf[1] = @intFromEnum(h.refusal);
    buf[2..18].* = h.member_id;
    writeU16(buf[18..20], h.address.len);
    @memcpy(buf[20 .. 20 + h.address.len], h.address);
    const off = 20 + h.address.len;
    @memcpy(buf[off .. off + 32], &h.genesis_hash);
    var epoch_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &epoch_buf, h.epoch, .little);
    @memcpy(buf[off + 32 .. off + 40], &epoch_buf);
    @memcpy(buf[off + 40 .. off + 56], &h.leader);
}

pub fn decodeHelloAck(allocator: std.mem.Allocator, bytes: []const u8) DecodeError!HelloAck {
    if (bytes.len < hello_ack_fixed_len + 2) return error.InvalidLength;
    if (bytes[0] > 1) return error.InvalidValue;
    const refusal_int = bytes[1];
    if (refusal_int > @intFromEnum(Refusal.max_members)) return error.InvalidValue;
    const addr_len: usize = std.mem.readInt(u16, bytes[18..20], .little);
    const off = 20 + addr_len;
    if (off + 32 + 8 + 16 != bytes.len) return error.InvalidLength;
    return .{
        .admitted = bytes[0] == 1,
        .refusal = @enumFromInt(refusal_int),
        .member_id = bytes[2..18].*,
        .address = try allocator.dupe(u8, bytes[20..off]),
        .genesis_hash = bytes[off .. off + 32][0..32].*,
        .epoch = std.mem.readInt(u64, bytes[off + 32 .. off + 40][0..8], .little),
        .leader = bytes[off + 40 .. off + 56][0..16].*,
    };
}

// -- append ----------------------------------------------------------------

/// A CLI client's append request. The serving node builds and signs the
/// entry as itself (the member you talk to is the author, matching the
/// library API shape), then follows the leader/follower write path.
pub const Append = struct {
    /// The journal's name (owned after decode); the node resolves it.
    journal: []const u8,
    payload: []const u8,
    ttl_ms: u64,
};

pub fn appendLen(a: Append) usize {
    return 2 + a.journal.len + 4 + a.payload.len + 8;
}

pub fn encodeAppend(a: Append, buf: []u8) void {
    writeU16(buf[0..2], a.journal.len);
    @memcpy(buf[2 .. 2 + a.journal.len], a.journal);
    const off = 2 + a.journal.len;
    writeU32(buf[off .. off + 4], a.payload.len);
    @memcpy(buf[off + 4 .. off + 4 + a.payload.len], a.payload);
    var ttl_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &ttl_buf, a.ttl_ms, .little);
    @memcpy(buf[off + 4 + a.payload.len ..], &ttl_buf);
}

pub fn decodeAppend(allocator: std.mem.Allocator, bytes: []const u8) DecodeError!Append {
    if (bytes.len < 2 + 4 + 8) return error.InvalidLength;
    const name_len: usize = std.mem.readInt(u16, bytes[0..2], .little);
    const payload_off = 2 + name_len;
    if (payload_off + 4 + 8 > bytes.len) return error.InvalidLength;
    var len_buf: [4]u8 = undefined;
    @memcpy(&len_buf, bytes[payload_off .. payload_off + 4]);
    const payload_len: usize = std.mem.readInt(u32, &len_buf, .little);
    if (payload_off + 4 + payload_len + 8 != bytes.len) return error.InvalidLength;
    var ttl_buf: [8]u8 = undefined;
    @memcpy(&ttl_buf, bytes[payload_off + 4 + payload_len ..]);
    return .{
        .journal = try allocator.dupe(u8, bytes[2..payload_off]),
        .payload = try allocator.dupe(u8, bytes[payload_off + 4 .. payload_off + 4 + payload_len]),
        .ttl_ms = std.mem.readInt(u64, &ttl_buf, .little),
    };
}

// -- ack -------------------------------------------------------------------

/// The reply to an `append`: the entry id and its slot, or a refusal name
/// (empty string = slotted). `id` and `position` are zeroed on refusal.
pub const Ack = struct {
    id: entry.Id,
    position: slot.Position,
    /// The refusal's error name, empty on success (owned after decode).
    refusal: []const u8,
};

pub fn ackLen(a: Ack) usize {
    return 16 + 8 + 8 + 8 + 2 + a.refusal.len;
}

pub fn encodeAck(a: Ack, buf: []u8) void {
    writeId(buf[0..24], a.id);
    writePosition(buf[24..40], a.position);
    writeU16(buf[40..42], a.refusal.len);
    @memcpy(buf[42..], a.refusal);
}

pub fn decodeAck(allocator: std.mem.Allocator, bytes: []const u8) DecodeError!Ack {
    if (bytes.len < 42) return error.InvalidLength;
    const refusal_len: usize = std.mem.readInt(u16, bytes[40..42], .little);
    if (42 + refusal_len != bytes.len) return error.InvalidLength;
    return .{
        .id = readId(bytes[0..24]),
        .position = readPosition(bytes[24..40]),
        .refusal = try allocator.dupe(u8, bytes[42..]),
    };
}

// -- forward ---------------------------------------------------------------

/// A member's signed entry forwarded to the leader: the entry record bytes
/// (`entry.encode` output — header then payload; the journal is inside the
/// entry). The leader validates, slots and broadcasts.
pub const Forward = struct {
    /// Owned after decode.
    entry_bytes: []const u8,
};

pub fn forwardLen(f: Forward) usize {
    return 4 + f.entry_bytes.len;
}

pub fn encodeForward(f: Forward, buf: []u8) void {
    writeU32(buf[0..4], f.entry_bytes.len);
    @memcpy(buf[4..], f.entry_bytes);
}

pub fn decodeForward(allocator: std.mem.Allocator, bytes: []const u8) DecodeError!Forward {
    if (bytes.len < 4) return error.InvalidLength;
    const len: usize = std.mem.readInt(u32, bytes[0..4], .little);
    if (4 + len != bytes.len) return error.InvalidLength;
    return .{ .entry_bytes = try allocator.dupe(u8, bytes[4..]) };
}

// -- slot ------------------------------------------------------------------

/// One replicated slot: a full record (len | crc | slot | entry) plus the
/// `reslotted` bit, which tells a fold whether to apply the entry with the
/// merge re-slot rule (`apply*Reslotted`). `sl` and `en` are decoded from
/// `record`, which the message owns.
pub const SlotMsg = struct {
    reslotted: bool,
    /// Owned after decode; `sl`/`en` borrow from it.
    record: []const u8,
    sl: slot.Slot,
    en: ?entry.Entry,
};

/// Encodes a slot message for broadcasting (a live slot always has its full
/// entry; compacted records are never broadcast).
pub fn encodeSlot(reslotted: bool, sl: *const slot.Slot, en: *const entry.Entry, buf: []u8) void {
    buf[0] = @intFromBool(reslotted);
    std.mem.writeInt(u32, buf[1..5], @intCast(segment.recordSize(sl, en)), .little);
    segment.encodeRecord(sl, en, buf[5..]);
}

/// Encodes a slot message from a pre-encoded record (len | crc | slot |
/// entry) instead of re-encoding `sl`/`en`: the leader writes a record to
/// the store and broadcasts the same bytes, so one encode (and its CRC)
/// serves both (the bytes `segment.encodeRecord` produced are exactly the
/// on-disk form the follower appends verbatim).
pub fn encodeSlotRecord(reslotted: bool, record: []const u8, buf: []u8) void {
    buf[0] = @intFromBool(reslotted);
    std.mem.writeInt(u32, buf[1..5], @intCast(record.len), .little);
    @memcpy(buf[5..], record);
}

pub fn decodeSlot(allocator: std.mem.Allocator, bytes: []const u8) DecodeError!SlotMsg {
    if (bytes.len < 5) return error.InvalidLength;
    if (bytes[0] > 1) return error.InvalidValue;
    const rec_len: usize = std.mem.readInt(u32, bytes[1..5], .little);
    if (5 + rec_len != bytes.len) return error.InvalidLength;
    const record = try allocator.dupe(u8, bytes[5..]);
    errdefer allocator.free(record);
    const rec = segment.decodeRecord(record) catch return error.InvalidValue;
    // The record must fill the payload exactly. `decodeRecord` reads the
    // record's *own* length prefix and ignores whatever follows it, so a
    // valid record with junk appended used to decode as a valid slot - and
    // `record` is the slice `Node.applyReplicated` hands to
    // `Store.appendRecord` verbatim, which refuses it with `BadRecord`
    // only after the fold has already advanced.
    if (rec.next_offset != record.len) return error.InvalidLength;
    // A broadcast slot always carries its full entry; a slot-only record
    // (a `retain = none` compaction artefact) is refused, not misread.
    if (rec.entry == null) return error.InvalidValue;
    return .{
        .reslotted = bytes[0] == 1,
        .record = record,
        .sl = rec.slot,
        .en = rec.entry,
    };
}

// -- sync ------------------------------------------------------------------

/// A backfill request: give me `journal_id`'s records from `from` on, up to
/// `max_bytes` of record bytes.
pub const SyncReq = struct {
    journal_id: [16]u8,
    from: slot.Position,
    max_bytes: u32,
};

pub const sync_req_len = 16 + 8 + 8 + 4;

pub fn encodeSyncReq(r: SyncReq, buf: *[sync_req_len]u8) void {
    buf[0..16].* = r.journal_id;
    writePosition(buf[16..32], r.from);
    std.mem.writeInt(u32, buf[32..36], r.max_bytes, .little);
}

pub fn decodeSyncReq(bytes: []const u8) DecodeError!SyncReq {
    if (bytes.len != sync_req_len) return error.InvalidLength;
    return .{
        .journal_id = bytes[0..16].*,
        .from = readPosition(bytes[16..32]),
        .max_bytes = std.mem.readInt(u32, bytes[32..36], .little),
    };
}

/// A page of backfill: `records` is a contiguous run of record bytes (the
/// same codec as a segment's record region), and `next` is the position
/// just past the last record — the requester's next `from`. `next` equals
/// `from` when nothing was served. Records are slot-only after a
/// `retain = none` compaction; a syncing member that meets one cannot fold
/// it (OQ 43) and stays `syncing`.
pub const SyncPage = struct {
    journal_id: [16]u8,
    next: slot.Position,
    /// Owned after decode; decode each record with `segment.decodeRecord`.
    records: []const u8,
};

pub fn syncPageLen(p: SyncPage) usize {
    return 16 + 8 + 8 + 4 + p.records.len;
}

pub fn encodeSyncPage(p: SyncPage, buf: []u8) void {
    buf[0..16].* = p.journal_id;
    writePosition(buf[16..32], p.next);
    writeU32(buf[32..36], p.records.len);
    @memcpy(buf[36..], p.records);
}

pub fn decodeSyncPage(allocator: std.mem.Allocator, bytes: []const u8) DecodeError!SyncPage {
    if (bytes.len < 36) return error.InvalidLength;
    const rec_len: usize = std.mem.readInt(u32, bytes[32..36], .little);
    if (36 + rec_len != bytes.len) return error.InvalidLength;
    return .{
        .journal_id = bytes[0..16].*,
        .next = readPosition(bytes[16..32]),
        .records = try allocator.dupe(u8, bytes[36..]),
    };
}

// -- heartbeat --------------------------------------------------------------

/// Liveness and the sender's control-chain view: enough for the failure
/// detector and for detecting a diverged branch on heal (`head`).
pub const Heartbeat = struct {
    member_id: [16]u8,
    epoch: u64,
    head: slot.Position,
    /// The highest position the sender has acknowledged (for
    /// `tiebreak = freshest`).
    last_ack: slot.Position,
};

pub const heartbeat_len = 16 + 8 + 8 + 8 + 8 + 8;

pub fn encodeHeartbeat(h: Heartbeat, buf: *[heartbeat_len]u8) void {
    buf[0..16].* = h.member_id;
    std.mem.writeInt(u64, buf[16..24], h.epoch, .little);
    writePosition(buf[24..40], h.head);
    writePosition(buf[40..56], h.last_ack);
}

pub fn decodeHeartbeat(bytes: []const u8) DecodeError!Heartbeat {
    if (bytes.len != heartbeat_len) return error.InvalidLength;
    return .{
        .member_id = bytes[0..16].*,
        .epoch = std.mem.readInt(u64, bytes[16..24], .little),
        .head = readPosition(bytes[24..40]),
        .last_ack = readPosition(bytes[40..56]),
    };
}

// -- read ------------------------------------------------------------------

/// A CLI client's read request; the node answers locally with `read_page`s.
/// `from` (0, 0) means the journal's genesis.
pub const ReadReq = struct {
    journal: []const u8,
    from: slot.Position,
    include_stale: bool,
    include_expired: bool,
    max_bytes: u32,
};

pub fn readReqLen(r: ReadReq) usize {
    return 2 + r.journal.len + 8 + 8 + 1 + 1 + 4;
}

pub fn encodeReadReq(r: ReadReq, buf: []u8) void {
    writeU16(buf[0..2], r.journal.len);
    @memcpy(buf[2 .. 2 + r.journal.len], r.journal);
    const off = 2 + r.journal.len;
    writePosition(buf[off .. off + 16], r.from);
    buf[off + 16] = @intFromBool(r.include_stale);
    buf[off + 17] = @intFromBool(r.include_expired);
    var max_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &max_buf, r.max_bytes, .little);
    @memcpy(buf[off + 18 .. off + 22], &max_buf);
}

pub fn decodeReadReq(allocator: std.mem.Allocator, bytes: []const u8) DecodeError!ReadReq {
    if (bytes.len < 2 + 22) return error.InvalidLength;
    const name_len: usize = std.mem.readInt(u16, bytes[0..2], .little);
    const off = 2 + name_len;
    if (off + 22 != bytes.len) return error.InvalidLength;
    if (bytes[off + 16] > 1 or bytes[off + 17] > 1) return error.InvalidValue;
    var max_buf: [4]u8 = undefined;
    @memcpy(&max_buf, bytes[off + 18 .. off + 22]);
    return .{
        .journal = try allocator.dupe(u8, bytes[2..off]),
        .from = readPosition(bytes[off .. off + 16]),
        .include_stale = bytes[off + 16] == 1,
        .include_expired = bytes[off + 17] == 1,
        .max_bytes = std.mem.readInt(u32, &max_buf, .little),
    };
}

/// A page of records for a read. `next` (0, 0) means the stream is done; a
/// non-empty `refusal` means the request was refused (e.g. an unknown
/// journal name) and the page carries no records — the wire equivalent of
/// the local read's named error (bug
/// 2026-08-28-sweep3-wire-read-unknown-journal).
pub const ReadPage = struct {
    next: slot.Position,
    /// Owned after decode; records use the segment record codec.
    records: []const u8,
    refusal: []const u8 = "",
};

pub fn readPageLen(p: ReadPage) usize {
    return 8 + 8 + 4 + p.records.len + 2 + p.refusal.len;
}

pub fn encodeReadPage(p: ReadPage, buf: []u8) void {
    writePosition(buf[0..16], p.next);
    writeU32(buf[16..20], p.records.len);
    const off = 20 + p.records.len;
    @memcpy(buf[20..off], p.records);
    writeU16(buf[off .. off + 2], p.refusal.len);
    @memcpy(buf[off + 2 ..], p.refusal);
}

pub fn decodeReadPage(allocator: std.mem.Allocator, bytes: []const u8) DecodeError!ReadPage {
    if (bytes.len < 20) return error.InvalidLength;
    const rec_len: usize = std.mem.readInt(u32, bytes[16..20], .little);
    const off = 20 + rec_len;
    if (off + 2 > bytes.len) return error.InvalidLength;
    var len_buf: [2]u8 = undefined;
    @memcpy(&len_buf, bytes[off .. off + 2]);
    const refusal_len: usize = std.mem.readInt(u16, &len_buf, .little);
    if (off + 2 + refusal_len != bytes.len) return error.InvalidLength;
    return .{
        .next = readPosition(bytes[0..16]),
        .records = try allocator.dupe(u8, bytes[20..off]),
        .refusal = try allocator.dupe(u8, bytes[off + 2 ..]),
    };
}

// -- settings ---------------------------------------------------------------

/// A settings change request from the CLI. `changes` is the change-list
/// encoding the chain itself uses (`settings_fold.changesLen`/`encodeChanges`),
/// so one codec serves chain and wire; the node resolves the journal name,
/// builds the payload and appends the entry (leader-authored).
pub const Settings = struct {
    journal: []const u8,
    /// Owned after decode.
    changes: []const u8,
};

pub fn settingsLen(s: Settings) usize {
    return 2 + s.journal.len + 4 + s.changes.len;
}

pub fn encodeSettings(s: Settings, buf: []u8) void {
    writeU16(buf[0..2], s.journal.len);
    @memcpy(buf[2 .. 2 + s.journal.len], s.journal);
    const off = 2 + s.journal.len;
    writeU32(buf[off .. off + 4], s.changes.len);
    @memcpy(buf[off + 4 ..], s.changes);
}

pub fn decodeSettings(allocator: std.mem.Allocator, bytes: []const u8) DecodeError!Settings {
    if (bytes.len < 2 + 4) return error.InvalidLength;
    const name_len: usize = std.mem.readInt(u16, bytes[0..2], .little);
    const off = 2 + name_len;
    if (off + 4 > bytes.len) return error.InvalidLength;
    var len_buf: [4]u8 = undefined;
    @memcpy(&len_buf, bytes[off .. off + 4]);
    const changes_len: usize = std.mem.readInt(u32, &len_buf, .little);
    if (off + 4 + changes_len != bytes.len) return error.InvalidLength;
    return .{
        .journal = try allocator.dupe(u8, bytes[2..off]),
        .changes = try allocator.dupe(u8, bytes[off + 4 ..]),
    };
}

// -- merge_offer -------------------------------------------------------------

/// The losing side of a healed partition names its branch so the survivor
/// can verify the survivor computation and fetch the branch to re-slot it.
pub const MergeOffer = struct {
    /// The losing branch's leader (who signed its slots).
    branch_leader: [16]u8,
    /// The losing branch's head — what a `merge` entry will name.
    branch_head: slot.Position,
};

pub const merge_offer_len = 16 + 8 + 8;

pub fn encodeMergeOffer(m: MergeOffer, buf: *[merge_offer_len]u8) void {
    buf[0..16].* = m.branch_leader;
    writePosition(buf[16..32], m.branch_head);
}

pub fn decodeMergeOffer(bytes: []const u8) DecodeError!MergeOffer {
    if (bytes.len != merge_offer_len) return error.InvalidLength;
    return .{
        .branch_leader = bytes[0..16].*,
        .branch_head = readPosition(bytes[16..32]),
    };
}

// -- members -----------------------------------------------------------------

/// One member in a `members_page`: the fold facts (`chain.Member`) minus
/// the public key, which the listing has no use for.
pub const MemberInfo = struct {
    id: [16]u8,
    /// The member's join slot (genesis for the founder); earlier = more
    /// senior (RFC 0002).
    seniority: slot.Position,
    /// Owned after decode; the founder advertises the empty string.
    address: []const u8,
};

/// The reply to a `members_req`: the control fold's membership plus the
/// answering node's epoch and leader view.
pub const MembersPage = struct {
    epoch: u64,
    leader: [16]u8,
    /// Owned after decode (the slice and each address).
    members: []MemberInfo,
};

pub fn membersPageLen(p: MembersPage) usize {
    var len: usize = 8 + 16 + 2;
    for (p.members) |m| len += 16 + 16 + 2 + m.address.len;
    return len;
}

pub fn encodeMembersPage(p: MembersPage, buf: []u8) void {
    std.mem.writeInt(u64, buf[0..8], p.epoch, .little);
    buf[8..24].* = p.leader;
    writeU16(buf[24..26], p.members.len);
    var off: usize = 26;
    for (p.members) |m| {
        @memcpy(buf[off .. off + 16], &m.id);
        writePosition(buf[off + 16 .. off + 32], m.seniority);
        writeU16(buf[off + 32 .. off + 34], m.address.len);
        @memcpy(buf[off + 34 .. off + 34 + m.address.len], m.address);
        off += 34 + m.address.len;
    }
}

pub fn decodeMembersPage(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) DecodeError!MembersPage {
    if (bytes.len < 26) return error.InvalidLength;
    const count = std.mem.readInt(u16, bytes[24..26], .little);
    const members = try allocator.alloc(MemberInfo, count);
    var done: usize = 0;
    errdefer {
        for (members[0..done]) |m| allocator.free(m.address);
        allocator.free(members);
    }
    var off: usize = 26;
    while (done < count) : (done += 1) {
        if (off + 34 > bytes.len) return error.InvalidLength;
        const addr_len = std.mem.readInt(u16, bytes[off + 32 ..][0..2], .little);
        if (off + 34 + addr_len > bytes.len) return error.InvalidLength;
        members[done] = .{
            .id = bytes[off..][0..16].*,
            .seniority = readPosition(bytes[off + 16 .. off + 32]),
            .address = try allocator.dupe(u8, bytes[off + 34 .. off + 34 + addr_len]),
        };
        off += 34 + addr_len;
    }
    if (off != bytes.len) return error.InvalidLength;
    return .{
        .epoch = std.mem.readInt(u64, bytes[0..8], .little),
        .leader = bytes[8..24].*,
        .members = members,
    };
}

// -- the message union ------------------------------------------------------

pub const Message = union(enum) {
    hello: Hello,
    hello_ack: HelloAck,
    append: Append,
    ack: Ack,
    forward: Forward,
    slot: SlotMsg,
    sync_req: SyncReq,
    sync_page: SyncPage,
    heartbeat: Heartbeat,
    read_req: ReadReq,
    read_page: ReadPage,
    settings: Settings,
    merge_offer: MergeOffer,
    merge_ack,
    members_req,
    members_page: MembersPage,

    pub fn kind(self: Message) Kind {
        return switch (self) {
            .hello => .hello,
            .hello_ack => .hello_ack,
            .append => .append,
            .ack => .ack,
            .forward => .forward,
            .slot => .slot,
            .sync_req => .sync_req,
            .sync_page => .sync_page,
            .heartbeat => .heartbeat,
            .read_req => .read_req,
            .read_page => .read_page,
            .settings => .settings,
            .merge_offer => .merge_offer,
            .merge_ack => .merge_ack,
            .members_req => .members_req,
            .members_page => .members_page,
        };
    }

    /// Frees the variable-length parts (no-ops for the fixed messages).
    pub fn deinit(self: *Message, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .hello => |v| allocator.free(v.address),
            .hello_ack => |v| allocator.free(v.address),
            .append => |v| {
                allocator.free(v.journal);
                allocator.free(v.payload);
            },
            .ack => |v| allocator.free(v.refusal),
            .forward => |v| allocator.free(v.entry_bytes),
            .slot => |v| allocator.free(v.record),
            .sync_page => |v| allocator.free(v.records),
            .read_req => |v| allocator.free(v.journal),
            .read_page => |v| {
                allocator.free(v.records);
                allocator.free(v.refusal);
            },
            .settings => |v| {
                allocator.free(v.journal);
                allocator.free(v.changes);
            },
            .members_page => |v| {
                for (v.members) |m| allocator.free(m.address);
                allocator.free(v.members);
            },
            else => {},
        }
    }
};

pub const DecodeError = error{
    BadVersion,
    UnknownKind,
    InvalidLength,
    InvalidValue,
    OutOfMemory,
};

/// Encoded size of a message body (version + kind + payload).
pub fn encodedLen(m: Message) usize {
    const payload: usize = switch (m) {
        .hello => |v| helloLen(v),
        .hello_ack => |v| helloAckLen(v),
        .append => |v| appendLen(v),
        .ack => |v| ackLen(v),
        .forward => |v| forwardLen(v),
        .slot => |v| 1 + 4 + segment.recordSize(&v.sl, &v.en.?),
        .sync_req => sync_req_len,
        .sync_page => |v| syncPageLen(v),
        .heartbeat => heartbeat_len,
        .read_req => |v| readReqLen(v),
        .read_page => |v| readPageLen(v),
        .settings => |v| settingsLen(v),
        .merge_offer => merge_offer_len,
        .merge_ack => 0,
        .members_req => 0,
        .members_page => |v| membersPageLen(v),
    };
    return 2 + payload;
}

/// Encodes a message body into `buf`, which must hold `encodedLen(m)`.
pub fn encode(m: Message, buf: []u8) void {
    buf[0] = version;
    buf[1] = @intFromEnum(m.kind());
    const out = buf[2..];
    switch (m) {
        .hello => |v| encodeHello(v, out),
        .hello_ack => |v| encodeHelloAck(v, out),
        .append => |v| encodeAppend(v, out),
        .ack => |v| encodeAck(v, out),
        .forward => |v| encodeForward(v, out),
        .slot => |v| if (v.record.len > 0)
            encodeSlotRecord(v.reslotted, v.record, out)
        else
            encodeSlot(v.reslotted, &v.sl, &v.en.?, out),
        .sync_req => |v| encodeSyncReq(v, out[0..sync_req_len]),
        .sync_page => |v| encodeSyncPage(v, out),
        .heartbeat => |v| encodeHeartbeat(v, out[0..heartbeat_len]),
        .read_req => |v| encodeReadReq(v, out),
        .read_page => |v| encodeReadPage(v, out),
        .settings => |v| encodeSettings(v, out),
        .merge_offer => |v| encodeMergeOffer(v, out[0..merge_offer_len]),
        .merge_ack => {},
        .members_req => {},
        .members_page => |v| encodeMembersPage(v, out),
    }
}

/// Decodes a frame body (`version | kind | payload`) into a message. The
/// result owns its variable-length parts via `allocator`.
pub fn decode(allocator: std.mem.Allocator, body: []const u8) DecodeError!Message {
    if (body.len < 2) return error.InvalidLength;
    if (body[0] != version) return error.BadVersion;
    const kind_int = body[1];
    if (kind_int < @intFromEnum(Kind.hello) or
        kind_int > @intFromEnum(Kind.members_page))
    {
        return error.UnknownKind;
    }
    const kind: Kind = @enumFromInt(kind_int);
    const payload = body[2..];
    return switch (kind) {
        .hello => .{ .hello = try decodeHello(allocator, payload) },
        .hello_ack => .{ .hello_ack = try decodeHelloAck(allocator, payload) },
        .append => .{ .append = try decodeAppend(allocator, payload) },
        .ack => .{ .ack = try decodeAck(allocator, payload) },
        .forward => .{ .forward = try decodeForward(allocator, payload) },
        .slot => .{ .slot = try decodeSlot(allocator, payload) },
        .sync_req => .{ .sync_req = try decodeSyncReq(payload) },
        .sync_page => .{ .sync_page = try decodeSyncPage(allocator, payload) },
        .heartbeat => .{ .heartbeat = try decodeHeartbeat(payload) },
        .read_req => .{ .read_req = try decodeReadReq(allocator, payload) },
        .read_page => .{ .read_page = try decodeReadPage(allocator, payload) },
        .settings => .{ .settings = try decodeSettings(allocator, payload) },
        .merge_offer => .{ .merge_offer = try decodeMergeOffer(payload) },
        .merge_ack => if (payload.len != 0) return error.InvalidLength else .merge_ack,
        .members_req => if (payload.len != 0) return error.InvalidLength else .members_req,
        .members_page => .{ .members_page = try decodeMembersPage(allocator, payload) },
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const test_alloc = std.testing.allocator;

const test_id: [16]u8 = "0123456789abcdef".*;
const test_key = [_]u8{0x42} ** 32;
const test_hash = [_]u8{0x13} ** 32;
const test_pos = slot.Position{ .epoch = 2, .seq = 3 };

fn roundTrip(m: Message) !Message {
    const buf = try test_alloc.alloc(u8, encodedLen(m));
    defer test_alloc.free(buf);
    encode(m, buf);
    var got = try decode(test_alloc, buf);
    errdefer got.deinit(test_alloc);
    return got;
}

test "hello round-trips" {
    var got = try roundTrip(.{ .hello = .{
        .member_id = test_id,
        .public_key = test_key,
        .genesis_hash = test_hash,
        .address = "127.0.0.1:6401",
    } });
    defer got.deinit(test_alloc);
    try std.testing.expectEqualSlices(u8, &test_id, &got.hello.member_id);
    try std.testing.expectEqualSlices(u8, &test_key, &got.hello.public_key);
    try std.testing.expectEqualSlices(u8, &test_hash, &got.hello.genesis_hash);
    try std.testing.expectEqualStrings("127.0.0.1:6401", got.hello.address);
}

test "hello_ack round-trips" {
    var got = try roundTrip(.{ .hello_ack = .{
        .admitted = true,
        .refusal = .none,
        .member_id = test_id,
        .address = "node-a",
        .genesis_hash = test_hash,
        .epoch = 4,
        .leader = test_id,
    } });
    defer got.deinit(test_alloc);
    try std.testing.expect(got.hello_ack.admitted);
    try std.testing.expectEqual(Refusal.none, got.hello_ack.refusal);
    try std.testing.expectEqualSlices(u8, &test_id, &got.hello_ack.member_id);
    try std.testing.expectEqualStrings("node-a", got.hello_ack.address);
    try std.testing.expectEqual(@as(u64, 4), got.hello_ack.epoch);
}

test "append round-trips" {
    var got = try roundTrip(.{ .append = .{
        .journal = "events",
        .payload = "a payload",
        .ttl_ms = 5000,
    } });
    defer got.deinit(test_alloc);
    try std.testing.expectEqualStrings("events", got.append.journal);
    try std.testing.expectEqualStrings("a payload", got.append.payload);
    try std.testing.expectEqual(@as(u64, 5000), got.append.ttl_ms);
}

test "ack round-trips, success and refusal" {
    var ok = try roundTrip(.{ .ack = .{
        .id = .{ .author = test_id, .author_seq = 7 },
        .position = test_pos,
        .refusal = "",
    } });
    defer ok.deinit(test_alloc);
    try std.testing.expectEqual(@as(u64, 7), ok.ack.id.author_seq);
    try std.testing.expectEqual(test_pos, ok.ack.position);
    try std.testing.expectEqual(@as(usize, 0), ok.ack.refusal.len);

    var refused = try roundTrip(.{ .ack = .{
        .id = .{ .author = [_]u8{0} ** 16, .author_seq = 0 },
        .position = .{ .epoch = 0, .seq = 0 },
        .refusal = "no_leader",
    } });
    defer refused.deinit(test_alloc);
    try std.testing.expectEqualStrings("no_leader", refused.ack.refusal);
}

test "forward round-trips the entry bytes" {
    const bytes = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    var got = try roundTrip(.{ .forward = .{ .entry_bytes = bytes } });
    defer got.deinit(test_alloc);
    try std.testing.expectEqualStrings(bytes, got.forward.entry_bytes);
}

/// A signed slot and its entry, for the slot-message tests. The payload is
/// a string literal, so the pair borrows nothing that needs freeing.
const SignedSlot = struct { sl: slot.Slot, en: entry.Entry };

fn testSignedSlot() !SignedSlot {
    var io_state = std.Io.Threaded.init(test_alloc, .{});
    const kp = crypto.sign.Ed25519.KeyPair.generate(io_state.io());
    var en = entry.Entry{
        .kind = .data,
        .journal = test_id,
        .author = test_id,
        .author_seq = 1,
        .author_ts_ms = 1_700_000_000_000,
        .ttl_ms = 0,
        .payload_hash = entry.payloadHash("hi"),
        .payload_len = 2,
        .payload_omitted = false,
        .signature = undefined,
        .payload = "hi",
    };
    en.signature = (try entry.sign(kp, &en)).toBytes();
    var sl = slot.Slot{
        .epoch = 1,
        .seq = 1,
        .slot_ts_ms = 1_700_000_000_000,
        .entry_hash = entry.entryHash(&en),
        .prev_slot_hash = slot.genesis_prev,
        .leader = test_id,
        .signature = undefined,
    };
    sl.signature = (try slot.sign(kp, &sl)).toBytes();
    return .{ .sl = sl, .en = en };
}

test "slot round-trips a signed slot with its entry" {
    const signed = try testSignedSlot();
    const sl = signed.sl;
    const en = signed.en;

    var got = try roundTrip(.{ .slot = .{
        .reslotted = true,
        .record = &.{},
        .sl = sl,
        .en = en,
    } });
    defer got.deinit(test_alloc);
    try std.testing.expect(got.slot.reslotted);
    try std.testing.expectEqual(sl.position(), got.slot.sl.position());
    try std.testing.expectEqualStrings("hi", got.slot.en.?.payload);
    // The decoded slot record decodes again (the message carries the record).
    const rec = try segment.decodeRecord(got.slot.record);
    try std.testing.expectEqual(sl.position(), rec.slot.position());
}

test "a slot carrying bytes past the end of its record is refused" {
    // `segment.decodeRecord` reads the record's own length prefix and
    // ignores everything after it, so a valid record with junk appended
    // decoded as a valid slot: the outer `5 + rec_len == bytes.len` check
    // passes when `rec_len` counts the junk too. `SlotMsg.record` is what
    // `Node.applyReplicated` appends to the store verbatim, and
    // `Store.appendRecord` refuses a slice longer than its own length
    // prefix (`error.BadRecord`) - after the fold has already advanced.
    const signed = try testSignedSlot();
    const m = Message{ .slot = .{
        .reslotted = false,
        .record = &.{},
        .sl = signed.sl,
        .en = signed.en,
    } };
    const valid_len = encodedLen(m);
    const junk = 3;
    const buf = try test_alloc.alloc(u8, valid_len + junk);
    defer test_alloc.free(buf);
    encode(m, buf[0..valid_len]);
    @memset(buf[valid_len..], 0xAA);
    // The payload's own length field must cover the junk, or the frame is
    // refused by the length check instead of by the record check.
    const rec_len = std.mem.readInt(u32, buf[3..7], .little);
    std.mem.writeInt(u32, buf[3..7], rec_len + junk, .little);

    try std.testing.expectError(error.InvalidLength, decode(test_alloc, buf));

    // The same bytes without the junk still decode: the check refuses the
    // surplus, not the record.
    std.mem.writeInt(u32, buf[3..7], rec_len, .little);
    var ok = try decode(test_alloc, buf[0..valid_len]);
    defer ok.deinit(test_alloc);
    try std.testing.expectEqual(signed.sl.position(), ok.slot.sl.position());
}

test "sync_req and heartbeat round-trip" {
    var req = try roundTrip(.{ .sync_req = .{
        .journal_id = test_id,
        .from = test_pos,
        .max_bytes = 65536,
    } });
    defer req.deinit(test_alloc);
    try std.testing.expectEqual(test_pos, req.sync_req.from);
    try std.testing.expectEqual(@as(u32, 65536), req.sync_req.max_bytes);

    var hb = try roundTrip(.{ .heartbeat = .{
        .member_id = test_id,
        .epoch = 3,
        .head = test_pos,
        .last_ack = test_pos,
    } });
    defer hb.deinit(test_alloc);
    try std.testing.expectEqual(@as(u64, 3), hb.heartbeat.epoch);
}

test "read_req and read_page round-trip" {
    var req = try roundTrip(.{ .read_req = .{
        .journal = "main",
        .from = test_pos,
        .include_stale = true,
        .include_expired = false,
        .max_bytes = 4096,
    } });
    defer req.deinit(test_alloc);
    try std.testing.expectEqualStrings("main", req.read_req.journal);
    try std.testing.expect(req.read_req.include_stale);
    try std.testing.expect(!req.read_req.include_expired);

    var page = try roundTrip(.{ .read_page = .{ .next = test_pos, .records = "recordbytes" } });
    defer page.deinit(test_alloc);
    try std.testing.expectEqualStrings("recordbytes", page.read_page.records);
    try std.testing.expectEqual(@as(usize, 0), page.read_page.refusal.len);

    // A refused read carries the refusal through the same codec (bug
    // 2026-08-28-sweep3-wire-read-unknown-journal).
    var refused = try roundTrip(.{ .read_page = .{
        .next = test_pos,
        .records = "",
        .refusal = "unknown_journal",
    } });
    defer refused.deinit(test_alloc);
    try std.testing.expectEqualStrings("unknown_journal", refused.read_page.refusal);
}

test "settings round-trips the change-list bytes" {
    var got = try roundTrip(.{ .settings = .{
        .journal = "main",
        .changes = "\x01\x00\x02\x00\x01\x00\x2a",
    } });
    defer got.deinit(test_alloc);
    try std.testing.expectEqualStrings("main", got.settings.journal);
    try std.testing.expectEqualStrings("\x01\x00\x02\x00\x01\x00\x2a", got.settings.changes);
}

test "merge_offer round-trips" {
    var got = try roundTrip(.{ .merge_offer = .{
        .branch_leader = test_id,
        .branch_head = test_pos,
    } });
    defer got.deinit(test_alloc);
    try std.testing.expectEqualSlices(u8, &test_id, &got.merge_offer.branch_leader);
    try std.testing.expectEqual(test_pos, got.merge_offer.branch_head);
}

test "members_req and members_page round-trip" {
    var req = try roundTrip(.members_req);
    defer req.deinit(test_alloc);
    try std.testing.expectEqual(Kind.members_req, req.kind());

    var infos = [_]MemberInfo{
        .{ .id = test_id, .seniority = .{ .epoch = 1, .seq = 1 }, .address = "" },
        .{ .id = [_]u8{7} ** 16, .seniority = test_pos, .address = "127.0.0.1:6402" },
    };
    var got = try roundTrip(.{ .members_page = .{
        .epoch = 3,
        .leader = test_id,
        .members = &infos,
    } });
    defer got.deinit(test_alloc);
    const page = got.members_page;
    try std.testing.expectEqual(@as(u64, 3), page.epoch);
    try std.testing.expectEqualSlices(u8, &test_id, &page.leader);
    try std.testing.expectEqual(@as(usize, 2), page.members.len);
    try std.testing.expectEqualSlices(u8, &test_id, &page.members[0].id);
    try std.testing.expectEqualStrings("", page.members[0].address);
    try std.testing.expectEqual(test_pos, page.members[1].seniority);
    try std.testing.expectEqualStrings("127.0.0.1:6402", page.members[1].address);
}

test "bad versions, kinds and lengths are refused by name" {
    const buf = try test_alloc.alloc(u8, encodedLen(.{ .heartbeat = .{
        .member_id = test_id,
        .epoch = 1,
        .head = test_pos,
        .last_ack = test_pos,
    } }));
    defer test_alloc.free(buf);
    encode(.{ .heartbeat = .{
        .member_id = test_id,
        .epoch = 1,
        .head = test_pos,
        .last_ack = test_pos,
    } }, buf);

    var bad_version = try test_alloc.dupe(u8, buf);
    defer test_alloc.free(bad_version);
    bad_version[0] = version + 1;
    try std.testing.expectError(error.BadVersion, decode(test_alloc, bad_version));

    var bad_kind = try test_alloc.dupe(u8, buf);
    defer test_alloc.free(bad_kind);
    bad_kind[1] = @intFromEnum(Kind.members_page) + 1;
    try std.testing.expectError(error.UnknownKind, decode(test_alloc, bad_kind));

    var zero_kind = try test_alloc.dupe(u8, buf);
    defer test_alloc.free(zero_kind);
    zero_kind[1] = 0;
    try std.testing.expectError(error.UnknownKind, decode(test_alloc, zero_kind));

    try std.testing.expectError(error.InvalidLength, decode(test_alloc, buf[0..1]));
}

test "a length field at its type's maximum is refused, not overflowed" {
    // Every decoder validates a peer-supplied length by adding it to the
    // fixed part of the message. Computing that sum in the *field's* type
    // (u16 or u32) overflows for a length near the type's maximum, which is
    // an abort in a safe build and a wrapped sum that passes the check in a
    // release one. The sums are usize now; these bodies are the minimum
    // length each decoder accepts, with the length field maxed, so every one
    // of them overflows the pre-fix arithmetic.
    //
    // `hello` is the case that matters most: `node.zig`'s `onFrame` decodes
    // before any admission check runs, so an 84-byte write to an open listen
    // port reached this with no key, no genesis hash and no allowlist entry.
    const Case = struct {
        kind: Kind,
        /// The payload length: the smallest the decoder accepts.
        payload_len: usize,
        /// Where the length field sits inside the payload, and how wide.
        field_off: usize,
        field_bytes: usize,
    };
    const cases = [_]Case{
        .{ .kind = .hello, .payload_len = 82, .field_off = 80, .field_bytes = 2 },
        .{
            .kind = .hello_ack,
            .payload_len = hello_ack_fixed_len + 2,
            .field_off = 18,
            .field_bytes = 2,
        },
        .{ .kind = .append, .payload_len = 14, .field_off = 0, .field_bytes = 2 },
        .{ .kind = .ack, .payload_len = 42, .field_off = 40, .field_bytes = 2 },
        .{ .kind = .forward, .payload_len = 4, .field_off = 0, .field_bytes = 4 },
        .{ .kind = .slot, .payload_len = 5, .field_off = 1, .field_bytes = 4 },
        .{ .kind = .sync_page, .payload_len = 36, .field_off = 32, .field_bytes = 4 },
        .{ .kind = .read_req, .payload_len = 24, .field_off = 0, .field_bytes = 2 },
        .{ .kind = .read_page, .payload_len = 20, .field_off = 16, .field_bytes = 4 },
        .{ .kind = .settings, .payload_len = 6, .field_off = 0, .field_bytes = 2 },
    };
    for (cases) |c| {
        const body = try test_alloc.alloc(u8, 2 + c.payload_len);
        defer test_alloc.free(body);
        @memset(body, 0);
        body[0] = version;
        body[1] = @intFromEnum(c.kind);
        // Max out the length field; every other byte stays zero, which keeps
        // the enum and boolean fields these decoders check in range.
        @memset(body[2 + c.field_off ..][0..c.field_bytes], 0xFF);
        try std.testing.expectError(error.InvalidLength, decode(test_alloc, body));
    }
}

const FuzzCtx = struct {
    fn fuzzOne(_: @This(), smith: *std.testing.Smith) anyerror!void {
        var buf: [512]u8 = undefined;
        const len = smith.slice(&buf);
        // Any error is acceptable; the decoder must never crash or read out
        // of bounds, and a successful decode must free cleanly.
        var got = decode(test_alloc, buf[0..len]) catch return;
        defer got.deinit(test_alloc);
        // A decoded message re-encodes to the same body.
        const re = try test_alloc.alloc(u8, encodedLen(got));
        defer test_alloc.free(re);
        encode(got, re);
        try std.testing.expectEqualSlices(u8, buf[0..len], re);
    }
};

test "message decoder fuzzes over untrusted bytes" {
    try std.testing.fuzz(FuzzCtx{}, FuzzCtx.fuzzOne, .{});
}

const crypto = std.crypto;
