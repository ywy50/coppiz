//! Membership fold rules (PRD 0003 phase 1): how the `join` and `leave`
//! control entries change the member table, and the seniority that is the
//! whole unspoofable-join answer (RFC 0002, decided as option A in
//! [ADR 0005](../../docs/adrs/0005-join-order-is-slot-position.md)).
//!
//! A `join` is written by an *existing* member — the admitter, normally the
//! leader — after admission, naming the newcomer's id, public key and
//! address; the fold appends the newcomer with seniority = this slot. A
//! `leave` is written by the leaving member itself or by the leader evicting
//! it; the fold removes the target, ending its seniority (a rejoin gets a
//! fresh slot). Validation is the pure rule every member runs; chain.zig
//! owns the slot/chain plumbing and calls the `apply*` functions here.
//!
//! Why a newcomer cannot write its own `join`: until the join is slotted no
//! member holds its key, so everything it signs is refused `unknown_author`.
//! Why it cannot move the join earlier: that needs a chain prefix every
//! other member's `prev_slot_hash` contradicts. No clocks are involved —
//! order is position, and position cannot be forged (ADR 0005).

const std = @import("std");
const crypto = std.crypto;
const entry = @import("../journal/entry.zig");
const slot = @import("../journal/slot.zig");
const chain = @import("../journal/chain.zig");
const validate = @import("../settings/validate.zig");
const schema = @import("../settings/schema.zig");
const ApplyError = chain.ApplyError;

/// `join` payload: newcomer id 16 | public key 32 | address len u16 |
/// address bytes. All integers little-endian; `address` is what the member
/// advertises for dialing and what an `authorities` entry may name.
pub const JoinPayload = struct {
    member_id: [16]u8,
    public_key: [32]u8,
    /// Owned after decode.
    address: []const u8,

    pub fn deinit(self: JoinPayload, allocator: std.mem.Allocator) void {
        allocator.free(self.address);
    }
};

pub fn joinPayloadLen(payload: JoinPayload) usize {
    return 16 + 32 + 2 + payload.address.len;
}

pub fn encodeJoinPayload(payload: JoinPayload, buf: []u8) void {
    buf[0..16].* = payload.member_id;
    buf[16..48].* = payload.public_key;
    std.mem.writeInt(u16, buf[48..50], @intCast(payload.address.len), .little);
    @memcpy(buf[50 .. 50 + payload.address.len], payload.address);
}

pub fn decodeJoinPayload(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) error{ InvalidLength, OutOfMemory }!JoinPayload {
    if (bytes.len < 16 + 32 + 2) return error.InvalidLength;
    const addr_len = std.mem.readInt(u16, bytes[48..50], .little);
    if (50 + addr_len != bytes.len) return error.InvalidLength;
    return .{
        .member_id = bytes[0..16].*,
        .public_key = bytes[16..48].*,
        .address = try allocator.dupe(u8, bytes[50..]),
    };
}

/// `leave` payload: the leaving member's id, 16 bytes.
pub const LeavePayload = struct {
    member_id: [16]u8,
};

pub fn encodeLeavePayload(payload: LeavePayload, buf: *[16]u8) void {
    buf[0..16].* = payload.member_id;
}

pub fn decodeLeavePayload(bytes: []const u8) error{InvalidLength}!LeavePayload {
    if (bytes.len != 16) return error.InvalidLength;
    return .{ .member_id = bytes[0..16].* };
}

/// Validates and applies a `join` control entry. Refusals: `bad_join` for a
/// member id that does not derive from the claimed key, `already_member`
/// when the key is already a member (a key that `left` may rejoin with a new
/// seniority — its old `join` slot is gone), and `bad_control_payload` for a
/// payload that does not parse. The admitter's membership is already
/// enforced by the caller's entry-signature check.
pub fn applyJoin(
    fold: *chain.FoldState,
    sl: *const slot.Slot,
    en: *const entry.Entry,
) ApplyError!void {
    const payload = decodeJoinPayload(fold.allocator, en.payload) catch |err|
        return chain.decodeCatch(err, error.BadControlPayload);
    defer payload.deinit(fold.allocator);
    const derived = chain.deriveMemberId(payload.public_key);
    if (!std.mem.eql(u8, &payload.member_id, &derived)) return error.BadJoin;
    if (fold.memberById(payload.member_id) != null) return error.AlreadyMember;
    try fold.members.append(fold.allocator, .{
        .id = payload.member_id,
        .public_key = payload.public_key,
        .seniority = sl.position(),
        .address = try fold.allocator.dupe(u8, payload.address),
    });
    // The empty-authorities rule is count-dependent (PRD 0004's n = 1
    // exception): a join that grows the cluster past it would leave a
    // state no leader can ever be elected under — and, since only the
    // leader can author settings entries, one that can never self-heal
    // (bug 2026-08-28-join-can-strand-cluster-leaderless). Refuse the
    // join, rolling the member back, when the state would be invalid at
    // the new count. A leave cannot create a violation (the rule only
    // loosens as the count shrinks).
    validate.validateState(&fold.settings, fold.memberCount()) catch {
        removeMember(fold, payload.member_id);
        return error.InvalidSettings;
    };
}

