//! `coppiz` — the standalone node wrapping the coppiz library.
//!
//! The tier-0 CLI (PRD 0001 phase 4, PRD 0004 phase 4) plus the cluster
//! surface of PRD 0003 phase 5: `serve` runs a node's loop, and every
//! command falls back to the wire when the data directory is locked by a
//! serving node (OQ 47: short-lived processes talk to the long-lived one).
//!
//! Commands:
//!
//!   coppiz init --dir DIR [--journal NAME] [--config FILE]
//!   coppiz serve --dir DIR [--config FILE]
//!   coppiz append --dir DIR --journal NAME [--ttl MS]
//!                 (--payload TEXT | --payload-file PATH)
//!   coppiz read --dir DIR --journal NAME [--from EPOCH:SEQ]
//!               [--include-stale] [--include-expired]
//!   coppiz head --dir DIR --journal NAME
//!   coppiz status --dir DIR
//!   coppiz settings schema
//!   coppiz settings set --dir DIR --key KEY --value VALUE [--journal NAME]
//!   coppiz admit --dir DIR --member HEXID

const std = @import("std");
const coppiz = @import("coppiz");
const journal = coppiz.journal;
const config = coppiz.config;
const net = coppiz.net;
const entry = journal.entry;
const slot = journal.slot;
const schema = coppiz.schema;
const settings_fold = coppiz.settings_fold;
const validate = coppiz.validate;

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
    if (std.mem.eql(u8, cmd, "serve")) return cmdServe(gpa, io, argv.items[2..]);
    if (std.mem.eql(u8, cmd, "append")) return cmdAppend(gpa, io, argv.items[2..]);
    if (std.mem.eql(u8, cmd, "read")) return cmdRead(gpa, io, argv.items[2..]);
    if (std.mem.eql(u8, cmd, "head")) return cmdHead(gpa, io, argv.items[2..]);
    if (std.mem.eql(u8, cmd, "status")) return cmdStatus(gpa, io, argv.items[2..]);
    if (std.mem.eql(u8, cmd, "settings")) return cmdSettings(gpa, io, argv.items[2..]);
    if (std.mem.eql(u8, cmd, "admit")) return cmdAdmit(gpa, io, argv.items[2..]);
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
        \\  coppiz serve --dir DIR [--config FILE]
        \\  coppiz append --dir DIR --journal NAME [--ttl MS] --payload TEXT
        \\  coppiz append --dir DIR --journal NAME [--ttl MS] --payload-file PATH
        \\  coppiz read --dir DIR --journal NAME [--from EPOCH:SEQ]
        \\               [--include-stale] [--include-expired]
        \\  coppiz head --dir DIR --journal NAME
        \\  coppiz status --dir DIR
        \\  coppiz settings schema
        \\  coppiz settings set --dir DIR --key KEY --value VALUE [--journal NAME]
        \\  coppiz admit --dir DIR --member HEXID
        \\
        \\EXAMPLES
        \\  coppiz init --dir ./data --journal main
        \\  coppiz serve --dir ./data
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

/// Loads `coppiz.toml` from the data dir (or the named file), tolerating
/// its absence.
fn loadConfig(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    file: ?[]const u8,
) !config.Config {
    var cfg = config.Config{ .allocator = gpa };
    errdefer cfg.deinit();
    if (file) |f| {
        try config.loadFile(gpa, io, f, &cfg);
    } else {
        const toml_path = try std.fmt.allocPrint(gpa, "{s}/coppiz.toml", .{dir_path});
        defer gpa.free(toml_path);
        config.loadFile(gpa, io, toml_path, &cfg) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }
    return cfg;
}

/// Opens the data directory and the node, loading `coppiz.toml` when it
/// exists (fsync policy and the queue bound).
fn openNode(gpa: std.mem.Allocator, io: std.Io, dir_path: []const u8) !*journal.Node {
    var cfg = try loadConfig(gpa, io, dir_path, null);
    defer cfg.deinit();
    const data_dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    return journal.Node.open(gpa, io, data_dir, .{
        .fsync = cfg.fsync,
        .unslotted_max_bytes = cfg.unslotted_max_bytes,
    });
}

fn journalId(node: *journal.Node, argv: []const []const u8) ![16]u8 {
    const name = getArg(argv, "--journal") orelse return error.MissingJournal;
    return node.journalIdByName(name) orelse error.UnknownJournal;
}

// -- wire client -----------------------------------------------------------

