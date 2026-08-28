//! Local configuration: `coppiz.toml` (PRD 0004 phase 4).
//!
//! Local config is limited to bootstrap — paths, identity, peers, fsync —
//! plus the founder's `[genesis]` initial settings. Everything that affects
//! what a member accepts, removes, or elects is a journal setting that lives
//! in the chain, and this module enforces the closed key set: an unknown key
//! is an error naming the key, and a key that *looks* like a journal setting
//! is an error naming the layer it belongs to — the failure mode where a
//! loader ignores unknown keys and a typo'd grant fails only at runtime is
//! one clanker documents having been bitten by.
//!
//! The parser is a hand-rolled TOML subset (ADR 0001 forbids fetching; OQ
//! 35): `key = value` lines, `[section]` and `[[array-of-tables]]` headers,
//! `#` comments, and the value shapes the schema needs — strings, integers,
//! booleans, and string arrays (for `leadership.authorities`).

const std = @import("std");
const schema = @import("../settings/schema.zig");
const validate = @import("../settings/validate.zig");

/// Provisional default for the unslotted-queue bound (OQ 55); the schema
/// marks the two other provisional defaults in docs/configuration.md.
pub const provisional_unslotted_max_bytes: u64 = 64 * 1024 * 1024;

/// The store's fsync policy; re-used so a parsed config feeds
/// `journal.Node`'s options directly.
pub const Fsync = @import("../journal/store.zig").Fsync;

pub const Peer = struct {
    address: []const u8, // owned
    public_key: ?[]const u8, // owned when present
};

pub const Config = struct {
    allocator: std.mem.Allocator,
    data_dir: ?[]const u8 = null,
    member_key_file: ?[]const u8 = null,
    listen: ?[]const u8 = null,
    log_level: ?[]const u8 = null,
    fsync: Fsync = .every,
    unslotted_max_bytes: u64 = provisional_unslotted_max_bytes,
    peers: std.ArrayListUnmanaged(Peer) = .empty,
    /// The founder's initial cluster settings ([genesis]); journal settings
    /// here are refused, not silently moved.
    genesis: std.ArrayListUnmanaged(validate.Change) = .empty,

    pub fn deinit(self: *Config) void {
        for (self.peers.items) |peer| {
            self.allocator.free(peer.address);
            if (peer.public_key) |key| self.allocator.free(key);
        }
        self.peers.deinit(self.allocator);
        for (self.genesis.items) |change| change.deinit(self.allocator);
        self.genesis.deinit(self.allocator);
        if (self.data_dir) |v| self.allocator.free(v);
        if (self.member_key_file) |v| self.allocator.free(v);
        if (self.listen) |v| self.allocator.free(v);
        if (self.log_level) |v| self.allocator.free(v);
        self.* = undefined;
    }
};

pub const ParseError = error{
    UnknownKey,
    JournalKeyInLocalConfig,
    InvalidValue,
    InvalidType,
    Syntax,
    OutOfMemory,
    FileNotFound,
    InputOutput,
};

/// Loads and parses `coppiz.toml` from `path`.
pub fn loadFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    config_out: *Config,
) ParseError!void {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        else => return error.InputOutput,
    };
    defer file.close(io);
    const len = file.length(io) catch return error.InputOutput;
    const text = allocator.alloc(u8, @intCast(len)) catch return error.OutOfMemory;
    defer allocator.free(text);
    const n = file.readPositionalAll(io, text, 0) catch return error.InputOutput;
    if (n != text.len) return error.InputOutput;
    try parse(allocator, text, config_out);
}

const Section = enum { none, genesis, peers };

