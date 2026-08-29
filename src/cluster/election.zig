//! Election (PRD 0003 phase 2): the pure `leader(...)` function.
//!
//! There is no vote. Given the folded member table and this member's view of
//! who is live and synced, `leader` returns one member id. Because it is
//! deterministic over the *same inputs*, every member that agrees on
//! liveness agrees on the leader; members that disagree on liveness are by
//! definition partitioned (PRD 0003 *Election*).
//!
//! `syncing` members are never eligible (PRD 0003 *Member states*): a member
//! that lacks the full state cannot lead. `left` members are not in the fold
//! at all, so the fold's member table is already the eligible-by-construction
//! set minus runtime state.
//!
//! `compareRank` is the same ranking the merge rule uses (PRD 0003 *Partition
//! and merge*): the surviving branch is the one whose leader ranks higher.

const std = @import("std");
const slot = @import("../journal/slot.zig");

/// Per-member liveness, as one member sees another (PRD 0003 *Member
/// states*): `lost` (`unreachable` in the PRD — the failure detector lost
/// it), `syncing` (backfilling to the head — never leader-eligible), or
/// `member` (at head within `sync.lag_slots` — the only leader-eligible
/// state).
pub const State = enum(u8) {
    lost,
    syncing,
    member,
};

/// One member's inputs to the election: everything `leader` needs to rank
/// it. The caller builds these from the fold's member table and its own
/// liveness view. `Member.View` is the cluster's instantiation; see
/// `Election` for why the id type is a parameter.
pub const View = Member.View;

/// The cluster's election: a member id is 16 bytes (PRD 0003).
pub const Member = Election([16]u8);

pub const leader = Member.leader;
pub const compareRank = Member.compareRank;
pub const authorityIndex = Member.authorityIndex;