/// A wire client against the serving node of `dir_path`: dials `listen`
/// from the local config, hello with this member's own key (the node
/// recognizes itself and admits the operator channel).
fn wireClient(gpa: std.mem.Allocator, io: std.Io, dir_path: []const u8) !net.client.Client {
    var cfg = try loadConfig(gpa, io, dir_path, null);
    defer cfg.deinit();
    const listen = cfg.listen orelse return error.NoListenAddress;
    const data_dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{});
    defer data_dir.close(io);
    const identity = try net.client.memberIdentity(gpa, io, data_dir);
    return net.client.Client.connect(
        gpa,
        io,
        listen,
        identity.member_id,
        identity.public_key,
        [_]u8{0} ** 32,
        "",
    );
}

fn wireHello(gpa: std.mem.Allocator, io: std.Io, dir_path: []const u8) !struct {
    client: net.client.Client,
    ack: net.message.HelloAck,
} {
    var client = try wireClient(gpa, io, dir_path);
    errdefer client.deinit();
    const ack = try client.helloAck();
    if (!ack.admitted) return error.NotAdmitted;
    return .{ .client = client, .ack = ack };
}

// -- init ------------------------------------------------------------------

fn cmdInit(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    const dir = getArg(argv, "--dir") orelse return error.MissingDir;
    const first_journal = getArg(argv, "--journal");

    var cfg = try loadConfig(gpa, io, dir, getArg(argv, "--config"));
    defer cfg.deinit();

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

// -- serve -----------------------------------------------------------------

fn cmdServe(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    const dir = getArg(argv, "--dir") orelse return error.MissingDir;
    var cfg = try loadConfig(gpa, io, dir, getArg(argv, "--config"));
    defer cfg.deinit();
    const listen = cfg.listen orelse return error.NoListenAddress;

    // A serve-able directory needs a member key; a joiner's dir has one and
    // no chain. `init` is for founders; serve writes the key on its own.
    std.Io.Dir.cwd().createDir(io, dir, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    var data_dir = try std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true });
    const key_missing = blk: {
        const file = data_dir.openFile(io, "member.key", .{}) catch |err| switch (err) {
            error.FileNotFound => break :blk true,
            else => return err,
        };
        file.close(io);
        break :blk false;
    };
    if (key_missing) {
        const keypair = crypto.sign.Ed25519.KeyPair.generate(io);
        try journal.writeMemberKey(gpa, io, data_dir, keypair);
    }

    const node = try journal.Node.open(gpa, io, data_dir, .{
        .fsync = cfg.fsync,
        .unslotted_max_bytes = cfg.unslotted_max_bytes,
        .replay_forward = true,
    });
    defer node.deinit();

    // The allowlist: [[peers]] public keys, hex -> bytes.
    var allowlist = std.ArrayListUnmanaged([32]u8).empty;
    defer allowlist.deinit(gpa);
    var seed_peers = std.ArrayListUnmanaged([]const u8).empty;
    defer seed_peers.deinit(gpa);
    for (cfg.peers.items) |peer| {
        if (peer.public_key) |hex| {
            if (hexKeyToBytes(hex)) |key| try allowlist.append(gpa, key);
        }
        try seed_peers.append(gpa, peer.address);
    }

    const tcp = net.transport.TcpTransport{ .allocator = gpa };
    const listener = try net.transport.tcpListen(gpa, io, listen);
    const cluster_node = try coppiz.cluster.ClusterNode.init(gpa, io, node, .{
        .transport = tcp.transport(),
        .listener = listener,
        .address = listen,
        .allowlist = allowlist.items,
        .seed_peers = seed_peers.items,
    });
    defer cluster_node.deinit();

    cluster_node.start();
    // Blocks until the loop stops (a fatal error or `stop`), then cancels
    // the remaining tasks and returns.
    cluster_node.waitForStop();
}

fn hexKeyToBytes(text: []const u8) ?[32]u8 {
    if (text.len != 64) return null;
    var out: [32]u8 = undefined;
    for (0..32) |i| {
        const hi = hexNibble(text[i * 2]) orelse return null;
        const lo = hexNibble(text[i * 2 + 1]) orelse return null;
        out[i] = (hi << 4) | lo;
    }
    return out;
}

