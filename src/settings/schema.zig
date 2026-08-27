//! The settings schema: one comptime table of every journal/cluster key
//! (PRD 0004 "Schema as code").
//!
//! A setting is either **cluster-scoped** (one value for the cluster:
//! `leadership.*`, `cluster.*`, `membership.*`, `merge.*`), **journal-scoped**
//! (one value per journal: `ttl.*`, `stale.*`, `checkpoint.*`, `journal.*`),
//! or **federation-scoped** — reserved now, populated by PRD 0006, with no
//! keys yet so that federating later is a new set of keys, not a schema
//! break. The table is the single source the generated
//! `docs/configuration.md` and `coppiz settings schema` render, and the
//! value codec below is the settings-entry payload format.
//!
//! Values are canonical: booleans one byte, integers little-endian, an enum
//! is a u16 index into the key's `allowed` list (so a bad value is an
//! out-of-range index), and a string list is length-prefixed. Enums as
//! indices keep the payload compact and make "value parses to its type" a
//! bounds check.

const std = @import("std");

pub const ValueType = enum(u8) {
    boolean,
    u64,
    u32,
    u16,
    string_enum,
    string_list,
};

pub const Scope = enum(u8) {
    cluster,
    journal,
    federation,
};

/// When a `settings` entry may touch the key. `requires_reconfigurable` and
/// `reconfigurable_turnoff_only` implement the PRD 0003 gate:
/// `leadership.*` changes live only while `leadership.reconfigurable` is
/// true, and that key itself can only be flipped from true to false live
/// (false -> true is the offline procedure, so genesis may set it freely).
pub const LiveRule = enum {
    always,
    requires_reconfigurable,
    reconfigurable_turnoff_only,
};

pub const Key = struct {
    name: []const u8,
    scope: Scope,
    value_type: ValueType,
    /// Legal values for `string_enum` keys, in enum order.
    allowed: []const []const u8 = &.{},
    default_enum: []const u8 = "",
    default_bool: bool = false,
    default_int: u64 = 0,
    default_list: []const []const u8 = &.{},
    live_rule: LiveRule,
    description: []const u8,
};

/// Defaults for `cluster.max_journals` (OQ 55) and `journal.max_entry_bytes`
/// (OQ 36) have no operator answer yet; these provisional values are the
/// ones the schema ships with and are called out as provisional in
/// `docs/configuration.md`.
pub const provisional_max_journals: u32 = 1024;
pub const provisional_max_entry_bytes: u64 = 16 * 1024 * 1024;

