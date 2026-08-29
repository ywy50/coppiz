//! Cross-key settings rules and live-changeability (PRD 0004 phase 2).
//!
//! Two kinds of rule gate a `settings` entry, and both are pure functions
//! every member evaluates so a bad change is refused by the fold, not by
//! whoever happened to be leader:
//!
//! - **live-changeability**, per key, against the state in force before the
//!   entry: `leadership.*` is frozen by `leadership.reconfigurable = false`
//!   (PRD 0003), and `reconfigurable` itself can only be flipped live from
//!   true to false - the reverse is the offline procedure, which is why
//!   genesis may set it freely (that path is `applyGenesis` in fold.zig).
//! - **whole-state validity**, after all changes of the entry are applied:
//!   the cross-key rules below, table-tested.

const std = @import("std");
const schema = @import("schema.zig");
const framing = @import("../net/framing.zig");

/// One `(key, value)` change inside a settings entry or genesis. Owns its
/// value per the Value contract.
pub const Change = struct {
    key: u16,
    value: schema.Value,

    pub fn deinit(self: Change, allocator: std.mem.Allocator) void {
        self.value.deinit(allocator);
    }

    pub fn clone(self: Change, allocator: std.mem.Allocator) !Change {
        return .{ .key = self.key, .value = try self.value.clone(allocator) };
    }
};

/// Upper bound on one authority-list entry (member id hex or an address /
/// DNS name). DNS names top out at 253 characters; this leaves headroom
/// without letting an entry grow without bound.
pub const authority_entry_max = 256;

/// The member facts the authority-resolvability rule needs: the id (32-hex
/// when written out) and the advertised address an `authorities` entry may
/// name. Callers (the fold's apply paths) build these from the member table
/// (chain.zig `memberViews`).
pub const MemberView = struct {
    id: [16]u8,
    address: []const u8,
};

const reconfigurable_key = schema.keyIndex("leadership.reconfigurable").?;

/// Whether a settings entry may touch `key_index` in the state in force
/// before it. `always` keys are free; both leadership gates reduce to "is
/// reconfigurable currently true" - the `reconfigurable` key's own rule
/// says it can only turn itself off live, which is exactly the same test.
pub fn isLiveChangeable(key_index: u16, current: *const schema.SettingsState) bool {
    return switch (schema.keys[key_index].live_rule) {
        .always => true,
        .requires_reconfigurable => current.getBool(reconfigurable_key),
        .reconfigurable_turnoff_only => current.getBool(reconfigurable_key),
    };
}

pub const CrossKeyError = error{
    /// `ttl.enforce = all` with `ttl.default_ms = 0` would expire every
    /// entry immediately (PRD 0002 failure modes).
    TtlEnforceAllNeedsDefault,
    /// `configured`/`combined` with an empty authority list and
    /// `fallback = stall` at n > 1 leaves nobody who may ever lead.
    EmptyAuthoritiesNeedsFallback,
    /// `configured`/`combined` with a non-empty authority list that names no
    /// member and `fallback = stall` at n > 1 strands the cluster the same
    /// way an empty list does: `leader()` finds no authority and nothing can
    /// ever be authored to fix it (bug
    /// 2026-08-28-sweep3-ghost-authority-strand).
    AuthoritiesMatchNoMember,
    /// An authority entry must name something (a member id or an address).
    EmptyAuthorityEntry,
    /// An authority entry longer than the bound is not a name coppiz can
    /// ever resolve.
    AuthorityEntryTooLong,
    /// `journal.max_entry_bytes` must leave room for the record and the
    /// message in one frame, or an accepted entry can never be replicated
    /// (bug 2026-08-28-sweep3-oversized-entry-unreplicable).
    MaxEntryBytesExceedsFrameCap,
};