fn hexNibble(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

const crypto = std.crypto;

// -- append ----------------------------------------------------------------

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
    const name = getArg(argv, "--journal") orelse return error.MissingJournal;

    // Local when the node is not serving; over the wire otherwise.
    const node = openNode(gpa, io, dir) catch |err| switch (err) {
        error.AlreadyOpen => {
            try appendViaWire(gpa, io, dir, name, payload, ttl);
            return;
        },
        else => return err,
    };
    defer node.deinit();
    const jid = node.journalIdByName(name) orelse return error.UnknownJournal;
    const id = try node.append(jid, payload, ttl);
    var buf: [128]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{x}:{d}\n", .{ id.author, id.author_seq });
    var out_writer = std.Io.File.stdout().writer(io, &stderr_buf);
    try out_writer.interface.writeAll(text);
    try out_writer.interface.flush();
}

fn appendViaWire(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: []const u8,
    name: []const u8,
    payload: []const u8,
    ttl: u64,
) !void {
    var session = try wireHello(gpa, io, dir);
    defer session.client.deinit();
    const reply = try session.client.append(name, payload, ttl);
    if (reply.refusal.len > 0) {
        var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
        try stderr_writer.interface.print("coppiz: {s}\n", .{reply.refusal});
        return error.Refused;
    }
    var buf: [128]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{x}:{d}\n", .{ reply.id.author, reply.id.author_seq });
    var out_writer = std.Io.File.stdout().writer(io, &stderr_buf);
    try out_writer.interface.writeAll(text);
    try out_writer.interface.flush();
}

// -- read / head -----------------------------------------------------------

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
    const name = getArg(argv, "--journal") orelse return error.MissingJournal;

    var out_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &out_buf);
    const writer = &stdout_writer.interface;

    const node = openNode(gpa, io, dir) catch |err| switch (err) {
        error.AlreadyOpen => {
            try readViaWire(gpa, io, dir, name, from, include_stale, include_expired, writer);
            try stdout_writer.interface.flush();
            return;
        },
        else => return err,
    };
    defer node.deinit();
    const jid = node.journalIdByName(name) orelse return error.UnknownJournal;
    try node.readRange(jid, from, null, include_stale, include_expired, writer, struct {
        fn cb(w: *std.Io.Writer, sl: *const slot.Slot, en: ?*const entry.Entry) anyerror!void {
            try printRecord(w, sl, en);
        }
    }.cb);
    try stdout_writer.interface.flush();
}

fn readViaWire(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: []const u8,
    name: []const u8,
    from: ?slot.Position,
    include_stale: bool,
    include_expired: bool,
    writer: *std.Io.Writer,
) !void {
    var session = try wireHello(gpa, io, dir);
    defer session.client.deinit();
    try session.client.read(name, from, include_stale, include_expired, writer, struct {
        fn cb(w: *std.Io.Writer, sl: *const slot.Slot, en: ?*const entry.Entry) anyerror!void {
            try printRecord(w, sl, en);
        }
    }.cb);
}

fn printRecord(w: *std.Io.Writer, sl: *const slot.Slot, en: ?*const entry.Entry) !void {
    try w.print("{f} ", .{sl.position()});
    if (en) |e| {
        try w.print("{x}:{d} {s} ", .{ e.author, e.author_seq, e.kind.name() });
        try w.writeAll(e.payload);
    } else {
        try w.writeAll("(removed)");
    }
    try w.writeByte('\n');
}

fn cmdHead(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    const dir = getArg(argv, "--dir") orelse return error.MissingDir;
    const name = getArg(argv, "--journal") orelse return error.MissingJournal;

    const node = openNode(gpa, io, dir) catch |err| switch (err) {
        error.AlreadyOpen => {
            try headViaWire(gpa, io, dir, name);
            return;
        },
        else => return err,
    };
    defer node.deinit();
    const jid = node.journalIdByName(name) orelse return error.UnknownJournal;
    const head = node.head(jid) orelse return error.EmptyJournal;
    var buf: [64]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{f}\n", .{head});
    var out_writer = std.Io.File.stdout().writer(io, &stderr_buf);
    try out_writer.interface.writeAll(text);
    try out_writer.interface.flush();
}

fn headViaWire(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, name: []const u8) !void {
    var session = try wireHello(gpa, io, dir);
    defer session.client.deinit();
    const Head = struct { pos: ?slot.Position = null };
    var head = Head{};
    try session.client.read(name, null, false, false, &head, struct {
        fn cb(h: *Head, sl: *const slot.Slot, _: ?*const entry.Entry) anyerror!void {
            h.pos = sl.position();
        }
    }.cb);
    const pos = head.pos orelse return error.EmptyJournal;
    var buf: [64]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{f}\n", .{pos});
    var out_writer = std.Io.File.stdout().writer(io, &stderr_buf);
    try out_writer.interface.writeAll(text);
    try out_writer.interface.flush();
}

