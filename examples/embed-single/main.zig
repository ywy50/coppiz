//! embed-single: the SQLite shape of coppiz (PRD 0005 example, G1).
//!
//! One process, one data directory, no network: init writes the member key
//! and the genesis, then the host appends, reads and follows. This is the
//! whole store at size 1 — peers, election and the wire are things a host
//! opts into later, by opening the same library with a cluster around it.
//!
//! Build and run it (also a test, run by `zig build examples`):
//!
//!     zig build examples -- embed-single
//!
//! The demo asserts as it goes and exits non-zero on failure, so the same
//! file is both the example and its test.

const std = @import("std");
const coppiz = @import("coppiz");

const demo_dir = "zig-out/examples/embed-single-data";

pub fn main() !void {
    // page_allocator is thread-safe (the node loops allocate on the io's
    // workers) and needs no setup or teardown — right for a demo host.
    const gpa = std.heap.page_allocator;
    var io_state = std.Io.Threaded.init(gpa, .{});
    defer io_state.deinit();
    const io = io_state.io();
    try runDemo(gpa, io);
}

test "embed-single: opens, appends, reads and follows with no config beyond a directory" {
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

fn runDemo(gpa: std.mem.Allocator, io: std.Io) !void {
    // A fresh data directory; `init` writes the member key and the genesis.
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, demo_dir) catch {};
    defer cwd.deleteTree(io, demo_dir) catch {};
    try cwd.createDirPath(io, demo_dir);

    var data_dir = try cwd.openDir(io, demo_dir, .{ .iterate = true });
    // init and Node.open take ownership of the directory (the store closes
    // it), so the host never closes it.
    try coppiz.journal.init(gpa, io, data_dir, &.{}, "events", &coppiz.journal.wallClock);

    // Open the node: the host's allocator and io, a directory, nothing else.
    data_dir = try cwd.openDir(io, demo_dir, .{ .iterate = true });
    var node = try coppiz.journal.Node.open(gpa, io, data_dir, .{});
    defer node.deinit();

    const events = node.journalIdByName("events").?;

    // Append is synchronous: queue, slot as this member (it is the leader),
    // return the entry id.
    const id = try node.append(events, "hello coppiz", 0);

    // Read everything back.
    var seen: usize = 0;
    try node.readRange(events, null, null, false, false, &seen, struct {
        fn on(
            c: *usize,
            _: *const coppiz.journal.slot.Slot,
            en: ?*const coppiz.journal.entry.Entry,
        ) anyerror!void {
            if (!std.mem.eql(u8, "hello coppiz", en.?.payload)) return error.ExampleAssertionFailed;
            c.* += 1;
        }
    }.on);
    try expectEq(usize, 1, seen);

    // Follow delivers the next slot to a callback, no polling. The
    // callback receives the ctx as *anyopaque, like the library's contract.
    var followed: usize = 0;
    try node.follow(events, .{ .epoch = 1, .seq = 1 }, &followed, struct {
        fn on(
            ctx: *anyopaque,
            _: [16]u8,
            _: *const coppiz.journal.slot.Slot,
            _: ?*const coppiz.journal.entry.Entry,
        ) void {
            const c: *usize = @ptrCast(@alignCast(ctx));
            c.* += 1;
        }
    }.on);
    _ = try node.append(events, "second", 0);
    // The cursor is inclusive, so the initial delivery replays the entry
    // at (1,1) and the new append delivers (1,2): two callbacks, no polling.
    try expectEq(usize, 2, followed);

    // The entry id names (author, author_seq); reads and head are local.
    try expectEq(u64, 1, id.author_seq);
    try expectEq(?coppiz.journal.slot.Position, .{ .epoch = 1, .seq = 2 }, node.head(events));

    std.debug.print("embed-single: appended, read and followed 2 entries at size 1\n", .{});
}
