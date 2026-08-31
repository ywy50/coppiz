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

    /// The sole destructor; only safe once the reader task has exited, and
    /// safe exactly once. It frees the connection, so a second call is a
    /// use-after-free rather than a no-op - a `closed` flag on the
    /// connection cannot say otherwise, because the flag is inside what the
    /// first call freed (bug 2026-08-29-close-guard-in-freed-allocation).
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

    /// The sole destructor, and safe exactly once: it frees the listener.
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
    /// The read buffer and the reader over it belong to the connection, not
    /// to one `recvFrame` call. A socket read is greedy: `Stream.Reader`
    /// hands the kernel both the caller's slice and its own buffer, and
    /// keeps whatever came back beyond what was asked for
    /// (`std.Io.net`'s `readVec`: `if (n > data_size) r.interface.end +=
    /// n - data_size`). TCP coalesces frames freely - the leader's tick
    /// sends a heartbeat and a slot broadcast back to back - so those extra
    /// bytes are routinely the start of the next frame. A per-call stack
    /// buffer threw them away *after* they had already been consumed from
    /// the socket: a whole frame lost is silent replication loss, and half a
    /// frame lost desynchronizes the stream, because the next read takes
    /// four arbitrary body bytes for a length prefix (bug
    /// 2026-08-29-tcp-recvframe-drops-buffered-bytes).
    ///
    /// `TcpConn` is always heap-allocated, so `read_buf`'s address is
    /// stable for the reader that points into it. The reader is built on
    /// first use because that is the first call that has an `Io`.
    read_buf: [4096]u8 = undefined,
    reader: ?net.Stream.Reader = null,

    fn recvFrame(ctx: *anyopaque, io: std.Io, allocator: std.mem.Allocator) framing.ReadError![]u8 {
        const self: *TcpConn = @ptrCast(@alignCast(ctx));
        if (self.reader == null) self.reader = self.stream.reader(io, &self.read_buf);
        return framing.readFrame(allocator, &self.reader.?.interface);
    }

    fn sendFrame(ctx: *anyopaque, io: std.Io, body: []const u8) !void {
        const self: *TcpConn = @ptrCast(@alignCast(ctx));
        // Keeps page-sized frames (sync/read) to a few large sends rather
        // than many small ones. A single frame's stack use is short-lived.
        var buf: [64 * 1024]u8 = undefined;
        var writer = self.stream.writer(io, &buf);
        try framing.writeFrame(&writer.interface, body);
        // The stream writer buffers; without the flush a small frame never
        // leaves the stack buffer (the hub's send is unbuffered, which is
        // why only the TCP path needed this).
        try writer.interface.flush();
    }

    /// Called exactly once; see `Conn.close`. The `closed` flag that used
    /// to guard this lived in the allocation the next line frees, so a
    /// second call read it back out of freed memory (bug
    /// 2026-08-29-close-guard-in-freed-allocation).
    fn closeFn(ctx: *anyopaque, io: std.Io) void {
        const self: *TcpConn = @ptrCast(@alignCast(ctx));
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

    fn acceptFn(ctx: *anyopaque, io: std.Io) !Conn {
        const self: *TcpListener = @ptrCast(@alignCast(ctx));
        const stream = try self.server.accept(io);
        // A failed TcpConn allocation must not leak the OS socket (bug
        // 2026-08-29-tcp-conn-fd-leak-on-oom).
        errdefer stream.close(io);
        const conn = try self.allocator.create(TcpConn);
        errdefer self.allocator.destroy(conn);
        conn.* = .{ .allocator = self.allocator, .stream = stream };
        return conn.conn();
    }

    /// Called exactly once; see `Listener.close`.
    fn closeFn(ctx: *anyopaque, io: std.Io) void {
        const self: *TcpListener = @ptrCast(@alignCast(ctx));
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
        // A failed TcpConn allocation must not leak the OS socket (bug
        // 2026-08-29-tcp-conn-fd-leak-on-oom).
        errdefer stream.close(io);
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
    var server = try addr.listen(io, .{ .mode = .stream, .reuse_address = true });
    // A create failure must not leak the listening socket (the same class
    // as bug 2026-08-29-tcp-conn-fd-leak-on-oom, which fixed the dial and
    // accept sides but missed listen).
    errdefer server.deinit(io);
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

    /// Pushes a header immediately followed by a body as one chunk: one
    /// lock, one copy, one sem post, where two `push` calls would each pay
    /// all three. The reader already handles a combined chunk (a partial
    /// `readInto` re-bases the remainder).
    pub fn pushFramed(self: *Direction, io: std.Io, header: []const u8, body: []const u8) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.closed) return;
        const copy = self.allocator.alloc(u8, header.len + body.len) catch return;
        @memcpy(copy[0..header.len], header);
        @memcpy(copy[header.len..], body);
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
        self.out.pushFramed(io, &header, body);
    }

    fn shutdownFn(ctx: *anyopaque, io: std.Io) void {
        const self: *PipeConn = @ptrCast(@alignCast(ctx));
        // Close the directions (the reader wakes with EOF) without freeing.
        self.in.close(io);
        self.out.close(io);
    }

    /// Called exactly once; see `Conn.close`. The directions themselves
    /// are hub-owned and their own `closed` flags do survive, so closing
    /// them twice (via `shutdown` then `close`) stays a no-op.
    fn closeFn(ctx: *anyopaque, io: std.Io) void {
        const self: *PipeConn = @ptrCast(@alignCast(ctx));
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
    /// Guards `endpoints`, `dropped` and `pipes`. Every node dials from its
    /// own `dialMain` task, so `HubDialer.connectFn` runs concurrently with
    /// itself and with `listen`, `drop` and `heal` from the test thread.
    /// Two unsynchronised `pipes.append` calls that both grow each allocate
    /// a backing buffer and then write `items.ptr`; the second write wins
    /// and the first buffer has no owner left, which is the one leaked
    /// allocation of bug 2026-08-29-hub-pipes-append-unsynchronised. The
    /// two hash maps are the same class of race and are covered by the same
    /// lock. `Endpoint` keeps its own mutex for `pending`; this one is
    /// never held across an `Endpoint` call.
    mutex: std.Io.Mutex = .init,
    /// address -> pending-connection queue of an endpoint.
    endpoints: std.StringHashMapUnmanaged(*Endpoint) = .empty,
    /// Directed edges currently partitioned, keyed "from\x00to".
    dropped: std.StringHashMapUnmanaged(void) = .empty,
    pipes: std.ArrayListUnmanaged(*Pipe) = .empty,
    /// Endpoints whose listener has closed. They leave `endpoints` so the
    /// address can be listened on again, but they are not destroyed there:
    /// `connectFn` releases the hub lock before calling `pushConn`, so a
    /// dial that looked one up a moment earlier may still be inside it.
    /// The hub outlives every dial, so it frees them at `deinit`.
    retired: std.ArrayListUnmanaged(*Endpoint) = .empty,

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
        for (self.retired.items) |ep| {
            ep.deinit(io);
            self.allocator.destroy(ep);
        }
        self.retired.deinit(self.allocator);
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
    pub fn listen(
        self: *Hub,
        io: std.Io,
        allocator: std.mem.Allocator,
        address: []const u8,
    ) !Listener {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
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
        // `put` keeps the key the map already holds, so a second drop of the
        // same edge would hand its fresh key to nobody and leak it. Probe
        // first with a borrowed key, and only allocate an owned one when the
        // edge is not already dropped. The owned key is the hub's, since
        // `heal` and `deinit` are what free it.
        const probe = try edgeKey(allocator, from, to);
        defer allocator.free(probe);
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (!self.dropped.contains(probe)) {
            const key = try self.allocator.dupe(u8, probe);
            errdefer self.allocator.free(key);
            try self.dropped.put(self.allocator, key, {});
        }
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

    pub fn heal(
        self: *Hub,
        io: std.Io,
        allocator: std.mem.Allocator,
        from: []const u8,
        to: []const u8,
    ) !void {
        const key = try edgeKey(allocator, from, to);
        defer allocator.free(key);
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        // remove() hands the stored key back; the map no longer owns it.
        if (self.dropped.fetchRemove(key)) |removed| self.allocator.free(removed.key);
    }

    pub fn isDropped(self: *Hub, io: std.Io, from: []const u8, to: []const u8) bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.isDroppedLocked(from, to);
    }

    /// `isDropped` for a caller that already holds the hub lock; the mutex
    /// is not recursive, so `connectFn` cannot go through the public one.
    /// The key must match `edgeKey` (the drop side) byte for byte: a fixed
    /// stack buffer would overflow to "not dropped" for long address pairs,
    /// silently letting dials through a partitioned edge (bug
    /// 2026-08-30-hub-dropped-edge-long-address).
    fn isDroppedLocked(self: *Hub, from: []const u8, to: []const u8) bool {
        const key = std.fmt.allocPrint(self.allocator, "{s}\x00{s}", .{ from, to }) catch
            return false;
        defer self.allocator.free(key);
        return self.dropped.contains(key);
    }
};