// -- status ----------------------------------------------------------------

fn cmdStatus(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    const dir = getArg(argv, "--dir") orelse return error.MissingDir;
    var session = try wireHello(gpa, io, dir);
    defer session.client.deinit();
    const ack = session.ack;
    var buf: [256]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "epoch {d}\nleader {x}\n", .{ ack.epoch, ack.leader });
    var out_writer = std.Io.File.stdout().writer(io, &stderr_buf);
    try out_writer.interface.writeAll(text);
    try out_writer.interface.flush();
}

// -- settings --------------------------------------------------------------

fn cmdSettings(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    if (argv.len < 1) return error.UnknownCommand;
    if (std.mem.eql(u8, argv[0], "schema")) {
        var out_buf: [4096]u8 = undefined;
        var stdout_writer = std.Io.File.stdout().writer(io, &out_buf);
        const writer = &stdout_writer.interface;
        try coppiz.render.render(writer);
        try stdout_writer.interface.flush();
        return;
    }
    if (std.mem.eql(u8, argv[0], "set")) return cmdSettingsSet(gpa, io, argv[1..]);
    return error.UnknownCommand;
}

/// `settings set` — a live settings change; the leader appends it (the
/// fold refuses what the mode freezes, PRD 0003 *Live reconfiguration*).
fn cmdSettingsSet(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    const dir = getArg(argv, "--dir") orelse return error.MissingDir;
    const key_text = getArg(argv, "--key") orelse return error.MissingKey;
    const value_text = getArg(argv, "--value") orelse return error.MissingValue;
    const name = getArg(argv, "--journal") orelse "__cluster__";

    const key = schema.keyIndex(key_text) orelse return error.UnknownKey;
    const parsed = try config.parseValue(gpa, key, value_text);
    defer parsed.deinit(gpa);
    const change = [_]validate.Change{.{ .key = key, .value = parsed }};
    const changes_len = settings_fold.changesLen(&change);
    const changes_buf = try gpa.alloc(u8, changes_len);
    defer gpa.free(changes_buf);
    settings_fold.encodeChanges(&change, changes_buf);

    var session = try wireHello(gpa, io, dir);
    defer session.client.deinit();
    const reply = try session.client.settings(name, changes_buf);
    if (reply.refusal.len > 0) {
        var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
        try stderr_writer.interface.print("coppiz: {s}\n", .{reply.refusal});
        try stderr_writer.interface.flush();
        return error.Refused;
    }
}

// -- admit -----------------------------------------------------------------

/// `admit` — the offline half of `cluster.admission = prompt`: append the
/// `join` entry for a dial that was recorded in `pending.admit`. The node
/// must be stopped and this member must be the leader (the fold's join rule
/// admits any member, but slotting requires the leader).
fn cmdAdmit(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    const dir = getArg(argv, "--dir") orelse return error.MissingDir;
    const target_hex = getArg(argv, "--member") orelse return error.MissingMember;
    const target = parseHexId(target_hex) orelse return error.BadMemberId;

    const data_dir = try std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true });
    var node = try journal.Node.open(gpa, io, data_dir, .{});
    defer node.deinit();
    if (!std.mem.eql(u8, &node.leader(), &node.member_id)) return error.NotLeader;

    const file = data_dir.openFile(io, "pending.admit", .{}) catch |err| switch (err) {
        error.FileNotFound => return error.NoPendingAdmissions,
        else => return err,
    };
    defer file.close(io);
    const len = try file.length(io);
    const text = try gpa.alloc(u8, @intCast(len));
    defer gpa.free(text);
    const n = try file.readPositionalAll(io, text, 0);
    if (n != text.len) return error.Truncated;

    // Lines: hex member id, hex public key, address.
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len < 98) continue;
        const id = parseHexId(line[0..32]) orelse continue;
        if (!std.mem.eql(u8, &id, &target)) continue;
        const key = hexKeyToBytes(line[33..97]) orelse continue;
        const address = std.mem.trim(u8, line[98..], " \t\r");
        const payload = try gpa.alloc(
            u8,
            coppiz.membership.joinPayloadLen(.{
                .member_id = target,
                .public_key = key,
                .address = address,
            }),
        );
        defer gpa.free(payload);
        coppiz.membership.encodeJoinPayload(
            .{ .member_id = target, .public_key = key, .address = address },
            payload,
        );
        // A join authored by any member folds; slotting requires the leader.
        try node.appendControl(.join, payload, &node.control);
        return;
    }
    return error.NoPendingAdmissions;
}

