//! embed-cluster: three embedded nodes in one test process (PRD 0005
//! example, step 2).
//!
//! The host opens three nodes of the same library on one `std.Io` — founder
//! plus two joiners over the in-memory hub transport — lets them elect, and
//! writes through the library API: `cluster.localAppend` runs the same write
//! path as a wire client (queue, forward, leader slots, broadcast), so a
//! host on a follower can append without ever touching the wire. Then a
//! partition and a heal, and the host's writes stay readable throughout.
//!
//! Build and run it (also a test, run by `zig build examples`):
//!
//!     zig build examples -- embed-cluster

const std = @import("std");
const coppiz = @import("coppiz");

const journal = coppiz.journal;
const cluster = coppiz.cluster;
const transport = coppiz.net.transport;
const schema = coppiz.schema;
const validate = coppiz.validate;

pub fn main() !void {
    // page_allocator is thread-safe (the node loops allocate on the io's
    // workers) and needs no setup or teardown — right for a demo host.
    const gpa = std.heap.page_allocator;
    // Three nodes need more async slots than `Io.Threaded`'s default gives:
    // each `ClusterNode` holds three permanently (loop, timer, accept) plus
    // one reader per connection, so a three-member mesh holds 15 while the
    // default limit is `cpu_count - 1`. Past the limit `groupAsync` runs the
    // task eagerly on the calling thread, and the third `start()` never
    // returns (bug 2026-08-29-embed-cluster-async-limit-deadlock).
    var io_state = std.Io.Threaded.init(gpa, .{ .async_limit = .limited(64) });
    defer io_state.deinit();
    const io = io_state.io();
    try runDemo(gpa, io);
}

test "embed-cluster: three embedded nodes join, host appends, a partition heals into one chain" {
    const gpa = std.heap.page_allocator;
    // Three nodes need more async slots than `Io.Threaded`'s default gives:
    // each `ClusterNode` holds three permanently (loop, timer, accept) plus
    // one reader per connection, so a three-member mesh holds 15 while the
    // default limit is `cpu_count - 1`. Past the limit `groupAsync` runs the
    // task eagerly on the calling thread, and the third `start()` never
    // returns (bug 2026-08-29-embed-cluster-async-limit-deadlock).
    var io_state = std.Io.Threaded.init(gpa, .{ .async_limit = .limited(64) });
    defer io_state.deinit();
    const io = io_state.io();
    try runDemo(gpa, io);
}

fn wallMs(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toMilliseconds();
}

const demo_base = "zig-out/examples/embed-cluster-data";

const Node = struct {
    node: *journal.Node,
    cn: *cluster.ClusterNode,
    listener: transport.Listener,
    dialer: transport.Transport,
    /// The host's wire client to this node (its own operator channel). The
    /// demo polls join/heal state through it; payload reads go through the
    /// node's loop instead (`cn.localReadRange`), so the host never touches
    /// the folds directly while the loop runs.
    client: *coppiz.net.client.Client,
    /// The seed list handed to the node's options: the loop's bootstrap
    /// reads it for the node's whole life, so the demo owns it (ClusterNode
    /// options borrow, they never copy).
    seeds: []const []const u8,

    fn stop(self: *const Node) void {
        self.cn.stop();
        self.cn.waitForStop();
        self.client.deinit();
        self.node.allocator.destroy(self.client);
        // The demo's own allocations free before the node does — reading
        // self.node.allocator after node.deinit would touch freed memory.
        if (self.seeds.len > 0) self.node.allocator.free(self.seeds);
        self.listener.close(self.cn.io);
        self.dialer.deinit();
        self.cn.deinit();
        self.node.deinit();
    }
};

