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
    // The sum is computed in `usize`, not in the prefix's own `u16`: a
    // length field near the type's maximum makes `50 + addr_len` overflow
    // and panic before it is ever compared against the record's real size
    // (bug 2026-08-31-join-payload-len-overflow, the sibling
    // `decodeCreateJournalPayload` fixed as
    // 2026-08-29-entry-decode-payload-len-overflow named and did not fix).
    const addr_len: usize = std.mem.readInt(u16, bytes[48..50], .little);
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
    // The dupe is a separate step so its failure path is nameable: as an
    // argument to `append` it was allocated first and orphaned when `append`
    // itself failed. Once the member is in the table, `removeMember` is what
    // frees the address, so the errdefer hands over at that point.
    const address = try fold.allocator.dupe(u8, payload.address);
    {
        errdefer fold.allocator.free(address);
        try fold.members.append(fold.allocator, .{
            .id = payload.member_id,
            .public_key = payload.public_key,
            .seniority = sl.position(),
            .address = address,
        });
    }
    // Every failure from here rolls the member back. `validateState` did so
    // explicitly; `memberViews` did not, and an allocation failure there
    // left a member in the fold that the chain has no entry for - a
    // divergence from every peer that did not fail.
    errdefer removeMember(fold, payload.member_id);
    // The whole-state rules are count-dependent (PRD 0004's n = 1
    // exception): a join that grows the cluster past them would leave a
    // state no leader can ever be elected under — an empty authority list,
    // or a non-empty list that names no member (bug
    // 2026-08-28-join-can-strand-cluster-leaderless,
    // 2026-08-28-sweep3-ghost-authority-strand) — and, since only the
    // leader can author settings entries, one that can never self-heal.
    // Refuse the join, rolling the member back, when the state would be
    // invalid at the new count.
    const views = try fold.memberViews(fold.allocator, null);
    defer fold.allocator.free(views);
    validate.validateState(&fold.settings, fold.memberCount(), views) catch
        return error.InvalidSettings;
}

/// Applies a re-slotted `join` after a merge — the same validation and the
/// same append at the new slot as a live `join`, because the survivor's fold
/// never saw the losing branch and must not accept what it would refuse
/// live (a member id that does not derive from the key). PRD 0003
/// *Partition and merge*: a member admitted on the losing side ends up
/// junior to everyone admitted on the winning side during the partition,
/// deterministically.
///
/// Idempotent for a member the fold already holds, like
/// `applyLeaveReslotted`. A newcomer that could reach both sides of a
/// partition is admitted by both leaders, so the losing branch carries a
/// second, distinct `join` for an id the survivor already has; a branch that
/// held `leave X` then `join X` replays the join first, because
/// `doMergeControl` defers the leaves. Both refused `AlreadyMember`, and the
/// refusal arrives after the `merge` entry is already on the survivor's
/// chain, so the heal could never complete and never stop retrying (bug
/// 2026-08-31-reslotted-join-already-member). The seniority that survives is
/// the one the merged chain gives, which every member computes identically.
pub fn applyJoinReslotted(
    fold: *chain.FoldState,
    sl: *const slot.Slot,
    en: *const entry.Entry,
) ApplyError!void {
    const payload = decodeJoinPayload(fold.allocator, en.payload) catch |err|
        return chain.decodeCatch(err, error.BadControlPayload);
    defer payload.deinit(fold.allocator);
    // Checked before the no-op: a re-slot must not smuggle an id that does
    // not derive from its key past the live rule, present member or not.
    const derived = chain.deriveMemberId(payload.public_key);
    if (!std.mem.eql(u8, &payload.member_id, &derived)) return error.BadJoin;
    if (fold.memberById(payload.member_id) != null) return;
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
    try applyLeaveChecked(fold, en, true);
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
    try applyLeaveChecked(fold, en, false);
}