fn parseHexId(text: []const u8) ?[16]u8 {
    if (text.len != 32) return null;
    var out: [16]u8 = undefined;
    for (0..16) |i| {
        const hi = hexNibble(text[i * 2]) orelse return null;
        const lo = hexNibble(text[i * 2 + 1]) orelse return null;
        out[i] = (hi << 4) | lo;
    }
    return out;
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
    try std.testing.expect(std.mem.indexOf(u8, text, "coppiz serve") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "coppiz append") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "coppiz read") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "coppiz head") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "coppiz status") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "settings schema") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "settings set") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "coppiz admit") != null);
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

test "hex key parsing round-trips" {
    const key = [_]u8{ 0xab, 0xcd, 0xef, 0x01, 0x23, 0x45, 0x67, 0x89 } ** 4;
    var hex: [64]u8 = undefined;
    const digits = "0123456789abcdef";
    for (key, 0..) |byte, i| {
        hex[i * 2] = digits[byte >> 4];
        hex[i * 2 + 1] = digits[byte & 0xf];
    }
    const parsed = hexKeyToBytes(&hex).?;
    try std.testing.expectEqualSlices(u8, &key, &parsed);
    try std.testing.expect(hexKeyToBytes("not-hex") == null);
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
        const res = try self.runRaw(args);
        if (res.code != 0) return error.ChildFailed;
        return res.out;
    }

    /// Like `run`, but returns the exit code instead of asserting success.
    fn runRaw(self: *BinTest, args: []const []const u8) !struct {
        out: []u8,
        code: u8,
    } {
        _ = self;
        var argv = std.ArrayListUnmanaged([]const u8).empty;
        defer argv.deinit(test_alloc);
        try argv.append(test_alloc, "zig-out/bin/coppiz");
        try argv.appendSlice(test_alloc, args);
        var child = try std.process.spawn(tio, .{
            .argv = argv.items,
            .stdout = .pipe,
            .stderr = .pipe,
            .stdin = .ignore,
        });
        var out = std.ArrayListUnmanaged(u8).empty;
        defer out.deinit(test_alloc);
        var err_buf = std.ArrayListUnmanaged(u8).empty;
        defer err_buf.deinit(test_alloc);
        var chunk: [4096]u8 = undefined;
        while (true) {
            const n = child.stdout.?.readStreaming(tio, &.{&chunk}) catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };
            if (n == 0) break;
            try out.appendSlice(test_alloc, chunk[0..n]);
        }
        while (true) {
            const n = child.stderr.?.readStreaming(tio, &.{&chunk}) catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };
            if (n == 0) break;
            try err_buf.appendSlice(test_alloc, chunk[0..n]);
        }
        const term = try child.wait(tio);
        const code: u8 = switch (term) {
            .exited => |c| c,
            else => 1,
        };
        if (code != 0) {
            if (err_buf.items.len > 0) {
                std.debug.print("child stderr: {s}\n", .{err_buf.items});
            }
            return .{ .out = try out.toOwnedSlice(test_alloc), .code = code };
        }
        return .{ .out = try out.toOwnedSlice(test_alloc), .code = code };
    }

    /// Runs the installed binary as a long-lived process (serve), returning
    /// the child for later killing.
    fn spawn(self: *BinTest, args: []const []const u8) !std.process.Child {
        _ = self;
        var argv = std.ArrayListUnmanaged([]const u8).empty;
        defer argv.deinit(test_alloc);
        try argv.append(test_alloc, "zig-out/bin/coppiz");
        try argv.appendSlice(test_alloc, args);
        // The children's output must not touch the test runner's own
        // stdout/stderr: under `zig build test` those carry the runner's
        // protocol pipe, and a child writing to it corrupts the stream.
        return std.process.spawn(tio, .{
            .argv = argv.items,
            .stdout = .ignore,
            .stderr = .ignore,
            .stdin = .ignore,
        });
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
    const append3 = try bt.run(&.{
        "append", "--dir", bt.dir, "--journal", "main", "--payload", "three",
    });
    defer test_alloc.free(append3);

    // Simulate a kill -9 mid-append of the third record: the head segment's
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

    // Reopen: the acknowledged appends "one" and "two" survive; the torn
    // third record is truncated away and the head reflects exactly that.
    const read = try bt.run(&.{ "read", "--dir", bt.dir, "--journal", "main" });
    defer test_alloc.free(read);
    try std.testing.expect(std.mem.indexOf(u8, read, "one") != null);
    try std.testing.expect(std.mem.indexOf(u8, read, "two") != null);
    try std.testing.expect(std.mem.indexOf(u8, read, "three") == null);

    const head = try bt.run(&.{ "head", "--dir", bt.dir, "--journal", "main" });
    defer test_alloc.free(head);
    try std.testing.expectEqualStrings("1:2\n", head);
}