fn spawnNode(
    gpa: std.mem.Allocator,
    io: std.Io,
    hub: *transport.Hub,
    address: []const u8,
    seed: ?[]const u8,
    keypair: ?std.crypto.sign.Ed25519.KeyPair,
) !Node {
    // A real data directory per member, under the demo base; the store
    // takes ownership of the dir it is opened with.
    const dir_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ demo_base, address });
    defer gpa.free(dir_path);
    const cwd = std.Io.Dir.cwd();
    // The base directory was wiped before the demo; each member's own
    // directory is created fresh here (the founder's was initialized with
    // `journal.init` just before its spawn, so spawnNode must not delete).
    try cwd.createDirPath(io, dir_path);
    const data_dir = try cwd.openDir(io, dir_path, .{ .iterate = true });
    if (keypair) |kp| try journal.writeMemberKey(gpa, io, data_dir, kp);
    var node = try journal.Node.open(gpa, io, data_dir, .{ .replay_forward = true });
    errdefer node.deinit();
    const listener = try hub.listen(gpa, address);
    const dialer = try hub.dialer(gpa, address);
    const seeds: []const []const u8 = if (seed) |s| blk: {
        const list = try gpa.alloc([]const u8, 1);
        list[0] = s;
        break :blk list;
    } else &.{};
    var cn = try cluster.ClusterNode.init(gpa, io, node, .{
        .transport = dialer,
        .listener = listener,
        .address = address,
        .seed_peers = seeds,
    });
    cn.start();
    const client_ptr = try gpa.create(coppiz.net.client.Client);
    errdefer gpa.destroy(client_ptr);
    client_ptr.* = try coppiz.net.client.Client.connectTransport(
        gpa,
        io,
        dialer,
        address,
        node.member_id,
        node.keypair.public_key.toBytes(),
        [_]u8{0} ** 32,
        "",
    );
    _ = try client_ptr.helloAck();
    return .{
        .node = node,
        .cn = cn,
        .listener = listener,
        .dialer = dialer,
        .client = client_ptr,
        .seeds = seeds,
    };
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

/// Whether the four demo payloads have all replicated to every member, read
/// through each member's own loop (`cn.localReadRange` — the host's read
/// path, PRD 0005).
fn allReplicated(
    nodes_list: []const *const Node,
    payloads_list: []const []const u8,
) !bool {
    const main_id = nodes_list[0].node.journalIdByName("main").?;
    for (nodes_list) |n| {
        const Ctx = struct {
            wanted: []const []const u8,
            found: [4]bool = [_]bool{false} ** 4,
        };
        var ctx = Ctx{ .wanted = payloads_list };
        try n.cn.localReadRange(n.cn.io, main_id, null, null, false, false, &ctx, struct {
            fn on(
                c: *Ctx,
                _: *const journal.slot.Slot,
                en: ?*const journal.entry.Entry,
            ) anyerror!void {
                const e = en orelse return;
                for (c.wanted, 0..) |w, i| {
                    if (std.mem.eql(u8, e.payload, w)) c.found[i] = true;
                }
            }
        }.on);
        for (ctx.found[0..payloads_list.len]) |f| {
            if (!f) return false;
        }
    }
    return true;
}