/// Parses `text` into `config` (which must be freshly initialized or
/// empty). Every unknown key is named by error; a journal-scoped key is
/// refused with `JournalKeyInLocalConfig`.
pub fn parse(allocator: std.mem.Allocator, text: []const u8, config: *Config) ParseError!void {
    var section: Section = .none;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = stripComment(raw);
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (trimmed[0] == '[') {
            section = try parseSection(allocator, trimmed, config);
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse
            return error.Syntax;
        const key = std.mem.trim(u8, trimmed[0..eq], " \t");
        const value = std.mem.trim(u8, trimmed[eq + 1 ..], " \t");
        try parseKeyValue(allocator, key, value, section, config);
    }
}

/// Cuts a line at the first `#` that is outside a basic string. In TOML a
/// `#` inside `"..."` is data, not a comment; the byte-wise cut corrupted
/// quoted values that contained one (bug
/// 2026-08-28-toml-parser-quote-unaware).
fn stripComment(line: []const u8) []const u8 {
    var in_quotes = false;
    for (line, 0..) |c, i| {
        if (c == '"') {
            in_quotes = !in_quotes;
        } else if (c == '#' and !in_quotes) {
            return line[0..i];
        }
    }
    return line;
}

fn parseSection(
    allocator: std.mem.Allocator,
    line: []const u8,
    config: *Config,
) ParseError!Section {
    // Array-of-tables headers are [[name]]; table headers are [name].
    if (std.mem.startsWith(u8, line, "[[")) {
        if (line.len < 5 or !std.mem.endsWith(u8, line, "]]")) return error.Syntax;
        const name = std.mem.trim(u8, line[2 .. line.len - 2], " \t");
        if (!std.mem.eql(u8, name, "peers")) return error.UnknownKey;
        try config.peers.append(allocator, .{ .address = "", .public_key = null });
        return .peers;
    }
    if (line.len < 3 or line[line.len - 1] != ']') return error.Syntax;
    const name = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
    if (std.mem.eql(u8, name, "genesis")) return .genesis;
    return error.UnknownKey;
}

fn parseKeyValue(
    allocator: std.mem.Allocator,
    key: []const u8,
    value: []const u8,
    section: Section,
    config: *Config,
) ParseError!void {
    // A journal-scoped schema key can never belong in local config.
    if (schema.keyIndexRuntime(key)) |idx| {
        if (schema.keys[idx].scope == .journal) {
            // Named as the layer error: it belongs in the chain.
            return error.JournalKeyInLocalConfig;
        }
    }
    switch (section) {
        .none => try parseTopLevel(allocator, key, value, config),
        .genesis => try parseGenesisKey(allocator, key, value, config),
        .peers => try parsePeerKey(allocator, key, value, config),
    }
}

fn parseTopLevel(
    allocator: std.mem.Allocator,
    key: []const u8,
    value: []const u8,
    config: *Config,
) ParseError!void {
    if (std.mem.eql(u8, key, "data_dir")) {
        config.data_dir = try allocator.dupe(u8, unquote(value));
        return;
    }
    if (std.mem.eql(u8, key, "member.key_file")) {
        config.member_key_file = try allocator.dupe(u8, unquote(value));
        return;
    }
    if (std.mem.eql(u8, key, "listen")) {
        config.listen = try allocator.dupe(u8, unquote(value));
        return;
    }
    if (std.mem.eql(u8, key, "log.level")) {
        config.log_level = try allocator.dupe(u8, unquote(value));
        return;
    }
    if (std.mem.eql(u8, key, "storage.fsync")) {
        const v = unquote(value);
        if (std.mem.eql(u8, v, "every")) {
            config.fsync = .every;
            return;
        }
        if (std.mem.eql(u8, v, "batched")) {
            config.fsync = .batched;
            return;
        }
        if (std.mem.eql(u8, v, "never")) {
            config.fsync = .never;
            return;
        }
        return error.InvalidValue;
    }
    if (std.mem.eql(u8, key, "sync.unslotted_max_bytes")) {
        config.unslotted_max_bytes = std.fmt.parseInt(u64, value, 10) catch
            return error.InvalidValue;
        return;
    }
    return error.UnknownKey;
}

