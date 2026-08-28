//! The transport seam (PRD 0003 phase 4): where a frame goes over a socket.
//! The node loop is written against `Conn`, `Listener` and `Transport` — a
//! frame-level byte stream, an accept side, and a dial side — so a test can
//! swap the TCP sockets for the in-memory `Hub` fabric. That is the OQ 27
//! shape: the same loop code runs under the simulator's transport, and a
//! partition in a test is just a closed hub edge.
//!
//! `Conn` is frame-level: `recv` returns one whole frame body (the framing
//! lives inside each implementation, over its byte source) and `send` writes
//! one whole frame. `error.EndOfStream` from `recv` means the peer closed.

const std = @import("std");
const net = std.Io.net;
const framing = @import("framing.zig");

/// A connected byte-stream pair with framing: one frame per recv/send.
/// `close` is the sole destructor — every implementation frees itself.
pub const Conn = struct {
    ctx: *anyopaque,
    recv_frame: *const fn (
        ctx: *anyopaque,
        io: std.Io,
        allocator: std.mem.Allocator,
    ) RecvError![]u8,
    send_frame: *const fn (ctx: *anyopaque, io: std.Io, body: []const u8) SendError!void,
    shutdown_fn: *const fn (ctx: *anyopaque, io: std.Io) void,
    close_fn: *const fn (ctx: *anyopaque, io: std.Io) void,

    pub fn recv(self: *const Conn, io: std.Io, allocator: std.mem.Allocator) RecvError![]u8 {
        return self.recv_frame(self.ctx, io, allocator);
    }

    pub fn send(self: *const Conn, io: std.Io, body: []const u8) SendError!void {
        return self.send_frame(self.ctx, io, body);
    }

    /// Tears the byte stream down (waking a blocked reader) without freeing
    /// the connection; the reader's peer-gone notice is what destroys it.
    /// The loop uses this so it never frees a conn its reader is using.
    pub fn shutdown(self: *const Conn, io: std.Io) void {
        self.shutdown_fn(self.ctx, io);
    }

    /// The sole destructor; only safe once the reader task has exited.
    pub fn close(self: *const Conn, io: std.Io) void {
        self.close_fn(self.ctx, io);
    }
};

/// What a frame send may fail with (the superset of every implementation's
/// errors; a pipe send, which never fails, coerces up).
pub const SendError = error{ SendFailed, OversizedFrame } || std.Io.Writer.Error;

/// What a frame recv may fail with.
pub const RecvError = framing.ReadError;

/// The accept side of a transport. `accept` blocks until a dialer connects.
pub const Listener = struct {
    ctx: *anyopaque,
    accept_fn: *const fn (ctx: *anyopaque, io: std.Io) anyerror!Conn,
    close_fn: *const fn (ctx: *anyopaque, io: std.Io) void,

    pub fn accept(self: *const Listener, io: std.Io) anyerror!Conn {
        return self.accept_fn(self.ctx, io);
    }

    pub fn close(self: *const Listener, io: std.Io) void {
        self.close_fn(self.ctx, io);
    }
};

/// The dial side of a transport: `connect(address)` returns a connected
/// `Conn` (or a refusal). TCP parses `address` as host:port; the hub routes
/// by the same string.
pub const Transport = struct {
    ctx: *anyopaque,
    connect_fn: *const fn (
        ctx: *anyopaque,
        io: std.Io,
        allocator: std.mem.Allocator,
        address: []const u8,
    ) anyerror!Conn,
    deinit_fn: *const fn (ctx: *anyopaque) void,

    pub fn connect(
        self: *const Transport,
        io: std.Io,
        allocator: std.mem.Allocator,
        address: []const u8,
    ) anyerror!Conn {
        return self.connect_fn(self.ctx, io, allocator, address);
    }

    pub fn deinit(self: *const Transport) void {
        self.deinit_fn(self.ctx);
    }
};

// ---------------------------------------------------------------------------
// TCP
// ---------------------------------------------------------------------------