/// Applies a re-slotted `join` after a merge — the same validation and the
/// same append at the new slot as a live `join`, because the survivor's fold
/// never saw the losing branch and must not accept what it would refuse
/// live (a member id that does not derive from the key). PRD 0003
/// *Partition and merge*: a member admitted on the losing side ends up
/// junior to everyone admitted on the winning side during the partition,
/// deterministically.
pub fn applyJoinReslotted(
    fold: *chain.FoldState,
    sl: *const slot.Slot,
    en: *const entry.Entry,
) ApplyError!void {
    try applyJoin(fold, sl, en);
}

/// Validates and applies a `leave` control entry. The author is the leaving
/// member itself, or the leader evicting it; anything else is `bad_leave`,
/// and so is a `leave` for an unknown member. A leader that leaves is
/// removed like anyone else — the cluster is leaderless until an `epoch`
/// entry — so a planned handover appends the new leader's `epoch` first
/// (PRD 0003 *Live reconfiguration*).
pub fn applyLeave(
    fold: *chain.FoldState,
    en: *const entry.Entry,
) ApplyError!void {
    const payload = decodeLeavePayload(en.payload) catch return error.BadControlPayload;
    const leader = fold.epoch.?.leader;
    const self_leave = std.mem.eql(u8, &payload.member_id, &en.author);
    const leader_evicts = std.mem.eql(u8, &en.author, &leader);
    if (!self_leave and !leader_evicts) return error.BadLeave;
    if (fold.memberById(payload.member_id) == null) return error.BadLeave;
    removeMember(fold, payload.member_id);
}

/// Applies a re-slotted `leave` after a merge, with the same authorization
/// as a live `leave` — but idempotent for a target that is already gone. A
/// member can legitimately leave on both sides of a partition, so the second
/// re-slot must be a no-op, not a refusal. A losing-side *leader*'s
/// eviction does not survive the merge: the re-slot's leader is the
/// survivor, and the rule says the leader evicts.
pub fn applyLeaveReslotted(
    fold: *chain.FoldState,
    en: *const entry.Entry,
) ApplyError!void {
    const payload = decodeLeavePayload(en.payload) catch return error.BadControlPayload;
    if (fold.memberById(payload.member_id) == null) return;
    try applyLeave(fold, en);
}