fn parseGenesisKey(
    allocator: std.mem.Allocator,
    key: []const u8,
    value: []const u8,
    config: *Config,
) ParseError!void {
    const idx = schema.keyIndexRuntime(key) orelse return error.UnknownKey;
    if (schema.keys[idx].scope != .cluster) return error.JournalKeyInLocalConfig;
    const parsed = try parseValue(allocator, idx, value);
    try config.genesis.append(allocator, .{ .key = idx, .value = parsed });
}

fn parsePeerKey(
    allocator: std.mem.Allocator,
    key: []const u8,
    value: []const u8,
    config: *Config,
) ParseError!void {
    const peer = &config.peers.items[config.peers.items.len - 1];
    if (std.mem.eql(u8, key, "address")) {
        allocator.free(peer.address);
        peer.address = try allocator.dupe(u8, unquote(value));
        return;
    }
    if (std.mem.eql(u8, key, "public_key")) {
        if (peer.public_key) |old| allocator.free(old);
        const hex = unquote(value);
        // A public_key names the peer's identity for the join allowlist; a
        // key that is not exactly 64 hex chars could never verify. Refuse
        // it here — the config layer is deliberately strict — instead of
        // silently dropping it from the allowlist at serve time, where the
        // operator sees only a refused join (bug
        // 2026-08-28-cmdserve-silent-allowlist-drop).
        if (hex.len != 64) return error.InvalidValue;
        for (hex) |c| {
            if (!std.ascii.isHex(c)) return error.InvalidValue;
        }
        peer.public_key = try allocator.dupe(u8, hex);
        return;
    }
    return error.UnknownKey;
}

/// Parses a value against the key's declared type. Public for the CLI's
/// `settings set` (the same grammar as `coppiz.toml`).
pub fn parseValue(
    allocator: std.mem.Allocator,
    key_index: u16,
    value: []const u8,
) ParseError!schema.Value {
    const key = schema.keys[key_index];
    return switch (key.value_type) {
        .boolean => blk: {
            if (std.mem.eql(u8, value, "true")) break :blk .{ .boolean = true };
            if (std.mem.eql(u8, value, "false")) break :blk .{ .boolean = false };
            return error.InvalidValue;
        },
        .u64 => .{ .u64 = std.fmt.parseInt(u64, value, 10) catch return error.InvalidValue },
        .u32 => .{ .u32 = std.fmt.parseInt(u32, value, 10) catch return error.InvalidValue },
        .u16 => .{ .u16 = std.fmt.parseInt(u16, value, 10) catch return error.InvalidValue },
        .string_enum => blk: {
            const name = unquote(value);
            const idx = schema.enumValue(key_index, name) orelse return error.InvalidValue;
            break :blk .{ .enum_value = idx };
        },
        .string_list => blk: {
            const items = try parseStringArray(allocator, value);
            break :blk .{ .string_list = items };
        },
    };
}

/// Parses a `["a", "b"]` string array into owned slices. Commas inside a
/// quoted item are data, not separators; the byte-wise split corrupted them
/// (bug 2026-08-28-toml-parser-quote-unaware).
fn parseStringArray(allocator: std.mem.Allocator, value: []const u8) ParseError![][]const u8 {
    const inner = std.mem.trim(u8, value, " \t");
    if (inner.len < 2 or inner[0] != '[' or inner[inner.len - 1] != ']') {
        return error.InvalidValue;
    }
    const body = inner[1 .. inner.len - 1];
    var out = std.ArrayListUnmanaged([]const u8).empty;
    errdefer {
        for (out.items) |item| allocator.free(item);
        out.deinit(allocator);
    }
    var start: usize = 0;
    var in_quotes = false;
    for (body, 0..) |c, i| {
        if (c == '"') {
            in_quotes = !in_quotes;
        } else if (c == ',' and !in_quotes) {
            const item = std.mem.trim(u8, body[start..i], " \t");
            if (item.len > 0) {
                try out.append(allocator, try allocator.dupe(u8, unquote(item)));
            }
            start = i + 1;
        }
    }
    const last = std.mem.trim(u8, body[start..], " \t");
    if (last.len > 0) {
        try out.append(allocator, try allocator.dupe(u8, unquote(last)));
    }
    return out.toOwnedSlice(allocator);
}

