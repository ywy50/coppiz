//! short-process: the CLI shape of coppiz (PRD 0005 example; the second
//! host shape of [RFC 0021](../../docs/rfcs/0021-host-shapes.md) option B).
//!
//! Every other example holds the node open for the life of the process.
//! This one is the shape clanker does not exercise: a command-line tool
//! that runs, does one unit of work, and exits — so the whole library
//! lifecycle (open, append, read, close) is paid once per invocation and
//! everything it learned has to come back off disk on the next one.
//!
//! What the demo checks, and why each one is a property of *this* shape:
//!
//! - a run after the first opens an existing directory without `init` and
//!   without config, and sees every earlier run's entries;
//! - `author_seq` keeps counting across processes — the member key and the
//!   author's sequence survive the close, they are not process state;
//! - the head position advances by exactly one slot per invocation, so a
//!   close mid-life leaves nothing torn behind it.
//!
//! Build and run it (also a test, run by `zig build test`):
//!
//!     zig build examples
//!
//! The demo asserts as it goes and exits non-zero on failure, so the same
//! file is both the example and its test.

const std = @import("std");
const coppiz = @import("coppiz");

const demo_dir = "zig-out/examples/short-process-data";

/// How many short-lived invocations the demo simulates. Three is the
/// smallest number that distinguishes "the second open works" from "every
/// later open works".
const invocations = 3;

pub fn main() !void {
    const gpa = std.heap.page_allocator;
    var io_state = std.Io.Threaded.init(gpa, .{});
    defer io_state.deinit();
    const io = io_state.io();
    try runDemo(gpa, io);
}

test "short-process: each invocation opens, appends, reads and closes" {
    const gpa = std.heap.page_allocator;
    var io_state = std.Io.Threaded.init(gpa, .{});
    defer io_state.deinit();
    const io = io_state.io();
    try runDemo(gpa, io);
}

fn expect(ok: bool) !void {
    // The demo runs both as an executable (`zig build examples`) and as a
    // test; std.testing.expect* refuses non-test builds, so the examples
    // assert with their own error-returning checks.
    if (!ok) return error.ExampleAssertionFailed;
}

fn expectEq(comptime T: type, expected: T, actual: T) !void {
    if (!std.meta.eql(expected, actual)) return error.ExampleAssertionFailed;
}

/// One invocation of the tool: open the directory, append one line, read
/// the whole journal back, close. Returns the entry id the append produced
/// and the number of entries the read saw.
fn invocation(
    gpa: std.mem.Allocator,
    io: std.Io,
    payload: []const u8,
) !struct { id: coppiz.journal.entry.Id, seen: usize, head: ?coppiz.journal.slot.Position } {
    const cwd = std.Io.Dir.cwd();
    // No `init`, no settings, no peers: an existing directory is all the
    // state a later run needs. Node.open takes ownership of the handle.
    const data_dir = try cwd.openDir(io, demo_dir, .{ .iterate = true });
    var node = try coppiz.journal.Node.open(gpa, io, data_dir, .{});
    defer node.deinit();

    const lines = node.journalIdByName("lines") orelse return error.ExampleAssertionFailed;
    const id = try node.append(lines, payload, 0);

    var seen: usize = 0;
    try node.readRange(lines, null, null, false, false, &seen, struct {
        fn on(
            c: *usize,
            _: *const coppiz.journal.slot.Slot,
            _: ?*const coppiz.journal.entry.Entry,
        ) anyerror!void {
            c.* += 1;
        }
    }.on);

    return .{ .id = id, .seen = seen, .head = node.head(lines) };
}

fn runDemo(gpa: std.mem.Allocator, io: std.Io) !void {
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, demo_dir) catch {};
    defer cwd.deleteTree(io, demo_dir) catch {};
    try cwd.createDirPath(io, demo_dir);

    // The install step of the tool, run once: it writes the member key and
    // the genesis. Every later invocation just opens the directory.
    const init_dir = try cwd.openDir(io, demo_dir, .{ .iterate = true });
    try coppiz.journal.init(gpa, io, init_dir, &.{}, "lines", &coppiz.journal.wallClock);

    var buf: [32]u8 = undefined;
    for (0..invocations) |i| {
        const payload = try std.fmt.bufPrint(&buf, "line {d}", .{i + 1});
        const run = try invocation(gpa, io, payload);

        // The author's sequence is chain state, not process state: it keeps
        // counting where the previous process left off.
        try expectEq(u64, @as(u64, @intCast(i + 1)), run.id.author_seq);
        // Each run sees its own append plus every earlier run's.
        try expectEq(usize, i + 1, run.seen);
        // One slot per invocation, and the epoch never moves: a size-1 host
        // that closes cleanly needs no failover to reopen.
        try expectEq(
            ?coppiz.journal.slot.Position,
            .{ .epoch = 1, .seq = @intCast(i + 1) },
            run.head,
        );
    }

    // A last read-only invocation: the shape's other half is a tool that
    // only inspects. It appends nothing, so nothing about the journal
    // changes, and it still sees everything.
    const data_dir = try cwd.openDir(io, demo_dir, .{ .iterate = true });
    var node = try coppiz.journal.Node.open(gpa, io, data_dir, .{});
    defer node.deinit();
    const lines = node.journalIdByName("lines") orelse return error.ExampleAssertionFailed;
    var seen: usize = 0;
    try node.readRange(lines, null, null, false, false, &seen, struct {
        fn on(
            c: *usize,
            _: *const coppiz.journal.slot.Slot,
            en: ?*const coppiz.journal.entry.Entry,
        ) anyerror!void {
            const want = if (c.* == 0) "line 1" else if (c.* == 1) "line 2" else "line 3";
            if (!std.mem.eql(u8, want, en.?.payload)) return error.ExampleAssertionFailed;
            c.* += 1;
        }
    }.on);
    try expectEq(usize, invocations, seen);
    try expect(node.head(lines) != null);

    std.debug.print(
        "short-process: {d} invocations, each open-append-read-close, {d} entries\n",
        .{ invocations, seen },
    );
}