/// The election over an abstract member id.
///
/// PRD 0006 *What the core must get right now* requires that "election is a
/// pure function over an abstract member set", so that a federation elects
/// over *groups* by calling the same function with groups as its members
/// (PRD 0006 G3). Nothing here reads a member id except to return it and to
/// match it against an `authorities` entry, so the id's width is the only
/// thing that has to vary: `Id` is any fixed-size byte array, and a
/// federation instantiates `Election([32]u8)` for a group id derived from a
/// genesis hash.
///
/// This is a parameter today rather than later because the alternative is a
/// federation that either copies the ranking or widens the cluster's id -
/// the first drifts, the second is a format break.
pub fn Election(comptime Id: type) type {
    return struct {
        const Self = @This();

        /// The hex length an `authorities` entry needs to name this id.
        pub const hex_len = @typeInfo(Id).array.len * 2;

        /// One member's inputs to the election: everything `leader` needs to
        /// rank it. The caller builds these from the fold's member table and
        /// its own liveness view.
        pub const View = struct {
            id: Id,
            seniority: slot.Position,
            /// The advertised address (borrowed); an `authorities` entry may
            /// name it, so a DNS rename is a settings change, not an identity
            /// change (PRD 0003).
            address: []const u8,
            state: State,
            /// The highest `(epoch, seq)` this member has acknowledged - its
            /// verified head. Used only by `tiebreak = freshest`, and frozen
            /// at election (OQ 12).
            last_ack: slot.Position,
        };

        /// The leader under `seniority`: the live, fully-synced member with
        /// the earliest join slot. `null` when none is in the `member` state.
        fn seniorityLeader(members: []const Self.View) ?Id {
            var best: ?Self.View = null;
            for (members) |m| {
                if (m.state != .member) continue;
                if (best) |b| {
                    if (slot.Position.order(m.seniority, b.seniority) == .lt) best = m;
                } else {
                    best = m;
                }
            }
            return if (best) |b| b.id else null;
        }

        /// Whether an `authorities` entry is written in the id form: exactly
        /// `hex_len` hex digits. The two naming forms share one list, so each
        /// entry has to belong to exactly one of them - see
        /// `authorityIndex`.
        pub fn authorityNamesAnId(authority: []const u8) bool {
            if (authority.len != Self.hex_len) return false;
            for (authority) |c| {
                if (hexNibble(c) == null) return false;
            }
            return true;
        }

        /// The index of `member` in the authority list; null when the member
        /// is not an authority. An authority that matches nobody is skipped
        /// by construction.
        ///
        /// Each entry is read as *either* an id or an address, never both.
        /// Matching an entry against both used to let one member occupy
        /// another's slot: a member's address is self-declared (`onHello`
        /// copies the dialer's `address` verbatim, and `addressSafe` accepts
        /// any printable ASCII, hex included), so a member advertising
        /// `address = <hex of the authority's id>` was reported as that
        /// authority. It could then lead an election that should have
        /// stalled, which defeats the id form's whole point - the id is
        /// derived from the key precisely so it cannot be chosen (PRD 0003
        /// *Identity*; bug 2026-08-30-authority-address-id-collision).
        pub fn authorityIndex(authorities: []const []const u8, member: Self.View) ?usize {
            for (authorities, 0..) |authority, i| {
                if (Self.authorityNamesAnId(authority)) {
                    if (isHexId(authority, &member.id)) return i;
                    continue;
                }
                if (std.mem.eql(u8, authority, member.address)) return i;
            }
            return null;
        }

        /// Orders two members the way the mode ranks them: `.lt` means `a` is
        /// preferred. `seniority` ranks by join slot; `configured` by
        /// authority list order; `combined` filters by the authority list and
        /// orders within it by `tiebreak`. When neither member is an authority
        /// (or the tiebreak ties), the ordering degrades to seniority -
        /// compareRank ranks and never refuses: the `fallback` setting gates
        /// `leader`'s election, not this ranking, so the merge rule
        /// (epoch.survivor) reaches the degradation whenever a branch's leader
        /// is not on the list.
        pub fn compareRank(inputs: Inputs, a: Self.View, b: Self.View) std.math.Order {
            // seniority ignores the authority list, exactly as `leader` does -
            // the merge survivor must use the same ranking election uses.
            if (std.mem.eql(u8, inputs.mode, "seniority"))
                return slot.Position.order(a.seniority, b.seniority);
            const a_idx = Self.authorityIndex(inputs.authorities, a);
            const b_idx = Self.authorityIndex(inputs.authorities, b);
            const configured = std.mem.eql(u8, inputs.mode, "configured");
            if (configured) {
                if (a_idx != null and b_idx != null) {
                    if (a_idx.? < b_idx.?) return .lt;
                    if (a_idx.? > b_idx.?) return .gt;
                }
                if (a_idx != null and b_idx == null) return .lt;
                if (b_idx != null and a_idx == null) return .gt;
                return slot.Position.order(a.seniority, b.seniority);
            }
            // combined: the list filters, the tiebreak orders.
            if (a_idx == null and b_idx == null) {
                return slot.Position.order(a.seniority, b.seniority);
            }
            if (a_idx != null and b_idx == null) return .lt;
            if (b_idx != null and a_idx == null) return .gt;
            return tiebreakOrder(inputs.tiebreak, a, b);
        }

        /// The `combined` tiebreak: `seniority` (default) or `freshest`.
        /// `freshest` prefers the eligible member with the higher acknowledged
        /// head; ties fall to seniority. `.lt` means `a` is preferred.
        fn tiebreakOrder(tiebreak: []const u8, a: Self.View, b: Self.View) std.math.Order {
            if (std.mem.eql(u8, tiebreak, "freshest")) {
                const o = slot.Position.order(a.last_ack, b.last_ack);
                if (o == .gt) return .lt;
                if (o == .lt) return .gt;
            }
            return slot.Position.order(a.seniority, b.seniority);
        }

        /// The leader under the mode, or `null` when the mode forbids one.
        /// `null` under `configured`/`combined` with `fallback = stall` means
        /// writes are refused (`no_leader`); under the seniority fallback the
        /// senior member leads instead.
        pub fn leader(inputs: Inputs, members: []const Self.View) ?Id {
            // n = 1: a single member is its own leader - "list self, or empty
            // list = self" (PRD 0003 table), the case that makes a one-member
            // cluster a complete cluster under every mode.
            if (members.len == 1 and members[0].state == .member) return members[0].id;

            if (std.mem.eql(u8, inputs.mode, "seniority")) return seniorityLeader(members);

            // configured and combined: only live, fully-synced authorities
            // lead.
            var best: ?Self.View = null;
            for (members) |m| {
                if (m.state != .member) continue;
                if (Self.authorityIndex(inputs.authorities, m) == null) continue;
                if (best) |b| {
                    if (Self.compareRank(inputs, m, b) == .lt) best = m;
                } else {
                    best = m;
                }
            }
            if (best == null) {
                if (std.mem.eql(u8, inputs.fallback, "seniority")) {
                    return seniorityLeader(members);
                }
                return null; // stall: no leader, `append` returns no_leader
            }
            return best.?.id;
        }
    };
}

