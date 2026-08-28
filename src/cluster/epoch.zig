//! Epochs and merge (PRD 0003 phase 3): the `epoch` and `merge` control
//! entries, and the pure rule that picks the surviving branch.
//!
//! An `epoch` entry opens a leadership term. It is the one control entry
//! whose slot is not signed by the current leader: the entry is the new
//! leader's first act, so its slot carries the *claimed* leader's signature.
//! Two shapes are valid:
//!
//! - **Post-failure election** (`leader_lost`, `manual`): the new leader
//!   authors the entry, names itself, and signs its own slot.
//! - **Handover** (`mode_change`): the current leader authors the entry,
//!   signs its slot, and names the leader the new mode selects — possibly
//!   itself. The handover is one slot wide: the old leader stops slotting
//!   after it (PRD 0003 *Live reconfiguration*).
//!
//! The fold's rules here are structural: a known reason, the epoch number
//! advancing by one, a claimed leader that is a member, signatures that
//! verify. The liveness half — the claimed leader must be what
//! `election.leader(...)` returns for the *caller's* liveness view — is
//! checked by the caller before offering the entry to the fold; a member
//! that disagrees keeps its previous view, and that disagreement is a
//! partition (PRD 0003 *Epochs*).
//!
//! A `merge` entry names the losing branch (its epoch and head). The
//! surviving leader appends it, then re-slots the losing branch's entries in
//! that branch's order (`chain.FoldState.applyControlReslotted`): same
//! bytes, new slots, entry ids unchanged. The fold records the merge so the
//! checkpoint settle rule (PRD 0002) can refuse checkpoints inside
//! `merge.settle_ms`. The survivor is the branch whose leader ranks higher
//! under the mode — the same ranking election uses — so any member given
//! both heads computes the same survivor and the same re-slot order (the
//! loser's chain order).

const std = @import("std");
const entry = @import("../journal/entry.zig");
const slot = @import("../journal/slot.zig");
const chain = @import("../journal/chain.zig");
const election = @import("election.zig");
const ApplyError = chain.ApplyError;

/// Why an epoch opened (PRD 0003 *Epochs*); the reason list is tier-1's.
pub const Reason = enum(u16) {
    leader_lost = 1,
    mode_change = 2,
    merge = 3,
    manual = 4,

    pub fn name(self: Reason) []const u8 {
        return switch (self) {
            .leader_lost => "leader_lost",
            .mode_change => "mode_change",
            .merge => "merge",
            .manual => "manual",
        };
    }
};

/// `epoch` payload: number u64 | reason u16 | leader 16. The number and
/// leader duplicate the slot's, redundantly but explicitly — the entry must
/// stand alone on the wire.
pub const EpochPayload = struct {
    number: u64,
    reason: Reason,
    leader: [16]u8,
};

pub const epoch_payload_len = 8 + 2 + 16;

pub fn encodeEpochPayload(payload: EpochPayload, buf: *[epoch_payload_len]u8) void {
    std.mem.writeInt(u64, buf[0..8], payload.number, .little);
    std.mem.writeInt(u16, buf[8..10], @intFromEnum(payload.reason), .little);
    buf[10..26].* = payload.leader;
}

pub fn decodeEpochPayload(bytes: []const u8) error{ InvalidLength, InvalidReason }!EpochPayload {
    if (bytes.len != epoch_payload_len) return error.InvalidLength;
    const reason_int = std.mem.readInt(u16, bytes[8..10], .little);
    const reason: Reason = if (reason_int < @intFromEnum(Reason.leader_lost) or
        reason_int > @intFromEnum(Reason.manual))
        return error.InvalidReason
    else
        @enumFromInt(reason_int);
    return .{
        .number = std.mem.readInt(u64, bytes[0..8], .little),
        .reason = reason,
        .leader = bytes[10..26].*,
    };
}