/// The whole schema. Order is stable — key index is part of the settings
/// payload format — so new keys append, never reorder.
pub const keys = [_]Key{
    // --- cluster scope ---
    .{
        .name = "leadership.mode",
        .scope = .cluster,
        .value_type = .string_enum,
        .allowed = &.{ "seniority", "configured", "combined" },
        .default_enum = "seniority",
        .live_rule = .requires_reconfigurable,
        .description = "which member leads: earliest join, an authority list, or tiebreak-filtered",
    },
    .{
        .name = "leadership.authorities",
        .scope = .cluster,
        .value_type = .string_list,
        .default_list = &.{},
        .live_rule = .requires_reconfigurable,
        .description = "ordered leader candidates under configured/combined: ids or addresses",
    },
    .{
        .name = "leadership.tiebreak",
        .scope = .cluster,
        .value_type = .string_enum,
        .allowed = &.{ "seniority", "freshest" },
        .default_enum = "seniority",
        .live_rule = .requires_reconfigurable,
        .description = "how combined orders eligible authorities",
    },
    .{
        .name = "leadership.fallback",
        .scope = .cluster,
        .value_type = .string_enum,
        .allowed = &.{ "stall", "seniority" },
        .default_enum = "stall",
        .live_rule = .requires_reconfigurable,
        .description = "what configured/combined do with no live authority: stall or degrade",
    },
    .{
        .name = "leadership.reconfigurable",
        .scope = .cluster,
        .value_type = .boolean,
        .default_bool = true,
        .live_rule = .reconfigurable_turnoff_only,
        .description = "whether leadership.* may change live; false freezes it until offline",
    },
    .{
        .name = "cluster.admission",
        .scope = .cluster,
        .value_type = .string_enum,
        .allowed = &.{ "allowlist", "prompt", "open" },
        .default_enum = "allowlist",
        .live_rule = .always,
        .description = "how a dialing node is admitted: allowlist key, prompt, or open",
    },
    .{
        .name = "cluster.max_members",
        .scope = .cluster,
        .value_type = .u16,
        .default_int = 32,
        .live_rule = .always,
        .description = "full-mesh membership cap per group; past it, grow by more groups",
    },
    .{
        .name = "cluster.max_journals",
        .scope = .cluster,
        .value_type = .u32,
        .default_int = provisional_max_journals,
        .live_rule = .always,
        .description = "journal cap for a cluster; past it, creation refuses (provisional, OQ 55)",
    },
    .{
        .name = "cluster.heartbeat_ms",
        .scope = .cluster,
        .value_type = .u64,
        .default_int = 1000,
        .live_rule = .always,
        .description = "failure-detector heartbeat cadence between members (placeholder, OQ 37)",
    },
    .{
        .name = "cluster.suspect_after_ms",
        .scope = .cluster,
        .value_type = .u64,
        .default_int = 5000,
        .live_rule = .always,
        .description = "a member missed for this long is unreachable (placeholder, OQ 37)",
    },
    .{
        .name = "membership.evict_after_ms",
        .scope = .cluster,
        .value_type = .u64,
        .default_int = 0,
        .live_rule = .always,
        .description = "convert an unreachable member to a leave after this long; 0 = never",
    },
    .{
        .name = "merge.settle_ms",
        .scope = .cluster,
        .value_type = .u64,
        .default_int = 30000,
        .live_rule = .always,
        .description = "no checkpoint for slots newer than a merge until this passes (OQ 60)",
    },
    // --- journal scope ---
    .{
        .name = "journal.max_entry_bytes",
        .scope = .journal,
        .value_type = .u64,
        .default_int = provisional_max_entry_bytes,
        .live_rule = .always,
        .description = "largest payload an append may carry; refused too_large (OQ 36 provisional)",
    },
    .{
        .name = "ttl.enforce",
        .scope = .journal,
        .value_type = .string_enum,
        .allowed = &.{ "off", "per_entry", "all" },
        .default_enum = "off",
        .live_rule = .always,
        .description = "which entries expire: none, only TTL-carrying ones, or every entry",
    },
    .{
        .name = "ttl.default_ms",
        .scope = .journal,
        .value_type = .u64,
        .default_int = 0,
        .live_rule = .always,
        .description = "TTL for entries without one under enforce=all; 0 there is an error",
    },
    .{
        .name = "ttl.max_ms",
        .scope = .journal,
        .value_type = .u64,
        .default_int = 0,
        .live_rule = .always,
        .description = "cap on a requested TTL; a larger ask is clamped to it; 0 = unbounded",
    },
    .{
        .name = "ttl.action",
        .scope = .journal,
        .value_type = .string_enum,
        .allowed = &.{ "mark_stale", "delete" },
        .default_enum = "mark_stale",
        .live_rule = .always,
        .description = "what expiry does at the instant: mark stale, or mark expired",
    },
    .{
        .name = "ttl.retain",
        .scope = .journal,
        .value_type = .string_enum,
        .allowed = &.{ "header", "none" },
        .default_enum = "header",
        .live_rule = .always,
        .description = "what a removal keeps: the entry header or only the slot",
    },
    .{
        .name = "ttl.grace_ms",
        .scope = .journal,
        .value_type = .u64,
        .default_int = 0,
        .live_rule = .always,
        .description = "read-side skew tolerance; hides once now passes expiry + grace",
    },
    .{
        .name = "stale.enforce",
        .scope = .journal,
        .value_type = .string_enum,
        .allowed = &.{ "off", "author" },
        .default_enum = "off",
        .live_rule = .always,
        .description = "whether author-marked staleness is on; a stale entry is refused while off",
    },
    .{
        .name = "stale.who",
        .scope = .journal,
        .value_type = .string_enum,
        .allowed = &.{"author"},
        .default_enum = "author",
        .live_rule = .always,
        .description = "who may mark when enabled; author is the only value in v1",
    },
    .{
        .name = "stale.cleanup",
        .scope = .journal,
        .value_type = .string_enum,
        .allowed = &.{ "delete", "keep" },
        .default_enum = "keep",
        .live_rule = .always,
        .description = "whether checkpoints remove stale entries; removal needs delete explicitly",
    },
    .{
        .name = "checkpoint.every_ms",
        .scope = .journal,
        .value_type = .u64,
        .default_int = 60000,
        .live_rule = .always,
        .description = "leader checkpoint cadence (placeholder, OQ 10)",
    },
    .{
        .name = "checkpoint.pending_bytes",
        .scope = .journal,
        .value_type = .u64,
        .default_int = 64 * 1024 * 1024,
        .live_rule = .always,
        .description = "early trigger once this much removable payload accumulated (OQ 10)",
    },
};

