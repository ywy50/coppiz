//! Renders the settings schema to the operator reference (PRD 0004 phase 5):
//! `coppiz settings schema` prints it, and `zig build docs` writes it to
//! `docs/configuration.md`. The pinned test compares the rendered table to
//! the file, so the reference cannot drift from the schema (G5).

const std = @import("std");
const schema = @import("schema.zig");

/// Renders the whole reference document into `writer`.
pub fn render(writer: anytype) !void {
    try writer.writeAll(
        \\# Configuration
        \\
        \\The journal configures itself through its own chain: every setting
        \\that affects what a member accepts, removes, or elects is stored in
        \\`genesis` and `settings` entries and folded identically on every
        \\member (PRD 0004). This page is generated from the schema table in
        \\`src/settings/schema.zig` - `zig build docs` regenerates it, and
        \\the test suite fails when it is stale.
        \\
        \\Local configuration is limited to bootstrap: paths, identity, peers
        \\and fsync. A local-config key that *looks* like a journal setting
        \\is a startup error, not a silent ignore.
        \\
        \\## Scopes
        \\
        \\- **cluster** - one value for the cluster (leadership, membership,
        \\  admission).
        \\- **journal** - one value per journal (TTL, staleness, checkpoints,
        \\  entry size).
        \\- **federation** - reserved for PRD 0006; no keys yet, so federating
        \\  later is a new set of keys, not a schema break.
        \\
        \\## Keys
        \\
        \\Live-changeability: `always` = changeable by a `settings` entry;
        \\`requires_reconfigurable` = only while `leadership.reconfigurable`
        \\is true; `turnoff_only` = can only be flipped from true to false
        \\live. Defaults marked *(provisional)* are placeholders awaiting the
        \\operator's values (OQ 36, OQ 55).
        \\
    );
    try renderTable(writer);
}

/// The keys table, one row per key. Kept as its own function so tests can
/// pin just the table if the prose ever needs editing.
pub fn renderTable(writer: anytype) !void {
    try writer.writeAll(
        \\| Key | Scope | Type | Default | Live | Description |
        \\|---|---|---|---|---|---|
        \\
    );
    var buf: [64]u8 = undefined;
    for (schema.keys) |key| {
        const default_text = try defaultText(key, &buf);
        const live_text = switch (key.live_rule) {
            .always => "always",
            .requires_reconfigurable => "if reconfigurable",
            .reconfigurable_turnoff_only => "true → false only",
        };
        try writer.print(
            "| `{s}` | {s} | {s} | {s} | {s} | {s} |\n",
            .{
                key.name,
                scopeName(key.scope),
                typeName(key.value_type),
                default_text,
                live_text,
                key.description,
            },
        );
    }
}

fn scopeName(scope: schema.Scope) []const u8 {
    return switch (scope) {
        .cluster => "cluster",
        .journal => "journal",
        .federation => "federation (reserved)",
    };
}

fn typeName(t: schema.ValueType) []const u8 {
    return switch (t) {
        .boolean => "bool",
        .u64 => "u64",
        .u32 => "u32",
        .u16 => "u16",
        .string_enum => "enum",
        .string_list => "string list",
    };
}

/// The default as the operator reference shows it: enum strings resolved
/// from the index, the provisional markers for the two unset values.
fn defaultText(key: schema.Key, buf: *[64]u8) ![]const u8 {
    switch (key.value_type) {
        .boolean => return if (key.default_bool) "true" else "false",
        .u64, .u32, .u16 => {
            const provisional = std.mem.eql(u8, key.name, "cluster.max_journals") or
                std.mem.eql(u8, key.name, "journal.max_entry_bytes");
            if (provisional) {
                return std.fmt.bufPrint(buf, "{d} *(provisional)*", .{key.default_int});
            }
            return std.fmt.bufPrint(buf, "{d}", .{key.default_int});
        },
        .string_enum => return key.default_enum,
        .string_list => return if (key.default_list.len == 0) "[]" else "…",
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "render produces a table with one row per key" {
    var buf: [16 * 1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try renderTable(&writer);
    const text = writer.buffered();

    // The header and every key's name appear; the row count matches.
    try std.testing.expect(std.mem.indexOf(u8, text, "| Key | Scope | Type |") != null);
    var rows: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (line.len > 0 and line[0] == '|' and !std.mem.startsWith(u8, line, "|---")) rows += 1;
    }
    // header + one row per key
    try std.testing.expectEqual(schema.key_count + 1, rows);
    for (schema.keys) |key| {
        try std.testing.expect(std.mem.indexOf(u8, text, key.name) != null);
    }
}

test "rendered document is stable against the checked-in configuration.md (PRD 0004 G5)" {
    var buf: [16 * 1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try render(&writer);
    const out = writer.buffered();

    // The reference lives in the repo's docs/; the test runner's cwd is the
    // build root (where the data dirs for the store tests land), so the
    // relative path is stable. `@src().file` is relative at compile time and
    // cannot anchor the path reliably.
    const io = std.testing.io;
    const file = std.Io.Dir.cwd().openFile(io, "docs/configuration.md", .{}) catch |err| {
        if (err != error.FileNotFound) return err;
        return error.StaleConfigurationDoc;
    };
    defer file.close(io);
    var file_buf: [1 << 16]u8 = undefined;
    const n = try file.readPositionalAll(io, &file_buf, 0);
    try std.testing.expectEqualStrings(file_buf[0..n], out);
}