/// The shared live/re-slot leave rule: authorization, then removal. The live
/// path additionally runs the whole-state rule on the would-be post-leave
/// state — a leave that would strand the cluster (removing the last
/// resolvable authority, PRD 0004 goal 4) is refused with the fold untouched
/// (bug 2026-08-28-sweep3-ghost-authority-strand). The merge re-slot path
/// skips that check: the survivor's chain already carries the merge entry,
/// so a refusal there would abort the heal permanently (bug
/// 2026-08-29-merge-data-reslot-refusals).
fn applyLeaveChecked(
    fold: *chain.FoldState,
    en: *const entry.Entry,
    check_whole_state: bool,
) ApplyError!void {
    const payload = decodeLeavePayload(en.payload) catch return error.BadControlPayload;
    const leader = fold.epoch.?.leader;
    const self_leave = std.mem.eql(u8, &payload.member_id, &en.author);
    const leader_evicts = std.mem.eql(u8, &en.author, &leader);
    if (!self_leave and !leader_evicts) return error.BadLeave;
    if (fold.memberById(payload.member_id) == null) return error.BadLeave;
    if (check_whole_state) {
        // The would-be state with the leaving member excluded; on refusal
        // nothing was mutated (the member is removed only after the check).
        const views = try fold.memberViews(fold.allocator, payload.member_id);
        defer fold.allocator.free(views);
        validate.validateState(&fold.settings, fold.memberCount() - 1, views) catch
            return error.InvalidSettings;
    }
    removeMember(fold, payload.member_id);
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
        return self.clusterIn(test_alloc);
    }

    /// `cluster`, on a caller-chosen allocator - the OOM tests build the
    /// fold on a `FailingAllocator` so the fold's own allocations are the
    /// ones that fail.
    fn clusterIn(self: *const Fix, allocator: std.mem.Allocator) !chain.FoldState {
        var fold = try chain.FoldState.init(allocator, true, [_]u8{0} ** 16);
        errdefer fold.deinit();
        const payload = try allocator.alloc(
            u8,
            chain.genesisPayloadLen(.{
                .founder_key = self.founder.public_key.toBytes(),
                .changes = &.{},
            }),
        );
        defer allocator.free(payload);
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

test "a join that would strand via a ghost authority list is refused" {
    // Bug 2026-08-28-sweep3-ghost-authority-strand: validateState checked
    // only list *emptiness*, so a non-empty list naming no member passed
    // genesis (n = 1 exempts the resolvability rule) and every join — until
    // the cluster grew past n = 1 with no resolvable authority and
    // election.leader returned null under fallback = stall forever.
    var fix = Fix.init();
    var fold = try chain.FoldState.init(test_alloc, true, [_]u8{0} ** 16);
    defer fold.deinit();

    const mode = schema.keyIndex("leadership.mode").?;
    const authorities = schema.keyIndex("leadership.authorities").?;
    const ghost_list = try test_alloc.alloc([]const u8, 1);
    defer test_alloc.free(ghost_list);
    ghost_list[0] = "deadbeefdeadbeefdeadbeefdeadbeef"; // 32-hex id no member has
    const changes = [_]validate.Change{
        .{ .key = mode, .value = .{ .enum_value = schema.enumValue(mode, "configured").? } },
        .{ .key = authorities, .value = .{ .string_list = ghost_list } },
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

test "a leave that removes the last resolvable authority is refused" {
    // Bug 2026-08-28-sweep3-ghost-authority-strand: a leave is the one
    // mutation the empty-list rule cannot violate (it only loosens as the
    // count shrinks), but removing the last resolvable authority strands a
    // cluster of ≥ 2 members under fallback = stall. The leave is refused
    // with the fold untouched.
    var fix = Fix.init();
    var fold = try chain.FoldState.init(test_alloc, true, [_]u8{0} ** 16);
    defer fold.deinit();

    const mode = schema.keyIndex("leadership.mode").?;
    const authorities = schema.keyIndex("leadership.authorities").?;
    const addr_list = try test_alloc.alloc([]const u8, 1);
    defer test_alloc.free(addr_list);
    addr_list[0] = "10.0.0.2:3939"; // the second member's advertised address
    const changes = [_]validate.Change{
        .{ .key = mode, .value = .{ .enum_value = schema.enumValue(mode, "configured").? } },
        .{ .key = authorities, .value = .{ .string_list = addr_list } },
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

    var third = crypto.sign.Ed25519.KeyPair.generate(fix.io_state.io());
    const third_id = chain.deriveMemberId(third.public_key.toBytes());
    const members = [_]struct { id: [16]u8, kp: crypto.sign.Ed25519.KeyPair, addr: []const u8 }{
        .{ .id = fix.second_id, .kp = fix.second, .addr = "10.0.0.2:3939" },
        .{ .id = third_id, .kp = third, .addr = "10.0.0.3:3939" },
    };
    for (members, 0..) |m, i| {
        const payload = try test_alloc.alloc(
            u8,
            joinPayloadLen(.{
                .member_id = m.id,
                .public_key = m.kp.public_key.toBytes(),
                .address = m.addr,
            }),
        );
        defer test_alloc.free(payload);
        encodeJoinPayload(
            .{ .member_id = m.id, .public_key = m.kp.public_key.toBytes(), .address = m.addr },
            payload,
        );
        const en = try fix.entryFor(
            fix.founder,
            .join,
            fix.control_id,
            nextAuthorSeq(&fold, fix.founder_id),
            payload,
        );
        const sl = try fix.nextSlot(&fold, entry.entryHash(&en), @intCast(1002 + i));
        try fold.applyControl(&sl, &en);
    }
    try std.testing.expectEqual(@as(usize, 3), fold.members.items.len);

    // The authority (second) leaves: n stays ≥ 2 and nothing resolves.
    var leave_buf: [16]u8 = undefined;
    encodeLeavePayload(.{ .member_id = fix.second_id }, &leave_buf);
    const leave_en = try fix.entryFor(
        fix.founder,
        .leave,
        fix.control_id,
        nextAuthorSeq(&fold, fix.founder_id),
        &leave_buf,
    );
    const leave_sl = try fix.nextSlot(&fold, entry.entryHash(&leave_en), 1004);
    try std.testing.expectError(error.InvalidSettings, fold.applyControl(&leave_sl, &leave_en));
    try std.testing.expectEqual(@as(usize, 3), fold.members.items.len);
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

test "a join payload's address length is refused, not added in its own u16" {
    // Bug 2026-08-31-join-payload-len-overflow: the length check read
    // `50 + addr_len` with `addr_len` a u16, so the header overhead pushed
    // the sum past the type and panicked in Debug and ReleaseSafe instead
    // of refusing the record. Every member folds the same bytes, including
    // on replay from disk, so a record that panics one member panics all of
    // them and the chain cannot be reopened.
    var buf: [50]u8 = undefined;
    @memset(&buf, 0);

    // The largest value the field can hold.
    std.mem.writeInt(u16, buf[48..50], std.math.maxInt(u16), .little);
    try std.testing.expectError(error.InvalidLength, decodeJoinPayload(test_alloc, &buf));

    // The first value whose sum with the 50-byte header leaves the type.
    std.mem.writeInt(u16, buf[48..50], 65_486, .little);
    try std.testing.expectError(error.InvalidLength, decodeJoinPayload(test_alloc, &buf));

    // The last value that fits, so the check is still a comparison and not
    // an unconditional refusal.
    std.mem.writeInt(u16, buf[48..50], 65_485, .little);
    try std.testing.expectError(error.InvalidLength, decodeJoinPayload(test_alloc, &buf));

    // And a payload whose field matches its own size still decodes.
    std.mem.writeInt(u16, buf[48..50], 0, .little);
    var decoded = try decodeJoinPayload(test_alloc, &buf);
    defer decoded.deinit(test_alloc);
    try std.testing.expectEqual(@as(usize, 0), decoded.address.len);
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

test "a re-slotted join for a member the fold already holds is a no-op" {
    // Bug 2026-08-31-reslotted-join-already-member: `applyJoinReslotted`
    // delegated verbatim to `applyJoin`, so a second join for an id already
    // in the table returned `AlreadyMember`. Two branch shapes produce one:
    // a newcomer that reached both sides of a partition is admitted by both
    // leaders, and a branch holding `leave X` then `join X` replays the join
    // first because `doMergeControl` defers the leaves. The refusal lands
    // after the `merge` entry is already on the survivor's chain, so the
    // heal aborts, and the retry refuses identically forever.
    var fix = Fix.init();
    var fold = try fix.cluster();
    defer fold.deinit();

    const info = JoinPayload{
        .member_id = fix.second_id,
        .public_key = fix.second.public_key.toBytes(),
        .address = "10.0.0.2:3939",
    };
    const payload = try test_alloc.alloc(u8, joinPayloadLen(info));
    defer test_alloc.free(payload);
    encodeJoinPayload(info, payload);

    // The survivor's own admission of the newcomer, live.
    {
        const en = try fix.entryFor(fix.founder, .join, fix.control_id, 2, payload);
        const sl = try fix.nextSlot(&fold, entry.entryHash(&en), 1001);
        try fold.applyControl(&sl, &en);
    }
    const seniority = fold.memberById(fix.second_id).?.seniority;
    try std.testing.expectEqual(@as(usize, 2), fold.memberCount());

    // The losing branch's own `join` for the same newcomer, re-slotted: a
    // different admitter sequence and a different advertised address, so it
    // is a distinct entry rather than a redelivery of the one above.
    const other = JoinPayload{
        .member_id = fix.second_id,
        .public_key = fix.second.public_key.toBytes(),
        .address = "10.0.0.9:3939",
    };
    const other_payload = try test_alloc.alloc(u8, joinPayloadLen(other));
    defer test_alloc.free(other_payload);
    encodeJoinPayload(other, other_payload);
    const en = try fix.entryFor(fix.founder, .join, fix.control_id, 3, other_payload);
    const sl = try fix.nextSlot(&fold, entry.entryHash(&en), 1002);
    try fold.applyControlReslotted(&sl, &en);

    // Accepted as a no-op: one member, and the seniority the merged chain
    // gave it is untouched - every member computes the same one.
    try std.testing.expectEqual(@as(usize, 2), fold.memberCount());
    try std.testing.expectEqual(seniority, fold.memberById(fix.second_id).?.seniority);
    try std.testing.expectEqualStrings(
        "10.0.0.2:3939",
        fold.memberById(fix.second_id).?.address,
    );

    // A forged pairing is still refused, present member or not: the id the
    // payload names does not derive from the key it carries.
    {
        const forged = JoinPayload{
            .member_id = fix.second_id,
            .public_key = fix.founder.public_key.toBytes(),
            .address = "10.0.0.9:3939",
        };
        const buf = try test_alloc.alloc(u8, joinPayloadLen(forged));
        defer test_alloc.free(buf);
        encodeJoinPayload(forged, buf);
        const f_en = try fix.entryFor(fix.founder, .join, fix.control_id, 4, buf);
        const f_sl = try fix.nextSlot(&fold, entry.entryHash(&f_en), 1003);
        try std.testing.expectError(error.BadJoin, fold.applyControlReslotted(&f_sl, &f_en));
    }
}

test "a join that runs out of memory leaves the fold exactly as it found it" {
    // `applyJoin` mutates the member table and *then* runs the whole-state
    // rule. The `validateState` refusal always rolled the member back; an
    // allocation failure did not, so an OOM in `memberViews` left the fold
    // holding a member the chain has no entry for - a permanent divergence
    // from every peer whose allocation succeeded. The address dupe had the
    // matching hole: built as an argument to `append`, it was orphaned when
    // `append` itself failed.
    //
    // The sweep fails each of the join's own allocations in turn. The fold
    // is built first with the allocator not yet failing, so only the join's
    // allocations are in the window.
    var fix = Fix.init();
    const info = JoinPayload{
        .member_id = fix.second_id,
        .public_key = fix.second.public_key.toBytes(),
        .address = "10.0.0.2:3939",
    };
    const payload = try test_alloc.alloc(u8, joinPayloadLen(info));
    defer test_alloc.free(payload);
    encodeJoinPayload(info, payload);

    var failed_at_least_once = false;
    var k: usize = 0;
    while (k < 8) : (k += 1) {
        var failing = std.testing.FailingAllocator.init(test_alloc, .{});
        const fa = failing.allocator();
        var fold = try fix.clusterIn(fa);
        defer fold.deinit();
        try std.testing.expectEqual(@as(usize, 1), fold.members.items.len);

        failing.fail_index = failing.alloc_index + k;
        const en = try fix.entryFor(
            fix.founder,
            .join,
            fix.control_id,
            nextAuthorSeq(&fold, fix.founder_id),
            payload,
        );
        const sl = try fix.nextSlot(&fold, entry.entryHash(&en), 1001);
        if (applyJoin(&fold, &sl, &en)) |_| {
            // The allocation the sweep aimed at was past the join's last
            // one; the member is in, as it should be.
            try std.testing.expectEqual(@as(usize, 2), fold.members.items.len);
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            failed_at_least_once = true;
            // The fold is untouched: still only the founder, and the
            // testing allocator behind the failing one reports no leak.
            try std.testing.expectEqual(@as(usize, 1), fold.members.items.len);
            try std.testing.expect(fold.memberById(fix.second_id) == null);
        }
        failing.fail_index = std.math.maxInt(usize);
    }
    // The sweep is only meaningful if it actually induced failures.
    try std.testing.expect(failed_at_least_once);
}