// -- process-level cluster tests -------------------------------------------
//
// These spawn the real binary as long-lived `serve` processes on loopback
// TCP and drive them through the CLI (which falls back to the wire when the
// data dir is locked). Ports are derived from the test process pid (with a
// distinct offset per node) so an aborted earlier run — whose serve children
// may outlive stop()'s wait — or a parallel checkout cannot collide on fixed
// ports; the suite runs the tests sequentially.

fn testAddr(offset: u16) ![]u8 {
    const pid: u32 = @intCast(@as(i64, std.c.getpid()));
    const port = 20000 + @as(u16, @intCast(pid % 40000)) + offset;
    return std.fmt.allocPrint(test_alloc, "127.0.0.1:{d}", .{port});
}

const ServingProc = struct {
    child: std.process.Child,

    fn stop(self: ServingProc) void {
        const child = self.child;
        // A raw kill that tolerates the child having already exited (the
        // io's child.kill treats ESRCH as a programmer bug and panics);
        // then poll with signal 0 until it is gone, so the directory lock
        // is released before the next step opens the dir.
        if (child.id) |pid| {
            std.posix.kill(pid, std.posix.SIG.KILL) catch {};
            var tries: u32 = 0;
            while (tries < 500) : (tries += 1) {
                std.posix.kill(pid, @enumFromInt(0)) catch break;
                std.Io.sleep(tio, std.Io.Duration.fromMilliseconds(10), .awake) catch break;
            }
        }
    }
};

/// Writes `<data>/coppiz.toml` with a listen address, seed peers and (for a
/// founder) fast failure detection.
fn writeToml(
    bt: *BinTest,
    listen: []const u8,
    seeds: []const []const u8,
    admission: ?[]const u8,
) !void {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(test_alloc);
    try buf.appendSlice(test_alloc, "listen = \"");
    try buf.appendSlice(test_alloc, listen);
    try buf.appendSlice(test_alloc, "\"\n");
    for (seeds) |seed| {
        try buf.appendSlice(test_alloc, "[[peers]]\naddress = \"");
        try buf.appendSlice(test_alloc, seed);
        try buf.appendSlice(test_alloc, "\"\n");
    }
    if (admission) |mode| {
        try buf.appendSlice(test_alloc, "[genesis]\ncluster.admission = \"");
        try buf.appendSlice(test_alloc, mode);
        try buf.appendSlice(test_alloc, "\"\n");
        // Fast failure detection so joins resolve quickly.
        try buf.appendSlice(test_alloc, "cluster.heartbeat_ms = 100\n");
        try buf.appendSlice(test_alloc, "cluster.suspect_after_ms = 800\n");
    }
    const file = try bt.tmp.dir.createFile(tio, "data/coppiz.toml", .{
        .read = true,
        .truncate = true,
    });
    defer file.close(tio);
    try file.writePositionalAll(tio, buf.items, 0);
}

/// Polls `status --dir` until the output contains `needle` (or the timeout).
fn waitStatus(bt: *BinTest, needle: []const u8) !void {
    const deadline = std.Io.Timestamp.now(tio, .real).toMilliseconds() + 30_000;
    while (std.Io.Timestamp.now(tio, .real).toMilliseconds() < deadline) {
        const res = bt.runRaw(&.{ "status", "--dir", bt.dir }) catch {
            std.Io.sleep(tio, std.Io.Duration.fromMilliseconds(150), .awake) catch {};
            continue;
        };
        if (res.code == 0 and std.mem.indexOf(u8, res.out, needle) != null) {
            test_alloc.free(res.out);
            return;
        }
        test_alloc.free(res.out);
        std.Io.sleep(tio, std.Io.Duration.fromMilliseconds(150), .awake) catch {};
    }
    return error.Timeout;
}

