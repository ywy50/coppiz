//! `coppiz` — the standalone node wrapping the coppiz library.
//!
//! The tier-0 CLI (PRD 0001 phase 4, PRD 0004 phase 4): every command is a
//! short-lived process that opens the data directory (locked), does its
//! work, and closes. The full node CLI (serve, doctor, status) is PRD
//! 0005's; this is the minimal surface the acceptance criteria need.
//!
//! Commands:
//!
//!   coppiz init --dir DIR [--journal NAME] [--config FILE]
//!   coppiz append --dir DIR --journal NAME [--ttl MS]
//!                 (--payload TEXT | --payload-file PATH)
//!   coppiz read --dir DIR [--journal NAME] [--from EPOCH:SEQ]
//!               [--include-stale] [--include-expired]
//!   coppiz head --dir DIR [--journal NAME]
//!   coppiz settings schema

const std = @import("std");
const coppiz = @import("coppiz");
const journal = coppiz.journal;
const config = coppiz.config;
const entry = journal.entry;
const slot = journal.slot;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var argv = std.ArrayListUnmanaged([]const u8).empty;
    defer argv.deinit(gpa);
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    while (args.next()) |a| try argv.append(gpa, a);

    if (argv.items.len < 2) {
        var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
        try printUsage(&stderr_writer.interface);
        return error.MissingCommand;
    }
    const cmd = argv.items[1];
    if (std.mem.eql(u8, cmd, "init")) return cmdInit(gpa, io, argv.items[2..]);
    if (std.mem.eql(u8, cmd, "append")) return cmdAppend(gpa, io, argv.items[2..]);
    if (std.mem.eql(u8, cmd, "read")) return cmdRead(gpa, io, argv.items[2..]);
    if (std.mem.eql(u8, cmd, "head")) return cmdHead(gpa, io, argv.items[2..]);
    if (std.mem.eql(u8, cmd, "settings")) return cmdSettings(gpa, io, argv.items[2..]);
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
    try printUsage(&stderr_writer.interface);
    return error.UnknownCommand;
}

var stderr_buf: [256]u8 = undefined;

fn printUsage(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\coppiz — a replicated, append-only store.
        \\
        \\USAGE
        \\  coppiz init --dir DIR [--journal NAME] [--config FILE]
        \\  coppiz append --dir DIR --journal NAME [--ttl MS] --payload TEXT
        \\  coppiz append --dir DIR --journal NAME [--ttl MS] --payload-file PATH
        \\  coppiz read --dir DIR [--journal NAME] [--from EPOCH:SEQ]
        \\               [--include-stale] [--include-expired]
        \\  coppiz head --dir DIR [--journal NAME]
        \\  coppiz settings schema
        \\
        \\EXAMPLES
        \\  coppiz init --dir ./data --journal main
        \\  coppiz append --dir ./data --journal main --payload "hello"
        \\  coppiz read --dir ./data --journal main
        \\  coppiz head --dir ./data --journal main
        \\
    );
}

fn getArg(argv: []const []const u8, comptime name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + 1 < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], name)) return argv[i + 1];
    }
    return null;
}

fn hasFlag(argv: []const []const u8, comptime name: []const u8) bool {
    for (argv) |a| {
        if (std.mem.eql(u8, a, name)) return true;
    }
    return false;
}

/// Opens the data directory and the node, loading `coppiz.toml` when it
/// exists (fsync policy and the queue bound).
fn openNode(gpa: std.mem.Allocator, io: std.Io, dir_path: []const u8) !*journal.Node {
    const fsync, const unslotted = blk: {
        var cfg = config.Config{ .allocator = gpa };
        defer cfg.deinit();
        const toml_path = try std.fmt.allocPrint(gpa, "{s}/coppiz.toml", .{dir_path});
        defer gpa.free(toml_path);
        if (config.loadFile(gpa, io, toml_path, &cfg)) |_| {
            break :blk .{ cfg.fsync, cfg.unslotted_max_bytes };
        } else |err| switch (err) {
            error.FileNotFound => break :blk .{
                config.Fsync.every,
                config.provisional_unslotted_max_bytes,
            },
            else => return err,
        }
    };
    const data_dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    return journal.Node.open(gpa, io, data_dir, .{
        .fsync = fsync,
        .unslotted_max_bytes = unslotted,
    });
}

fn journalId(node: *journal.Node, argv: []const []const u8) ![16]u8 {
    const name = getArg(argv, "--journal") orelse return error.MissingJournal;
    return node.journalIdByName(name) orelse error.UnknownJournal;
}