/// A connected TCP stream. Owned by whoever accepted or dialed it; `close`
/// frees it.
pub const TcpConn = struct {
    allocator: std.mem.Allocator,
    stream: net.Stream,
    closed: bool = false,

    fn recvFrame(ctx: *anyopaque, io: std.Io, allocator: std.mem.Allocator) framing.ReadError![]u8 {
        const self: *TcpConn = @ptrCast(@alignCast(ctx));
        var buf: [4096]u8 = undefined;
        var reader = self.stream.reader(io, &buf);
        return framing.readFrame(allocator, &reader.interface);
    }

    fn sendFrame(ctx: *anyopaque, io: std.Io, body: []const u8) !void {
        const self: *TcpConn = @ptrCast(@alignCast(ctx));
        var buf: [4096]u8 = undefined;
        var writer = self.stream.writer(io, &buf);
        try framing.writeFrame(&writer.interface, body);
        // The stream writer buffers; without the flush a small frame never
        // leaves the stack buffer (the hub's send is unbuffered, which is
        // why only the TCP path needed this).
        try writer.interface.flush();
    }

    fn closeFn(ctx: *anyopaque, io: std.Io) void {
        const self: *TcpConn = @ptrCast(@alignCast(ctx));
        if (self.closed) return;
        self.closed = true;
        self.stream.close(io);
        self.allocator.destroy(self);
    }

    fn shutdownFn(ctx: *anyopaque, io: std.Io) void {
        const self: *TcpConn = @ptrCast(@alignCast(ctx));
        self.stream.shutdown(io, .both) catch {};
    }

    pub fn conn(self: *TcpConn) Conn {
        return .{
            .ctx = self,
            .recv_frame = recvFrame,
            .send_frame = sendFrame,
            .shutdown_fn = shutdownFn,
            .close_fn = closeFn,
        };
    }
};

/// A listening TCP socket. Owned by the loop; `close` frees it.
pub const TcpListener = struct {
    allocator: std.mem.Allocator,
    server: net.Server,
    closed: bool = false,

    fn acceptFn(ctx: *anyopaque, io: std.Io) !Conn {
        const self: *TcpListener = @ptrCast(@alignCast(ctx));
        const stream = try self.server.accept(io);
        const conn = try self.allocator.create(TcpConn);
        errdefer self.allocator.destroy(conn);
        conn.* = .{ .allocator = self.allocator, .stream = stream };
        return conn.conn();
    }

    fn closeFn(ctx: *anyopaque, io: std.Io) void {
        const self: *TcpListener = @ptrCast(@alignCast(ctx));
        if (self.closed) return;
        self.closed = true;
        self.server.deinit(io);
        self.allocator.destroy(self);
    }

    pub fn listener(self: *TcpListener) Listener {
        return .{ .ctx = self, .accept_fn = acceptFn, .close_fn = closeFn };
    }
};

/// Dial-side TCP: `connect` parses host:port and dials.
pub const TcpTransport = struct {
    allocator: std.mem.Allocator,

    fn connectFn(
        ctx: *anyopaque,
        io: std.Io,
        allocator: std.mem.Allocator,
        address: []const u8,
    ) !Conn {
        const self: *const TcpTransport = @ptrCast(@alignCast(ctx));
        _ = self;
        const addr = try net.IpAddress.parseLiteral(address);
        const stream = try addr.connect(io, .{ .mode = .stream });
        const conn = try allocator.create(TcpConn);
        errdefer allocator.destroy(conn);
        conn.* = .{ .allocator = allocator, .stream = stream };
        return conn.conn();
    }

    fn deinitFn(_: *anyopaque) void {}

    pub fn transport(self: *const TcpTransport) Transport {
        return .{
            .ctx = @constCast(self),
            .connect_fn = connectFn,
            .deinit_fn = deinitFn,
        };
    }
};

