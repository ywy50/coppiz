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
const net = @import("net.zig");
const message = net.message;
const transport = net.transport;

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
        transport_impl: net.transport.Transport,
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
            var off: usize = 0;
            while (off < page.records.len) {
                const rec = segment.decodeRecord(page.records[off..]) catch
                    return error.BadRecord;
                try on_record(ctx, &rec.slot, if (rec.entry) |*en| en else null);
                off += rec.next_offset;
            }
            if (page.next.epoch == 0 and page.next.seq == 0) return; // done
            std.debug.assert(slot.Position.order(page.next, position) == .gt);
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
