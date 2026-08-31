//! The CLI's wire client (PRD 0003 phase 5): short-lived commands against a
//! serving node — the OQ 47 shape where the store's directory lock keeps the
//! short-lived process out, so it talks to the long-lived one over the wire.
//! One connection per command: dial, hello, request, collect the answer.
//!
//! The client is the node's own operator channel: it dials with the same
//! member key (the data dir is readable while locked) and a zero genesis —
//! the serving node recognizes "this is me" and admits the connection
//! without treating it as a joining member.

const std = @import("std");
const journal = @import("../journal/journal.zig");
const slot = @import("../journal/slot.zig");
const entry = @import("../journal/entry.zig");
const segment = @import("../journal/segment.zig");
const chain = @import("../journal/chain.zig");
const message = @import("message.zig");
const transport = @import("transport.zig");

/// How long `recvMessage` waits for a reply before giving up. A backstop,
/// not an SLA: the point is to turn an unbounded hang into a bounded,
/// diagnosable failure, so the number sits far above every legitimate wait
/// in the suite (the e2e convergence polls allow 20 s, and there are 30 s
/// status polls) and far below "forever". It matches
/// `transport.default_read_timeout_ms`, which bounds the hub half of the
/// same path.
pub const default_recv_timeout_ms: i64 = 120_000;