/// The founder's member id, from its own status line before anyone joins.
fn leaderHex(bt: *BinTest) ![]u8 {
    try waitStatus(bt, "epoch 1");
    const res = try bt.runRaw(&.{ "status", "--dir", bt.dir });
    defer test_alloc.free(res.out);
    const prefix = "leader ";
    const start = std.mem.indexOf(u8, res.out, prefix) orelse return error.NoLeader;
    const hex = std.mem.trim(u8, res.out[start + prefix.len ..], " \n\r");
    return test_alloc.dupe(u8, hex);
}

/// The number of members in the fold of `name`'s data dir (nodes stopped).
fn memberCountOf(bt: *BinTest) !usize {
    const data_dir = try bt.tmp.dir.openDir(tio, "data", .{ .iterate = true });
    var node = try journal.Node.open(test_alloc, tio, data_dir, .{});
    defer node.deinit();
    return node.control.memberCount();
}

test "process-level: a live cluster grows 1 → 2 → 3 members over TCP, founder stays leader" {
    // A founds the cluster with open admission.
    var a = try BinTest.init();
    defer a.deinit();
    const addr_a = try testAddr(0);
    defer test_alloc.free(addr_a);
    try writeToml(&a, addr_a, &.{}, "open");
    _ = try a.run(&.{ "init", "--dir", a.dir, "--journal", "main" });
    const pa = try a.spawn(&.{ "serve", "--dir", a.dir });
    const pa_proc = ServingProc{ .child = pa };
    defer pa_proc.stop();
    const a_id = try leaderHex(&a);
    defer test_alloc.free(a_id);
    // A alone is the leader of its own cluster.
    try waitStatus(&a, a_id);

    // B joins, backfills, and reads what A wrote.
    var b = try BinTest.init();
    defer b.deinit();
    const addr_b = try testAddr(1);
    defer test_alloc.free(addr_b);
    try writeToml(&b, addr_b, &.{addr_a}, null);
    const pb = try b.spawn(&.{ "serve", "--dir", b.dir });
    const pb_proc = ServingProc{ .child = pb };
    defer pb_proc.stop();
    const needle_b = try std.fmt.allocPrint(test_alloc, "leader {s}", .{a_id});
    defer test_alloc.free(needle_b);
    try waitStatus(&b, needle_b); // B's view elects A
    const m1 = try a.run(&.{
        "append", "--dir", a.dir, "--journal", "main", "--payload", "m1",
    });
    defer test_alloc.free(m1);
    const read_b = try pollRead(&b, "m1");
    defer test_alloc.free(read_b);

    // C joins; wait for its backfill to reach the pre-existing entry, then
    // B (a follower) appends and C reads the replicated entry.
    var c = try BinTest.init();
    defer c.deinit();
    const addr_c = try testAddr(2);
    defer test_alloc.free(addr_c);
    try writeToml(&c, addr_c, &.{addr_a}, null);
    const pc = try c.spawn(&.{ "serve", "--dir", c.dir });
    const pc_proc = ServingProc{ .child = pc };
    defer pc_proc.stop();
    const needle_c = try std.fmt.allocPrint(test_alloc, "leader {s}", .{a_id});
    defer test_alloc.free(needle_c);
    try waitStatus(&c, needle_c);
    // C's leader view updates once its control chain folds; its data
    // backfill may still be running, and a broadcast during it is dropped.
    // Reading the pre-existing entry means the backfill is done.
    const read_c_m1 = try pollRead(&c, "m1");
    defer test_alloc.free(read_c_m1);
    const m2 = try b.run(&.{
        "append", "--dir", b.dir, "--journal", "main", "--payload", "m2",
    });
    defer test_alloc.free(m2);
    const read_c = try pollRead(&c, "m2");
    defer test_alloc.free(read_c);

    // The founder leads at every step.
    try waitStatus(&a, a_id);
    try waitStatus(&c, a_id);

    // Stop everything and confirm the fold grew to three members.
    pa_proc.stop();
    pb_proc.stop();
    pc_proc.stop();
    try std.testing.expectEqual(@as(usize, 3), try memberCountOf(&a));
    try std.testing.expectEqual(@as(usize, 3), try memberCountOf(&b));
}

/// Polls `read --dir` until the output contains `needle`.
fn pollRead(bt: *BinTest, needle: []const u8) ![]u8 {
    const deadline = std.Io.Timestamp.now(tio, .real).toMilliseconds() + 20_000;
    while (std.Io.Timestamp.now(tio, .real).toMilliseconds() < deadline) {
        const res = bt.runRaw(&.{ "read", "--dir", bt.dir, "--journal", "main" }) catch {
            std.Io.sleep(tio, std.Io.Duration.fromMilliseconds(150), .awake) catch {};
            continue;
        };
        if (res.code == 0 and std.mem.indexOf(u8, res.out, needle) != null) {
            return res.out;
        }
        test_alloc.free(res.out);
        std.Io.sleep(tio, std.Io.Duration.fromMilliseconds(150), .awake) catch {};
    }
    return error.Timeout;
}

