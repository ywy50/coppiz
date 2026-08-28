//! The settings entry payload and how a fold applies it (PRD 0004 phases 1
//! and 3).
//!
//! A `settings` entry's payload names a scope, a journal id (journal scope
//! only), and an ordered list of `(key, value)` changes. Every member
//! decodes and applies it with the same pure rule, so settings cannot be
//! disagreed on: keys must exist and parse, must be live-changeable in the
//! state before the entry, and the resulting state must be valid as a
//! whole. Application is clone -> validate -> commit, so a refused entry
//! leaves the state untouched.
//!
//! Payload layout (all little-endian):
//!
//!   scope u8 | journal_id 16 | count u16 | (key u16, value_len u16, value)*

const std = @import("std");
const schema = @import("schema.zig");
const validate = @import("validate.zig");

/// A decoded settings entry payload. Owns its changes.
pub const SettingsPayload = struct {
    scope: schema.Scope,
    journal_id: [16]u8,
    /// Owned after decode (the changes are freed by deinit); callers may
    /// borrow when encoding.
    changes: []const validate.Change,

    pub fn deinit(self: SettingsPayload, allocator: std.mem.Allocator) void {
        for (self.changes) |change| change.deinit(allocator);
        allocator.free(self.changes);
    }
};

/// Encoded size of a change list: the count plus each (key, value_len,
/// value) tuple.
pub fn changesLen(changes: []const validate.Change) usize {
    var n: usize = 2;
    for (changes) |change| n += 2 + 2 + schema.valueLen(change.value);
    return n;
}

/// Encodes a change list (count + tuples) into `buf`, which must hold
/// `changesLen`.
pub fn encodeChanges(changes: []const validate.Change, buf: []u8) void {
    std.mem.writeInt(u16, buf[0..2], @intCast(changes.len), .little);
    var off: usize = 2;
    var len_buf: [2]u8 = undefined;
    for (changes) |change| {
        std.mem.writeInt(u16, &len_buf, change.key, .little);
        @memcpy(buf[off .. off + 2], &len_buf);
        const vlen = schema.valueLen(change.value);
        std.mem.writeInt(u16, &len_buf, @intCast(vlen), .little);
        @memcpy(buf[off + 2 .. off + 4], &len_buf);
        schema.encodeValue(change.value, buf[off + 4 .. off + 4 + vlen]);
        off += 4 + vlen;
    }
}

/// Decodes a change list, validating each key index and value. Owns the
/// values. The same encoding carries the `settings` entry's changes, a
/// genesis's initial settings, and a create_journal's journal settings;
/// `scope_filter` enforces that every key belongs to the declared scope
/// (the settings entry's scope, or cluster for genesis / journal for
/// create_journal).
pub fn decodeChanges(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    scope_filter: ?schema.Scope,
) DecodeError![]validate.Change {
    if (bytes.len < 2) return error.InvalidLength;
    const count = std.mem.readInt(u16, bytes[0..2], .little);
    const changes = try allocator.alloc(validate.Change, count);
    var filled: usize = 0;
    errdefer {
        for (changes[0..filled]) |change| change.deinit(allocator);
        allocator.free(changes);
    }
    var off: usize = 2;
    var len_buf: [2]u8 = undefined;
    for (0..count) |i| {
        if (off + 4 > bytes.len) return error.InvalidLength;
        @memcpy(&len_buf, bytes[off .. off + 2]);
        const key = std.mem.readInt(u16, &len_buf, .little);
        @memcpy(&len_buf, bytes[off + 2 .. off + 4]);
        const vlen = std.mem.readInt(u16, &len_buf, .little);
        off += 4;
        if (key >= schema.key_count) return error.UnknownKey;
        if (scope_filter) |filter| {
            if (schema.keys[key].scope != filter) return error.ScopeMismatch;
        }
        if (off + vlen > bytes.len) return error.InvalidLength;
        const value = try schema.decodeValue(allocator, key, bytes[off .. off + vlen]);
        off += vlen;
        changes[i] = .{ .key = key, .value = value };
        filled += 1;
    }
    if (off != bytes.len) return error.InvalidLength;
    return changes;
}

pub fn payloadLen(payload: SettingsPayload) usize {
    return 1 + 16 + changesLen(payload.changes);
}

/// Encodes a payload into `buf`, which must hold `payloadLen`.
pub fn encodePayload(payload: SettingsPayload, buf: []u8) void {
    buf[0] = @intFromEnum(payload.scope);
    buf[1..17].* = payload.journal_id;
    encodeChanges(payload.changes, buf[17..]);
}