const HubListener = struct {
    hub: *Hub,
    address: []const u8,
    endpoint: *Hub.Endpoint,

    fn acceptFn(ctx: *anyopaque, io: std.Io) !Conn {
        const self: *HubListener = @ptrCast(@alignCast(ctx));
        return self.endpoint.acceptConn(io);
    }

    /// Called exactly once; see `Listener.close`.
    fn closeFn(ctx: *anyopaque, io: std.Io) void {
        const self: *HubListener = @ptrCast(@alignCast(ctx));
        // Unregister first, so the address can be listened on again — a
        // node restarting in the fabric re-listens on the address it had,
        // and leaving the entry behind answered that with `AddressInUse`
        // for the life of the hub. The endpoint is retired rather than
        // destroyed: a dial that looked it up before the removal may still
        // be inside `pushConn`, which runs without the hub lock.
        retire: {
            self.hub.mutex.lockUncancelable(io);
            defer self.hub.mutex.unlock(io);
            const e = self.hub.endpoints.getEntry(self.address) orelse break :retire;
            const key = e.key_ptr.*;
            // Take the retirement slot before unregistering. If it cannot
            // be taken the endpoint stays in the map, owned by it, and the
            // address stays taken — the behaviour before this change, and
            // better than an endpoint owned by nothing.
            self.hub.retired.append(self.hub.allocator, e.value_ptr.*) catch break :retire;
            _ = self.hub.endpoints.remove(self.address);
            self.hub.allocator.free(key);
        }
        // The endpoint's `closed` is read under the endpoint mutex by pushConn and
        // acceptConn; a close racing an accept/dial must not be a data race.
        // Capture the mutex before `self` is destroyed below. The hub lock is
        // released above: it is never held across an `Endpoint` call.
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
        // One critical section covers the drop check, the endpoint lookup
        // and the `pipes` append: concurrent dials otherwise race the array
        // list's growth and orphan one of the two backing buffers (bug
        // 2026-08-29-hub-pipes-append-unsynchronised). It is released before
        // `ep.pushConn`, which takes the endpoint's own mutex - the hub lock
        // is never held across an `Endpoint` call.
        self.hub.mutex.lockUncancelable(io);
        var hub_locked = true;
        errdefer if (hub_locked) self.hub.mutex.unlock(io);
        if (self.hub.isDroppedLocked(self.from, to)) {
            self.hub.mutex.unlock(io);
            hub_locked = false;
            return error.ConnectionRefused;
        }
        const ep = self.hub.endpoints.get(to) orelse {
            self.hub.mutex.unlock(io);
            hub_locked = false;
            return error.ConnectionRefused;
        };
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
        self.hub.mutex.unlock(io);
        hub_locked = false;
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
    var listener = try hub.listen(tio, test_alloc, "node-a");
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
    var listener = try hub.listen(tio, test_alloc, "node-a");
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
    try hub.heal(tio, test_alloc, "node-b", "node-a");
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

test "a dropped edge with a long address pair still refuses dials" {
    // Bug 2026-08-30-hub-dropped-edge-long-address: the dial-side drop
    // check built the edge key in a fixed 512-byte stack buffer, so a pair
    // whose combined length exceeds it reported "not dropped" and the dial
    // proceeded through the partition.
    var hub = Hub.init(test_alloc);
    defer hub.deinit(tio);
    const long_a = "a" ** 300;
    const long_b = "b" ** 300;
    var listener = try hub.listen(tio, test_alloc, long_a);
    defer listener.close(tio);
    var dialer = try hub.dialer(test_alloc, long_b);
    defer dialer.deinit();

    try hub.drop(test_alloc, tio, long_b, long_a);
    try std.testing.expectError(
        error.ConnectionRefused,
        dialer.connect(tio, test_alloc, long_a),
    );
}

test "dropping the same edge twice does not leak the second key" {
    var hub = Hub.init(test_alloc);
    defer hub.deinit(tio);
    // The testing allocator fails the test on a leak: before the fix the
    // second `drop` allocated a key the map's `put` then discarded (it keeps
    // the key it already holds), so nothing ever freed it.
    try hub.drop(test_alloc, tio, "node-a", "node-b");
    try hub.drop(test_alloc, tio, "node-a", "node-b");
    try std.testing.expect(hub.isDropped(tio, "node-a", "node-b"));
    try hub.heal(tio, test_alloc, "node-a", "node-b");
    try std.testing.expect(!hub.isDropped(tio, "node-a", "node-b"));
}

test "hub send refuses an oversized frame" {
    var hub = Hub.init(test_alloc);
    defer hub.deinit(tio);
    var listener = try hub.listen(tio, test_alloc, "node-a");
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
    var listener = try hub.listen(tio, test_alloc, "node-a");
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
    var l1 = try hub.listen(tio, test_alloc, "node-a");
    defer l1.close(tio);
    try std.testing.expectError(error.AddressInUse, hub.listen(tio, test_alloc, "node-a"));

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
    var listener = try hub.listen(tio, failing, "node-a");
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

/// Dials `address` and writes two frames with a single flush, so the kernel
/// delivers them to the server in one read.
fn twoFramesInOneSend(address: []const u8) error{Canceled}!void {
    const addr = net.IpAddress.parseLiteral(address) catch return;
    const stream = addr.connect(tio, .{ .mode = .stream }) catch return;
    defer stream.close(tio);
    var buf: [256]u8 = undefined;
    var writer = stream.writer(tio, &buf);
    framing.writeFrame(&writer.interface, "frame-one") catch return;
    framing.writeFrame(&writer.interface, "frame-two") catch return;
    writer.interface.flush() catch return;
    // Hold the connection open until the reader has both frames; a close
    // here would be graceful anyway, but waiting keeps the failure mode of
    // the test unambiguous.
    std.Io.sleep(tio, std.Io.Duration.fromMilliseconds(200), .awake) catch {};
}

test "no self-freeing closer keeps its guard inside the allocation it frees" {
    // `close` is the sole destructor of these four: it frees the allocation
    // the struct lives in. A `closed: bool` on them could therefore only be
    // read back out of freed memory, which is a use-after-free whose result
    // depends on what the allocator did with the block - a recycled block
    // reads `false` and the second close frees it a second time (bug
    // 2026-08-29-close-guard-in-freed-allocation). The invariant is
    // structural, so it is checked structurally rather than by provoking
    // the misuse.
    inline for (.{ TcpConn, TcpListener, PipeConn, HubListener }) |T| {
        try std.testing.expect(!@hasField(T, "closed"));
    }
    // The two that do keep a flag are hub-owned: `Direction.close` and the
    // endpoint's close mark state without freeing the struct, so those
    // flags are read from live memory and stay.
    try std.testing.expect(@hasField(Direction, "closed"));
    try std.testing.expect(@hasField(Hub.Endpoint, "closed"));
}

test "a TCP conn keeps the bytes its socket read past the current frame" {
    // A socket read is greedy: the reader hands the kernel its own buffer
    // alongside the caller's slice and keeps whatever comes back beyond what
    // was asked for. When that buffer belonged to one `recvFrame` call, the
    // surplus was consumed from the socket and then dropped on return - and
    // TCP coalesces frames freely, so the surplus is routinely the next
    // frame. Two frames written with one flush reproduce it.
    var address_buf: [32]u8 = undefined;
    var address: []const u8 = undefined;
    var listener: Listener = undefined;
    // A fixed base with a linear probe: whatever else holds a port (an
    // aborted earlier run, a parallel checkout), the next one is free.
    var port: u16 = 29876;
    while (true) : (port += 1) {
        if (port > 29876 + 64) return error.NoFreeLoopbackPort;
        address = try std.fmt.bufPrint(&address_buf, "127.0.0.1:{d}", .{port});
        listener = tcpListen(test_alloc, tio, address) catch continue;
        break;
    }
    defer listener.close(tio);

    var group: std.Io.Group = .init;
    group.async(tio, twoFramesInOneSend, .{address});

    const conn = try listener.accept(tio);
    defer conn.close(tio);
    const first = try conn.recv(tio, test_alloc);
    defer test_alloc.free(first);
    const second = try conn.recv(tio, test_alloc);
    defer test_alloc.free(second);
    try std.testing.expectEqualSlices(u8, "frame-one", first);
    try std.testing.expectEqualSlices(u8, "frame-two", second);
    try group.await(tio);
}

test "closing a hub listener frees its address for a new one" {
    // A node restarting in the in-memory fabric re-listens on the address
    // it had. `closeFn` marked the endpoint closed but left it registered,
    // so `listen` answered `AddressInUse` for the life of the hub and no
    // scenario could restart a member.
    var hub = Hub.init(test_alloc);
    defer hub.deinit(tio);

    var first = try hub.listen(tio, test_alloc, "node-a");
    try std.testing.expectError(error.AddressInUse, hub.listen(tio, test_alloc, "node-a"));
    first.close(tio);

    // Taken again by a second listener, which accepts and echoes like any
    // other: the address is genuinely free, not merely absent from the map.
    var second = try hub.listen(tio, test_alloc, "node-a");
    defer second.close(tio);
    var dialer = try hub.dialer(test_alloc, "node-b");
    defer dialer.deinit();
    var group: std.Io.Group = .init;
    group.async(tio, acceptAndEcho, .{&second});
    var conn = try dialer.connect(tio, test_alloc, "node-a");
    defer conn.close(tio);
    try conn.send(tio, "ping");
    const reply = try conn.recv(tio, test_alloc);
    defer test_alloc.free(reply);
    try std.testing.expectEqualStrings("pong", reply);
    try group.await(tio);
}