pub const Client = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    conn: transport.Conn,
    member_id: [16]u8,
    public_key: [32]u8,
    address: []const u8,
    /// Message parts are arena-owned and valid until the next recv; the
    /// arena outlives each `recvMessage` so a returned `read_page`'s records
    /// are safe to process before the next request.
    arena: std.heap.ArenaAllocator,
    /// Overridable per connection so a test can pin the bound in
    /// milliseconds rather than minutes. Zero or less disables it, which is
    /// the pre-fix behaviour and the only option when the `Io` cannot run a
    /// concurrent task.
    recv_timeout_ms: i64 = default_recv_timeout_ms,

    pub fn deinit(self: *Client) void {
        self.arena.deinit();
        self.conn.close(self.io);
    }

    /// Dials `address` through a caller-provided transport (TCP for the
    /// CLI; the hub for in-process tests) and sends the hello.
    pub fn connectTransport(
        allocator: std.mem.Allocator,
        io: std.Io,
        transport_impl: transport.Transport,
        address: []const u8,
        member_id: [16]u8,
        public_key: [32]u8,
        genesis_hash: [32]u8,
        my_address: []const u8,
    ) !Client {
        const conn = try transport_impl.connect(io, allocator, address);
        var self = Client{
            .allocator = allocator,
            .io = io,
            .conn = conn,
            .member_id = member_id,
            .public_key = public_key,
            .address = my_address,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
        errdefer self.deinit();
        try self.send(.{ .hello = .{
            .member_id = member_id,
            .public_key = public_key,
            .genesis_hash = genesis_hash,
            .address = my_address,
        } });
        return self;
    }

    /// Dials `address` and sends the hello. `genesis_hash` is the caller's
    /// cluster identity (zeros when it has no chain yet); a member client
    /// passes its own key so the serving node recognizes it.
    pub fn connect(
        allocator: std.mem.Allocator,
        io: std.Io,
        address: []const u8,
        member_id: [16]u8,
        public_key: [32]u8,
        genesis_hash: [32]u8,
        my_address: []const u8,
    ) !Client {
        var tcp = transport.TcpTransport{ .allocator = allocator };
        return connectTransport(
            allocator,
            io,
            tcp.transport(),
            address,
            member_id,
            public_key,
            genesis_hash,
            my_address,
        );
    }

    /// Reads one frame and decodes it into the client's arena; the result
    /// is valid until the next `recvMessage`.
    fn recvMessage(self: *Client) !message.Message {
        _ = self.arena.reset(.retain_capacity);
        const body = try self.recvBounded();
        return message.decode(self.arena.allocator(), body);
    }

    /// Reads one frame with a deadline, returning `error.Timeout` when the
    /// peer answers neither data nor a close in `recv_timeout_ms`.
    ///
    /// `recvMessage` used to block in `Conn.recv` with no bound at all. Over
    /// the hub `Direction` supplies one (bug
    /// 2026-08-31-hub-read-has-no-deadline), but the production path is
    /// TCP, where a peer that accepts the connection and then answers
    /// nothing parks the caller forever - a `readv` at 0% CPU with no
    /// diagnosis (bug 2026-08-31-client-recv-has-no-deadline).
    ///
    /// The bound cannot come from the socket. `std.Io.net` exposes no
    /// receive-timeout option, and setting `SO_RCVTIMEO` behind its back
    /// does not work either: the option raises `EAGAIN`, which
    /// `Io.Threaded`'s `netReadPosix` routes through `errnoBug` (a
    /// `std.debug.panic` in a debug build), while `Io.Kqueue`'s `netRead`
    /// treats `EAGAIN` as "register a read filter and yield" and so ignores
    /// the option entirely. So the read runs as a concurrent task and this
    /// one waits on its completion event against an absolute deadline.
    ///
    /// On expiry the read is ended with `Conn.shutdown`, which exists for
    /// exactly this - waking a blocked reader without freeing the
    /// connection - rather than with `Future.cancel`, whose ability to
    /// interrupt a blocked `readv` is implementation-dependent. The task is
    /// always awaited before `task` leaves scope, since it writes into it.
    fn recvBounded(self: *Client) ![]u8 {
        const arena_alloc = self.arena.allocator();
        if (self.recv_timeout_ms <= 0) return self.conn.recv(self.io, arena_alloc);
        var task: RecvTask = .{
            .conn = &self.conn,
            .io = self.io,
            .allocator = arena_alloc,
        };
        var future = self.io.concurrent(RecvTask.run, .{&task}) catch {
            // `ConcurrencyUnavailable` - a single-threaded build, or a pool
            // at its limit. No bound is expressible, so the read runs inline
            // exactly as it did before. Degrading to the old behaviour is
            // honest; claiming a bound that is not there would not be.
            return self.conn.recv(self.io, arena_alloc);
        };
        // Converted to an absolute deadline once, on entry: the budget is
        // the total wait, not a fresh allowance per wakeup.
        const budget: std.Io.Timeout = .{ .duration = .{
            .raw = std.Io.Duration.fromMilliseconds(self.recv_timeout_ms),
            .clock = .awake,
        } };
        const outcome = waitRecv(self.io, &task.done, budget.toDeadline(self.io));
        if (outcome != .ready) self.conn.shutdown(self.io);
        future.await(self.io);
        // The task's own result wins even on expiry: a frame that landed in
        // the same instant is data, not a timeout - the last-look shape
        // `Direction.expired` uses on the hub side.
        if (task.result) |body| return body else |err| return switch (outcome) {
            .ready => err,
            .expired => error.Timeout,
            .canceled => error.Canceled,
        };
    }

    fn send(self: *Client, m: message.Message) !void {
        const body = try self.allocator.alloc(u8, message.encodedLen(m));
        defer self.allocator.free(body);
        message.encode(m, body);
        try self.conn.send(self.io, body);
    }

    /// The hello reply: admission, the node's identity and its cluster view.
    pub fn helloAck(self: *Client) !message.HelloAck {
        const reply = try self.recvMessage();
        return switch (reply) {
            .hello_ack => |a| a,
            else => error.ProtocolError,
        };
    }

    /// Re-sends the hello and reads the reply — a status poll against a
    /// live node (helloAck alone reads the reply to the connect-time hello).
    pub fn hello(self: *Client) !message.HelloAck {
        try self.send(.{ .hello = .{
            .member_id = self.member_id,
            .public_key = self.public_key,
            .genesis_hash = [_]u8{0} ** 32,
            .address = self.address,
        } });
        return self.helloAck();
    }

    /// Appends and waits for the ack (the slot, or a refusal).
    pub fn append(
        self: *Client,
        journal_name: []const u8,
        payload: []const u8,
        ttl_ms: u64,
    ) !message.Ack {
        try checkJournalName(journal_name);
        try self.send(.{ .append = .{
            .journal = journal_name,
            .payload = payload,
            .ttl_ms = ttl_ms,
        } });
        const reply = try self.recvMessage();
        return switch (reply) {
            .ack => |a| a,
            else => error.ProtocolError,
        };
    }

    /// Reads a journal from `from` (null = genesis), page by page, calling
    /// `on_record` for each decoded record until the stream ends.
    pub fn read(
        self: *Client,
        journal_name: []const u8,
        from: ?slot.Position,
        include_stale: bool,
        include_expired: bool,
        ctx: anytype,
        comptime on_record: fn (
            @TypeOf(ctx),
            *const slot.Slot,
            ?*const entry.Entry,
        ) anyerror!void,
    ) !void {
        try checkJournalName(journal_name);
        var position: slot.Position = from orelse .{ .epoch = 0, .seq = 0 };
        while (true) {
            try self.send(.{ .read_req = .{
                .journal = journal_name,
                .from = position,
                .include_stale = include_stale,
                .include_expired = include_expired,
                .max_bytes = 64 * 1024,
            } });
            const reply = try self.recvMessage();
            const page = switch (reply) {
                .read_page => |p| p,
                else => return error.ProtocolError,
            };
            // The wire equivalent of the local read's UnknownJournal (bug
            // 2026-08-28-sweep3-wire-read-unknown-journal).
            if (page.refusal.len > 0) return error.UnknownJournal;
            var off: usize = 0;
            while (off < page.records.len) {
                const rec = segment.decodeRecord(page.records[off..]) catch
                    return error.BadRecord;
                try on_record(ctx, &rec.slot, if (rec.entry) |*en| en else null);
                off += rec.next_offset;
            }
            if (page.next.epoch == 0 and page.next.seq == 0) return; // done
            // The cursor comes from the peer, so it is checked, not
            // asserted: a `next` that does not advance is an unbounded
            // request loop in a release build and a panic in a safe one.
            if (slot.Position.order(page.next, position) != .gt) {
                return error.ProtocolError;
            }
            position = page.next;
        }
    }

    /// The member listing: the node's control fold's members plus its
    /// epoch and leader view. The reply is arena-owned; it lives until
    /// `deinit`.
    pub fn members(self: *Client) !message.MembersPage {
        try self.send(.members_req);
        const reply = try self.recvMessage();
        return switch (reply) {
            .members_page => |p| p,
            else => error.ProtocolError,
        };
    }

    /// A settings change request (the change-list bytes the chain encodes).
    pub fn settings(self: *Client, journal_name: []const u8, changes: []const u8) !message.Ack {
        try checkJournalName(journal_name);
        try self.send(.{ .settings = .{
            .journal = journal_name,
            .changes = changes,
        } });
        const reply = try self.recvMessage();
        return switch (reply) {
            .ack => |a| a,
            else => error.ProtocolError,
        };
    }
};