/// `merge` payload: the losing branch's epoch u64 and head seq u64 — enough
/// to name the branch; the re-slotted entries that follow are the content.
pub const MergePayload = struct {
    branch_epoch: u64,
    branch_seq: u64,
};

pub fn encodeMergePayload(payload: MergePayload, buf: *[16]u8) void {
    std.mem.writeInt(u64, buf[0..8], payload.branch_epoch, .little);
    std.mem.writeInt(u64, buf[8..16], payload.branch_seq, .little);
}

pub fn decodeMergePayload(bytes: []const u8) error{InvalidLength}!MergePayload {
    if (bytes.len != 16) return error.InvalidLength;
    return .{
        .branch_epoch = std.mem.readInt(u64, bytes[0..8], .little),
        .branch_seq = std.mem.readInt(u64, bytes[8..16], .little),
    };
}

/// One branch's inputs to the merge rule.
pub const Branch = struct {
    /// The branch's leader — the member that elected it and signed its
    /// slots.
    leader: [16]u8,
    /// The leader's ranking inputs; `state` is irrelevant here (both branch
    /// leaders were elected by their own side), but `last_ack` is the
    /// branch's head for `tiebreak = freshest`.
    leader_view: election.View,
};

/// Which branch survives: the one whose leader ranks higher under the mode
/// (PRD 0003 *Partition and merge*: earlier seniority, or earlier in the
/// authority list). `.a` means the first argument's branch survives.
/// Deterministic over the same inputs, so any member given both heads
/// computes the same survivor; the re-slot order is then the losing branch's
/// own chain order, which is the same on every member by construction.
pub const Winner = enum { a, b };

pub fn survivor(inputs: election.Inputs, a: Branch, b: Branch) Winner {
    return switch (election.compareRank(inputs, a.leader_view, b.leader_view)) {
        .lt, .eq => .a,
        .gt => .b,
    };
}

/// Validates and applies an `epoch` control entry (the structural half; the
/// liveness half — the claimed leader matches the caller's `leader(...)` —
/// is the caller's, checked before offering the entry to the fold).
/// Refusals: `bad_epoch` for a malformed payload, a stale or wrong epoch
/// number, a claimed leader that is not a member, signatures that do not
/// verify, or an author that is neither the current leader (handover) nor
/// the claimed leader (post-failure election).
pub fn applyEpoch(
    fold: *chain.FoldState,
    sl: *const slot.Slot,
    en: *const entry.Entry,
) ApplyError!void {
    const payload = decodeEpochPayload(en.payload) catch return error.BadEpoch;
    if (payload.number != sl.epoch) return error.BadEpoch;
    const current_epoch = fold.epoch orelse return error.BadEpoch;
    if (sl.epoch != current_epoch.number + 1) return error.BadEpoch;
    const current = current_epoch.leader;
    const new_leader = fold.memberById(payload.leader) orelse return error.BadEpoch;

    if (std.mem.eql(u8, &en.author, &current)) {
        // Handover: the current leader signs the slot; the payload names the
        // new leader, which may be itself.
        if (!std.mem.eql(u8, &sl.leader, &current)) return error.BadEpoch;
        const current_member = fold.memberById(current) orelse return error.BadEpoch;
        try chain.FoldState.verifySlotSignature(current_member, sl);
    } else {
        // Post-failure election: the new leader announces itself and signs
        // its own slot.
        if (!std.mem.eql(u8, &en.author, &payload.leader)) return error.BadEpoch;
        if (!std.mem.eql(u8, &sl.leader, &payload.leader)) return error.BadEpoch;
        try chain.FoldState.verifySlotSignature(new_leader, sl);
    }
    try fold.checkEntrySignature(en);
    try fold.checkAuthorSeq(en);
    fold.epoch = .{
        .number = sl.epoch,
        .leader = payload.leader,
        .reason = payload.reason.name(),
    };
    try fold.registerEntry(sl, en);
}