/// Listens on `listen` (host:port), returning the accept side.
pub fn tcpListen(
    allocator: std.mem.Allocator,
    io: std.Io,
    listen: []const u8,
) !Listener {
    const addr = try net.IpAddress.parseLiteral(listen);
    // SO_REUSEADDR: a crashed serve's TIME_WAIT socket must not block the
    // restart (process-level tests restart servers on the same port).
    const server = try addr.listen(io, .{ .mode = .stream, .reuse_address = true });
    const l = try allocator.create(TcpListener);
    errdefer allocator.destroy(l);
    l.* = .{ .allocator = allocator, .server = server };
    return l.listener();
}

// ---------------------------------------------------------------------------
// In-memory hub (tests and the simulator's transport)
// ---------------------------------------------------------------------------

/// One direction of a hub pipe: an ordered queue of frame bodies. `recv`
/// pops them; `send` (from the peer) appends. A `close` wakes the reader
/// with EndOfStream and later sends are discarded.
pub const Direction = struct {
    allocator: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    sem: std.Io.Semaphore = .{},
    chunks: std.ArrayListUnmanaged([]u8) = .empty,
    closed: bool = false,

    pub fn deinit(self: *Direction) void {
        for (self.chunks.items) |chunk| self.allocator.free(chunk);
        self.chunks.deinit(self.allocator);
    }

    /// Pushes a body, copying it into the hub's memory. No-op once closed.
    pub fn push(self: *Direction, io: std.Io, body: []const u8) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.closed) return;
        const copy = self.allocator.dupe(u8, body) catch return;
        self.chunks.append(self.allocator, copy) catch {
            self.allocator.free(copy);
            return;
        };
        self.sem.post(io);
    }

    pub fn close(self: *Direction, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.closed) return;
        self.closed = true;
        self.sem.post(io);
    }

    /// Reads up to `dest.len` bytes, blocking until data or a close. Returns
    /// 0 on a clean close with nothing left.
    pub fn readInto(self: *Direction, io: std.Io, dest: []u8) !usize {
        while (true) {
            self.mutex.lockUncancelable(io);
            if (self.chunks.items.len > 0) {
                const chunk = self.chunks.items[0];
                const n = @min(chunk.len, dest.len);
                @memcpy(dest[0..n], chunk[0..n]);
                if (n == chunk.len) {
                    const taken = self.chunks.orderedRemove(0);
                    self.mutex.unlock(io);
                    self.allocator.free(taken);
                    // An empty frame body (a legal zero-length frame) is
                    // data, not a close: keep reading instead of returning 0.
                    if (n == 0) continue;
                } else {
                    // A partial read must not store an interior slice of the
                    // allocation: a later full read would free it. Re-base
                    // the remainder into its own allocation first.
                    const remainder = self.allocator.dupe(u8, chunk[n..]) catch {
                        self.mutex.unlock(io);
                        return error.OutOfMemory;
                    };
                    self.allocator.free(chunk);
                    self.chunks.items[0] = remainder;
                    self.mutex.unlock(io);
                }
                return n;
            }
            const closed = self.closed;
            self.mutex.unlock(io);
            if (closed) return 0;
            try self.sem.wait(io);
        }
    }
};

/// A hub pipe between a dialer and an endpoint. `out` carries dialer ->
/// endpoint data, `in` the reverse; both are owned by the hub and freed at
/// its deinit.
pub const Pipe = struct {
    out: Direction,
    in: Direction,
    /// The edge this pipe serves (owned by the hub), for `drop` to find it.
    from: []const u8,
    to: []const u8,
};