/// Strips surrounding quotes from a TOML basic string.
fn unquote(value: []const u8) []const u8 {
    const v = std.mem.trim(u8, value, " \t");
    if (v.len >= 2 and v[0] == '"' and v[v.len - 1] == '"') return v[1 .. v.len - 1];
    return v;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const test_alloc = std.testing.allocator;

test "a minimal config parses into its fields" {
    var config = Config{ .allocator = test_alloc };
    defer config.deinit();
    try parse(test_alloc,
        \\data_dir = "/var/lib/coppiz"
        \\member.key_file = "member.key"
        \\listen = "127.0.0.1:6400"
        \\log.level = "debug"
        \\storage.fsync = "batched"
        \\
        \\[[peers]]
        \\address = "10.0.0.2:6400"
        \\public_key = "abcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcd"
        \\
        \\[genesis]
        \\leadership.mode = "configured"
        \\cluster.max_journals = 64
        \\leadership.authorities = ["a1b2", "node.example"]
    , &config);
    try std.testing.expectEqualStrings("/var/lib/coppiz", config.data_dir.?);
    try std.testing.expectEqualStrings("member.key", config.member_key_file.?);
    try std.testing.expectEqualStrings("127.0.0.1:6400", config.listen.?);
    try std.testing.expectEqual(Fsync.batched, config.fsync);
    try std.testing.expectEqual(@as(usize, 1), config.peers.items.len);
    try std.testing.expectEqualStrings("10.0.0.2:6400", config.peers.items[0].address);
    try std.testing.expectEqual(@as(usize, 3), config.genesis.items.len);

    const mode = schema.keyIndex("leadership.mode").?;
    try std.testing.expectEqual(mode, config.genesis.items[0].key);
    const mode_name = schema.enumName(mode, config.genesis.items[0].value.enum_value).?;
    try std.testing.expectEqualStrings("configured", mode_name);
    const authorities = schema.keyIndex("leadership.authorities").?;
    try std.testing.expectEqual(authorities, config.genesis.items[2].key);
    try std.testing.expectEqualStrings("a1b2", config.genesis.items[2].value.string_list[0]);
    const list = config.genesis.items[2].value.string_list;
    try std.testing.expectEqualStrings("node.example", list[1]);
}

test "a journal setting in local config is a startup error naming the layer" {
    var config = Config{ .allocator = test_alloc };
    defer config.deinit();
    try std.testing.expectError(
        error.JournalKeyInLocalConfig,
        parse(test_alloc, "ttl.action = \"delete\"\n", &config),
    );
    try std.testing.expectError(
        error.JournalKeyInLocalConfig,
        parse(test_alloc, "[genesis]\nttl.default_ms = 1000\n", &config),
    );
}

test "unknown keys are refused, not ignored" {
    var config = Config{ .allocator = test_alloc };
    defer config.deinit();
    const unknown = "ttl.enforcee = \"all\"\n";
    try std.testing.expectError(error.UnknownKey, parse(test_alloc, unknown, &config));
    try std.testing.expectError(error.UnknownKey, parse(test_alloc, "[bogus]\n", &config));
    const unknown_genesis = "[genesis]\nno.such.key = 1\n";
    try std.testing.expectError(error.UnknownKey, parse(test_alloc, unknown_genesis, &config));
}

test "a # inside a quoted value is data, not a comment" {
    // Bug 2026-08-28-toml-parser-quote-unaware: stripComment cut at the
    // first `#` regardless of quotes, so `data_dir = "/var/lib/coppiz#prod"`
    // parsed as the broken value `"/var/lib/coppiz` (leading quote kept).
    var config = Config{ .allocator = test_alloc };
    defer config.deinit();
    try parse(test_alloc, "data_dir = \"/var/lib/coppiz#prod\"\n", &config);
    try std.testing.expectEqualStrings("/var/lib/coppiz#prod", config.data_dir.?);
}

test "a comma inside a quoted array item is data, not a separator" {
    // Bug 2026-08-28-toml-parser-quote-unaware: parseStringArray split on
    // every comma, so `["node-a,node-b"]` became the two bogus entries
    // `"node-a` and `node-b"`.
    var config = Config{ .allocator = test_alloc };
    defer config.deinit();
    try parse(test_alloc,
        \\[genesis]
        \\leadership.authorities = ["node-a,node-b"]
    , &config);
    const authorities = schema.keyIndex("leadership.authorities").?;
    var list: ?[]const []const u8 = null;
    for (config.genesis.items) |change| {
        if (change.key == authorities) list = change.value.string_list;
    }
    const got = list orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqualStrings("node-a,node-b", got[0]);
}

test "bad values are refused" {
    var config = Config{ .allocator = test_alloc };
    defer config.deinit();
    const bad_fsync = "storage.fsync = \"sometimes\"\n";
    try std.testing.expectError(error.InvalidValue, parse(test_alloc, bad_fsync, &config));
    const bad_mode = "[genesis]\nleadership.mode = \"dictator\"\n";
    try std.testing.expectError(error.InvalidValue, parse(test_alloc, bad_mode, &config));
    const bad_int = "[genesis]\ncluster.max_journals = \"many\"\n";
    try std.testing.expectError(error.InvalidValue, parse(test_alloc, bad_int, &config));
    const bad_list = "[genesis]\nleadership.authorities = \"not-an-array\"\n";
    try std.testing.expectError(error.InvalidValue, parse(test_alloc, bad_list, &config));
}

test "a malformed peer public_key is refused at parse time" {
    // Bug 2026-08-28-cmdserve-silent-allowlist-drop: a public_key that was
    // not exactly 64 hex chars passed config parsing and was silently
    // dropped from the join allowlist at serve time — a refused join with
    // no diagnostic. The config layer refuses it here instead.
    var config = Config{ .allocator = test_alloc };
    defer config.deinit();
    const short = "[[peers]]\naddress = \"10.0.0.2:6400\"\npublic_key = \"abcd\"\n";
    try std.testing.expectError(error.InvalidValue, parse(test_alloc, short, &config));

    var config2 = Config{ .allocator = test_alloc };
    defer config2.deinit();
    const wrong_len = "[[peers]]\naddress = \"10.0.0.2:6400\"\npublic_key = \"" ++
        "abcd" ** 16 ++ "a" ++ "\"\n";
    try std.testing.expectError(error.InvalidValue, parse(test_alloc, wrong_len, &config2));

    var config3 = Config{ .allocator = test_alloc };
    defer config3.deinit();
    const non_hex = "[[peers]]\naddress = \"10.0.0.2:6400\"\npublic_key = \"" ++
        "gg" ** 32 ++ "\"\n";
    try std.testing.expectError(error.InvalidValue, parse(test_alloc, non_hex, &config3));
}

test "genesis initial settings fold back to the parsed state (PRD 0004 G6 half)" {
    var config = Config{ .allocator = test_alloc };
    defer config.deinit();
    try parse(test_alloc,
        \\[genesis]
        \\leadership.reconfigurable = false
        \\cluster.max_journals = 16
    , &config);
    var state = try schema.SettingsState.initDefaults(test_alloc);
    defer state.deinit();
    try @import("../settings/fold.zig").applyGenesis(&state, config.genesis.items);
    try std.testing.expect(!state.getBool(schema.keyIndex("leadership.reconfigurable").?));
    const max_journals = schema.keyIndex("cluster.max_journals").?;
    try std.testing.expectEqual(@as(u32, 16), state.getU32(max_journals));
}