/// The whole-state rules (PRD 0004 goal 4): a settings state must be valid
/// as a whole, not key by key. `member_count` is the cluster's current
/// membership, which the fold knows: a one-member cluster may run
/// `configured` with an empty authority list, because PRD 0003 makes the
/// empty list mean self there. `members` carries the member table (id and
/// address) for the authority-resolvability rule; callers without a table
/// (genesis, journal scope) pass an empty slice — the rule is inert there,
/// because the empty-list exception (n = 1) also exempts the ghost check.
pub fn validateState(
    state: *const schema.SettingsState,
    member_count: u32,
    members: []const MemberView,
) CrossKeyError!void {
    const ttl_enforce = schema.keyIndex("ttl.enforce").?;
    const ttl_default = schema.keyIndex("ttl.default_ms").?;
    if (std.mem.eql(u8, state.getEnum(ttl_enforce), "all") and
        state.getU64(ttl_default) == 0)
    {
        return error.TtlEnforceAllNeedsDefault;
    }

    const mode = schema.keyIndex("leadership.mode").?;
    const fallback = schema.keyIndex("leadership.fallback").?;
    const authorities = schema.keyIndex("leadership.authorities").?;
    const mode_name = state.getEnum(mode);
    const fallback_name = state.getEnum(fallback);
    const list = state.getList(authorities);
    const empty_ok = std.mem.eql(u8, mode_name, "seniority") or
        std.mem.eql(u8, fallback_name, "seniority") or
        member_count <= 1;
    if (list.len == 0 and !empty_ok) return error.EmptyAuthoritiesNeedsFallback;
    for (list) |entry| {
        if (entry.len == 0) return error.EmptyAuthorityEntry;
        if (entry.len > authority_entry_max) return error.AuthorityEntryTooLong;
    }
    // A non-empty list that names no member strands the cluster exactly as
    // an empty one does under the same conditions: `leader()` (election.zig)
    // scans for a live authority, finds none, and `fallback = stall` returns
    // null — while only the leader could author the fix. The empty-list
    // exceptions (n = 1, seniority fallback) exempt this check too: the lone
    // member self-leads (PRD 0003), and the seniority fallback elects
    // without the list.
    if (!empty_ok and list.len > 0 and !anyAuthorityResolves(list, members)) {
        return error.AuthoritiesMatchNoMember;
    }

    // The frame must be able to carry any accepted entry (the record and
    // the message envelope ride in one frame), or it can never replicate
    // (bug 2026-08-28-sweep3-oversized-entry-unreplicable).
    const max_entry_bytes = schema.keyIndex("journal.max_entry_bytes").?;
    if (state.getU64(max_entry_bytes) > @as(u64, framing.max_body_bytes) - 4096) {
        return error.MaxEntryBytesExceedsFrameCap;
    }
}

/// Whether any authority entry names a member — verbatim address or 32-hex
/// member id — the same matching `authorityIndex` (election.zig) uses when
/// `leader()` scans for an authority.
fn anyAuthorityResolves(list: []const []const u8, members: []const MemberView) bool {
    for (list) |authority| {
        for (members) |m| {
            if (std.mem.eql(u8, authority, m.address)) return true;
            if (authority.len == 32 and isHexId(authority, m.id)) return true;
        }
    }
    return false;
}