/// A `Conn` whose bytes travel through hub-owned directions.
pub const PipeConn = struct {
    allocator: std.mem.Allocator,
    in: *Direction,
    out: *Direction,
    closed: bool = false,

    fn recvFrame(ctx: *anyopaque, io: std.Io, allocator: std.mem.Allocator) framing.ReadError![]u8 {
        const self: *PipeConn = @ptrCast(@alignCast(ctx));
        var header: [framing.len_bytes]u8 = undefined;
        var n = self.in.readInto(io, &header) catch return error.ReadFailed;
        if (n == 0) return error.EndOfStream;
        while (n < framing.len_bytes) {
            const more = self.in.readInto(io, header[n..]) catch return error.ReadFailed;
            if (more == 0) return error.EndOfStream;
            n += more;
        }
        const len = std.mem.readInt(u32, &header, .little);
        if (len > framing.max_body_bytes) return error.OversizedFrame;
        const body = try allocator.alloc(u8, len);
        var got: usize = 0;
        while (got < len) {
            const more = self.in.readInto(io, body[got..]) catch {
                allocator.free(body);
                return error.ReadFailed;
            };
            if (more == 0) {
                allocator.free(body);
                return error.EndOfStream;
            }
            got += more;
        }
        return body;
    }

    fn sendFrame(ctx: *anyopaque, io: std.Io, body: []const u8) !void {
        const self: *PipeConn = @ptrCast(@alignCast(ctx));
        if (body.len > framing.max_body_bytes) return error.OversizedFrame;
        var header: [framing.len_bytes]u8 = undefined;
        std.mem.writeInt(u32, &header, @intCast(body.len), .little);
        self.out.push(io, &header);
        self.out.push(io, body);
    }

    fn shutdownFn(ctx: *anyopaque, io: std.Io) void {
        const self: *PipeConn = @ptrCast(@alignCast(ctx));
        // Close the directions (the reader wakes with EOF) without freeing.
        self.in.close(io);
        self.out.close(io);
    }

    fn closeFn(ctx: *anyopaque, io: std.Io) void {
        const self: *PipeConn = @ptrCast(@alignCast(ctx));
        if (self.closed) return;
        self.closed = true;
        self.in.close(io);
        self.out.close(io);
        self.allocator.destroy(self);
    }

    pub fn conn(self: *PipeConn) Conn {
        return .{
            .ctx = self,
            .recv_frame = recvFrame,
            .send_frame = sendFrame,
            .shutdown_fn = shutdownFn,
            .close_fn = closeFn,
        };
    }
};