fn runDemo(gpa: std.mem.Allocator, io: std.Io) !void {
    // Open admission and fast failure detection from genesis.
    const admission = schema.keyIndex("cluster.admission").?;
    const heartbeat = schema.keyIndex("cluster.heartbeat_ms").?;
    const suspect = schema.keyIndex("cluster.suspect_after_ms").?;
    const genesis_changes = [_]validate.Change{
        .{ .key = admission, .value = .{
            .enum_value = schema.enumValue(admission, "open").?,
        } },
        .{ .key = heartbeat, .value = .{ .u64 = 50 } },
        .{ .key = suspect, .value = .{ .u64 = 800 } },
    };

    var hub = transport.Hub.init(gpa);
    defer hub.deinit(io);
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, demo_base) catch {};
    defer cwd.deleteTree(io, demo_base) catch {};

    // Founder A with the "main" journal; B and C are key-only joiners whose
    // keys open admission accepts.
    try cwd.createDirPath(io, demo_base ++ "/a");
    {
        const data_dir = try cwd.openDir(io, demo_base ++ "/a", .{ .iterate = true });
        try journal.init(gpa, io, data_dir, &genesis_changes, "main", &journal.wallClock);
    }
    const a = try spawnNode(gpa, io, &hub, "a", null, null);
    defer a.stop();
    const b_key = std.crypto.sign.Ed25519.KeyPair.generate(io);
    const b = try spawnNode(gpa, io, &hub, "b", "a", b_key);
    defer b.stop();
    const c_key = std.crypto.sign.Ed25519.KeyPair.generate(io);
    const c = try spawnNode(gpa, io, &hub, "c", "a", c_key);
    defer c.stop();

    // Both joiners reach the founder's view: their hello acks carry the
    // founder's epoch, which only a member sees.
    {
        const deadline = wallMs(io) + 20_000;
        while (wallMs(io) < deadline) {
            const hb = b.client.hello() catch continue;
            const hc = c.client.hello() catch continue;
            if (hb.epoch >= 1 and hc.epoch >= 1) break;
        }
        const hb = b.client.hello() catch return error.NotJoined;
        const hc = c.client.hello() catch return error.NotJoined;
        if (hb.epoch < 1 or hc.epoch < 1) return error.NotJoined;
    }
    // Let the join and backfill settle before writes race it.
    {
        const deadline = wallMs(io) + 1500;
        while (wallMs(io) < deadline) {}
    }

    // The host writes through the library: on the leader (slotted directly)
    // and on a follower (queued, forwarded, slotted by the leader). Both
    // block until the slot folds back.
    const id_leader = try a.cn.localAppend(io, "main", "host-on-leader", 0);
    const id_follower = try b.cn.localAppend(io, "main", "host-on-follower", 0);
    try expect(std.mem.eql(u8, &id_leader.author, &a.node.member_id));
    try expect(std.mem.eql(u8, &id_follower.author, &b.node.member_id));

    // Both host writes are visible on every member (read over the wire).
    {
        const deadline = wallMs(io) + 15_000;
        while (wallMs(io) < deadline) {
            if (try allReplicated(
                &.{ &a, &b, &c },
                &.{ "host-on-leader", "host-on-follower" },
            )) break;
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(100), .awake) catch return;
        }
        if (!try allReplicated(&.{ &a, &b, &c }, &.{ "host-on-leader", "host-on-follower" })) {
            return error.NotReplicated;
        }
    }

    // Partition A from B and C, then heal before the failure detector
    // fires: the connections drop and redial, the cluster continues on one
    // leader, and the host's writes stay readable throughout. (A partition
    // that lasts past the suspect timeout elects a second leader and needs
    // the deterministic merge — that story is the node loop's own e2e, two
    // members, over this same transport.)
    try hub.drop(gpa, io, "a", "b");
    try hub.drop(gpa, io, "b", "a");
    try hub.drop(gpa, io, "a", "c");
    try hub.drop(gpa, io, "c", "a");
    {
        const deadline = wallMs(io) + 300;
        while (wallMs(io) < deadline) {}
    }
    try hub.heal(gpa, "a", "b");
    try hub.heal(gpa, "b", "a");
    try hub.heal(gpa, "a", "c");
    try hub.heal(gpa, "c", "a");
    {
        const deadline = wallMs(io) + 15_000;
        var healthy = false;
        while (wallMs(io) < deadline) {
            const hb = b.client.hello() catch {
                std.Io.sleep(io, std.Io.Duration.fromMilliseconds(100), .awake) catch return;
                continue;
            };
            const hc = c.client.hello() catch {
                std.Io.sleep(io, std.Io.Duration.fromMilliseconds(100), .awake) catch return;
                continue;
            };
            if (hb.epoch >= 1 and hc.epoch >= 1) {
                healthy = true;
                break;
            }
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(100), .awake) catch return;
        }
        if (!healthy) return error.NotHealed;
    }

    // The host's writes still read on every member after the heal.
    {
        const deadline = wallMs(io) + 15_000;
        while (wallMs(io) < deadline) {
            if (try allReplicated(
                &.{ &a, &b, &c },
                &.{ "host-on-leader", "host-on-follower" },
            )) break;
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(100), .awake) catch return;
        }
        if (!try allReplicated(
            &.{ &a, &b, &c },
            &.{ "host-on-leader", "host-on-follower" },
        )) {
            return error.NotReplicated;
        }
    }

    std.debug.print(
        "embed-cluster: 3 members joined, host appended via leader and follower, healed\n",
        .{},
    );
}