/// Removes the target member, ending its seniority. Validation has already
/// run; the caller has checked the author.
fn removeMember(fold: *chain.FoldState, member_id: [16]u8) void {
    for (fold.members.items, 0..) |member, i| {
        if (std.mem.eql(u8, &member.id, &member_id)) {
            fold.allocator.free(member.address);
            _ = fold.members.swapRemove(i);
            return;
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const test_alloc = std.testing.allocator;

/// One cluster's worth of identities for a membership test: the founder (who
/// admits) and a second member (who joins and leaves).
const Fix = struct {
    io_state: std.Io.Threaded,
    founder: crypto.sign.Ed25519.KeyPair,
    founder_id: [16]u8,
    second: crypto.sign.Ed25519.KeyPair,
    second_id: [16]u8,
    control_id: [16]u8,

    fn init() Fix {
        var io_state = std.Io.Threaded.init(test_alloc, .{});
        const founder = crypto.sign.Ed25519.KeyPair.generate(io_state.io());
        const second = crypto.sign.Ed25519.KeyPair.generate(io_state.io());
        return .{
            .io_state = io_state,
            .founder = founder,
            .founder_id = chain.deriveMemberId(founder.public_key.toBytes()),
            .second = second,
            .second_id = chain.deriveMemberId(second.public_key.toBytes()),
            .control_id = "0123456789abcdef".*,
        };
    }

    fn entryFor(
        _: *const Fix,
        kp: crypto.sign.Ed25519.KeyPair,
        kind: entry.Kind,
        journal: [16]u8,
        author_seq: u64,
        payload: []const u8,
    ) !entry.Entry {
        var e = entry.Entry{
            .kind = kind,
            .journal = journal,
            .author = chain.deriveMemberId(kp.public_key.toBytes()),
            .author_seq = author_seq,
            .author_ts_ms = 0,
            .ttl_ms = 0,
            .payload_hash = entry.payloadHash(payload),
            .payload_len = @intCast(payload.len),
            .payload_omitted = false,
            .signature = undefined,
            .payload = payload,
        };
        e.signature = (try entry.sign(kp, &e)).toBytes();
        return e;
    }

    fn slotFor(
        _: *const Fix,
        kp: crypto.sign.Ed25519.KeyPair,
        ep: u64,
        seq: u64,
        entry_hash: [32]u8,
        prev: [32]u8,
        ts: u64,
    ) !slot.Slot {
        var s = slot.Slot{
            .epoch = ep,
            .seq = seq,
            .slot_ts_ms = ts,
            .entry_hash = entry_hash,
            .prev_slot_hash = prev,
            .leader = chain.deriveMemberId(kp.public_key.toBytes()),
            .signature = undefined,
        };
        s.signature = (try slot.sign(kp, &s)).toBytes();
        return s;
    }

    /// A control fold with genesis folded and the founder as leader.
    fn cluster(self: *const Fix) !chain.FoldState {
        var fold = try chain.FoldState.init(test_alloc, true, [_]u8{0} ** 16);
        errdefer fold.deinit();
        const payload = try test_alloc.alloc(
            u8,
            chain.genesisPayloadLen(.{
                .founder_key = self.founder.public_key.toBytes(),
                .changes = &.{},
            }),
        );
        defer test_alloc.free(payload);
        chain.encodeGenesisPayload(
            .{ .founder_key = self.founder.public_key.toBytes(), .changes = &.{} },
            payload,
        ) catch unreachable;
        const en = try self.entryFor(self.founder, .genesis, self.control_id, 1, payload);
        const sl = try self.slotFor(
            self.founder,
            1,
            1,
            entry.entryHash(&en),
            slot.genesis_prev,
            1000,
        );
        try fold.applyControl(&sl, &en);
        return fold;
    }

    /// The next control-journal slot for a caller-built entry.
    fn nextSlot(
        self: *const Fix,
        fold: *const chain.FoldState,
        entry_hash: [32]u8,
        ts: u64,
    ) !slot.Slot {
        return self.slotFor(
            self.founder,
            1,
            fold.head.?.seq + 1,
            entry_hash,
            fold.head_slot_hash,
            ts,
        );
    }
};

/// The founder's next author_seq in a fold (author_seq is per
/// (author, journal) and covers control entries).
fn nextAuthorSeq(fold: *const chain.FoldState, author: [16]u8) u64 {
    const current = fold.authors.get(author) orelse return 1;
    return current.last_seq + 1;
}

test "join admits a newcomer with seniority at its slot" {
    var fix = Fix.init();
    var fold = try fix.cluster();
    defer fold.deinit();

    const payload = try test_alloc.alloc(
        u8,
        joinPayloadLen(.{
            .member_id = fix.second_id,
            .public_key = fix.second.public_key.toBytes(),
            .address = "10.0.0.2:3939",
        }),
    );
    defer test_alloc.free(payload);
    encodeJoinPayload(
        .{
            .member_id = fix.second_id,
            .public_key = fix.second.public_key.toBytes(),
            .address = "10.0.0.2:3939",
        },
        payload,
    );
    const en = try fix.entryFor(
        fix.founder,
        .join,
        fix.control_id,
        nextAuthorSeq(&fold, fix.founder_id),
        payload,
    );
    const sl = try fix.nextSlot(&fold, entry.entryHash(&en), 1001);
    try fold.applyControl(&sl, &en);

    try std.testing.expectEqual(@as(usize, 2), fold.members.items.len);
    const second = fold.memberById(fix.second_id).?;
    try std.testing.expectEqual(slot.Position{ .epoch = 1, .seq = 2 }, second.seniority);
    try std.testing.expectEqualStrings("10.0.0.2:3939", second.address);
    // The founder's seniority is genesis, and stays senior to the newcomer.
    try std.testing.expectEqual(
        slot.Position{ .epoch = 1, .seq = 1 },
        fold.memberById(fix.founder_id).?.seniority,
    );
}

test "a join that would strand the cluster leaderless is refused" {
    // Bug 2026-08-28-join-can-strand-cluster-leaderless: `configured` with
    // an empty authority list is legal at n = 1 (the empty list means
    // self, PRD 0003), but growing the cluster to n = 2 left a state
    // `election.leader` returns null for under fallback = stall — and,
    // since only the leader can author settings entries, one that could
    // never be fixed. The join must be refused instead.
    var fix = Fix.init();
    var fold = try chain.FoldState.init(test_alloc, true, [_]u8{0} ** 16);
    defer fold.deinit();

    const mode = schema.keyIndex("leadership.mode").?;
    const changes = [_]validate.Change{
        .{ .key = mode, .value = .{ .enum_value = schema.enumValue(mode, "configured").? } },
    };
    const g_payload = try test_alloc.alloc(
        u8,
        chain.genesisPayloadLen(.{
            .founder_key = fix.founder.public_key.toBytes(),
            .changes = &changes,
        }),
    );
    defer test_alloc.free(g_payload);
    try chain.encodeGenesisPayload(
        .{ .founder_key = fix.founder.public_key.toBytes(), .changes = &changes },
        g_payload,
    );
    const g_en = try fix.entryFor(fix.founder, .genesis, fix.control_id, 1, g_payload);
    const g_sl = try fix.slotFor(
        fix.founder,
        1,
        1,
        entry.entryHash(&g_en),
        slot.genesis_prev,
        1000,
    );
    try fold.applyControl(&g_sl, &g_en);

    const payload = try test_alloc.alloc(
        u8,
        joinPayloadLen(.{
            .member_id = fix.second_id,
            .public_key = fix.second.public_key.toBytes(),
            .address = "10.0.0.2:3939",
        }),
    );
    defer test_alloc.free(payload);
    encodeJoinPayload(
        .{
            .member_id = fix.second_id,
            .public_key = fix.second.public_key.toBytes(),
            .address = "10.0.0.2:3939",
        },
        payload,
    );
    const en = try fix.entryFor(
        fix.founder,
        .join,
        fix.control_id,
        nextAuthorSeq(&fold, fix.founder_id),
        payload,
    );
    const sl = try fix.nextSlot(&fold, entry.entryHash(&en), 1001);
    try std.testing.expectError(error.InvalidSettings, fold.applyControl(&sl, &en));
    // The join was rolled back; the cluster stays at one member.
    try std.testing.expectEqual(@as(usize, 1), fold.members.items.len);
}

test "join is refused when the id does not derive from the key, or already a member" {
    var fix = Fix.init();
    var fold = try fix.cluster();
    defer fold.deinit();

    // A join naming a member id that is not SHA-256(key)[0..16].
    {
        const payload = try test_alloc.alloc(
            u8,
            joinPayloadLen(.{
                .member_id = [_]u8{0xAB} ** 16,
                .public_key = fix.second.public_key.toBytes(),
                .address = "",
            }),
        );
        defer test_alloc.free(payload);
        encodeJoinPayload(
            .{
                .member_id = [_]u8{0xAB} ** 16,
                .public_key = fix.second.public_key.toBytes(),
                .address = "",
            },
            payload,
        );
        const en = try fix.entryFor(
            fix.founder,
            .join,
            fix.control_id,
            nextAuthorSeq(&fold, fix.founder_id),
            payload,
        );
        const sl = try fix.nextSlot(&fold, entry.entryHash(&en), 1001);
        try std.testing.expectError(error.BadJoin, fold.applyControl(&sl, &en));
    }

    // The same key admitted twice is already_member (a key that left may
    // rejoin, but an active one cannot).
    {
        const payload = try test_alloc.alloc(
            u8,
            joinPayloadLen(.{
                .member_id = fix.second_id,
                .public_key = fix.second.public_key.toBytes(),
                .address = "",
            }),
        );
        defer test_alloc.free(payload);
        encodeJoinPayload(
            .{
                .member_id = fix.second_id,
                .public_key = fix.second.public_key.toBytes(),
                .address = "",
            },
            payload,
        );
        const en = try fix.entryFor(
            fix.founder,
            .join,
            fix.control_id,
            nextAuthorSeq(&fold, fix.founder_id),
            payload,
        );
        const sl = try fix.nextSlot(&fold, entry.entryHash(&en), 1001);
        try fold.applyControl(&sl, &en);
        const en2 = try fix.entryFor(
            fix.founder,
            .join,
            fix.control_id,
            nextAuthorSeq(&fold, fix.founder_id),
            payload,
        );
        const sl2 = try fix.nextSlot(&fold, entry.entryHash(&en2), 1002);
        try std.testing.expectError(error.AlreadyMember, fold.applyControl(&sl2, &en2));
    }
}

test "leave: by the member itself, by the leader evicting, and refusals" {
    var fix = Fix.init();
    var fold = try fix.cluster();
    defer fold.deinit();

    // Admit the second member.
    const join = try test_alloc.alloc(
        u8,
        joinPayloadLen(.{
            .member_id = fix.second_id,
            .public_key = fix.second.public_key.toBytes(),
            .address = "node-2",
        }),
    );
    defer test_alloc.free(join);
    encodeJoinPayload(
        .{
            .member_id = fix.second_id,
            .public_key = fix.second.public_key.toBytes(),
            .address = "node-2",
        },
        join,
    );
    const j_en = try fix.entryFor(
        fix.founder,
        .join,
        fix.control_id,
        nextAuthorSeq(&fold, fix.founder_id),
        join,
    );
    const j_sl = try fix.nextSlot(&fold, entry.entryHash(&j_en), 1001);
    try fold.applyControl(&j_sl, &j_en);

    // A stranger (third key) cannot evict the second member.
    {
        var io_state = std.Io.Threaded.init(test_alloc, .{});
        const stranger = crypto.sign.Ed25519.KeyPair.generate(io_state.io());
        var buf: [16]u8 = undefined;
        encodeLeavePayload(.{ .member_id = fix.second_id }, &buf);
        const en = try fix.entryFor(
            stranger,
            .leave,
            fix.control_id,
            1,
            &buf,
        );
        const sl = try fix.nextSlot(&fold, entry.entryHash(&en), 1002);
        try std.testing.expectError(error.UnknownAuthor, fold.applyControl(&sl, &en));
    }

    // The member itself leaves.
    {
        var buf: [16]u8 = undefined;
        encodeLeavePayload(.{ .member_id = fix.second_id }, &buf);
        const en = try fix.entryFor(
            fix.second,
            .leave,
            fix.control_id,
            1,
            &buf,
        );
        const sl = try fix.nextSlot(&fold, entry.entryHash(&en), 1002);
        try fold.applyControl(&sl, &en);
        try std.testing.expect(fold.memberById(fix.second_id) == null);
    }

    // Rejoin after leave gets a *new* seniority: the second member is
    // admitted again, now junior to anyone admitted before.
    {
        const payload = try test_alloc.alloc(
            u8,
            joinPayloadLen(.{
                .member_id = fix.second_id,
                .public_key = fix.second.public_key.toBytes(),
                .address = "node-2",
            }),
        );
        defer test_alloc.free(payload);
        encodeJoinPayload(
            .{
                .member_id = fix.second_id,
                .public_key = fix.second.public_key.toBytes(),
                .address = "node-2",
            },
            payload,
        );
        const en = try fix.entryFor(
            fix.founder,
            .join,
            fix.control_id,
            nextAuthorSeq(&fold, fix.founder_id),
            payload,
        );
        const sl = try fix.nextSlot(&fold, entry.entryHash(&en), 1003);
        try fold.applyControl(&sl, &en);
        try std.testing.expectEqual(
            slot.Position{ .epoch = 1, .seq = 4 },
            fold.memberById(fix.second_id).?.seniority,
        );
    }

    // The leader evicting works too; a leave for an unknown member is
    // bad_leave.
    {
        var buf: [16]u8 = undefined;
        encodeLeavePayload(.{ .member_id = fix.second_id }, &buf);
        const en = try fix.entryFor(
            fix.founder,
            .leave,
            fix.control_id,
            nextAuthorSeq(&fold, fix.founder_id),
            &buf,
        );
        const sl = try fix.nextSlot(&fold, entry.entryHash(&en), 1004);
        try fold.applyControl(&sl, &en);
        try std.testing.expect(fold.memberById(fix.second_id) == null);

        const unknown = [_]u8{0xEE} ** 16;
        encodeLeavePayload(.{ .member_id = unknown }, &buf);
        const en2 = try fix.entryFor(
            fix.founder,
            .leave,
            fix.control_id,
            nextAuthorSeq(&fold, fix.founder_id),
            &buf,
        );
        const sl2 = try fix.nextSlot(&fold, entry.entryHash(&en2), 1005);
        try std.testing.expectError(error.BadLeave, fold.applyControl(&sl2, &en2));
    }
}

test "membership payload codecs round-trip" {
    const payload = JoinPayload{
        .member_id = [_]u8{7} ** 16,
        .public_key = [_]u8{9} ** 32,
        .address = "node.example:3939",
    };
    const buf = try test_alloc.alloc(u8, joinPayloadLen(payload));
    defer test_alloc.free(buf);
    encodeJoinPayload(payload, buf);
    var decoded = try decodeJoinPayload(test_alloc, buf);
    defer decoded.deinit(test_alloc);
    try std.testing.expectEqualSlices(u8, &payload.member_id, &decoded.member_id);
    try std.testing.expectEqualSlices(u8, &payload.public_key, &decoded.public_key);
    try std.testing.expectEqualStrings("node.example:3939", decoded.address);

    var leave_buf: [16]u8 = undefined;
    encodeLeavePayload(.{ .member_id = [_]u8{3} ** 16 }, &leave_buf);
    const leave = try decodeLeavePayload(&leave_buf);
    try std.testing.expectEqualSlices(u8, &[_]u8{3} ** 16, &leave.member_id);
}

test "re-slots validate like live entries: join bad id refused, leave idempotent" {
    var fix = Fix.init();
    var fold = try fix.cluster();
    defer fold.deinit();

    // A re-slotted join must pass the same rules a live join would: a member
    // id that does not derive from the key is refused bad_join (the
    // survivor's fold never saw the losing branch, so the re-slot cannot
    // smuggle what the live rule refuses).
    {
        const payload = try test_alloc.alloc(
            u8,
            joinPayloadLen(.{
                .member_id = [_]u8{0xAB} ** 16,
                .public_key = fix.second.public_key.toBytes(),
                .address = "node-2",
            }),
        );
        defer test_alloc.free(payload);
        encodeJoinPayload(
            .{
                .member_id = [_]u8{0xAB} ** 16,
                .public_key = fix.second.public_key.toBytes(),
                .address = "node-2",
            },
            payload,
        );
        const en = try fix.entryFor(fix.founder, .join, fix.control_id, 2, payload);
        const sl = try fix.nextSlot(&fold, entry.entryHash(&en), 1001);
        try std.testing.expectError(error.BadJoin, fold.applyControlReslotted(&sl, &en));
    }

    // A valid re-slotted join of the second member is accepted at the new
    // slot (seniority = the re-slot position).
    {
        const payload = try test_alloc.alloc(
            u8,
            joinPayloadLen(.{
                .member_id = fix.second_id,
                .public_key = fix.second.public_key.toBytes(),
                .address = "node-2",
            }),
        );
        defer test_alloc.free(payload);
        encodeJoinPayload(
            .{
                .member_id = fix.second_id,
                .public_key = fix.second.public_key.toBytes(),
                .address = "node-2",
            },
            payload,
        );
        const en = try fix.entryFor(fix.founder, .join, fix.control_id, 2, payload);
        const sl = try fix.nextSlot(&fold, entry.entryHash(&en), 1001);
        try fold.applyControlReslotted(&sl, &en);
        try std.testing.expectEqual(
            slot.Position{ .epoch = 1, .seq = 2 },
            fold.memberById(fix.second_id).?.seniority,
        );
    }

    // A re-slotted leave by a member that is neither the target nor the
    // leader is refused: the survivor's rule still holds at the new slot.
    {
        var buf: [16]u8 = undefined;
        encodeLeavePayload(.{ .member_id = fix.founder_id }, &buf);
        const en = try fix.entryFor(fix.second, .leave, fix.control_id, 1, &buf);
        const sl = try fix.nextSlot(&fold, entry.entryHash(&en), 1002);
        try std.testing.expectError(error.BadLeave, fold.applyControlReslotted(&sl, &en));
    }

    // A re-slotted leave for an already-left member is an idempotent no-op
    // (the member can legitimately leave on both sides of a partition).
    {
        var buf: [16]u8 = undefined;
        encodeLeavePayload(.{ .member_id = fix.second_id }, &buf);
        const en = try fix.entryFor(fix.founder, .leave, fix.control_id, 3, &buf);
        const sl = try fix.nextSlot(&fold, entry.entryHash(&en), 1002);
        try fold.applyControlReslotted(&sl, &en);
        try std.testing.expect(fold.memberById(fix.second_id) == null);

        const again = try fix.entryFor(fix.founder, .leave, fix.control_id, 4, &buf);
        const again_sl = try fix.nextSlot(&fold, entry.entryHash(&again), 1003);
        try fold.applyControlReslotted(&again_sl, &again);
    }
}