/// Validates and applies a `merge` control entry. The author must be the
/// current leader; the payload must name a branch (epoch and head seq at
/// least 1 — epoch numbering starts at 1). The fold cannot verify the named
/// branch's contents — a member that was on neither side never saw them and
/// receives them as an archived branch — so validation is deliberately
/// shallow: everything after the merge entry is signed by the surviving
/// leader like any other slot, and validated as it folds.
pub fn applyMerge(
    fold: *chain.FoldState,
    sl: *const slot.Slot,
    en: *const entry.Entry,
) ApplyError!void {
    try chain.FoldState.checkAuthorIsLeader(en, fold.epoch.?.leader);
    const payload = decodeMergePayload(en.payload) catch return error.BadMerge;
    if (payload.branch_epoch == 0 or payload.branch_seq == 0) return error.BadMerge;
    fold.last_merge = .{ .position = sl.position(), .slot_ts_ms = sl.slot_ts_ms };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const test_alloc = std.testing.allocator;
const crypto = std.crypto;

/// One cluster's worth of identities for an epoch test: the founder (epoch
/// 1 leader) and a second member that takes over.
const Fix = struct {
    io_state: std.Io.Threaded,
    founder: crypto.sign.Ed25519.KeyPair,
    founder_id: [16]u8,
    second: crypto.sign.Ed25519.KeyPair,
    second_id: [16]u8,
    control_id: [16]u8,
    data_id: [16]u8,

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
            .data_id = "abcdef0123456789".*,
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

    /// A control fold with genesis folded, the founder leading epoch 1, and
    /// the second member admitted.
    fn cluster(self: *const Fix) !chain.FoldState {
        var fold = try chain.FoldState.init(test_alloc, true, [_]u8{0} ** 16);
        errdefer fold.deinit();
        const g = try test_alloc.alloc(
            u8,
            chain.genesisPayloadLen(.{
                .founder_key = self.founder.public_key.toBytes(),
                .changes = &.{},
            }),
        );
        defer test_alloc.free(g);
        chain.encodeGenesisPayload(
            .{ .founder_key = self.founder.public_key.toBytes(), .changes = &.{} },
            g,
        );
        const g_en = try self.entryFor(self.founder, .genesis, self.control_id, 1, g);
        const g_sl = try self.slotFor(
            self.founder,
            1,
            1,
            entry.entryHash(&g_en),
            slot.genesis_prev,
            1000,
        );
        try fold.applyControl(&g_sl, &g_en);

        const join = try test_alloc.alloc(
            u8,
            @import("membership.zig").joinPayloadLen(.{
                .member_id = self.second_id,
                .public_key = self.second.public_key.toBytes(),
                .address = "node-2",
            }),
        );
        defer test_alloc.free(join);
        @import("membership.zig").encodeJoinPayload(
            .{
                .member_id = self.second_id,
                .public_key = self.second.public_key.toBytes(),
                .address = "node-2",
            },
            join,
        );
        const j_en = try self.entryFor(self.founder, .join, self.control_id, 2, join);
        const j_sl = try self.slotFor(
            self.founder,
            1,
            2,
            entry.entryHash(&j_en),
            slot.slotHash(&g_sl),
            1001,
        );
        try fold.applyControl(&j_sl, &j_en);
        return fold;
    }
};

fn nextAuthorSeq(fold: *const chain.FoldState, author: [16]u8) u64 {
    const current = fold.authors.get(author) orelse return 1;
    return current.last_seq + 1;
}

test "a post-failure epoch by the new leader opens the next term" {
    var fix = Fix.init();
    var fold = try fix.cluster();
    defer fold.deinit();

    var buf: [epoch_payload_len]u8 = undefined;
    encodeEpochPayload(
        .{ .number = 2, .reason = .leader_lost, .leader = fix.second_id },
        &buf,
    );
    const en = try fix.entryFor(
        fix.second,
        .epoch,
        fix.control_id,
        nextAuthorSeq(&fold, fix.second_id),
        &buf,
    );
    const sl = try fix.slotFor(
        fix.second,
        2,
        1,
        entry.entryHash(&en),
        fold.head_slot_hash,
        1002,
    );
    try fold.applyControl(&sl, &en);
    try std.testing.expectEqual(@as(u64, 2), fold.epoch.?.number);
    try std.testing.expectEqualSlices(u8, &fix.second_id, &fold.epoch.?.leader);
    try std.testing.expectEqualStrings("leader_lost", fold.epoch.?.reason);
    try std.testing.expect(fold.last_merge == null);
}

test "a mode_change handover is authored by the current leader, naming the new one" {
    var fix = Fix.init();
    var fold = try fix.cluster();
    defer fold.deinit();

    var buf: [epoch_payload_len]u8 = undefined;
    encodeEpochPayload(
        .{ .number = 2, .reason = .mode_change, .leader = fix.second_id },
        &buf,
    );
    const en = try fix.entryFor(
        fix.founder,
        .epoch,
        fix.control_id,
        nextAuthorSeq(&fold, fix.founder_id),
        &buf,
    );
    const sl = try fix.slotFor(
        fix.founder,
        2,
        1,
        entry.entryHash(&en),
        fold.head_slot_hash,
        1002,
    );
    try fold.applyControl(&sl, &en);
    try std.testing.expectEqual(@as(u64, 2), fold.epoch.?.number);
    try std.testing.expectEqualSlices(u8, &fix.second_id, &fold.epoch.?.leader);
}

test "epoch refusals: bad payload, wrong number, non-member leader, wrong author" {
    var fix = Fix.init();

    // Bad payload (unknown reason).
    {
        var fold = try fix.cluster();
        defer fold.deinit();
        var buf: [epoch_payload_len]u8 = undefined;
        encodeEpochPayload(
            .{ .number = 2, .reason = .manual, .leader = fix.second_id },
            &buf,
        );
        std.mem.writeInt(u16, buf[8..10], 99, .little);
        const en = try fix.entryFor(
            fix.second,
            .epoch,
            fix.control_id,
            nextAuthorSeq(&fold, fix.second_id),
            &buf,
        );
        const sl = try fix.slotFor(
            fix.second,
            2,
            1,
            entry.entryHash(&en),
            fold.head_slot_hash,
            1002,
        );
        try std.testing.expectError(error.BadEpoch, fold.applyControl(&sl, &en));
    }

    // The claimed leader is not a member.
    {
        var fold = try fix.cluster();
        defer fold.deinit();
        var buf: [epoch_payload_len]u8 = undefined;
        const stranger = crypto.sign.Ed25519.KeyPair.generate(fix.io_state.io());
        const stranger_id = chain.deriveMemberId(stranger.public_key.toBytes());
        encodeEpochPayload(
            .{ .number = 2, .reason = .leader_lost, .leader = stranger_id },
            &buf,
        );
        const en = try fix.entryFor(
            stranger,
            .epoch,
            fix.control_id,
            1,
            &buf,
        );
        const sl = try fix.slotFor(
            stranger,
            2,
            1,
            entry.entryHash(&en),
            fold.head_slot_hash,
            1002,
        );
        try std.testing.expectError(error.BadEpoch, fold.applyControl(&sl, &en));
    }

    // A member that is neither the current leader nor the claimed leader
    // cannot open an epoch (the founder claims second as leader — but the
    // founder is the current leader, so it must sign the slot itself).
    {
        var fold = try fix.cluster();
        defer fold.deinit();
        var buf: [epoch_payload_len]u8 = undefined;
        encodeEpochPayload(
            .{ .number = 2, .reason = .leader_lost, .leader = fix.second_id },
            &buf,
        );
        const en = try fix.entryFor(
            fix.founder,
            .epoch,
            fix.control_id,
            nextAuthorSeq(&fold, fix.founder_id),
            &buf,
        );
        const sl = try fix.slotFor(
            fix.second,
            2,
            1,
            entry.entryHash(&en),
            fold.head_slot_hash,
            1002,
        );
        try std.testing.expectError(error.BadEpoch, fold.applyControl(&sl, &en));
    }

    // A wrong epoch number is refused.
    {
        var fold = try fix.cluster();
        defer fold.deinit();
        var buf: [epoch_payload_len]u8 = undefined;
        encodeEpochPayload(
            .{ .number = 9, .reason = .leader_lost, .leader = fix.second_id },
            &buf,
        );
        const en = try fix.entryFor(
            fix.second,
            .epoch,
            fix.control_id,
            nextAuthorSeq(&fold, fix.second_id),
            &buf,
        );
        const sl = try fix.slotFor(
            fix.second,
            9,
            1,
            entry.entryHash(&en),
            fold.head_slot_hash,
            1002,
        );
        try std.testing.expectError(error.BadEpoch, fold.applyControl(&sl, &en));
    }

    // After the epoch, the new leader slots; the old one is refused.
    {
        var fold = try fix.cluster();
        defer fold.deinit();
        var buf: [epoch_payload_len]u8 = undefined;
        encodeEpochPayload(
            .{ .number = 2, .reason = .leader_lost, .leader = fix.second_id },
            &buf,
        );
        const en = try fix.entryFor(
            fix.second,
            .epoch,
            fix.control_id,
            nextAuthorSeq(&fold, fix.second_id),
            &buf,
        );
        const sl = try fix.slotFor(
            fix.second,
            2,
            1,
            entry.entryHash(&en),
            fold.head_slot_hash,
            1002,
        );
        try fold.applyControl(&sl, &en);

        // The founder's slot in the new epoch is refused: it is not the
        // leader anymore.
        const founder_en = try fix.entryFor(
            fix.founder,
            .settings,
            fix.control_id,
            nextAuthorSeq(&fold, fix.founder_id),
            "late",
        );
        const founder_sl = try fix.slotFor(
            fix.founder,
            2,
            2,
            entry.entryHash(&founder_en),
            fold.head_slot_hash,
            1003,
        );
        try std.testing.expectError(error.NotLeader, fold.applyControl(&founder_sl, &founder_en));
    }
}

test "merge records the last merge; a bad merge is refused" {
    var fix = Fix.init();
    var fold = try fix.cluster();
    defer fold.deinit();

    var buf: [16]u8 = undefined;
    encodeMergePayload(.{ .branch_epoch = 2, .branch_seq = 5 }, &buf);
    const en = try fix.entryFor(
        fix.founder,
        .merge,
        fix.control_id,
        nextAuthorSeq(&fold, fix.founder_id),
        &buf,
    );
    const sl = try fix.slotFor(
        fix.founder,
        1,
        3,
        entry.entryHash(&en),
        fold.head_slot_hash,
        1002,
    );
    try fold.applyControl(&sl, &en);
    try std.testing.expect(fold.last_merge != null);
    try std.testing.expectEqual(
        slot.Position{ .epoch = 1, .seq = 3 },
        fold.last_merge.?.position,
    );

    // A bad merge — a zero branch, authored by the leader — is refused.
    var bad: [16]u8 = undefined;
    encodeMergePayload(.{ .branch_epoch = 0, .branch_seq = 0 }, &bad);
    const bad_en = try fix.entryFor(
        fix.founder,
        .merge,
        fix.control_id,
        nextAuthorSeq(&fold, fix.founder_id),
        &bad,
    );
    const bad_sl = try fix.slotFor(
        fix.founder,
        1,
        4,
        entry.entryHash(&bad_en),
        fold.head_slot_hash,
        1003,
    );
    try std.testing.expectError(error.BadMerge, fold.applyControl(&bad_sl, &bad_en));
    // (A non-leader author fails earlier with not_leader — the leader check
    // runs before the payload is decoded.)
}

test "a checkpoint inside merge.settle_ms of the last merge is refused" {
    var fix = Fix.init();
    var control = try fix.cluster();
    defer control.deinit();
    var data = try chain.FoldState.init(test_alloc, false, fix.data_id);
    defer data.deinit();

    // A checkpoint in the data journal: the settle rule reads the cluster's
    // merge.settle_ms and the fold's last_merge (set when the merge entry
    // folded). Hand-build the data fold with a merge recorded at ts 1000.
    data.last_merge = .{ .position = .{ .epoch = 1, .seq = 9 }, .slot_ts_ms = 1000 };

    const checkpoint = @import("../journal/chain.zig").CheckpointPayload{
        .expire_through = .{ .epoch = 1, .seq = 1 },
    };
    var cp_buf: [16]u8 = undefined;
    @import("../journal/chain.zig").encodeCheckpointPayload(checkpoint, &cp_buf);
    const cp_en = try fix.entryFor(
        fix.founder,
        .checkpoint,
        fix.data_id,
        nextAuthorSeq(&data, fix.founder_id),
        &cp_buf,
    );
    const cp_sl = try fix.slotFor(
        fix.founder,
        1,
        1,
        entry.entryHash(&cp_en),
        slot.genesis_prev,
        2000, // 1000 ms after the merge: inside settle_ms (default 30000)
    );
    try std.testing.expectError(
        error.MergeSettling,
        data.applyData(&control, &cp_sl, &cp_en),
    );

    // Once settle_ms has passed, the checkpoint is accepted.
    const late_sl = try fix.slotFor(
        fix.founder,
        1,
        1,
        entry.entryHash(&cp_en),
        slot.genesis_prev,
        1000 + 30000,
    );
    try data.applyData(&control, &late_sl, &cp_en);
    try std.testing.expect(data.entries.contains(cp_en.id()));
}

test "survivor: the branch whose leader ranks higher survives" {
    const inputs = election.Inputs{
        .mode = "seniority",
        .authorities = &.{},
        .tiebreak = "seniority",
        .fallback = "stall",
    };
    const a = Branch{
        .leader = "aaaaaaaaaaaaaaaa".*,
        .leader_view = .{
            .id = "aaaaaaaaaaaaaaaa".*,
            .seniority = .{ .epoch = 1, .seq = 1 },
            .address = "node-a",
            .state = .member,
            .last_ack = .{ .epoch = 1, .seq = 9 },
        },
    };
    const b = Branch{
        .leader = "bbbbbbbbbbbbbbbb".*,
        .leader_view = .{
            .id = "bbbbbbbbbbbbbbbb".*,
            .seniority = .{ .epoch = 1, .seq = 2 },
            .address = "node-b",
            .state = .member,
            .last_ack = .{ .epoch = 2, .seq = 4 },
        },
    };
    // Seniority: the earlier join survives even though b is fresher.
    try std.testing.expectEqual(Winner.a, survivor(inputs, a, b));
    try std.testing.expectEqual(Winner.b, survivor(inputs, b, a));
}

test "epoch and merge payload codecs round-trip" {
    var buf: [epoch_payload_len]u8 = undefined;
    encodeEpochPayload(
        .{ .number = 3, .reason = .merge, .leader = [_]u8{5} ** 16 },
        &buf,
    );
    const epoch = try decodeEpochPayload(&buf);
    try std.testing.expectEqual(@as(u64, 3), epoch.number);
    try std.testing.expectEqual(Reason.merge, epoch.reason);
    try std.testing.expectEqualSlices(u8, &[_]u8{5} ** 16, &epoch.leader);

    var m: [16]u8 = undefined;
    encodeMergePayload(.{ .branch_epoch = 7, .branch_seq = 11 }, &m);
    const merge = try decodeMergePayload(&m);
    try std.testing.expectEqual(@as(u64, 7), merge.branch_epoch);
    try std.testing.expectEqual(@as(u64, 11), merge.branch_seq);
}
