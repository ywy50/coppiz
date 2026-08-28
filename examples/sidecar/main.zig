//! sidecar: a host speaking to a coppiz node over the wire (PRD 0005
//! example, step 3).
//!
//! The `coppiz` binary wraps the same library for hosts that would rather
//! talk to a process. A host on the other side of that interface speaks
//! `coppiz.net.client` — hello, append, read — which is exactly what the
//! node's own CLI does when the data directory is locked. For the test the
//! node is embedded in-process behind the in-memory hub; the client code is
//! identical to talking to a `coppiz serve` over TCP.
//!
//! Build and run it (also a test, run by `zig build examples`):
//!
//!     zig build examples -- sidecar

const std = @import("std");
const coppiz = @import("coppiz");

const journal = coppiz.journal;
const cluster = coppiz.cluster;
const transport = coppiz.net.transport;
const client = coppiz.net.client;

const demo_dir = "zig-out/examples/sidecar-data";

pub fn main() !void {
    // page_allocator is thread-safe (the node loops allocate on the io's
    // workers) and needs no setup or teardown — right for a demo host.
    const gpa = std.heap.page_allocator;
    var io_state = std.Io.Threaded.init(gpa, .{});
    defer io_state.deinit();
    const io = io_state.io();
    try runDemo(gpa, io);
}

test "sidecar: a host speaks to a node over the wire" {
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
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, demo_dir) catch {};
    defer cwd.deleteTree(io, demo_dir) catch {};
    try cwd.createDirPath(io, demo_dir);

    // The node side: init, open, and the loop behind a listener.
    {
        const data_dir = try cwd.openDir(io, demo_dir, .{ .iterate = true });
        try journal.init(gpa, io, data_dir, &.{}, "main", &journal.wallClock);
    }
    const data_dir = try cwd.openDir(io, demo_dir, .{ .iterate = true });
    var node = try journal.Node.open(gpa, io, data_dir, .{ .replay_forward = true });
    defer node.deinit();

    var hub = transport.Hub.init(gpa);
    defer hub.deinit(io);
    const listener = try hub.listen(gpa, "node-a");
    const dialer = try hub.dialer(gpa, "node-a");
    var cn = try cluster.ClusterNode.init(gpa, io, node, .{
        .transport = dialer,
        .listener = listener,
        .address = "node-a",
    });
    cn.start();
    defer {
        cn.stop();
        cn.waitForStop();
        listener.close(io);
        dialer.deinit();
        cn.deinit();
    }

    // The host side: read the node's key from its data directory (the
    // sidecar has access to it, or the operator provisions it), then speak
    // the wire protocol — the same interface a `coppiz serve` exposes.
    const keypair = try journal.loadMemberKeyPublic(gpa, io, data_dir);
    var wire = try client.Client.connectTransport(
        gpa,
        io,
        dialer,
        "node-a",
        node.member_id,
        keypair.public_key.toBytes(),
        [_]u8{0} ** 32,
        "",
    );
    defer wire.deinit();

    const hello = try wire.helloAck();
    try expect(hello.admitted);
    try expectEq(u64, 1, hello.epoch);

    const reply = try wire.append("main", "via-wire", 0);
    try expectEq(usize, 0, reply.refusal.len);

    var seen: usize = 0;
    try wire.read("main", null, false, false, &seen, struct {
        fn on(
            c: *usize,
            _: *const journal.slot.Slot,
            en: ?*const journal.entry.Entry,
        ) anyerror!void {
            if (!std.mem.eql(u8, "via-wire", en.?.payload)) return error.ExampleAssertionFailed;
            c.* += 1;
        }
    }.on);
    try expectEq(usize, 1, seen);

    std.debug.print("sidecar: a host spoke hello, append and read over the wire\n", .{});
}