pub const DecodeError = error{
    InvalidLength,
    InvalidScope,
    UnknownKey,
    ScopeMismatch,
    InvalidValue,
    OutOfMemory,
};

/// Decodes a payload, validating as it goes: the scope byte must be a known
/// scope, the journal id must be zero exactly when the scope is not
/// journal, every key must exist and belong to the entry's scope, and every
/// value must parse against its key's type.
pub fn decodePayload(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) DecodeError!SettingsPayload {
    if (bytes.len < 1 + 16 + 2) return error.InvalidLength;
    const scope_int = bytes[0];
    const max_scope = @intFromEnum(schema.Scope.federation);
    const scope: schema.Scope =
        if (scope_int > max_scope) return error.InvalidScope else @enumFromInt(scope_int);
    const journal_id: [16]u8 = bytes[1..17].*;
    const id_is_zero = std.mem.allEqual(u8, &journal_id, 0);
    if (scope == .journal and id_is_zero) return error.InvalidScope;
    if (scope != .journal and !id_is_zero) return error.InvalidScope;

    const changes = try decodeChanges(allocator, bytes[17..], scope);
    return .{ .scope = scope, .journal_id = journal_id, .changes = changes };
}

/// Applies a settings entry to `state` (PRD 0004 validation order):
/// live-changeability of every key in the state before the entry, then the
/// whole-state rules on the resulting state, then commit. A refusal leaves
/// `state` untouched and names the failing check.
pub fn applySettings(
    state: *schema.SettingsState,
    payload: SettingsPayload,
    member_count: u32,
) !void {
    for (payload.changes) |change| {
        if (!validate.isLiveChangeable(change.key, state)) return error.NotLiveChangeable;
    }
    var candidate = try state.clone();
    defer candidate.deinit();
    for (payload.changes) |change| {
        try candidate.set(change.key, change.value);
    }
    try validate.validateState(&candidate, member_count);
    // Commit by swapping the validated candidate in. Re-applying the changes
    // to `state` would clone again, and a failure part-way through would
    // leave the entry half-applied *and* refused — a replicated fold that
    // silently diverges from every member that did not fail there.
    std.mem.swap(schema.SettingsState, state, &candidate);
}