/// The in-memory fabric: nodes listen by name, dial each other by name, and
/// `drop` closes one directed edge (a partition) until `heal` reopens it.
/// Owns every pipe it creates; `deinit` frees them. Connection objects are
/// freed by their own `Conn.close`.
pub const Hub = struct {
    allocator: std.mem.Allocator,
    /// address -> pending-connection queue of an endpoint.
    endpoints: std.StringHashMapUnmanaged(*Endpoint) = .empty,
    /// Directed edges currently partitioned, keyed "from\x00to".
    dropped: std.StringHashMapUnmanaged(void) = .empty,
    pipes: std.ArrayListUnmanaged(*Pipe) = .empty,

    pub const Endpoint = struct {
        allocator: std.mem.Allocator,
        mutex: std.Io.Mutex = .init,
        sem: std.Io.Semaphore = .{},
        pending: std.ArrayListUnmanaged(Conn) = .empty,
        closed: bool = false,

        pub fn deinit(self: *Endpoint, io: std.Io) void {
            // Unaccepted connections are closed, never leaked: a dial that
            // landed while the listener was closing has nobody to accept it.
            for (self.pending.items) |conn| conn.close(io);
            self.pending.deinit(self.allocator);
        }

        fn pushConn(self: *Endpoint, io: std.Io, conn: Conn) void {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            if (self.closed) {
                // Nobody will ever accept this dial; closing frees the
                // connection (and wakes the dialer's reader with EOF).
                conn.close(io);
                return;
            }
            self.pending.append(self.allocator, conn) catch {
                conn.close(io);
                return;
            };
            self.sem.post(io);
        }

        fn acceptConn(self: *Endpoint, io: std.Io) !Conn {
            while (true) {
                self.mutex.lockUncancelable(io);
                if (self.pending.items.len > 0) {
                    const conn = self.pending.orderedRemove(0);
                    self.mutex.unlock(io);
                    return conn;
                }
                const closed = self.closed;
                self.mutex.unlock(io);
                if (closed) return error.ConnectionRefused;
                try self.sem.wait(io);
            }
        }
    };

    pub fn init(allocator: std.mem.Allocator) Hub {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Hub, io: std.Io) void {
        var it = self.endpoints.iterator();
        while (it.next()) |kv| {
            kv.value_ptr.*.deinit(io);
            self.allocator.destroy(kv.value_ptr.*);
            self.allocator.free(kv.key_ptr.*);
        }
        self.endpoints.deinit(self.allocator);
        var dit = self.dropped.keyIterator();
        while (dit.next()) |key| self.allocator.free(key.*);
        self.dropped.deinit(self.allocator);
        for (self.pipes.items) |pipe| {
            pipe.out.deinit();
            pipe.in.deinit();
            self.allocator.free(pipe.from);
            self.allocator.free(pipe.to);
            self.allocator.destroy(pipe);
        }
        self.pipes.deinit(self.allocator);
        self.* = undefined;
    }

    /// Registers `address` as a listenable endpoint. One listener per
    /// address; a second registration is refused with `AddressInUse` (a
    /// `put` overwrite would leak the first endpoint and orphan its
    /// listener).
    pub fn listen(self: *Hub, allocator: std.mem.Allocator, address: []const u8) !Listener {
        if (self.endpoints.contains(address)) return error.AddressInUse;
        const ep = try allocator.create(Endpoint);
        errdefer allocator.destroy(ep);
        ep.* = .{ .allocator = allocator };
        const l = try allocator.create(HubListener);
        errdefer allocator.destroy(l);
        const l_address = try allocator.dupe(u8, address);
        errdefer allocator.free(l_address);
        l.* = .{
            .hub = self,
            .address = l_address,
            .endpoint = ep,
        };
        const key = try allocator.dupe(u8, address);
        errdefer allocator.free(key);
        // Last fallible step: once the map owns `ep` no errdefer above may
        // fire, or `Hub.deinit` would destroy an endpoint already freed.
        try self.endpoints.put(allocator, key, ep);
        return .{
            .ctx = l,
            .accept_fn = HubListener.acceptFn,
            .close_fn = HubListener.closeFn,
        };
    }

    fn edgeKey(allocator: std.mem.Allocator, from: []const u8, to: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}\x00{s}", .{ from, to });
    }

    /// The dial side bound to `from`: connects to any endpoint by name.
    pub fn dialer(self: *Hub, allocator: std.mem.Allocator, from: []const u8) !Transport {
        const d = try allocator.create(HubDialer);
        errdefer allocator.destroy(d);
        const from_dup = try allocator.dupe(u8, from);
        d.* = .{ .hub = self, .from = from_dup };
        return .{
            .ctx = d,
            .connect_fn = HubDialer.connectFn,
            .deinit_fn = HubDialer.deinitFn,
        };
    }

    /// Partitions the directed edge `from -> to`: live connections on it get
    /// their `from -> to` direction closed (the reader wakes with
    /// EndOfStream) and new dials are refused until `heal`. Only the named
    /// direction is affected; a symmetric partition drops both ways.
    pub fn drop(
        self: *Hub,
        allocator: std.mem.Allocator,
        io: std.Io,
        from: []const u8,
        to: []const u8,
    ) !void {
        const key = try edgeKey(allocator, from, to);
        // The map owns the key (freed at deinit); it is never freed here.
        try self.dropped.put(allocator, key, {});
        for (self.pipes.items) |pipe| {
            // A pipe's `out` carries dialer -> endpoint; `in` the reverse.
            // The named sender decides which direction closes.
            if (std.mem.eql(u8, pipe.from, from) and std.mem.eql(u8, pipe.to, to)) {
                pipe.out.close(io);
            } else if (std.mem.eql(u8, pipe.to, from) and std.mem.eql(u8, pipe.from, to)) {
                pipe.in.close(io);
            }
        }
    }

    pub fn heal(self: *Hub, allocator: std.mem.Allocator, from: []const u8, to: []const u8) !void {
        const key = try edgeKey(allocator, from, to);
        defer allocator.free(key);
        // remove() hands the stored key back; the map no longer owns it.
        if (self.dropped.fetchRemove(key)) |removed| self.allocator.free(removed.key);
    }

    pub fn isDropped(self: *Hub, from: []const u8, to: []const u8) bool {
        var buf: [512]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "{s}\x00{s}", .{ from, to }) catch return false;
        return self.dropped.contains(key);
    }
};