/// One frame read, run as a concurrent task so the caller can bound it.
/// `run` publishes `result` before `done`, and `done.set` releases, so a
/// waiter that observes the event observes the result.
const RecvTask = struct {
    conn: *const transport.Conn,
    io: std.Io,
    allocator: std.mem.Allocator,
    result: transport.RecvError![]u8 = error.EndOfStream,
    done: std.Io.Event = .unset,

    fn run(task: *RecvTask) void {
        task.result = task.conn.recv(task.io, task.allocator);
        task.done.set(task.io);
    }
};

/// Why the wait ended.
const WaitOutcome = enum { ready, expired, canceled };

/// Waits for `done` until `deadline`. `Io.Event.waitTimeout` reports a
/// spurious wakeup as `error.Timeout` just like a real expiry - it does not
/// loop - so the clock decides, not the error: the deadline is re-checked
/// after every return, the way `Direction.readInto` re-checks its own.
fn waitRecv(io: std.Io, done: *std.Io.Event, deadline: std.Io.Timeout) WaitOutcome {
    while (true) {
        if (done.isSet()) return .ready;
        done.waitTimeout(io, deadline) catch |err| switch (err) {
            error.Timeout => {},
            error.Canceled => return .canceled,
        };
        if (done.isSet()) return .ready;
        const left = deadline.toDurationFromNow(io) orelse continue;
        if (left.raw.nanoseconds <= 0) return .expired;
    }
}