/// Applies genesis initial settings. Genesis is the offline bootstrap, so
/// the live-changeability gate does not apply — a founder may start frozen
/// (`reconfigurable = false`, a configured authority list) — but the
/// whole-state rules still hold, against the founder's cluster (n = 1).
pub fn applyGenesis(
    state: *schema.SettingsState,
    changes: []const validate.Change,
) !void {
    var candidate = try state.clone();
    defer candidate.deinit();
    for (changes) |change| {
        try candidate.set(change.key, change.value);
    }
    try validate.validateState(&candidate, 1);
    // Atomic commit, as in `applySettings`.
    std.mem.swap(schema.SettingsState, state, &candidate);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const test_alloc = std.testing.allocator;

test "settings payload round-trips" {
    const mode = schema.keyIndex("leadership.mode").?;
    const max_journals = schema.keyIndex("cluster.max_journals").?;
    const authorities = schema.keyIndex("leadership.authorities").?;

    // The Value contract: a string_list owns its slices, so build one that
    // does (deinit below frees exactly what we allocated).
    const names = try test_alloc.alloc([]const u8, 2);
    errdefer test_alloc.free(names);
    names[0] = try test_alloc.dupe(u8, "a1b2");
    names[1] = try test_alloc.dupe(u8, "node.example");

    const built = [_]validate.Change{
        .{ .key = mode, .value = .{ .enum_value = schema.enumValue(mode, "combined").? } },
        .{ .key = max_journals, .value = .{ .u32 = 64 } },
        .{ .key = authorities, .value = .{ .string_list = names } },
    };
    const payload = SettingsPayload{
        .scope = .cluster,
        .journal_id = [_]u8{0} ** 16,
        .changes = &built,
    };

    const buf = try test_alloc.alloc(u8, payloadLen(payload));
    defer test_alloc.free(buf);
    encodePayload(payload, buf);
    defer {
        test_alloc.free(names[0]);
        test_alloc.free(names[1]);
        test_alloc.free(names);
    }

    var decoded = try decodePayload(test_alloc, buf);
    defer decoded.deinit(test_alloc);
    try std.testing.expectEqual(schema.Scope.cluster, decoded.scope);
    try std.testing.expectEqual(payload.changes.len, decoded.changes.len);
    for (payload.changes, decoded.changes) |want, got| {
        try std.testing.expectEqual(want.key, got.key);
        try std.testing.expect(want.value.eql(got.value));
    }
}

test "payload decode refuses bad scopes, unknown keys, and scope mismatches" {
    const mode = schema.keyIndex("leadership.mode").?;
    const ttl = schema.keyIndex("ttl.enforce").?;
    var buf = [_]u8{0} ** 64;

    // Unknown scope byte.
    buf[0] = 9;
    try std.testing.expectError(error.InvalidScope, decodePayload(test_alloc, &buf));

    // Journal scope with a zero id.
    buf[0] = @intFromEnum(schema.Scope.journal);
    try std.testing.expectError(error.InvalidScope, decodePayload(test_alloc, &buf));

    // Cluster scope with a non-zero id.
    buf[0] = @intFromEnum(schema.Scope.cluster);
    buf[1] = 1;
    try std.testing.expectError(error.InvalidScope, decodePayload(test_alloc, &buf));
    buf[1] = 0;

    // One change, key beyond the table.
    buf[0] = @intFromEnum(schema.Scope.cluster);
    std.mem.writeInt(u16, buf[17..19], 1, .little);
    std.mem.writeInt(u16, buf[19..21], 9999, .little);
    try std.testing.expectError(error.UnknownKey, decodePayload(test_alloc, &buf));

    // A journal-scoped key inside a cluster-scoped entry.
    std.mem.writeInt(u16, buf[19..21], ttl, .little);
    try std.testing.expectError(error.ScopeMismatch, decodePayload(test_alloc, &buf));

    // A valid cluster key parses.
    std.mem.writeInt(u16, buf[19..21], mode, .little);
    std.mem.writeInt(u16, buf[21..23], 2, .little);
    std.mem.writeInt(u16, buf[23..25], 1, .little); // enum value "configured"
    var decoded = try decodePayload(test_alloc, buf[0..25]);
    defer decoded.deinit(test_alloc);
    try std.testing.expectEqual(@as(usize, 1), decoded.changes.len);
}

test "applySettings clones-before-commit: a refusal leaves the state intact" {
    var state = try schema.SettingsState.initDefaults(test_alloc);
    defer state.deinit();
    const before = try state.hash(test_alloc);

    // ttl.enforce=all with default 0: cross-key refusal.
    const ttl_enforce = schema.keyIndex("ttl.enforce").?;
    const ttl_default = schema.keyIndex("ttl.default_ms").?;
    var changes = [_]validate.Change{
        .{
            .key = ttl_enforce,
            .value = .{ .enum_value = schema.enumValue(ttl_enforce, "all").? },
        },
    };
    var payload = SettingsPayload{
        .scope = .cluster,
        .journal_id = [_]u8{0} ** 16,
        .changes = &changes,
    };
    try std.testing.expectError(error.TtlEnforceAllNeedsDefault, applySettings(&state, payload, 1));
    try std.testing.expectEqualSlices(u8, &before, &(try state.hash(test_alloc)));

    // The same change is accepted once the default is non-zero.
    var good = [_]validate.Change{
        .{ .key = ttl_default, .value = .{ .u64 = 5000 } },
        .{ .key = ttl_enforce, .value = .{ .enum_value = schema.enumValue(ttl_enforce, "all").? } },
    };
    payload.changes = &good;
    try applySettings(&state, payload, 1);
    try std.testing.expectEqualStrings("all", state.getEnum(ttl_enforce));
    try std.testing.expectEqual(@as(u64, 5000), state.getU64(ttl_default));
}

test "applySettings refuses leadership changes while reconfigurable=false" {
    var state = try schema.SettingsState.initDefaults(test_alloc);
    defer state.deinit();
    const mode = schema.keyIndex("leadership.mode").?;
    const reconfigurable = schema.keyIndex("leadership.reconfigurable").?;
    try state.set(reconfigurable, .{ .boolean = false });

    var changes = [_]validate.Change{
        .{ .key = mode, .value = .{ .enum_value = schema.enumValue(mode, "configured").? } },
    };
    const payload = SettingsPayload{
        .scope = .cluster,
        .journal_id = [_]u8{0} ** 16,
        .changes = &changes,
    };
    try std.testing.expectError(error.NotLiveChangeable, applySettings(&state, payload, 1));
}

test "applyGenesis may start the cluster frozen" {
    var state = try schema.SettingsState.initDefaults(test_alloc);
    defer state.deinit();
    const reconfigurable = schema.keyIndex("leadership.reconfigurable").?;
    const changes = [_]validate.Change{
        .{ .key = reconfigurable, .value = .{ .boolean = false } },
    };
    try applyGenesis(&state, &changes);
    try std.testing.expect(!state.getBool(reconfigurable));
}