const HubListener = struct {
    hub: *Hub,
    address: []const u8,
    endpoint: *Hub.Endpoint,
    closed: bool = false,

    fn acceptFn(ctx: *anyopaque, io: std.Io) !Conn {
        const self: *HubListener = @ptrCast(@alignCast(ctx));
        return self.endpoint.acceptConn(io);
    }

    fn closeFn(ctx: *anyopaque, io: std.Io) void {
        const self: *HubListener = @ptrCast(@alignCast(ctx));
        if (self.closed) return;
        self.closed = true;
        // `closed` is read under the endpoint mutex by pushConn and
        // acceptConn; a close racing an accept/dial must not be a data race.
        // Capture the mutex before `self` is destroyed below.
        const ep_mutex = &self.endpoint.mutex;
        ep_mutex.lockUncancelable(io);
        defer ep_mutex.unlock(io);
        self.endpoint.closed = true;
        self.endpoint.sem.post(io);
        self.hub.allocator.free(self.address);
        self.hub.allocator.destroy(self);
    }
};

const HubDialer = struct {
    hub: *Hub,
    from: []const u8,

    fn connectFn(
        ctx: *anyopaque,
        io: std.Io,
        allocator: std.mem.Allocator,
        to: []const u8,
    ) !Conn {
        const self: *HubDialer = @ptrCast(@alignCast(ctx));
        if (self.hub.isDropped(self.from, to)) return error.ConnectionRefused;
        const ep = self.hub.endpoints.get(to) orelse return error.ConnectionRefused;
        const hub_alloc = self.hub.allocator;
        const pipe = try hub_alloc.create(Pipe);
        errdefer hub_alloc.destroy(pipe);
        const from = try hub_alloc.dupe(u8, self.from);
        errdefer hub_alloc.free(from);
        const to_dup = try hub_alloc.dupe(u8, to);
        errdefer hub_alloc.free(to_dup);
        pipe.* = .{
            .out = .{ .allocator = hub_alloc },
            .in = .{ .allocator = hub_alloc },
            .from = from,
            .to = to_dup,
        };
        errdefer {
            pipe.out.deinit();
            pipe.in.deinit();
        }

        const from_conn = try hub_alloc.create(PipeConn);
        errdefer hub_alloc.destroy(from_conn);
        from_conn.* = .{
            .allocator = hub_alloc,
            .in = &pipe.in,
            .out = &pipe.out,
        };
        const to_conn = try hub_alloc.create(PipeConn);
        errdefer hub_alloc.destroy(to_conn);
        to_conn.* = .{
            .allocator = hub_alloc,
            .in = &pipe.out,
            .out = &pipe.in,
        };
        // Last fallible step: the errdefers above free the pipe, so the hub
        // must not own it until nothing can still fail.
        try self.hub.pipes.append(hub_alloc, pipe);
        ep.pushConn(io, to_conn.conn());
        _ = allocator; // connections are hub-owned; the caller's allocator is unused
        return from_conn.conn();
    }

    fn deinitFn(ctx: *anyopaque) void {
        const self: *HubDialer = @ptrCast(@alignCast(ctx));
        self.hub.allocator.free(self.from);
        self.hub.allocator.destroy(self);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const test_alloc = std.testing.allocator;
const tio = std.testing.io;

test "hub connect delivers frames both ways" {
    var hub = Hub.init(test_alloc);
    defer hub.deinit(tio);
    var listener = try hub.listen(test_alloc, "node-a");
    defer listener.close(tio);
    var dialer = try hub.dialer(test_alloc, "node-b");
    defer dialer.deinit();

    // The accept side runs as a task; the dialer sends first.
    var group: std.Io.Group = .init;
    group.async(tio, acceptAndEcho, .{&listener});
    const conn = try dialer.connect(tio, test_alloc, "node-a");
    defer conn.close(tio);

    try conn.send(tio, "ping");
    const reply = try conn.recv(tio, test_alloc);
    defer test_alloc.free(reply);
    try std.testing.expectEqualStrings("pong", reply);
    try group.await(tio);
}

fn acceptAndEcho(listener: *Listener) error{Canceled}!void {
    var conn = listener.accept(tio) catch return;
    defer conn.close(tio);
    const body = conn.recv(tio, test_alloc) catch return;
    defer test_alloc.free(body);
    conn.send(tio, "pong") catch {};
}

fn acceptEchoThenExpectEof(listener: *Listener) error{Canceled}!void {
    var conn = listener.accept(tio) catch return;
    defer conn.close(tio);
    const body = conn.recv(tio, test_alloc) catch return;
    defer test_alloc.free(body);
    conn.send(tio, "pong") catch {};
    if (conn.recv(tio, test_alloc)) |extra| {
        test_alloc.free(extra);
        @panic("drop did not end the live connection: recv returned data");
    } else |err| if (err != error.EndOfStream) {
        @panic("drop did not end the live connection with EndOfStream");
    }
}

test "a dropped edge refuses dials and ends live connections" {
    var hub = Hub.init(test_alloc);
    defer hub.deinit(tio);
    var listener = try hub.listen(test_alloc, "node-a");
    defer listener.close(tio);
    var dialer = try hub.dialer(test_alloc, "node-b");
    defer dialer.deinit();

    // The first connection works end to end; the accept side then blocks on
    // a second recv, which the drop below must end with EndOfStream.
    var group: std.Io.Group = .init;
    group.async(tio, acceptEchoThenExpectEof, .{&listener});
    var conn = try dialer.connect(tio, test_alloc, "node-a");
    defer conn.close(tio);
    try conn.send(tio, "ping");
    const reply = try conn.recv(tio, test_alloc);
    defer test_alloc.free(reply);
    try std.testing.expectEqualStrings("pong", reply);

    // Dropping the edge ends the live connection and refuses new dials.
    try hub.drop(test_alloc, tio, "node-b", "node-a");
    try group.await(tio);
    try std.testing.expectError(
        error.ConnectionRefused,
        dialer.connect(tio, test_alloc, "node-a"),
    );

    // Heal reopens the edge and a fresh connection works.
    try hub.heal(test_alloc, "node-b", "node-a");
    var group2: std.Io.Group = .init;
    group2.async(tio, acceptAndEcho, .{&listener});
    var conn2 = try dialer.connect(tio, test_alloc, "node-a");
    defer conn2.close(tio);
    try conn2.send(tio, "ping");
    const reply2 = try conn2.recv(tio, test_alloc);
    defer test_alloc.free(reply2);
    try std.testing.expectEqualStrings("pong", reply2);
    try group2.await(tio);
}

test "hub send refuses an oversized frame" {
    var hub = Hub.init(test_alloc);
    defer hub.deinit(tio);
    var listener = try hub.listen(test_alloc, "node-a");
    defer listener.close(tio);
    var dialer = try hub.dialer(test_alloc, "node-b");
    defer dialer.deinit();

    var group: std.Io.Group = .init;
    group.async(tio, acceptAndClose, .{&listener});
    var conn = try dialer.connect(tio, test_alloc, "node-a");
    defer conn.close(tio);
    try group.await(tio);
    const too_big = try test_alloc.alloc(u8, framing.max_body_bytes + 1);
    defer test_alloc.free(too_big);
    @memset(too_big, 0);
    try std.testing.expectError(error.OversizedFrame, conn.send(tio, too_big));
}

test "pipe reader returns EndOfStream when the peer closes" {
    var hub = Hub.init(test_alloc);
    defer hub.deinit(tio);
    var listener = try hub.listen(test_alloc, "node-a");
    defer listener.close(tio);
    var dialer = try hub.dialer(test_alloc, "node-b");
    defer dialer.deinit();

    var group: std.Io.Group = .init;
    group.async(tio, acceptAndClose, .{&listener});
    var conn = try dialer.connect(tio, test_alloc, "node-a");
    defer conn.close(tio);
    try group.await(tio);
    try std.testing.expectError(error.EndOfStream, conn.recv(tio, test_alloc));
}

fn acceptAndClose(listener: *Listener) error{Canceled}!void {
    var conn = listener.accept(tio) catch return;
    conn.close(tio);
}

test "hub listen refuses a duplicate address" {
    var hub = Hub.init(test_alloc);
    defer hub.deinit(tio);
    var l1 = try hub.listen(test_alloc, "node-a");
    defer l1.close(tio);
    try std.testing.expectError(error.AddressInUse, hub.listen(test_alloc, "node-a"));

    // The first listener is untouched: it still accepts and echoes.
    var dialer = try hub.dialer(test_alloc, "node-b");
    defer dialer.deinit();
    var group: std.Io.Group = .init;
    group.async(tio, acceptAndEcho, .{&l1});
    var conn = try dialer.connect(tio, test_alloc, "node-a");
    defer conn.close(tio);
    try conn.send(tio, "ping");
    const reply = try conn.recv(tio, test_alloc);
    defer test_alloc.free(reply);
    try std.testing.expectEqualStrings("pong", reply);
    try group.await(tio);
}

/// One full hub lifecycle under an allocator that fails at a chosen
/// allocation: init, listen, dial (with the accept side closing any conn
/// that gets through), teardown. Every path must be free of leaks and
/// double-frees — the GPA backing this allocator panics on either.
fn hubRound(failing: std.mem.Allocator) !void {
    var hub = Hub.init(failing);
    defer hub.deinit(tio);
    var listener = try hub.listen(failing, "node-a");
    var group: std.Io.Group = .init;
    group.async(tio, acceptAndClose, .{&listener});
    defer {
        // Closing the listener wakes the blocked accept with a refusal.
        listener.close(tio);
        group.await(tio) catch {};
    }
    var dialer = try hub.dialer(failing, "node-b");
    defer dialer.deinit();
    if (dialer.connect(tio, failing, "node-a")) |conn| {
        conn.close(tio);
    } else |_| {}
}

test "hub connect and listen never double-free on allocation failure" {
    // Fail one allocation at a time until a round succeeds. Before the fix
    // a failure after the pipe entered hub.pipes freed it twice at deinit.
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        var failing = std.testing.FailingAllocator.init(test_alloc, .{ .fail_index = i });
        if (hubRound(failing.allocator())) |_| break else |_| {}
    }
}

test "a partial read leaves a freeable remainder" {
    var dir = Direction{ .allocator = test_alloc };
    defer dir.deinit();
    dir.push(tio, "hello");
    var first: [4]u8 = undefined;
    var second: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), try dir.readInto(tio, &first));
    try std.testing.expectEqualStrings("hell", &first);
    // The remainder was re-based into its own allocation; freeing it here
    // must not free an interior pointer of the original chunk.
    try std.testing.expectEqual(@as(usize, 1), try dir.readInto(tio, &second));
    try std.testing.expectEqualStrings("o", second[0..1]);
}

test "an empty pushed body is data, not a close" {
    var dir = Direction{ .allocator = test_alloc };
    defer dir.deinit();
    // A zero-length frame body is legal on the wire (framing.zig); reading
    // it must consume it and continue, not report a close.
    dir.push(tio, "");
    dir.push(tio, "abc");
    var buf: [3]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 3), try dir.readInto(tio, &buf));
    try std.testing.expectEqualStrings("abc", &buf);
}