pub const key_count = keys.len;

/// A setting value as stored in the folded state and in the settings-entry
/// payload. `string_list` owns its slices (allocator-backed); everything
/// else is owned-free. An enum is stored as the index into its key's
/// `allowed` list.
pub const Value = union(enum) {
    boolean: bool,
    u64: u64,
    u32: u32,
    u16: u16,
    enum_value: u16,
    string_list: []const []const u8,

    pub fn eql(a: Value, b: Value) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .boolean => |v| v == b.boolean,
            .u64 => |v| v == b.u64,
            .u32 => |v| v == b.u32,
            .u16 => |v| v == b.u16,
            .enum_value => |v| v == b.enum_value,
            .string_list => |v| blk: {
                if (v.len != b.string_list.len) break :blk false;
                for (v, b.string_list) |x, y| {
                    if (!std.mem.eql(u8, x, y)) break :blk false;
                }
                break :blk true;
            },
        };
    }

    pub fn deinit(self: Value, allocator: std.mem.Allocator) void {
        switch (self) {
            .string_list => |items| {
                for (items) |item| allocator.free(item);
                allocator.free(items);
            },
            else => {},
        }
    }

    pub fn clone(self: Value, allocator: std.mem.Allocator) !Value {
        return switch (self) {
            .boolean => |v| .{ .boolean = v },
            .u64 => |v| .{ .u64 = v },
            .u32 => |v| .{ .u32 = v },
            .u16 => |v| .{ .u16 = v },
            .enum_value => |v| .{ .enum_value = v },
            .string_list => |items| blk: {
                const out = try allocator.alloc([]const u8, items.len);
                for (items, 0..) |item, i| {
                    out[i] = try allocator.dupe(u8, item);
                }
                break :blk .{ .string_list = out };
            },
        };
    }
};

pub fn keyIndex(name: []const u8) ?u16 {
    for (keys, 0..) |key, i| {
        if (std.mem.eql(u8, key.name, name)) return @intCast(i);
    }
    return null;
}

pub fn keyName(index: u16) []const u8 {
    return keys[index].name;
}

/// The runtime default value for a key, owned per the Value contract. The
/// schema's only non-empty default containers are the enum strings, which
/// resolve to indices; a non-empty string_list default is asserted away by
/// a test so Value ownership never mixes borrowed and owned storage.
pub fn defaultValue(allocator: std.mem.Allocator, index: u16) !Value {
    const key = keys[index];
    return switch (key.value_type) {
        .boolean => .{ .boolean = key.default_bool },
        .u64 => .{ .u64 = key.default_int },
        .u32 => .{ .u32 = @intCast(key.default_int) },
        .u16 => .{ .u16 = @intCast(key.default_int) },
        .string_enum => blk: {
            const idx = enumValue(index, key.default_enum) orelse return error.BadSchemaDefault;
            break :blk .{ .enum_value = idx };
        },
        .string_list => .{ .string_list = try allocator.alloc([]const u8, key.default_list.len) },
    };
}

/// The string for an enum value index, if in range.
pub fn enumName(key_index: u16, value: u16) ?[]const u8 {
    const allowed = keys[key_index].allowed;
    if (value >= allowed.len) return null;
    return allowed[value];
}

/// The index for an enum string, if allowed.
pub fn enumValue(key_index: u16, name: []const u8) ?u16 {
    for (keys[key_index].allowed, 0..) |allowed, i| {
        if (std.mem.eql(u8, allowed, name)) return @intCast(i);
    }
    return null;
}