test "process-level: live reconfiguration freezes leadership.* and refuses to unfreeze live" {
    var a = try BinTest.init();
    defer a.deinit();
    const addr_a = try testAddr(3);
    defer test_alloc.free(addr_a);
    try writeToml(&a, addr_a, &.{}, null);
    _ = try a.run(&.{ "init", "--dir", a.dir, "--journal", "main" });
    const pa = try a.spawn(&.{ "serve", "--dir", a.dir });
    const pa_proc = ServingProc{ .child = pa };
    defer pa_proc.stop();
    try waitStatus(&a, "epoch 1");

    // Leadership is live while reconfigurable (the default).
    const set_mode = try a.run(&.{
        "settings", "set",             "--dir",   a.dir,
        "--key",    "leadership.mode", "--value", "configured",
    });
    defer test_alloc.free(set_mode);
    // Freeze leadership.
    const freeze = try a.run(&.{
        "settings", "set",                       "--dir",   a.dir,
        "--key",    "leadership.reconfigurable", "--value", "false",
    });
    defer test_alloc.free(freeze);
    // A leadership change is now refused by the fold...
    const refused_mode = try a.runRaw(&.{
        "settings", "set",             "--dir",   a.dir,
        "--key",    "leadership.mode", "--value", "seniority",
    });
    defer test_alloc.free(refused_mode.out);
    try std.testing.expect(refused_mode.code != 0);
    // ...and so is flipping reconfigurable back live (offline only).
    const refused_unfreeze = try a.runRaw(&.{
        "settings", "set",                       "--dir",   a.dir,
        "--key",    "leadership.reconfigurable", "--value", "true",
    });
    defer test_alloc.free(refused_unfreeze.out);
    try std.testing.expect(refused_unfreeze.code != 0);

    // The refused changes did not land: stop and inspect the fold.
    pa_proc.stop();
    const data_dir = try a.tmp.dir.openDir(tio, "data", .{ .iterate = true });
    var node = try journal.Node.open(test_alloc, tio, data_dir, .{});
    defer node.deinit();
    const mode = node.control.settings.getEnum(schema.keyIndex("leadership.mode").?);
    try std.testing.expectEqualStrings("configured", mode);
    const recfg = node.control.settings.getBool(schema.keyIndex("leadership.reconfigurable").?);
    try std.testing.expect(!recfg);
}

test "process-level: a chain from a different genesis is refused admission" {
    var a = try BinTest.init();
    defer a.deinit();
    const addr_a = try testAddr(4);
    defer test_alloc.free(addr_a);
    try writeToml(&a, addr_a, &.{}, "open");
    _ = try a.run(&.{ "init", "--dir", a.dir, "--journal", "main" });
    const pa = try a.spawn(&.{ "serve", "--dir", a.dir });
    const pa_proc = ServingProc{ .child = pa };
    defer pa_proc.stop();
    try waitStatus(&a, "epoch 1");

    // D founds its OWN chain, then dials A's cluster as a seed peer.
    var d = try BinTest.init();
    defer d.deinit();
    const addr_d = try testAddr(5);
    defer test_alloc.free(addr_d);
    try writeToml(&d, addr_d, &.{addr_a}, "open");
    _ = try d.run(&.{ "init", "--dir", d.dir, "--journal", "main" });
    const pd = try d.spawn(&.{ "serve", "--dir", d.dir });
    const pd_proc = ServingProc{ .child = pd };
    defer pd_proc.stop();

    // Give the refused dials time to retry a few times.
    const deadline = std.Io.Timestamp.now(tio, .real).toMilliseconds() + 2000;
    while (std.Io.Timestamp.now(tio, .real).toMilliseconds() < deadline) {
        std.Io.sleep(tio, std.Io.Duration.fromMilliseconds(200), .awake) catch {};
    }

    // A's fold never admitted D; D remains its own single-member chain.
    pa_proc.stop();
    pd_proc.stop();
    try std.testing.expectEqual(@as(usize, 1), try memberCountOf(&a));
    try std.testing.expectEqual(@as(usize, 1), try memberCountOf(&d));
}