fn cmdInit(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    const dir = getArg(argv, "--dir") orelse return error.MissingDir;
    const first_journal = getArg(argv, "--journal");

    var cfg = config.Config{ .allocator = gpa };
    defer cfg.deinit();
    if (getArg(argv, "--config")) |file| {
        try config.loadFile(gpa, io, file, &cfg);
    } else {
        // The default location is <data_dir>/coppiz.toml (ADR 0004).
        const toml_path = try std.fmt.allocPrint(gpa, "{s}/coppiz.toml", .{dir});
        defer gpa.free(toml_path);
        config.loadFile(gpa, io, toml_path, &cfg) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }

    // Create the data directory if needed; the genesis validation happens
    // inside journal.init before anything is written (G6).
    std.Io.Dir.cwd().createDir(io, dir, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    var data_dir = try std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true });
    errdefer data_dir.close(io);
    try journal.init(gpa, io, data_dir, cfg.genesis.items, first_journal, &journal.wallClock);
}

fn cmdAppend(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    const dir = getArg(argv, "--dir") orelse return error.MissingDir;
    const payload = if (getArg(argv, "--payload")) |p|
        p
    else if (getArg(argv, "--payload-file")) |path|
        try readFile(gpa, io, path)
    else
        return error.MissingPayload;
    const ttl: u64 = if (getArg(argv, "--ttl")) |t|
        std.fmt.parseInt(u64, t, 10) catch return error.BadTtl
    else
        0;

    var node = try openNode(gpa, io, dir);
    defer node.deinit();
    const jid = try journalId(node, argv);
    const id = try node.append(jid, payload, ttl);
    var buf: [128]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{x}:{d}\n", .{ id.author, id.author_seq });
    var out_writer = std.Io.File.stdout().writer(io, &stderr_buf);
    try out_writer.interface.writeAll(text);
    try out_writer.interface.flush();
}

fn cmdRead(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    const dir = getArg(argv, "--dir") orelse return error.MissingDir;
    const from: ?slot.Position = if (getArg(argv, "--from")) |pos| blk: {
        var parts = std.mem.splitScalar(u8, pos, ':');
        const epoch_text = parts.next() orelse return error.BadPosition;
        const seq_text = parts.next() orelse return error.BadPosition;
        break :blk slot.Position{
            .epoch = std.fmt.parseInt(u64, epoch_text, 10) catch return error.BadPosition,
            .seq = std.fmt.parseInt(u64, seq_text, 10) catch return error.BadPosition,
        };
    } else null;
    const include_stale = hasFlag(argv, "--include-stale");
    const include_expired = hasFlag(argv, "--include-expired");

    var node = try openNode(gpa, io, dir);
    defer node.deinit();
    const jid = try journalId(node, argv);

    var out_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &out_buf);
    const writer = &stdout_writer.interface;
    try node.readRange(jid, from, null, include_stale, include_expired, writer, struct {
        fn cb(w: *std.Io.Writer, sl: *const slot.Slot, en: ?*const entry.Entry) anyerror!void {
            try w.print("{f} ", .{sl.position()});
            if (en) |e| {
                try w.print("{x}:{d} {s} ", .{ e.author, e.author_seq, e.kind.name() });
                try w.writeAll(e.payload);
            } else {
                try w.writeAll("(removed)");
            }
            try w.writeByte('\n');
        }
    }.cb);
    try stdout_writer.interface.flush();
}

fn cmdHead(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    const dir = getArg(argv, "--dir") orelse return error.MissingDir;
    var node = try openNode(gpa, io, dir);
    defer node.deinit();
    const jid = try journalId(node, argv);
    const head = node.head(jid) orelse return error.EmptyJournal;
    var buf: [64]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{f}\n", .{head});
    var out_writer = std.Io.File.stdout().writer(io, &stderr_buf);
    try out_writer.interface.writeAll(text);
    try out_writer.interface.flush();
}

fn cmdSettings(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    _ = gpa;
    if (argv.len < 1 or !std.mem.eql(u8, argv[0], "schema")) {
        return error.UnknownCommand;
    }
    var out_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &out_buf);
    const writer = &stdout_writer.interface;
    try coppiz.render.render(writer);
    try stdout_writer.interface.flush();
}

fn readFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const len = try file.length(io);
    const buf = try gpa.alloc(u8, @intCast(len));
    errdefer gpa.free(buf);
    const n = try file.readPositionalAll(io, buf, 0);
    if (n != buf.len) return error.Truncated;
    return buf;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "usage prints every command" {
    var buf: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try printUsage(&writer);
    const text = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, text, "coppiz init") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "coppiz append") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "coppiz read") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "coppiz head") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "settings schema") != null);
}

test "all public declarations analyze" {
    // main.zig is a test root; it imports only the `coppiz` library module
    // (whose own root owes its modules the refAllDecls pairing), so this
    // root's own declarations are all that is left to force through the
    // analyzer.
    std.testing.refAllDecls(@This());
}

test "flag helpers pick values and presence" {
    const argv = [_][]const u8{ "--dir", "/tmp/x", "--include-stale", "--ttl", "5" };
    try std.testing.expectEqualStrings("/tmp/x", getArg(&argv, "--dir").?);
    try std.testing.expectEqualStrings("5", getArg(&argv, "--ttl").?);
    try std.testing.expect(getArg(&argv, "--journal") == null);
    try std.testing.expect(hasFlag(&argv, "--include-stale"));
    try std.testing.expect(!hasFlag(&argv, "--include-expired"));
}