fn hexNibble(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// Whether `text` is the hex of `id` (either letter case) — the id form an
/// `authorities` entry may name. Mirrors election.zig `isHexId`.
fn isHexId(text: []const u8, id: [16]u8) bool {
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        const hi = hexNibble(text[i * 2]) orelse return false;
        const lo = hexNibble(text[i * 2 + 1]) orelse return false;
        if ((hi << 4) | lo != id[i]) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

// Module-level test constants must not collide with the function locals
// above (Zig refuses a local shadowing a module-level declaration), so the
// constants carry the `test_` prefix.
const test_ttl_enforce = schema.keyIndex("ttl.enforce").?;
const test_ttl_default = schema.keyIndex("ttl.default_ms").?;
const test_mode = schema.keyIndex("leadership.mode").?;
const test_fallback = schema.keyIndex("leadership.fallback").?;
const test_authorities = schema.keyIndex("leadership.authorities").?;
const test_reconfigurable = schema.keyIndex("leadership.reconfigurable").?;

test "leadership keys are frozen while reconfigurable=false, live while true" {
    var state = try schema.SettingsState.initDefaults(std.testing.allocator);
    defer state.deinit();

    try std.testing.expect(isLiveChangeable(test_mode, &state));
    try std.testing.expect(isLiveChangeable(test_authorities, &state));
    try std.testing.expect(isLiveChangeable(test_reconfigurable, &state));

    try state.set(test_reconfigurable, .{ .boolean = false });
    try std.testing.expect(!isLiveChangeable(test_mode, &state));
    try std.testing.expect(!isLiveChangeable(test_authorities, &state));
    try std.testing.expect(!isLiveChangeable(test_reconfigurable, &state));

    // Everything else stays live while leadership is frozen.
    try std.testing.expect(isLiveChangeable(test_ttl_enforce, &state));
}

test "authorities empty is legal under seniority, fallback=seniority, and at n=1" {
    var state = try schema.SettingsState.initDefaults(std.testing.allocator);
    defer state.deinit();

    // Defaults: seniority, fallback=stall, empty authorities.
    try validateState(&state, 6, &.{});

    // configured + stall + empty authorities at n=6 refuses...
    try state.set(test_mode, .{ .enum_value = schema.enumValue(test_mode, "configured").? });
    try std.testing.expectError(
        error.EmptyAuthoritiesNeedsFallback,
        validateState(&state, 6, &.{}),
    );
    // ...but is legal at n=1 (empty list means self)...
    try validateState(&state, 1, &.{});
    // ...and legal at any n once fallback degrades to seniority.
    try state.set(test_fallback, .{ .enum_value = schema.enumValue(test_fallback, "seniority").? });
    try validateState(&state, 6, &.{});
}

test "authority entries must be non-empty and bounded" {
    var state = try schema.SettingsState.initDefaults(std.testing.allocator);
    defer state.deinit();
    try state.set(test_mode, .{ .enum_value = schema.enumValue(test_mode, "configured").? });
    try state.set(test_fallback, .{ .enum_value = schema.enumValue(test_fallback, "seniority").? });

    const allocator = std.testing.allocator;
    const entries = try allocator.alloc([]const u8, 1);
    defer allocator.free(entries);

    entries[0] = "";
    try state.set(test_authorities, .{ .string_list = entries });
    try std.testing.expectError(error.EmptyAuthorityEntry, validateState(&state, 2, &.{}));

    const long = "a" ** (authority_entry_max + 1);
    entries[0] = long;
    try state.set(test_authorities, .{ .string_list = entries });
    try std.testing.expectError(error.AuthorityEntryTooLong, validateState(&state, 2, &.{}));
}

test "a non-empty authority list naming no member is refused when it would strand" {
    // Bug 2026-08-28-sweep3-ghost-authority-strand: validateState checked
    // only list *emptiness*, so a non-empty list whose entries matched no
    // member passed every validation and stranded the cluster once it grew
    // past n = 1 — `leader()` found no authority, `fallback = stall`
    // returned null, and only the leader could have authored the fix.
    var state = try schema.SettingsState.initDefaults(std.testing.allocator);
    defer state.deinit();
    try state.set(test_mode, .{ .enum_value = schema.enumValue(test_mode, "configured").? });
    try state.set(test_fallback, .{ .enum_value = schema.enumValue(test_fallback, "stall").? });

    const allocator = std.testing.allocator;
    const entries = try allocator.alloc([]const u8, 1);
    defer allocator.free(entries);
    entries[0] = "deadbeefdeadbeefdeadbeefdeadbeef"; // 32-hex id no member has
    try state.set(test_authorities, .{ .string_list = entries });

    const members = [_]MemberView{
        .{ .id = [_]u8{1} ** 16, .address = "10.0.0.1:3939" },
        .{ .id = [_]u8{2} ** 16, .address = "10.0.0.2:3939" },
    };
    try std.testing.expectError(
        error.AuthoritiesMatchNoMember,
        validateState(&state, 2, &members),
    );

    // n = 1 keeps the pre-provisioning carve-out: the lone member
    // self-leads (PRD 0003), so a future member may be named before it joins.
    try validateState(&state, 1, &.{});

    // fallback = seniority rescues the same state at n > 1.
    try state.set(test_fallback, .{ .enum_value = schema.enumValue(test_fallback, "seniority").? });
    try validateState(&state, 2, &members);

    // An entry that names a member by address or by 32-hex id resolves.
    // (The state owns its copy of the list — `set` again after mutating.)
    try state.set(test_fallback, .{ .enum_value = schema.enumValue(test_fallback, "stall").? });
    entries[0] = "10.0.0.2:3939";
    try state.set(test_authorities, .{ .string_list = entries });
    try validateState(&state, 2, &members);
    entries[0] = "01010101010101010101010101010101"; // hex of the first id
    try state.set(test_authorities, .{ .string_list = entries });
    try validateState(&state, 2, &members);
}

test "ttl.enforce=all needs a non-zero default" {
    var state = try schema.SettingsState.initDefaults(std.testing.allocator);
    defer state.deinit();

    try state.set(test_ttl_enforce, .{ .enum_value = schema.enumValue(test_ttl_enforce, "all").? });
    try std.testing.expectError(error.TtlEnforceAllNeedsDefault, validateState(&state, 1, &.{}));

    try state.set(test_ttl_default, .{ .u64 = 5000 });
    try validateState(&state, 1, &.{});
}

test "max_entry_bytes must leave room for the record in a frame" {
    // Bug 2026-08-28-sweep3-oversized-entry-unreplicable: a max_entry_bytes
    // beyond the frame cap accepts entries no frame can carry.
    var state = try schema.SettingsState.initDefaults(std.testing.allocator);
    defer state.deinit();
    const key = schema.keyIndex("journal.max_entry_bytes").?;
    try state.set(key, .{ .u64 = framing.max_body_bytes });
    try std.testing.expectError(error.MaxEntryBytesExceedsFrameCap, validateState(&state, 1, &.{}));
    // The default (16 MiB) stays valid under the raised frame cap.
    try state.set(key, .{ .u64 = schema.provisional_max_entry_bytes });
    try validateState(&state, 1, &.{});
}

test "validateState does not mutate the state it inspects" {
    var state = try schema.SettingsState.initDefaults(std.testing.allocator);
    defer state.deinit();

    try state.set(test_ttl_enforce, .{ .enum_value = schema.enumValue(test_ttl_enforce, "all").? });
    try std.testing.expectError(error.TtlEnforceAllNeedsDefault, validateState(&state, 1, &.{}));
    // The state still holds the change (validateState only inspects); the
    // fold's apply path is what must clone-before-commit (fold.zig).
    try std.testing.expectEqualStrings("all", state.getEnum(test_ttl_enforce));
}
