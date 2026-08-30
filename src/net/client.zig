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
        const body = try self.conn.recv(self.io, self.arena.allocator());
        return message.decode(self.arena.allocator(), body);
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

test "a journal name past the wire's u16 length cap is refused before encoding" {
    // Bug 2026-08-30-wire-name-len-unchecked: the encoders cast the name
    // length to u16 unchecked, so a name past the cap panicked in a safe
    // build and wrapped in a release one. The client refuses it cleanly.
    const long = "j" ** 65536;
    try std.testing.expectError(error.JournalNameTooLong, checkJournalName(long));
    try checkJournalName("main");
}