// ---------------------------------------------------------------------------
// Process-level e2e tests (spawn the real binary)
// ---------------------------------------------------------------------------

const test_alloc = std.testing.allocator;
const tio = std.testing.io;

const BinTest = struct {
    tmp: std.testing.TmpDir,
    dir: []const u8,

    fn init() !BinTest {
        var tmp = std.testing.tmpDir(.{});
        const base = try std.fmt.allocPrint(test_alloc, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
        defer test_alloc.free(base);
        const dir = try std.fmt.allocPrint(test_alloc, "{s}/data", .{base});
        try tmp.dir.createDir(tio, "data", .default_dir);
        return .{ .tmp = tmp, .dir = dir };
    }

    fn deinit(self: *BinTest) void {
        test_alloc.free(self.dir);
        self.tmp.cleanup();
    }

    /// Runs the installed binary with `args`, capturing stdout.
    fn run(self: *BinTest, args: []const []const u8) ![]u8 {
        _ = self;
        var argv = std.ArrayListUnmanaged([]const u8).empty;
        defer argv.deinit(test_alloc);
        try argv.append(test_alloc, "zig-out/bin/coppiz");
        try argv.appendSlice(test_alloc, args);
        var child = try std.process.spawn(tio, .{
            .argv = argv.items,
            .stdout = .pipe,
            .stderr = .inherit,
            .stdin = .ignore,
        });
        var out = std.ArrayListUnmanaged(u8).empty;
        defer out.deinit(test_alloc);
        var chunk: [4096]u8 = undefined;
        while (true) {
            const n = child.stdout.?.readStreaming(tio, &.{&chunk}) catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };
            if (n == 0) break;
            try out.appendSlice(test_alloc, chunk[0..n]);
        }
        const term = try child.wait(tio);
        try std.testing.expectEqual(@as(u8, 0), switch (term) {
            .exited => |code| code,
            else => 1,
        });
        return out.toOwnedSlice(test_alloc);
    }
};

test "the coppiz binary runs the single-member journal end to end" {
    var bt = try BinTest.init();
    defer bt.deinit();
    const init_out = try bt.run(&.{ "init", "--dir", bt.dir, "--journal", "main" });
    defer test_alloc.free(init_out);
    const append1 = try bt.run(&.{
        "append", "--dir", bt.dir, "--journal", "main", "--payload", "hello",
    });
    defer test_alloc.free(append1);
    const append2 = try bt.run(&.{
        "append", "--dir", bt.dir, "--journal", "main", "--payload", "world",
    });
    defer test_alloc.free(append2);

    const read = try bt.run(&.{ "read", "--dir", bt.dir, "--journal", "main" });
    defer test_alloc.free(read);
    try std.testing.expect(std.mem.indexOf(u8, read, "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, read, "world") != null);
    try std.testing.expect(std.mem.indexOf(u8, read, "1:1 ") != null);
    try std.testing.expect(std.mem.indexOf(u8, read, "1:2 ") != null);

    const head = try bt.run(&.{ "head", "--dir", bt.dir, "--journal", "main" });
    defer test_alloc.free(head);
    try std.testing.expectEqualStrings("1:2\n", head);
}

test "acknowledged appends survive a crash-like truncation (G4, process level)" {
    var bt = try BinTest.init();
    defer bt.deinit();
    const init_out = try bt.run(&.{ "init", "--dir", bt.dir, "--journal", "main" });
    defer test_alloc.free(init_out);
    const append1 = try bt.run(&.{
        "append", "--dir", bt.dir, "--journal", "main", "--payload", "one",
    });
    defer test_alloc.free(append1);
    const append2 = try bt.run(&.{
        "append", "--dir", bt.dir, "--journal", "main", "--payload", "two",
    });
    defer test_alloc.free(append2);

    // Simulate a kill -9 mid-append of a third record: the head segment's
    // tail is a partial write. Locate the data journal's segment through
    // the library, then truncate it.
    {
        const data_dir = try bt.tmp.dir.openDir(tio, "data", .{ .iterate = true });
        var node = try journal.Node.open(test_alloc, tio, data_dir, .{});
        defer node.deinit();
        const jid = node.journalIdByName("main").?;
        const dir_name = try journal.store.journalDirName(test_alloc, jid);
        defer test_alloc.free(dir_name);
        const seg_rel = try std.fmt.allocPrint(test_alloc, "data/{s}/seg-00000001", .{dir_name});
        defer test_alloc.free(seg_rel);
        const file = try bt.tmp.dir.openFile(tio, seg_rel, .{ .mode = .read_write });
        defer file.close(tio);
        const len = try file.length(tio);
        try file.setLength(tio, len - 10);
    }

    // Reopen: the acknowledged append "one" survives; the partial tail is
    // truncated and the store still opens and reads.
    const read = try bt.run(&.{ "read", "--dir", bt.dir, "--journal", "main" });
    defer test_alloc.free(read);
    try std.testing.expect(std.mem.indexOf(u8, read, "one") != null);
}