/// The election's settings inputs, resolved from the fold (PRD 0003
/// settings table). Passed as strings so election stays schema-free; the
/// caller maps the settings state to these. Shared by every instantiation:
/// the settings are the same whether the members are nodes or groups.
pub const Inputs = struct {
    /// "seniority" | "configured" | "combined".
    mode: []const u8,
    /// The `leadership.authorities` list verbatim: member ids (hex) or
    /// addresses.
    authorities: []const []const u8,
    /// "seniority" | "freshest" (combined only).
    tiebreak: []const u8,
    /// "stall" | "seniority" (configured/combined only).
    fallback: []const u8,
};

fn hexNibble(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// Whether `text` is the hex of `id` (either letter case). Takes the id as a
/// slice so one implementation serves every id width.
pub fn isHexId(text: []const u8, id: []const u8) bool {
    if (text.len != id.len * 2) return false;
    for (id, 0..) |byte, i| {
        const hi = hexNibble(text[i * 2]) orelse return false;
        const lo = hexNibble(text[i * 2 + 1]) orelse return false;
        if ((hi << 4) | lo != byte) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const A = "aaaaaaaaaaaaaaaa".*;
const B = "bbbbbbbbbbbbbbbb".*;
const C = "cccccccccccccccc".*;
const D = "dddddddddddddddd".*;
const E = "eeeeeeeeeeeeeeee".*;
const F = "ffffffffffffffff".*;

const P = slot.Position;

/// Views for members a..f with join slots 1..6 and the matching addresses.
/// `states` and `acks` parallel the id list; defaults are all .member and
/// heads equal to the join slot. The six views live by value in the struct —
/// a slice of a stack-local array would dangle.
const Members = struct {
    views6: [6]View,

    fn init(states: []const State, acks: []const P) Members {
        const ids = [_][16]u8{ A, B, C, D, E, F };
        const addrs = [_][]const u8{
            "node-a", "node-b", "node-c", "node-d", "node-e", "node-f",
        };
        var views: [6]View = undefined;
        for (0..6) |i| {
            views[i] = .{
                .id = ids[i],
                .seniority = .{ .epoch = 1, .seq = @intCast(i + 1) },
                .address = addrs[i],
                .state = if (i < states.len) states[i] else .member,
                .last_ack = if (i < acks.len) acks[i] else .{ .epoch = 1, .seq = @intCast(i + 1) },
            };
        }
        return .{ .views6 = views };
    }

    /// The first `n` views, for the n-member tests.
    fn slice(self: *const Members, n: usize) []const View {
        return self.views6[0..n];
    }

    fn view(self: *const Members, idx: usize) View {
        return self.views6[idx];
    }
};

const seniority_inputs = Inputs{
    .mode = "seniority",
    .authorities = &[_][]const u8{},
    .tiebreak = "seniority",
    .fallback = "stall",
};

const configured_inputs = Inputs{
    .mode = "configured",
    .authorities = &[_][]const u8{ "node-b", "node-d" },
    .tiebreak = "seniority",
    .fallback = "stall",
};

const combined_inputs = Inputs{
    .mode = "combined",
    .authorities = &[_][]const u8{ "node-b", "node-d" },
    .tiebreak = "seniority",
    .fallback = "stall",
};

const empty_states = [_]State{};
const empty_acks = [_]P{};

test "seniority: the earliest join slot leads at n = 1, 2, 3, 4, 6" {
    // n = 1: one member is its own leader.
    var m = Members.init(&empty_states, &empty_acks);
    try std.testing.expectEqualSlices(u8, &A, &leader(seniority_inputs, m.slice(1)).?);

    // n = 2: the senior member leads.
    try std.testing.expectEqualSlices(u8, &A, &leader(seniority_inputs, m.slice(2)).?);

    // n = 3, 4, 6: still the earliest join.
    try std.testing.expectEqualSlices(u8, &A, &leader(seniority_inputs, m.slice(3)).?);
    try std.testing.expectEqualSlices(u8, &A, &leader(seniority_inputs, m.slice(4)).?);
    try std.testing.expectEqualSlices(u8, &A, &leader(seniority_inputs, m.slice(6)).?);
}

test "seniority: every liveness subset picks the earliest member-state member" {
    // The senior member unreachable: the next one leads.
    var m = Members.init(&[_]State{ .lost, .member, .member }, &empty_acks);
    try std.testing.expectEqualSlices(u8, &B, &leader(seniority_inputs, m.slice(3)).?);

    // The senior member syncing: never eligible, the next member leads (G5).
    m = Members.init(&[_]State{ .syncing, .member, .member }, &empty_acks);
    try std.testing.expectEqualSlices(u8, &B, &leader(seniority_inputs, m.slice(3)).?);

    // Nobody reachable: no leader.
    m = Members.init(&[_]State{ .lost, .lost, .lost }, &empty_acks);
    try std.testing.expect(leader(seniority_inputs, m.slice(3)) == null);

    // A single syncing member at n = 1 is never eligible (G5).
    m = Members.init(&[_]State{.syncing}, &empty_acks);
    try std.testing.expect(leader(seniority_inputs, m.slice(1)) == null);

    // Middle of a 6-member set: only the earliest member-state member leads.
    m = Members.init(
        &[_]State{ .lost, .syncing, .member, .lost, .member, .member },
        &empty_acks,
    );
    try std.testing.expectEqualSlices(u8, &C, &leader(seniority_inputs, m.slice(6)).?);
}

test "configured: list order decides, odd subsets work, stall and seniority fallback" {
    // authorities = [b, d]; both live: b (list order, not seniority).
    var m = Members.init(&empty_states, &empty_acks);
    try std.testing.expectEqualSlices(u8, &B, &leader(configured_inputs, m.slice(4)).?);

    // The first authority unreachable: the next on the list leads.
    m = Members.init(&[_]State{ .lost, .lost, .member, .member }, &empty_acks);
    try std.testing.expectEqualSlices(u8, &D, &leader(configured_inputs, m.slice(4)).?);

    // No authority live (b and d are lost; a and c are members but not
    // authorities), fallback = stall: no leader (writes refused).
    m = Members.init(&[_]State{ .member, .lost, .member, .lost }, &empty_acks);
    try std.testing.expect(leader(configured_inputs, m.slice(4)) == null);

    // Same, fallback = seniority: degrades to the senior member.
    var degraded = configured_inputs;
    degraded.fallback = "seniority";
    try std.testing.expectEqualSlices(u8, &A, &leader(degraded, m.slice(4)).?);

    // n = 6 with an odd authority subset [b, d, f]: list order wins.
    const odd = Inputs{
        .mode = "configured",
        .authorities = &[_][]const u8{ "node-b", "node-d", "node-f" },
        .tiebreak = "seniority",
        .fallback = "stall",
    };
    m = Members.init(&empty_states, &empty_acks);
    try std.testing.expectEqualSlices(u8, &B, &leader(odd, m.slice(6)).?);
    // The authority list can also be written as hex ids.
    var hex = odd;
    hex.authorities = &[_][]const u8{ &idHex(D), &idHex(F) };
    try std.testing.expectEqualSlices(u8, &D, &leader(hex, m.slice(6)).?);

    // An authority nobody advertises is skipped; the other one leads.
    var ghost = odd;
    ghost.authorities = &[_][]const u8{ "ghost.example", "node-d" };
    try std.testing.expectEqualSlices(u8, &D, &leader(ghost, m.slice(6)).?);
}

test "combined: authorities filter, tiebreak orders within them" {
    // authorities = [b, d]; tiebreak = seniority: d's list position does not
    // matter — the senior of the two authorities leads.
    var m = Members.init(&empty_states, &empty_acks);
    try std.testing.expectEqualSlices(u8, &B, &leader(combined_inputs, m.slice(4)).?);

    // tiebreak = freshest: the authority with the higher acknowledged head
    // leads, even if it joined later.
    var freshest = combined_inputs;
    freshest.tiebreak = "freshest";
    m = Members.init(
        &empty_states,
        &[_]P{ P{ .epoch = 1, .seq = 1 }, P{ .epoch = 1, .seq = 5 } },
    );
    try std.testing.expectEqualSlices(u8, &B, &leader(freshest, m.slice(2)).?);
    m = Members.init(
        &empty_states,
        &[_]P{
            P{ .epoch = 1, .seq = 1 }, P{ .epoch = 1, .seq = 1 },
            P{ .epoch = 1, .seq = 1 }, P{ .epoch = 2, .seq = 3 },
        },
    );
    try std.testing.expectEqualSlices(u8, &D, &leader(freshest, m.slice(4)).?);

    // Non-authorities never lead under combined, even the founder.
    try std.testing.expectEqualSlices(u8, &B, &leader(combined_inputs, m.slice(3)).?);

    // No authority live, fallback = stall: no leader.
    m = Members.init(&[_]State{ .member, .lost, .member, .lost }, &empty_acks);
    try std.testing.expect(leader(combined_inputs, m.slice(4)) == null);
}

test "a syncing member is never returned in any mode or subset (G5)" {
    // seniority: the senior member is syncing; only the members lead.
    var m = Members.init(&[_]State{ .syncing, .member, .member }, &empty_acks);
    try std.testing.expectEqualSlices(u8, &B, &leader(seniority_inputs, m.slice(3)).?);
    // configured: the authority is syncing; fallback stall -> null.
    m = Members.init(&[_]State{ .member, .syncing }, &empty_acks);
    try std.testing.expect(leader(configured_inputs, m.slice(2)) == null);
    // combined: same.
    m = Members.init(&[_]State{ .member, .syncing }, &empty_acks);
    try std.testing.expect(leader(combined_inputs, m.slice(2)) == null);
}

test "an authority named by id is not matched by a member's advertised address" {
    // A member's address is self-declared: `onHello` copies the dialer's
    // `address` into the member map and `admitNewcomer` copies it into the
    // `join` payload, filtered only by `addressSafe` (printable ASCII, <=
    // 300 bytes) - which accepts a 32-character hex string. Matching each
    // authority entry against *both* the address and the id therefore let
    // any admitted member occupy another member's id-named authority slot,
    // and the id form is the one PRD 0003 calls unspoofable.
    const b_hex = idHex(B);
    const inputs = Inputs{
        .mode = "configured",
        .authorities = &[_][]const u8{&b_hex},
        .tiebreak = "seniority",
        .fallback = "stall",
    };

    // A is senior to B and advertises B's id as its address. Only A is live.
    var m = Members.init(&[_]State{ .member, .lost }, &empty_acks);
    m.views6[0].address = &b_hex;

    // A is not an authority: the sole authority (B) is down, so `stall`
    // refuses writes rather than handing the term to the impostor.
    try std.testing.expect(authorityIndex(inputs.authorities, m.view(0)) == null);
    try std.testing.expect(leader(inputs, m.slice(2)) == null);

    // B itself still matches its own entry, and still leads when live.
    try std.testing.expectEqual(@as(?usize, 0), authorityIndex(inputs.authorities, m.view(1)));
    var both = Members.init(&empty_states, &empty_acks);
    both.views6[0].address = &b_hex;
    try std.testing.expectEqualSlices(u8, &B, &leader(inputs, both.slice(2)).?);

    // The address form is untouched: an entry that is not hex of the right
    // width is still matched against the advertised address only.
    const by_address = Inputs{
        .mode = "configured",
        .authorities = &[_][]const u8{"node-a"},
        .tiebreak = "seniority",
        .fallback = "stall",
    };
    const plain = Members.init(&empty_states, &empty_acks);
    try std.testing.expectEqual(
        @as(?usize, 0),
        authorityIndex(by_address.authorities, plain.view(0)),
    );

    // A hex string of the wrong width is an address, not an id.
    try std.testing.expect(!Member.authorityNamesAnId("abcdef"));
    try std.testing.expect(Member.authorityNamesAnId(&b_hex));
    // Non-hex characters at the right length are an address too.
    try std.testing.expect(!Member.authorityNamesAnId("node-b.example.internal.zzzzzzzz"));
}

test "compareRank: the merge rule's survivor ranking" {
    // seniority: the earlier join wins.
    var m = Members.init(&empty_states, &empty_acks);
    try std.testing.expectEqual(
        .lt,
        compareRank(seniority_inputs, m.view(0), m.view(1)),
    );
    try std.testing.expectEqual(
        .gt,
        compareRank(seniority_inputs, m.view(1), m.view(0)),
    );
    // configured: list position wins over seniority.
    try std.testing.expectEqual(
        .lt,
        compareRank(configured_inputs, m.view(1), m.view(0)),
    );
    // combined + freshest: the higher head wins.
    var freshest = combined_inputs;
    freshest.tiebreak = "freshest";
    m = Members.init(
        &empty_states,
        &[_]P{ P{ .epoch = 1, .seq = 1 }, P{ .epoch = 2, .seq = 9 } },
    );
    try std.testing.expectEqual(
        .lt,
        compareRank(freshest, m.view(1), m.view(0)),
    );
}

fn idHex(id: [16]u8) [32]u8 {
    var buf: [32]u8 = undefined;
    const hex = "0123456789abcdef";
    for (id, 0..) |byte, i| {
        buf[i * 2] = hex[byte >> 4];
        buf[i * 2 + 1] = hex[byte & 0xf];
    }
    return buf;
}

test "(PRD 0006 G3) the same election functions rank groups as they rank members" {
    // PRD 0006's "what the core must get right now" table requires election
    // to be a pure function over an abstract member set, so a federation can
    // elect over groups by calling it with groups as members. G3 states the
    // check: import both and assert they are the same functions over
    // different member types.
    //
    // A group id is a genesis hash, so 32 bytes where a member id is 16.
    const Group = Election([32]u8);

    // Same functions, not lookalikes: the cluster's exported `leader` and
    // `compareRank` *are* the 16-byte instantiation's.
    try std.testing.expect(leader == Member.leader);
    try std.testing.expect(compareRank == Member.compareRank);
    try std.testing.expect(authorityIndex == Member.authorityIndex);
    try std.testing.expect(Member.hex_len == 32);
    try std.testing.expect(Group.hex_len == 64);
    // Distinct instantiations, so the ids really are different types.
    try std.testing.expect(Member.View != Group.View);

    const g1 = [_]u8{0x11} ** 32;
    const g2 = [_]u8{0x22} ** 32;
    const groups = [_]Group.View{
        .{
            .id = g2,
            .seniority = .{ .epoch = 1, .seq = 2 },
            .address = "group-two",
            .state = .member,
            .last_ack = .{ .epoch = 1, .seq = 9 },
        },
        .{
            .id = g1,
            .seniority = .{ .epoch = 1, .seq = 1 },
            .address = "group-one",
            .state = .member,
            .last_ack = .{ .epoch = 1, .seq = 3 },
        },
    };

    // seniority: the earliest join slot leads, groups exactly as members.
    try std.testing.expectEqual(g1, Group.leader(seniority_inputs, &groups).?);

    // The authority list names a group by its hex id, 64 chars wide, and
    // the same code path that matches a member's 32-char hex matches it.
    var hex: [64]u8 = undefined;
    _ = try std.fmt.bufPrint(&hex, "{x}", .{g2});
    const authorities = [_][]const u8{&hex};
    const configured = Inputs{
        .mode = "configured",
        .authorities = &authorities,
        .tiebreak = "seniority",
        .fallback = "stall",
    };
    try std.testing.expectEqual(@as(?usize, 0), Group.authorityIndex(&authorities, groups[0]));
    try std.testing.expect(Group.authorityIndex(&authorities, groups[1]) == null);
    try std.testing.expectEqual(g2, Group.leader(configured, &groups).?);

    // A syncing group is never eligible, the same rule members get.
    var syncing = groups;
    syncing[0].state = .syncing;
    try std.testing.expect(Group.leader(configured, &syncing) == null);

    // And the ranking the merge rule uses is the same function too: under
    // `combined` + `freshest`, the group with the higher acknowledged head
    // ranks first, which is what `epoch.survivor` asks of members.
    const both = [_][]const u8{ "group-one", "group-two" };
    const combined = Inputs{
        .mode = "combined",
        .authorities = &both,
        .tiebreak = "freshest",
        .fallback = "stall",
    };
    try std.testing.expectEqual(
        std.math.Order.lt,
        Group.compareRank(combined, groups[0], groups[1]),
    );
    try std.testing.expectEqual(g2, Group.leader(combined, &groups).?);
}