/// Encoded size of a value in the settings payload.
pub fn valueLen(value: Value) usize {
    return switch (value) {
        .boolean => 1,
        .u64 => 8,
        .u32 => 4,
        .u16 => 2,
        .enum_value => 2,
        .string_list => |items| blk: {
            var n: usize = 2;
            for (items) |item| n += 2 + item.len;
            break :blk n;
        },
    };
}

/// Encodes a value canonically into `buf` (which must hold `valueLen`).
pub fn encodeValue(value: Value, buf: []u8) void {
    switch (value) {
        .boolean => |v| buf[0] = @intFromBool(v),
        .u64 => |v| std.mem.writeInt(u64, buf[0..8], v, .little),
        .u32 => |v| std.mem.writeInt(u32, buf[0..4], v, .little),
        .u16 => |v| std.mem.writeInt(u16, buf[0..2], v, .little),
        .enum_value => |v| std.mem.writeInt(u16, buf[0..2], v, .little),
        .string_list => |items| {
            var len_buf: [2]u8 = undefined;
            std.mem.writeInt(u16, &len_buf, @intCast(items.len), .little);
            @memcpy(buf[0..2], &len_buf);
            var off: usize = 2;
            for (items) |item| {
                std.mem.writeInt(u16, &len_buf, @intCast(item.len), .little);
                @memcpy(buf[off .. off + 2], &len_buf);
                off += 2;
                @memcpy(buf[off .. off + item.len], item);
                off += item.len;
            }
        },
    }
}

/// Decodes a value for `key_index`. Owns the string_list's slices. Refuses
/// an out-of-range enum index with `invalid_value`.
pub fn decodeValue(
    allocator: std.mem.Allocator,
    key_index: u16,
    bytes: []const u8,
) error{ InvalidValue, InvalidLength, OutOfMemory }!Value {
    const key = keys[key_index];
    return switch (key.value_type) {
        .boolean => blk: {
            if (bytes.len != 1) return error.InvalidLength;
            if (bytes[0] > 1) return error.InvalidValue;
            break :blk .{ .boolean = bytes[0] == 1 };
        },
        .u64 => blk: {
            if (bytes.len != 8) return error.InvalidLength;
            break :blk .{ .u64 = std.mem.readInt(u64, bytes[0..8], .little) };
        },
        .u32 => blk: {
            if (bytes.len != 4) return error.InvalidLength;
            break :blk .{ .u32 = std.mem.readInt(u32, bytes[0..4], .little) };
        },
        .u16 => blk: {
            if (bytes.len != 2) return error.InvalidLength;
            break :blk .{ .u16 = std.mem.readInt(u16, bytes[0..2], .little) };
        },
        .string_enum => blk: {
            if (bytes.len != 2) return error.InvalidLength;
            const idx = std.mem.readInt(u16, bytes[0..2], .little);
            if (idx >= key.allowed.len) return error.InvalidValue;
            break :blk .{ .enum_value = idx };
        },
        .string_list => blk: {
            if (bytes.len < 2) return error.InvalidLength;
            const count = std.mem.readInt(u16, bytes[0..2], .little);
            const items = try allocator.alloc([]const u8, count);
            errdefer allocator.free(items);
            var off: usize = 2;
            for (0..count) |i| {
                if (off + 2 > bytes.len) return error.InvalidLength;
                var len_buf: [2]u8 = undefined;
                @memcpy(&len_buf, bytes[off .. off + 2]);
                const len = std.mem.readInt(u16, &len_buf, .little);
                off += 2;
                if (off + len > bytes.len) return error.InvalidLength;
                items[i] = try allocator.dupe(u8, bytes[off .. off + len]);
                off += len;
            }
            if (off != bytes.len) return error.InvalidLength;
            break :blk .{ .string_list = items };
        },
    };
}