/// The wire's journal-name field is a u16 length, and the encoders cast it
/// unchecked: a name past the cap panics in a safe build and wraps in a
/// release one (bug 2026-08-30-wire-name-len-unchecked). The store's own
/// name bound is far smaller (max_journal_name), so no real name can reach
/// the cap - refuse before the encoder does.
fn checkJournalName(journal_name: []const u8) error{JournalNameTooLong}!void {
    if (journal_name.len > std.math.maxInt(u16)) return error.JournalNameTooLong;
}

/// Loads a member key from a data dir (readable while the node holds the
/// lock) and derives the member id.
pub fn memberIdentity(
    allocator: std.mem.Allocator,
    io: std.Io,
    data_dir: std.Io.Dir,
) !struct { member_id: [16]u8, public_key: [32]u8 } {
    const keypair = try journal.loadMemberKeyPublic(allocator, io, data_dir);
    return .{
        .member_id = chain.deriveMemberId(keypair.public_key.toBytes()),
        .public_key = keypair.public_key.toBytes(),
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const test_alloc = std.testing.allocator;
const tio = std.testing.io;

fn sendTestMessage(conn: *const transport.Conn, m: message.Message) !void {
    const body = try test_alloc.alloc(u8, message.encodedLen(m));
    defer test_alloc.free(body);
    message.encode(m, body);
    try conn.send(tio, body);
}

/// A server that answers every `read_req` with the same non-zero cursor: the
/// second page does not advance past the first, which is what the client has
/// to refuse rather than request forever.
fn stuckReadServer(listener: *transport.Listener) error{Canceled}!void {
    var conn = listener.accept(tio) catch return;
    defer conn.close(tio);
    const hello = conn.recv(tio, test_alloc) catch return;
    test_alloc.free(hello);
    sendTestMessage(&conn, .{ .hello_ack = .{
        .admitted = true,
        .refusal = .none,
        .member_id = [_]u8{9} ** 16,
        .address = "server",
        .genesis_hash = [_]u8{0} ** 32,
        .epoch = 1,
        .leader = [_]u8{9} ** 16,
    } }) catch return;
    var i: usize = 0;
    while (i < 2) : (i += 1) {
        const req = conn.recv(tio, test_alloc) catch return;
        test_alloc.free(req);
        sendTestMessage(&conn, .{ .read_page = .{
            .next = .{ .epoch = 1, .seq = 1 },
            .records = &.{},
            .refusal = "",
        } }) catch return;
    }
}

fn ignoreRecord(_: *usize, _: *const slot.Slot, _: ?*const entry.Entry) anyerror!void {}

test "a read page whose cursor does not advance is refused, not looped" {
    var hub = transport.Hub.init(test_alloc);
    defer hub.deinit(tio);
    var listener = try hub.listen(tio, test_alloc, "server");
    defer listener.close(tio);
    var dialer = try hub.dialer(test_alloc, "client");
    defer dialer.deinit();

    var group: std.Io.Group = .init;
    group.async(tio, stuckReadServer, .{&listener});

    var client = try Client.connectTransport(
        test_alloc,
        tio,
        dialer,
        "server",
        [_]u8{1} ** 16,
        [_]u8{2} ** 32,
        [_]u8{0} ** 32,
        "client",
    );
    defer client.deinit();
    _ = try client.helloAck();

    var seen: usize = 0;
    try std.testing.expectError(
        error.ProtocolError,
        client.read("events", null, false, false, &seen, ignoreRecord),
    );
    try std.testing.expectEqual(@as(usize, 0), seen);
    try group.await(tio);
}

/// Accepts one connection, answers the hello, then goes silent: the request
/// that follows is read and never answered, and the connection is held open,
/// so the client's next read has neither data nor a close.
fn silentAfterHello(listener: *transport.Listener) error{Canceled}!void {
    var conn = listener.accept(tio) catch return;
    defer conn.close(tio);
    const hello = conn.recv(tio, test_alloc) catch return;
    test_alloc.free(hello);
    sendTestMessage(&conn, .{ .hello_ack = .{
        .admitted = true,
        .refusal = .none,
        .member_id = [_]u8{7} ** 16,
        .address = "server",
        .genesis_hash = [_]u8{0} ** 32,
        .epoch = 1,
        .leader = [_]u8{7} ** 16,
    } }) catch return;
    // Reads whatever the client sends and answers none of it, until the
    // client gives up and tears the stream down.
    while (true) {
        const req = conn.recv(tio, test_alloc) catch return;
        test_alloc.free(req);
    }
}

test "a client request a live peer never answers times out over TCP" {
    // Bug 2026-08-31-client-recv-has-no-deadline: recvMessage blocked in
    // Conn.recv with no bound. Over the hub Direction supplies one; over
    // TCP - the production path - nothing did, so a peer that accepts the
    // connection and then answers nothing parked the caller forever.
    var address_buf: [32]u8 = undefined;
    var address: []const u8 = undefined;
    var listener: transport.Listener = undefined;
    // A fixed base with a linear probe, like the transport's own TCP test.
    var port: u16 = 29976;
    while (true) : (port += 1) {
        if (port > 29976 + 64) return error.NoFreeLoopbackPort;
        address = try std.fmt.bufPrint(&address_buf, "127.0.0.1:{d}", .{port});
        listener = transport.tcpListen(test_alloc, tio, address) catch continue;
        break;
    }
    defer listener.close(tio);

    var group: std.Io.Group = .init;
    group.async(tio, silentAfterHello, .{&listener});

    var client = try Client.connect(
        test_alloc,
        tio,
        address,
        [_]u8{1} ** 16,
        [_]u8{2} ** 32,
        [_]u8{0} ** 32,
        "",
    );
    defer client.deinit();
    // Pinned in milliseconds so the test costs the suite nothing; the
    // shipped default is `default_recv_timeout_ms`.
    client.recv_timeout_ms = 100;
    _ = try client.helloAck();

    try std.testing.expectError(error.Timeout, client.members());
    // Ends the silent server's read whether or not the timeout path did.
    client.conn.shutdown(tio);
    try group.await(tio);
}

/// Accepts one connection and answers the hello, then returns.
fn helloOnlyServer(listener: *transport.Listener) error{Canceled}!void {
    var conn = listener.accept(tio) catch return;
    defer conn.close(tio);
    const hello = conn.recv(tio, test_alloc) catch return;
    test_alloc.free(hello);
    sendTestMessage(&conn, .{ .hello_ack = .{
        .admitted = true,
        .refusal = .none,
        .member_id = [_]u8{5} ** 16,
        .address = "server",
        .genesis_hash = [_]u8{0} ** 32,
        .epoch = 3,
        .leader = [_]u8{5} ** 16,
    } }) catch return;
}

test "a zero recv timeout reads inline, with no bound and no task" {
    // The disabling branch of `recvBounded`, which is also the fallback when
    // the `Io` cannot run a concurrent task: the read still has to work.
    var hub = transport.Hub.init(test_alloc);
    defer hub.deinit(tio);
    var listener = try hub.listen(tio, test_alloc, "server");
    defer listener.close(tio);
    var dialer = try hub.dialer(test_alloc, "client");
    defer dialer.deinit();

    var group: std.Io.Group = .init;
    group.async(tio, helloOnlyServer, .{&listener});

    var client = try Client.connectTransport(
        test_alloc,
        tio,
        dialer,
        "server",
        [_]u8{1} ** 16,
        [_]u8{2} ** 32,
        [_]u8{0} ** 32,
        "client",
    );
    defer client.deinit();
    client.recv_timeout_ms = 0;
    const ack = try client.helloAck();
    try std.testing.expect(ack.admitted);
    try std.testing.expectEqual(@as(u64, 3), ack.epoch);
    try group.await(tio);
}

test "a journal name past the wire's u16 length cap is refused before encoding" {
    // Bug 2026-08-30-wire-name-len-unchecked: the encoders cast the name
    // length to u16 unchecked, so a name past the cap panicked in a safe
    // build and wrapped in a release one. The client refuses it cleanly.
    const long = "j" ** 65536;
    try std.testing.expectError(error.JournalNameTooLong, checkJournalName(long));
    try checkJournalName("main");
}