/// The folded settings state for one scope (PRD 0004): one value per key in
/// table order — the defaults plus everything the chain applied. Owns its
/// values (a `string_list`'s slices are allocator-backed); the `get*`
/// accessors borrow. One instance per scope per journal lives in the fold.
pub const SettingsState = struct {
    allocator: std.mem.Allocator,
    values: []Value,

    pub fn initDefaults(allocator: std.mem.Allocator) !SettingsState {
        const values = try allocator.alloc(Value, key_count);
        errdefer allocator.free(values);
        for (0..key_count) |i| {
            values[i] = try defaultValue(allocator, @intCast(i));
        }
        return .{ .allocator = allocator, .values = values };
    }

    pub fn deinit(self: *SettingsState) void {
        for (self.values) |value| value.deinit(self.allocator);
        self.allocator.free(self.values);
        self.* = undefined;
    }

    pub fn clone(self: *const SettingsState) !SettingsState {
        const values = try self.allocator.alloc(Value, key_count);
        errdefer self.allocator.free(values);
        for (0..key_count) |i| {
            values[i] = try self.values[i].clone(self.allocator);
        }
        return .{ .allocator = self.allocator, .values = values };
    }

    pub fn get(self: *const SettingsState, key_index: u16) Value {
        return self.values[key_index];
    }

    pub fn getBool(self: *const SettingsState, key_index: u16) bool {
        return self.values[key_index].boolean;
    }

    pub fn getU64(self: *const SettingsState, key_index: u16) u64 {
        return self.values[key_index].u64;
    }

    pub fn getU32(self: *const SettingsState, key_index: u16) u32 {
        return self.values[key_index].u32;
    }

    pub fn getU16(self: *const SettingsState, key_index: u16) u16 {
        return self.values[key_index].u16;
    }

    /// The resolved string of an enum-typed key; the stored index is always
    /// in range (decode and defaults guarantee it).
    pub fn getEnum(self: *const SettingsState, key_index: u16) []const u8 {
        return enumName(key_index, self.values[key_index].enum_value) orelse unreachable;
    }

    pub fn getList(self: *const SettingsState, key_index: u16) []const []const u8 {
        return self.values[key_index].string_list;
    }

    /// Replaces one key's value with a clone of `value`, freeing the old
    /// one. A failed clone leaves the state untouched.
    pub fn set(self: *SettingsState, key_index: u16, value: Value) !void {
        const fresh = try value.clone(self.allocator);
        self.values[key_index].deinit(self.allocator);
        self.values[key_index] = fresh;
    }

    /// The canonical encoding of the whole state, in table order: key index,
    /// encoded value, concatenated. Two states are equal iff their canonical
    /// encodings are equal, which is what the fold determinism hash checks.
    pub fn encodeCanonical(self: *const SettingsState, allocator: std.mem.Allocator) ![]u8 {
        var out = std.ArrayListUnmanaged(u8).empty;
        errdefer out.deinit(allocator);
        for (self.values, 0..) |value, i| {
            var key_buf: [2]u8 = undefined;
            std.mem.writeInt(u16, &key_buf, @intCast(i), .little);
            try out.appendSlice(allocator, &key_buf);
            const len = valueLen(value);
            const scratch = try allocator.alloc(u8, len);
            defer allocator.free(scratch);
            encodeValue(value, scratch);
            try out.appendSlice(allocator, scratch);
        }
        return out.toOwnedSlice(allocator);
    }

    pub fn hash(self: *const SettingsState, allocator: std.mem.Allocator) ![32]u8 {
        const canon = try self.encodeCanonical(allocator);
        defer allocator.free(canon);
        var out: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(canon, &out, .{});
        return out;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "every key has a unique name, a scope, a live rule and a description" {
    var seen = std.StringHashMap(void).init(std.testing.allocator);
    defer seen.deinit();
    for (keys) |key| {
        try std.testing.expect(seen.get(key.name) == null);
        try seen.put(key.name, {});
        try std.testing.expect(key.description.len > 0);
        _ = key.scope;
        _ = key.live_rule;
    }
}

test "keys are unique — the index, part of the settings payload format, is stable" {
    // The order itself is a format fact (see the module doc): new keys
    // append, never reorder. What the test pins is that the table holds no
    // duplicate names, so a lookup by name resolves exactly one key.
    var seen = std.StringHashMap(void).init(std.testing.allocator);
    defer seen.deinit();
    for (keys) |key| {
        try std.testing.expect(seen.get(key.name) == null);
        try seen.put(key.name, {});
    }
    try std.testing.expectEqual(keys.len, seen.count());
}

test "enum defaults name a legal value and every allowed list is non-empty" {
    for (keys, 0..) |key, i| {
        if (key.value_type != .string_enum) continue;
        try std.testing.expect(key.allowed.len > 0);
        try std.testing.expect(enumValue(@intCast(i), key.default_enum) != null);
    }
}

test "the only string_list default is empty (ownership contract)" {
    for (keys) |key| {
        if (key.value_type != .string_list) continue;
        try std.testing.expectEqual(@as(usize, 0), key.default_list.len);
    }
}

test "defaults decode back to their declared type" {
    for (keys, 0..) |key, i| {
        const v = try defaultValue(std.testing.allocator, @intCast(i));
        defer v.deinit(std.testing.allocator);
        const want_type: ValueType = key.value_type;
        const got_type: ValueType = switch (v) {
            .boolean => .boolean,
            .u64 => .u64,
            .u32 => .u32,
            .u16 => .u16,
            .enum_value => .string_enum,
            .string_list => .string_list,
        };
        try std.testing.expectEqual(want_type, got_type);
    }
}

test "value codec round-trips every value shape" {
    const allocator = std.testing.allocator;
    const values = [_]Value{
        .{ .boolean = true },
        .{ .u64 = 0x1122_3344_5566_7788 },
        .{ .u32 = 0xDEAD_BEEF },
        .{ .u16 = 65535 },
        .{ .enum_value = 1 },
        .{ .string_list = &.{ "alpha", "", "longer string" } },
    };
    for (values) |value| {
        // Decode with a key of the value's own type: the codec validates
        // against the key's declared type, so a mismatched key is a refusal.
        const key_index: u16 = blk: {
            const want: ValueType = switch (value) {
                .boolean => .boolean,
                .u64 => .u64,
                .u32 => .u32,
                .u16 => .u16,
                .enum_value => .string_enum,
                .string_list => .string_list,
            };
            for (keys, 0..) |key, i| {
                if (key.value_type == want) break :blk @intCast(i);
            }
            unreachable;
        };
        const encoded = try allocator.alloc(u8, valueLen(value));
        defer allocator.free(encoded);
        encodeValue(value, encoded);
        const decoded = try decodeValue(allocator, key_index, encoded);
        defer decoded.deinit(allocator);
        try std.testing.expect(value.eql(decoded));
    }
}

test "decodeValue refuses bad enum indices and bad lengths" {
    const allocator = std.testing.allocator;
    const leadership_mode: u16 = keyIndex("leadership.mode").?;
    // 2 is out of range for leadership.mode (allowed len is 3, so use 3).
    var buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &buf, 3, .little);
    try std.testing.expectError(error.InvalidValue, decodeValue(allocator, leadership_mode, &buf));
    const short = buf[0..1];
    const bad_len = error.InvalidLength;
    try std.testing.expectError(bad_len, decodeValue(allocator, leadership_mode, short));
    // A bool value of 2 is invalid.
    const bool_key: u16 = keyIndex("leadership.reconfigurable").?;
    try std.testing.expectError(error.InvalidValue, decodeValue(allocator, bool_key, &[_]u8{2}));
}

test "unknown keys are not in the table" {
    try std.testing.expect(keyIndex("ttl.enforcee") == null);
    try std.testing.expect(keyIndex("leader") == null);
    try std.testing.expect(keyIndex("cluster.max_journal") == null);
}

test "settings state: defaults, set, clone, hash" {
    const allocator = std.testing.allocator;
    var state = try SettingsState.initDefaults(allocator);
    defer state.deinit();

    const mode = keyIndex("leadership.mode").?;
    try std.testing.expectEqualStrings("seniority", state.getEnum(mode));
    try std.testing.expect(state.getBool(keyIndex("leadership.reconfigurable").?));

    const h1 = try state.hash(allocator);
    var copy = try state.clone();
    defer copy.deinit();
    try std.testing.expectEqualSlices(u8, &h1, &(try copy.hash(allocator)));

    const configured = enumValue(mode, "configured").?;
    try copy.set(mode, .{ .enum_value = configured });
    const h2 = try copy.hash(allocator);
    try std.testing.expect(!std.mem.eql(u8, &h1, &h2));
    try std.testing.expectEqualStrings("configured", copy.getEnum(mode));
    // The original state is untouched by the clone's set.
    try std.testing.expectEqualStrings("seniority", state.getEnum(mode));
}
