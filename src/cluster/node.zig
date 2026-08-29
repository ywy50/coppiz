//! The cluster node loop (PRD 0003 phase 5): the failure detector, the
//! election -> epoch cycle, admission and the replication write path, all
//! as one event-processing task per member over the wire (src/net).
//!
//! The loop owns every mutation of the member's state and consumes only
//! events: frames from connection reader tasks, ticks from a timer task,
//! accepted/dialed connections, and `stop`. Sockets never touch the fold —
//! the reader tasks post frames, the loop decides — which is the OQ 27
//! shape: the same loop is drivable by a deterministic transport.
//!
//! Message flow (PRD 0003):
//!
//!   client ─append─▶ local member ──forward──▶ leader ──(slot)──▶ every member
//!                       │ durable queue        │ slot + broadcast   │ validate,
//!                       ◀── ack after the slot folds back ───────────┘ fold, store
//!
//! Admission: a dial's `hello` is checked against `cluster.admission`
//! (allowlist / open; prompt is recorded and refused until `coppiz admit`
//! runs offline), the admitter appends the `join` entry, and the newcomer
//! backfills every journal from genesis before it becomes leader-eligible.
//! A partition heals by the simulator's discipline (OQ 44): the losing
//! branch truncates its store to the last common slot and re-folds the
//! survivor's chain, which carries the `merge` entry and the loser's entries
//! re-slotted (the fold infers re-slots from author and epoch — chain.zig).

const std = @import("std");
const crypto = std.crypto;
const journal = @import("../journal/journal.zig");
const chain = @import("../journal/chain.zig");
const entry = @import("../journal/entry.zig");
const slot = @import("../journal/slot.zig");
const segment = @import("../journal/segment.zig");
const store = @import("../journal/store.zig");
const schema = @import("../settings/schema.zig");
const settings_fold = @import("../settings/fold.zig");
const validate = @import("../settings/validate.zig");
const membership = @import("membership.zig");
const election = @import("election.zig");
const epoch = @import("epoch.zig");
const net = @import("../net/net.zig");
const message = net.message;
const transport = net.transport;

/// The sync/backfill page size: a provisional value standing in until OQ 56
/// resolves `sync.page_bytes` (which names no value and no layer). Kept
/// small enough that one page fits inside one wire frame; the request is
/// capped by `framing.max_body_bytes` either way.
pub const provisional_page_bytes: u32 = 64 * 1024;

// ---------------------------------------------------------------------------
// Mailbox
// ---------------------------------------------------------------------------

const Event = union(enum) {
    /// The timer fired: periodic work (heartbeats, suspects, election,
    /// backfill, redials).
    tick,
    /// An accepted or dialed connection, pre-hello. `outbound` is set for
    /// connections this member dialed (they expect `hello_ack`); inbound
    /// accepts expect `hello`.
    conn_ready: struct { conn: net.transport.Conn, outbound: bool },
    /// One frame from a connection's reader task; `body` is owned by the
    /// loop and freed after dispatch.
    frame: Frame,
    /// A connection's reader hit end-of-stream or an error.
    peer_gone: u64,
    /// A dial task could not connect; `address` is owned.
    dial_failed: []const u8,
    /// An embedded host's append, posted from the host's own thread (PRD
    /// 0005): the loop runs the same write path as a wire client's append,
    /// then completes the host's semaphore with the entry id.
    local_append: LocalAppend,
    /// An embedded host's read, posted from the host's own thread (PRD
    /// 0005): the loop runs the range over its own state and copies the
    /// records into the host's completion, then posts it.
    local_read: LocalRead,
    /// Shut the loop down.
    stop,
};

/// One embedded-host append in flight (PRD 0005). The host blocks on
/// `completion.sem` until the loop slots the entry (or refuses it); the
/// journal name and payload are the host's, alive for as long as the host
/// is blocked.
const LocalAppend = struct {
    journal: []const u8,
    payload: []const u8,
    ttl_ms: u64,
    completion: *LocalCompletion,
};

/// What an embedded host's `localAppend` waits on: the slot folded (or a
/// refusal), posted exactly once by the loop.
const LocalCompletion = struct {
    sem: std.Io.Semaphore = .{},
    id: entry.Id = undefined,
    refusal: []const u8 = "",
};

fn completeLocal(completion: *LocalCompletion, io: std.Io, id: entry.Id, refusal: []const u8) void {
    completion.id = id;
    completion.refusal = refusal;
    completion.sem.post(io);
}

/// One embedded-host read in flight (PRD 0005). The host blocks on
/// `completion.sem` until the loop has copied the requested range; the
/// range bounds and flags are the host's, alive for as long as the host is
/// blocked.
const LocalRead = struct {
    journal_id: [16]u8,
    from: ?slot.Position,
    to: ?slot.Position,
    include_stale: bool,
    include_expired: bool,
    completion: *LocalReadCompletion,
};

/// What an embedded host's `localReadRange` waits on: the records the loop
/// copied (slots in chain order, entries when the store still has them),
/// or the error that aborted the read, posted exactly once. `records` is
/// owned by the completion and freed by whoever waits on it.
const LocalReadCompletion = struct {
    allocator: std.mem.Allocator,
    sem: std.Io.Semaphore = .{},
    records: std.ArrayListUnmanaged(LocalRecord) = .empty,
    err: ?anyerror = null,
};

/// A record as the loop hands it to a host: the slot, and the entry when
/// present. `entry.payload` is owned by the completion.
const LocalRecord = struct {
    slot: slot.Slot,
    entry: ?entry.Entry,
};

fn completeLocalRead(completion: *LocalReadCompletion, io: std.Io, err: ?anyerror) void {
    if (err) |e| completion.err = e;
    completion.sem.post(io);
}

/// Frees the records the loop copied (entry payloads included). Called by
/// whoever waits on the completion — the host's `localReadRange`.
fn deinitLocalRead(completion: *LocalReadCompletion, allocator: std.mem.Allocator) void {
    for (completion.records.items) |rec| {
        if (rec.entry) |en| allocator.free(en.payload);
    }
    completion.records.deinit(allocator);
}

const Frame = struct {
    conn_id: u64,
    body: []u8,
};

const Mailbox = struct {
    allocator: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    sem: std.Io.Semaphore = .{},
    events: std.ArrayListUnmanaged(Event) = .empty,

    /// False when the event could not be queued (the caller still owns any
    /// memory or connection the event carried).
    fn post(self: *Mailbox, io: std.Io, ev: Event) bool {
        self.mutex.lockUncancelable(io);
        self.events.append(self.allocator, ev) catch {
            self.mutex.unlock(io);
            return false;
        };
        self.mutex.unlock(io);
        self.sem.post(io);
        return true;
    }

    fn wait(self: *Mailbox, io: std.Io) error{Canceled}!Event {
        try self.sem.wait(io);
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        std.debug.assert(self.events.items.len > 0);
        return self.events.orderedRemove(0);
    }
};

// ---------------------------------------------------------------------------
// Peer state
// ---------------------------------------------------------------------------

/// One member's runtime state in the loop: the fold knows identity and
/// seniority; this is liveness, connection and heads.
const MemberState = struct {
    /// The address to dial (owned).
    address: []const u8,
    /// The public key last bound to this id (zeros until hello or fold).
    public_key: [32]u8 = [_]u8{0} ** 32,
    /// The live connection's id, when connected.
    conn_id: ?u64 = null,
    /// Liveness as this member sees the peer (election.State).
    state: election.State = .lost,
    /// The peer's advertised control head (heartbeat).
    head: slot.Position = .{ .epoch = 0, .seq = 0 },
    last_heard_ms: u64 = 0,
    next_heartbeat_ms: u64 = 0,
    /// When to (re)dial; grows by `backoff_ms` on failures.
    dial_at_ms: u64 = 0,
    backoff_ms: u64 = 250,
};

/// Upper bound on an advertised address. A real `host:port` needs at most
/// a 253-byte hostname plus ":65535"; the wire allows 65535 bytes, and the
/// surplus only ever reaches a chain entry or an operator's terminal.
const max_address_len = 300;

/// How a live connection was authenticated. Operator and replication
/// messages are refused until hello completes.
const ConnRole = enum { unknown, operator, member };

/// One live connection: a member peer, a CLI client, or a pre-hello
/// connection. `member_id` is set when the hello identifies the peer.
const ConnState = struct {
    conn: net.transport.Conn,
    member_id: ?[16]u8 = null,
    role: ConnRole = .unknown,
    /// True when this member dialed; only then is `hello_ack` accepted.
    outbound: bool = false,
    /// The reader has been shut down and its peer-gone notice will destroy
    /// the conn; no further sends.
    closing: bool = false,
};

// ---------------------------------------------------------------------------
// ClusterNode
// ---------------------------------------------------------------------------

pub const Options = struct {
    /// The dial side of the transport.
    transport: net.transport.Transport,
    /// The accept side, or null when this member does not listen.
    listener: ?net.transport.Listener = null,
    /// The advertised address (recorded in this member's join).
    address: []const u8 = "",
    /// Allowlist public keys (cluster.admission = allowlist), raw 32 bytes.
    allowlist: []const [32]u8 = &.{},
    /// Additional addresses to dial (config `[[peers]]`), for the joiner
    /// that is not a member of anything yet.
    seed_peers: []const []const u8 = &.{},
};

pub const ClusterNode = struct {
    /// What a leader-authored control entry returns: the id and the slot,
    /// shared by authorControl and authorControlFold so callers can branch
    /// on which chain the entry went to without two anonymous types.
    const Authored = struct {
        id: entry.Id,
        sl: slot.Slot,
    };

    allocator: std.mem.Allocator,
    io: std.Io,
    node: *journal.Node,
    options: Options,

    mailbox: Mailbox,
    group: std.Io.Group = .init,

    /// conn_id -> live connection.
    conns: std.AutoHashMapUnmanaged(u64, ConnState) = .empty,
    /// member_id -> runtime state.
    members: std.AutoHashMapUnmanaged([16]u8, MemberState) = .empty,
    /// CLI clients awaiting their entry's slot: entry id -> conn_id.
    pending_clients: std.AutoHashMapUnmanaged(entry.Id, u64) = .empty,
    /// Embedded hosts awaiting their entry's slot (PRD 0005): entry id ->
    /// the completion the host's thread is blocked on.
    pending_locals: std.AutoHashMapUnmanaged(entry.Id, *LocalCompletion) = .empty,
    /// The next position to request per journal during backfill.
    sync_cursors: std.AutoHashMapUnmanaged([16]u8, slot.Position) = .empty,
    /// Whether a sync request is in flight (one at a time).
    sync_in_flight: bool = false,
    /// Whether this member is backfilling (never leader-eligible).
    syncing: bool = false,

    next_conn_id: u64 = 1,
    /// The first slot of my current branch (the epoch that opened it), and
    /// the last slot before it (the common prefix both sides share).
    branch_start: ?slot.Position = null,
    common_tail: ?slot.Position = null,
    /// The tick interval, recomputed from settings; read by the timer task.
    tick_ms: std.atomic.Value(u32) = std.atomic.Value(u32).init(100),
    /// Set by `stop`; the loop exits on the next event once it is set.
    stopped: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Set by the loop task itself when it returns. `waitForStop` waits for
    /// this — not `stopped` — before cancelling the group: a cancel must
    /// never land while the loop is mid-event (it runs the store and the
    /// fold), or an in-flight compaction would abort with the journal's
    /// segments half-swapped. The loop drains the `.stop` event first, then
    /// the remaining tasks (timer, accept, readers, dials) are cancelled.
    loop_exited: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// My own next author_seq per journal, counting entries I built but
    /// that have not slotted yet (the fold only advances when they do).
    my_seq: std.AutoHashMapUnmanaged([16]u8, u64) = .empty,

    /// Merge state: when non-null, this member is the survivor of a healed
    /// partition and is fetching the loser's branch to re-slot it. The
    /// buffers hold the loser's raw records per journal; `merge_pending`
    /// lists the data journals still to fetch.
    merging_from: ?u64 = null,
    merge_buffers: std.AutoHashMapUnmanaged([16]u8, std.ArrayListUnmanaged(u8)) = .empty,
    merge_pending: std.ArrayListUnmanaged([16]u8) = .empty,

    /// Seed addresses not yet connected to any member, with the next
    /// retry time (the admitter may not be listening when a joiner starts).
    seed_retry: std.StringHashMapUnmanaged(u64) = .empty,

    /// The checkpoint cadence (PRD 0002 phase 4): when the leader may next
    /// checkpoint each data journal, and the head it last scanned (the
    /// pending-bytes early trigger rescans only when data arrived).
    next_checkpoint_ms: std.AutoHashMapUnmanaged([16]u8, u64) = .empty,
    last_scan_head: std.AutoHashMapUnmanaged([16]u8, slot.Position) = .empty,

    // -- lifecycle -----------------------------------------------------------

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        node: *journal.Node,
        options: Options,
    ) !*ClusterNode {
        const self = try allocator.create(ClusterNode);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .node = node,
            .options = options,
            .mailbox = .{ .allocator = allocator },
        };
        errdefer allocator.destroy(self);
        try self.syncMembersFromFold();
        try self.resetMySeq();
        // A member with no chain is a joiner: it syncs before it may lead.
        self.syncing = node.control.head == null;
        return self;
    }

    pub fn deinit(self: *ClusterNode) void {
        var it = self.conns.valueIterator();
        while (it.next()) |cs| cs.conn.close(self.io);
        self.conns.deinit(self.allocator);
        var mit = self.members.valueIterator();
        while (mit.next()) |ms| self.allocator.free(ms.address);
        self.members.deinit(self.allocator);
        self.pending_clients.deinit(self.allocator);
        self.pending_locals.deinit(self.allocator);
        self.sync_cursors.deinit(self.allocator);
        self.my_seq.deinit(self.allocator);
        var bit = self.merge_buffers.valueIterator();
        while (bit.next()) |buf| buf.deinit(self.allocator);
        self.merge_buffers.deinit(self.allocator);
        self.merge_pending.deinit(self.allocator);
        var sit = self.seed_retry.keyIterator();
        while (sit.next()) |addr| self.allocator.free(addr.*);
        self.seed_retry.deinit(self.allocator);
        self.next_checkpoint_ms.deinit(self.allocator);
        self.last_scan_head.deinit(self.allocator);
        // Events the loop never processed (it exited on stop while readers
        // and dials were still posting) own their payloads: frame bodies,
        // accepted connections, and dial-failure addresses.
        for (self.mailbox.events.items) |ev| switch (ev) {
            .frame => |f| self.allocator.free(f.body),
            .conn_ready => |ready| ready.conn.close(self.io),
            .dial_failed => |address| self.allocator.free(address),
            else => {},
        };
        self.mailbox.events.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// Spawns the loop, the timer and the accept tasks. The node runs until
    /// `stop` is called or the group is cancelled.
    pub fn start(self: *ClusterNode) void {
        self.group.async(self.io, loopMain, .{self});
        self.group.async(self.io, timerMain, .{self});
        if (self.options.listener) |*l| {
            self.group.async(self.io, acceptMain, .{ self, l });
        }
    }

    /// Requests a clean shutdown: the loop exits on the next event.
    pub fn stop(self: *ClusterNode) void {
        self.stopped.store(true, .release);
        _ = self.mailbox.post(self.io, .stop);
    }

    /// Blocks until the loop has exited, then cancels the remaining tasks
    /// (timer, accept, readers, dials). Must be called from a task that is
    /// not part of the node's group — the CLI's main, a test.
    pub fn waitForStop(self: *ClusterNode) void {
        while (!self.loop_exited.load(.acquire)) {
            std.Io.sleep(
                self.io,
                std.Io.Duration.fromMilliseconds(10),
                .awake,
            ) catch return;
        }
        self.group.cancel(self.io);
        self.group.await(self.io) catch {};
    }

    /// Cancels every task (the loop, readers, timers, dials).
    pub fn cancel(self: *ClusterNode) void {
        self.group.cancel(self.io);
    }

    /// The embedded-host write path (PRD 0005): appends as this member from
    /// the host's own thread, and blocks until the entry's slot folds back
    /// — the same write path as a wire client's append (queue durably, then
    /// the leader slots, or the follower forwards), so the entry replicates
    /// like any other. The caller's thread never touches the folds or the
    /// store: the loop owns every mutation, and this posts an event for it.
    /// `journal` and `payload` must stay alive for the call (the caller is
    /// blocked, so its own slices do). Returns the entry id, or `Refused`
    /// when the loop rejected the append (unknown journal, too large, full
    /// queue); a `write.ack = local` variant that returns on the durable
    /// queue instead of the slot is open question 3.
    pub fn localAppend(
        self: *ClusterNode,
        io: std.Io,
        journal_name: []const u8,
        payload: []const u8,
        ttl_ms: u64,
    ) !entry.Id {
        var completion = LocalCompletion{};
        if (!self.mailbox.post(io, .{ .local_append = .{
            .journal = journal_name,
            .payload = payload,
            .ttl_ms = ttl_ms,
            .completion = &completion,
        } })) {
            completeLocal(&completion, io, undefined, "mailbox_full");
        }
        completion.sem.wait(io) catch return error.Canceled;
        if (completion.refusal.len > 0) return error.Refused;
        return completion.id;
    }

    /// The embedded-host read path (PRD 0005): reads `[from, to]` of a
    /// journal from the host's own thread, and blocks until the loop has
    /// copied the range — the same read path a wire client's `read` takes,
    /// so a host thread never touches the folds while the loop runs. The
    /// loop runs the range over its own state (atomic with respect to its
    /// own mutations), copies every visible record into the completion, and
    /// the caller's thread replays `on_entry` over the copies. The whole
    /// range is buffered in memory; a host that wants to stream a large
    /// journal page by page still reads through the wire client.
    pub fn localReadRange(
        self: *ClusterNode,
        io: std.Io,
        journal_id: [16]u8,
        from: ?slot.Position,
        to: ?slot.Position,
        include_stale: bool,
        include_expired: bool,
        ctx: anytype,
        comptime on_entry: fn (@TypeOf(ctx), *const slot.Slot, ?*const entry.Entry) anyerror!void,
    ) !void {
        var completion = LocalReadCompletion{ .allocator = self.allocator };
        if (!self.mailbox.post(io, .{ .local_read = .{
            .journal_id = journal_id,
            .from = from,
            .to = to,
            .include_stale = include_stale,
            .include_expired = include_expired,
            .completion = &completion,
        } })) {
            completion.err = error.MailboxFull;
        } else {
            completion.sem.wait(io) catch return error.Canceled;
        }
        defer deinitLocalRead(&completion, self.allocator);
        if (completion.err) |err| return err;
        for (completion.records.items) |*rec| {
            try on_entry(ctx, &rec.slot, if (rec.entry) |*en| en else null);
        }
    }

    // -- bootstrap helpers ---------------------------------------------------

    /// Reconciles the members map with the fold (new joins appear, addresses
    /// move); never removes — a left member's entry just goes stale.
    fn syncMembersFromFold(self: *ClusterNode) !void {
        for (self.node.control.members.items) |member| {
            if (std.mem.eql(u8, &member.id, &self.node.member_id)) continue;
            if (self.members.getPtr(member.id)) |ms| {
                ms.public_key = member.public_key;
                // The runtime address (learned from the peer's hello) wins;
                // the fold's address is authoritative only when it names
                // something — the founder's genesis records none.
                if (member.address.len > 0 and !std.mem.eql(u8, ms.address, member.address)) {
                    const updated = try self.allocator.dupe(u8, member.address);
                    self.allocator.free(ms.address);
                    ms.address = updated;
                }
            } else {
                try self.members.put(self.allocator, member.id, .{
                    .address = try self.allocator.dupe(u8, member.address),
                    .public_key = member.public_key,
                });
            }
        }
    }

    /// Re-derives my per-journal author_seq floor from the fold and the
    /// queued-but-unslotted entries (which keep their original seqs on a
    /// re-forward after restart), then re-forwards the queue.
    fn resetMySeq(self: *ClusterNode) !void {
        self.my_seq.clearRetainingCapacity();
        const Ctx = struct { self: *ClusterNode };
        var ctx = Ctx{ .self = self };
        try self.node.queue.scan(&ctx, struct {
            fn cb(c: *Ctx, en: *const entry.Entry) anyerror!void {
                if (!std.mem.eql(u8, &en.author, &c.self.node.member_id)) return;
                const current = c.self.my_seq.get(en.journal) orelse 0;
                if (en.author_seq >= current) {
                    try c.self.my_seq.put(c.self.allocator, en.journal, en.author_seq + 1);
                }
            }
        }.cb);
        try self.reforwardQueue();
    }

    /// Re-sends the queued entries to the current leader, or slots them
    /// locally when this member is the leader (a crash or failover may
    /// have left them queued; already-slotted ids are trimmed).
    fn reforwardQueue(self: *ClusterNode) !void {
        // The common reconnect case is an empty queue; a scan reads the whole
        // file, so skip it entirely then.
        if (self.node.queue.queued_bytes == 0) return;
        const Ctx = struct {
            self: *ClusterNode,
            pending: *std.ArrayListUnmanaged(entry.Entry),
        };
        var pending = std.ArrayListUnmanaged(entry.Entry).empty;
        defer {
            for (pending.items) |en| self.allocator.free(en.payload);
            pending.deinit(self.allocator);
        }
        var ctx = Ctx{ .self = self, .pending = &pending };
        try self.node.queue.scan(&ctx, struct {
            fn cb(
                c: *Ctx,
                en: *const entry.Entry,
            ) anyerror!void {
                // The scan's buffer dies with the call; keep the payload.
                var copy = en.*;
                copy.payload = try c.self.allocator.dupe(u8, en.payload);
                try c.pending.append(c.self.allocator, copy);
            }
        }.cb);
        for (pending.items) |en| {
            if (self.entryKnown(en.journal, en.id())) {
                // The slot landed while this member was backfilling or
                // merging, so `onSlot` never ran for it: whoever is waiting
                // on this entry is resolved here, before the queue drops it
                // (bug 2026-08-28-localappend-completion-lost).
                self.completePendingFor(&en);
                self.node.queue.remove(en.journal, en.id()) catch {};
                continue;
            }
            if (self.isLeader()) {
                _ = self.slotAndBroadcast(&en, false) catch |err| {
                    // The embedded host's completion and the wire client's
                    // ack are resolved on both outcomes, with the refusal on
                    // the error path — otherwise the host hangs (bug
                    // 2026-08-29-reforward-queue-loses-local-completion).
                    if (self.pending_clients.fetchRemove(en.id())) |kv| {
                        self.ackClient(kv.value, en.id(), clientRefusalName(err)) catch {};
                    }
                    if (self.pending_locals.fetchRemove(en.id())) |kv| {
                        completeLocal(kv.value, self.io, undefined, clientRefusalName(err));
                    }
                    continue;
                };
                self.completePendingFor(&en);
                if (self.pending_clients.fetchRemove(en.id())) |kv| {
                    self.ackClient(kv.value, en.id(), "") catch {};
                }
            } else {
                self.sendForward(&en) catch continue;
            }
        }
    }

    fn foldFor(self: *ClusterNode, journal_id: [16]u8) ?*chain.FoldState {
        if (std.mem.eql(u8, &journal_id, &self.node.control.journal_id)) {
            return &self.node.control;
        }
        const journal_state = self.node.journals.get(journal_id) orelse return null;
        return &journal_state.fold;
    }

    /// My next author_seq for a journal: the fold's floor, raised by any
    /// entries I have built that are not slotted yet.
    fn nextAuthorSeq(self: *ClusterNode, journal_id: [16]u8) u64 {
        const fold = self.foldFor(journal_id) orelse return 1;
        const floor = self.node.nextAuthorSeq(fold);
        const mine = self.my_seq.get(journal_id) orelse 1;
        return @max(floor, mine);
    }

    fn noteBuilt(self: *ClusterNode, journal_id: [16]u8, seq: u64) !void {
        try self.my_seq.put(self.allocator, journal_id, seq + 1);
    }

    // -- tasks ---------------------------------------------------------------

    fn loopMain(self: *ClusterNode) error{Canceled}!void {
        defer self.loop_exited.store(true, .release);
        self.bootstrapDial();
        while (true) {
            const ev = self.mailbox.wait(self.io) catch return;
            switch (ev) {
                .stop => return,
                .tick => self.onTick() catch self.fatal(),
                .local_append => |a| self.onLocalAppend(a),
                .local_read => |r| self.onLocalRead(r),
                .conn_ready => |ready| self.onConnReady(
                    ready.conn,
                    ready.outbound,
                ) catch self.fatal(),
                .frame => |f| {
                    defer self.allocator.free(f.body);
                    // Operator refusals are acked inside the handler. Anything
                    // that still errors here isolates the peer, not the loop.
                    self.onFrame(f.conn_id, f.body) catch self.closeConn(f.conn_id);
                },
                .peer_gone => |conn_id| self.onPeerGone(conn_id),
                .dial_failed => |address| {
                    self.onDialFailed(address);
                    self.allocator.free(address);
                },
            }
        }
    }

    /// Fatal errors stop the loop; `waitForStop` (the CLI's serve) only
    /// unblocks once `stopped` is set, so this must go through `stop`.
    fn fatal(self: *ClusterNode) void {
        self.stop();
    }

    /// Tells the loop a dial died so it can back off and retry. `address`
    /// is borrowed; the event owns a copy.
    fn noteDialFailed(self: *ClusterNode, address: []const u8) void {
        const owned = self.allocator.dupe(u8, address) catch return;
        if (!self.mailbox.post(self.io, .{ .dial_failed = owned })) {
            self.allocator.free(owned);
        }
    }

    fn bootstrapDial(self: *ClusterNode) void {
        for (self.options.seed_peers) |address| {
            self.spawnDial(self.allocator.dupe(u8, address) catch return);
            // Retry until a peer at this address is connected; a fresh
            // joiner may start before the admitter is listening.
            const owned = self.allocator.dupe(u8, address) catch return;
            self.seed_retry.put(self.allocator, owned, 0) catch {
                self.allocator.free(owned);
                return;
            };
        }
        var mit = self.members.keyIterator();
        while (mit.next()) |id| {
            if (!self.shouldDial(id.*)) continue;
            const ms = self.members.get(id.*).?;
            if (ms.state == .lost) self.spawnDial(self.allocator.dupe(u8, ms.address) catch return);
        }
    }

    /// One dialer per member pair, so the full mesh never double-dials: the
    /// member with the lower id dials the higher. Seed-peer dials (the
    /// joiner reaching the admitter) are unconditional.
    fn shouldDial(self: *ClusterNode, member_id: [16]u8) bool {
        return std.mem.order(u8, &self.node.member_id, &member_id) == .lt;
    }

    fn spawnDial(self: *ClusterNode, address: []const u8) void {
        self.group.async(self.io, dialMain, .{ self, address });
    }

    fn timerMain(self: *ClusterNode) error{Canceled}!void {
        while (true) {
            const tick = self.tick_ms.load(.acquire);
            std.Io.sleep(
                self.io,
                std.Io.Duration.fromMilliseconds(tick),
                .awake,
            ) catch return;
            _ = self.mailbox.post(self.io, .tick);
        }
    }

    fn acceptMain(self: *ClusterNode, listener: *net.transport.Listener) error{Canceled}!void {
        while (true) {
            const conn = listener.accept(self.io) catch return;
            if (!self.mailbox.post(self.io, .{
                .conn_ready = .{ .conn = conn, .outbound = false },
            })) {
                conn.close(self.io);
            }
        }
    }

    /// Dials one address, sends the hello, and hands the connection to the
    /// loop (which assigns the conn id and spawns the reader).
    fn dialMain(self: *ClusterNode, address: []const u8) error{Canceled}!void {
        defer self.allocator.free(address);
        const conn = self.options.transport.connect(self.io, self.allocator, address) catch {
            self.noteDialFailed(address);
            return;
        };
        const hello = self.buildHello() catch {
            conn.close(self.io);
            self.noteDialFailed(address);
            return;
        };
        conn.send(self.io, hello) catch {
            self.allocator.free(hello);
            conn.close(self.io);
            self.noteDialFailed(address);
            return;
        };
        self.allocator.free(hello);
        if (!self.mailbox.post(self.io, .{
            .conn_ready = .{ .conn = conn, .outbound = true },
        })) {
            conn.close(self.io);
            self.noteDialFailed(address);
        }
    }

    fn readerMain(self: *ClusterNode, conn_id: u64) error{Canceled}!void {
        const conn = self.conns.get(conn_id).?.conn;
        while (true) {
            const body = conn.recv(self.io, self.allocator) catch {
                break;
            };
            if (!self.mailbox.post(self.io, .{ .frame = .{ .conn_id = conn_id, .body = body } })) {
                self.allocator.free(body);
            }
        }
        _ = self.mailbox.post(self.io, .{ .peer_gone = conn_id });
    }

    // -- events --------------------------------------------------------------

    fn onConnReady(self: *ClusterNode, conn: net.transport.Conn, outbound: bool) !void {
        const conn_id = self.next_conn_id;
        self.next_conn_id += 1;
        errdefer conn.close(self.io);
        try self.conns.put(self.allocator, conn_id, .{ .conn = conn, .outbound = outbound });
        self.group.async(self.io, readerMain, .{ self, conn_id });
    }

    fn onPeerGone(self: *ClusterNode, conn_id: u64) void {
        // A dead conn can strand an in-flight sync or a merge; release both.
        self.sync_in_flight = false;
        if (self.merging_from == conn_id) {
            self.merging_from = null;
            var bit = self.merge_buffers.valueIterator();
            while (bit.next()) |buf| buf.deinit(self.allocator);
            self.merge_buffers.clearRetainingCapacity();
            self.merge_pending.clearRetainingCapacity();
        }
        const cs = self.conns.get(conn_id) orelse return;
        if (cs.member_id) |id| {
            if (self.members.getPtr(id)) |ms| {
                // A newer conn may have replaced this one already.
                if (ms.conn_id == conn_id) {
                    // The conn died but the member is not lost yet: only
                    // the suspect timer marks `.lost`, so a redial blip
                    // cannot eject a live member from the election.
                    ms.conn_id = null;
                    if (ms.dial_at_ms == 0) ms.dial_at_ms = self.elapsedMs() + ms.backoff_ms;
                }
            }
        }
        // The reader has exited: only now is the conn safe to destroy.
        cs.conn.close(self.io);
        _ = self.conns.remove(conn_id);
    }

    fn onDialFailed(self: *ClusterNode, address: []const u8) void {
        var mit = self.members.valueIterator();
        while (mit.next()) |ms| {
            if (std.mem.eql(u8, ms.address, address)) {
                // Not `.lost`: the suspect timer owns that transition.
                ms.dial_at_ms = self.elapsedMs() + ms.backoff_ms;
                ms.backoff_ms = @min(ms.backoff_ms * 2, 8000);
            }
        }
    }

    fn onFrame(self: *ClusterNode, conn_id: u64, body: []const u8) !void {
        if (!self.conns.contains(conn_id)) return;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const msg = message.decode(arena.allocator(), body) catch {
            // A malformed frame is a protocol violation: drop the connection.
            self.closeConn(conn_id);
            return;
        };
        const cs = self.conns.get(conn_id) orelse return;
        if (!frameAllowed(cs.role, cs.outbound, msg.kind())) {
            self.closeConn(conn_id);
            return;
        }
        switch (msg) {
            .hello => |h| try self.onHello(conn_id, h),
            .hello_ack => |a| try self.onHelloAck(conn_id, a),
            .append => |a| try self.onAppend(conn_id, a),
            .forward => |f| try self.onForward(conn_id, f),
            .slot => |m| try self.onSlot(conn_id, m),
            .sync_req => |r| try self.onSyncReq(conn_id, r),
            .sync_page => |p| try self.onSyncPage(conn_id, p),
            .heartbeat => |hb| try self.onHeartbeat(conn_id, hb),
            .read_req => |r| try self.onReadReq(conn_id, r),
            .read_page => {},
            .settings => |s| try self.onSettings(conn_id, s),
            .merge_offer => |o| try self.onMergeOffer(conn_id, o),
            .merge_ack => self.onMergeAck(conn_id) catch {},
            .members_req => try self.onMembersReq(conn_id),
            .members_page => {},
            .ack => {},
        }
    }

    /// Operator messages need the node's own hello; replication messages
    /// need a member hello. `hello_ack` is only the reply to an outbound
    /// dial — an inbound one is how a stranger would steal a member id.
    fn frameAllowed(role: ConnRole, outbound: bool, kind: message.Kind) bool {
        return switch (kind) {
            .hello => true,
            .hello_ack => outbound,
            .append, .read_req, .settings, .members_req => role == .operator,
            .forward, .slot, .sync_req, .sync_page, .heartbeat => role == .member,
            .merge_offer, .merge_ack => role == .member,
            .ack, .read_page, .members_page => true,
        };
    }

    fn onTick(self: *ClusterNode) !void {
        const now = self.elapsedMs();
        self.updateTick();
        const heartbeat_ms = self.settingU64("cluster.heartbeat_ms", 1000);
        const suspect_after = self.settingU64("cluster.suspect_after_ms", 5000);
        const evict_after = self.settingU64("membership.evict_after_ms", 0);

        // Reconcile membership (joins folded), heartbeats, failure detection.
        try self.syncMembersFromFold();
        var mit = self.members.keyIterator();
        while (mit.next()) |id| {
            const ms = self.members.getPtr(id.*) orelse continue;
            // The suspect timer is the failure detector: a member is only
            // `.lost` after `suspect_after` without a heartbeat. A conn
            // blip (the dup-close dance of a redial) must not drop it from
            // the election — that window is exactly when a spurious
            // self-election would happen. The check runs for conn-less
            // members too, so a member whose conn died still gets suspected.
            if (ms.last_heard_ms != 0 and now -| ms.last_heard_ms >= suspect_after) {
                if (ms.conn_id) |cid| self.closeConn(cid);
                ms.conn_id = null;
                ms.state = .lost;
                ms.dial_at_ms = now + ms.backoff_ms;
            } else if (ms.conn_id != null) {
                if (now >= ms.next_heartbeat_ms) {
                    self.sendHeartbeat(ms) catch {};
                    ms.next_heartbeat_ms = now + heartbeat_ms;
                }
            } else if (ms.dial_at_ms != 0 and now >= ms.dial_at_ms) {
                ms.dial_at_ms = 0;
                if (!self.shouldDial(id.*)) continue;
                self.spawnDial(self.allocator.dupe(u8, ms.address) catch continue);
            }
        }

        // Eviction: the leader converts a long-lost member to a leave.
        if (evict_after > 0 and self.isLeader()) {
            var targets = std.ArrayListUnmanaged([16]u8).empty;
            defer targets.deinit(self.allocator);
            var kit = self.members.keyIterator();
            while (kit.next()) |id| {
                const ms = self.members.get(id.*) orelse continue;
                if (ms.state == .lost and ms.last_heard_ms != 0 and
                    now -| ms.last_heard_ms >= evict_after)
                {
                    try targets.append(self.allocator, id.*);
                }
            }
            for (targets.items) |target| {
                self.evictMember(target) catch {};
            }
        }

        try self.runElection();
        // A newly elected leader's own queue does not drain by itself: the
        // slots it awaits come from the leader, and the leader is now this
        // member (sendForward has no leader connection to send to). Slot
        // what is queued before the checkpoint cadence measures anything.
        if (self.isLeader()) try self.slotQueuedEntries();
        try self.driveCheckpoints();
        try self.driveBackfill();
        // Seed dials retry until a peer at that address is connected.
        var sit = self.seed_retry.iterator();
        while (sit.next()) |seed_entry| {
            if (now < seed_entry.value_ptr.*) continue;
            var connected = false;
            var cmit = self.members.valueIterator();
            while (cmit.next()) |ms| {
                if (ms.conn_id != null and std.mem.eql(u8, ms.address, seed_entry.key_ptr.*)) {
                    connected = true;
                    break;
                }
            }
            if (connected) continue;
            self.spawnDial(self.allocator.dupe(u8, seed_entry.key_ptr.*) catch continue);
            seed_entry.value_ptr.* = now + 2000;
        }
    }

    /// A `leave` by the leader evicting a member (PRD 0003 *Leave and
    /// seniority*).
    fn evictMember(self: *ClusterNode, member_id: [16]u8) !void {
        var buf: [16]u8 = undefined;
        membership.encodeLeavePayload(.{ .member_id = member_id }, &buf);
        _ = try self.authorControl(.leave, &buf);
    }

    fn runElection(self: *ClusterNode) !void {
        if (self.syncing) {
            return; // never eligible, never elected
        }
        const fold = &self.node.control;
        if (fold.epoch == null) {
            return; // no chain yet
        }
        const inputs = self.electionInputs();
        const views = try self.viewsFor();
        defer self.allocator.free(views);
        const elected = election.leader(inputs, views) orelse return;
        const current = fold.epoch.?.leader;
        if (std.mem.eql(u8, &elected, &current)) return;
        if (std.mem.eql(u8, &elected, &self.node.member_id)) {
            // I am the new leader: open the term.
            try self.appendEpoch(.leader_lost);
        }
        // Otherwise the new leader's epoch will arrive; a member that does
        // not agree is partitioned and keeps its view.
    }

    fn driveBackfill(self: *ClusterNode) !void {
        if (!self.syncing or self.sync_in_flight) return;
        // Pick the next journal to sync, control first, then each data
        // journal the fold knows.
        const control_id = self.node.control.journal_id;
        if (self.sync_cursors.get(control_id)) |from| {
            const conn_id = self.syncPeerConn() orelse return;
            try self.requestSync(conn_id, control_id, from);
            return;
        }
        var it = self.node.control.journals.iterator();
        while (it.next()) |kv| {
            if (self.sync_cursors.get(kv.key_ptr.*)) |from| {
                const conn_id = self.syncPeerConn() orelse return;
                try self.requestSync(conn_id, kv.key_ptr.*, from);
                return;
            }
        }
        // Nothing left to sync: at head. Broadcasts were dropped while
        // backfilling, so drain the queue now — entries the sync pages
        // already carried are trimmed and their waiters completed.
        // A chainless joiner has no cursor yet (the hello_ack seeds it), so
        // a tick that beats the handshake must not clear syncing and strand
        // it permanently (bug 2026-08-28-sweep3-joiner-syncing-race).
        if (self.node.control.head == null) return;
        self.syncing = false;
        try self.reforwardQueue();
    }

    /// The leader slots its own queued entries. The queue drains when a
    /// slot folds back, and a follower's entries are forwarded to the
    /// leader — but an entry queued when the old leader died is never
    /// slotted by anyone once this member is elected (sendForward has no
    /// leader connection to send to), so it would sit in the durable queue
    /// until a later election elsewhere. Ids already in the fold are
    /// skipped: a redelivery after a restart, not a re-slot. A client that
    /// queued the entry through this member is acked exactly as onSlot
    /// would have.
    fn slotQueuedEntries(self: *ClusterNode) !void {
        const Ctx = struct {
            self: *ClusterNode,
        };
        var ctx = Ctx{ .self = self };
        try self.node.queue.scan(&ctx, struct {
            fn cb(c: *Ctx, en: *const entry.Entry) anyerror!void {
                if (!std.mem.eql(u8, &en.author, &c.self.node.member_id)) return;
                if (c.self.entryKnown(en.journal, en.id())) {
                    // Applied through another path (a sync page) that may
                    // not have posted the ack/completion (bug
                    // 2026-08-28-localappend-completion-lost).
                    c.self.completePendingFor(en);
                    return;
                }
                _ = try c.self.slotAndBroadcast(en, false);
                if (c.self.pending_clients.fetchRemove(en.id())) |kv| {
                    c.self.ackClient(kv.value, en.id(), "") catch {};
                }
                if (c.self.pending_locals.fetchRemove(en.id())) |kv| {
                    completeLocal(kv.value, c.self.io, en.id(), "");
                }
            }
        }.cb);
    }

    /// The leader's checkpoint cadence (PRD 0002 phase 4): emits a
    /// checkpoint for a journal when `checkpoint.every_ms` has passed since
    /// the last one, or when `checkpoint.pending_bytes` of removable payload
    /// has accumulated — the second is probed as data arrives (a head moved
    /// since the last scan), never by a full scan every tick. A checkpoint
    /// is never emitted with an empty removal set (G7). Journals with
    /// neither removal cause enabled (`ttl.enforce = off` and
    /// `stale.enforce = off` — the defaults) are skipped entirely.
    fn driveCheckpoints(self: *ClusterNode) !void {
        if (!self.isLeader()) return;
        const now = self.nowMs();
        var it = self.node.control.journals.iterator();
        while (it.next()) |entry_kv| {
            const jid = entry_kv.key_ptr.*;
            const js = self.node.journals.get(jid) orelse continue;
            const fold = &js.fold;
            const enforce = fold.settings.getEnum(schema.keyIndex("ttl.enforce").?);
            const stale_enforce = fold.settings.getEnum(schema.keyIndex("stale.enforce").?);
            const cleanup_enabled = !std.mem.eql(u8, enforce, "off") or
                !std.mem.eql(u8, stale_enforce, "off");
            if (!cleanup_enabled) continue;
            const head = fold.head orelse continue;

            const every = fold.settings.getU64(schema.keyIndex("checkpoint.every_ms").?);
            const pending_cap = fold.settings.getU64(schema.keyIndex("checkpoint.pending_bytes").?);
            const prev_due = self.next_checkpoint_ms.get(jid);

            // The first sight of a journal is due immediately (the cadence
            // bounds the rate, not the initial check); afterwards the due
            // time must live in the map, or every tick would recompute
            // `now + every` and the cadence would never elapse.
            var emit = prev_due == null or now >= prev_due.?;
            if (!emit) {
                // The pending-bytes early trigger: rescanned only when data
                // arrived since the last scan, never by a per-tick full scan.
                const prev_scan = self.last_scan_head.get(jid);
                const dirty = if (prev_scan) |p|
                    !(p.epoch == head.epoch and p.seq == head.seq)
                else
                    true;
                if (!dirty) continue;
                try self.last_scan_head.put(self.allocator, jid, head);
                const removed =
                    self.node.checkpointRemovalSet(jid, head, @intCast(now)) catch continue;
                const pending = removableBytes(removed, fold);
                self.allocator.free(removed);
                emit = pending >= pending_cap;
            }
            if (!emit) continue;

            const ckpt = self.node.checkpointForBroadcast(jid) catch |err| {
                // Skip this journal this tick; keep it due so a pending-bytes
                // trigger still retries after settle_ms (bug
                // 2026-08-29-settle-rule-kills-checkpoint-cadence).
                if (err == error.MergeSettling) {
                    try self.next_checkpoint_ms.put(self.allocator, jid, now);
                    continue;
                }
                return err;
            };
            if (ckpt) |c| {
                defer self.allocator.free(c.en.payload);
                self.broadcastToMembers(.{ .slot = .{
                    .reslotted = false,
                    .record = &.{},
                    .sl = c.sl,
                    .en = c.en,
                } });
            }
            try self.next_checkpoint_ms.put(self.allocator, jid, now +| every);
            try self.last_scan_head.put(self.allocator, jid, head);
        }
    }

    /// The payload bytes a removal set would reclaim (PRD 0002
    /// `checkpoint.pending_bytes`).
    fn removableBytes(
        removed: []const entry.Id,
        fold: *const chain.FoldState,
    ) u64 {
        var total: u64 = 0;
        for (removed) |id| {
            if (fold.entries.get(id)) |info| total +|= info.payload_len;
        }
        return total;
    }

    /// The connection to sync from: any connected member (the admitter
    /// first, but any member serves pages).
    fn syncPeerConn(self: *ClusterNode) ?u64 {
        var mit = self.members.valueIterator();
        while (mit.next()) |ms| {
            if (ms.conn_id != null) return ms.conn_id;
        }
        return null;
    }

    fn buildHello(self: *ClusterNode) ![]u8 {
        const h = message.Hello{
            .member_id = self.node.member_id,
            .public_key = self.node.keypair.public_key.toBytes(),
            .genesis_hash = self.node.group_hash,
            .address = self.options.address,
        };
        const body = try self.allocator.alloc(u8, 2 + message.helloLen(h));
        message.encode(.{ .hello = h }, body);
        return body;
    }

    fn sendMessage(self: *ClusterNode, conn_id: u64, m: message.Message) !void {
        const cs = self.conns.get(conn_id) orelse return error.NoConn;
        const body = try self.allocator.alloc(u8, message.encodedLen(m));
        defer self.allocator.free(body);
        message.encode(m, body);
        try cs.conn.send(self.io, body);
    }

    /// Encodes one record into a page. A record that does not fit is skipped
    /// only after the page already holds something; the first record is
    /// always encoded so an entry larger than `max_bytes` still moves.
    fn encodeRecordIntoPage(
        self: *ClusterNode,
        records: *std.ArrayListUnmanaged(u8),
        sl: *const slot.Slot,
        en: *const entry.Entry,
        bytes: *usize,
        max_bytes: u32,
    ) error{ StopServing, OutOfMemory }!void {
        const size = segment.recordSize(sl, en);
        if (bytes.* > 0 and bytes.* + size > @as(usize, max_bytes)) return error.StopServing;
        const buf = try self.allocator.alloc(u8, size);
        defer self.allocator.free(buf);
        segment.encodeRecord(sl, en, buf);
        try records.appendSlice(self.allocator, buf);
        bytes.* += size;
    }

    fn broadcastToMembers(self: *ClusterNode, m: message.Message) void {
        const body = self.allocator.alloc(u8, message.encodedLen(m)) catch return;
        defer self.allocator.free(body);
        message.encode(m, body);
        var it = self.conns.valueIterator();
        while (it.next()) |cs| {
            if (cs.member_id == null) continue;
            cs.conn.send(self.io, body) catch {};
        }
    }

    fn sendHeartbeat(self: *ClusterNode, ms: *MemberState) !void {
        const conn_id = ms.conn_id orelse return;
        const cs = self.conns.get(conn_id) orelse return error.NoConn;
        // The heartbeat body is fixed-size; a stack buffer avoids a heap
        // allocation per member per heartbeat interval (the most frequent
        // steady-state message in a cluster).
        var body: [2 + message.heartbeat_len]u8 = undefined;
        message.encode(.{ .heartbeat = .{
            .member_id = self.node.member_id,
            .epoch = self.epochNumber(),
            .head = self.node.control.head orelse .{ .epoch = 0, .seq = 0 },
            .last_ack = self.node.control.head orelse .{ .epoch = 0, .seq = 0 },
        } }, &body);
        try cs.conn.send(self.io, &body);
    }

    /// Closes a connection, marking its member lost and scheduling a redial.
    /// The teardown is deferred: the conn is shut down (its reader wakes
    /// with EOF), and the reader's peer-gone notice destroys it — the loop
    /// never frees a conn its reader may still be using.
    fn closeConn(self: *ClusterNode, conn_id: u64) void {
        const cs = self.conns.getPtr(conn_id) orelse return;
        if (cs.closing) return;
        cs.closing = true;
        if (cs.member_id) |id| {
            if (self.members.getPtr(id)) |ms| {
                // Not `.lost` here: the suspect timer owns that transition,
                // so a quick redial cannot eject the member from elections.
                ms.conn_id = null;
                ms.dial_at_ms = self.elapsedMs() + ms.backoff_ms;
                ms.backoff_ms = @min(ms.backoff_ms * 2, 8000);
            }
        }
        cs.conn.shutdown(self.io);
    }

    /// An advertised address is dialed, folded into the chain by a `join`,
    /// written as one `pending.admit` line and printed by `coppiz members`.
    /// It arrives from an un-admitted dialer, so it is held to the shape a
    /// real `host:port` has: printable ASCII, bounded length. That rules
    /// out the NUL/CR/LF that would inject extra `pending.admit` records
    /// and the escape sequences that would drive an operator's terminal.
    /// The founder advertises the empty string, which stays valid.
    fn addressSafe(address: []const u8) bool {
        if (address.len > max_address_len) return false;
        for (address) |c| {
            if (c < 0x21 or c > 0x7e) return false;
        }
        return true;
    }

    /// Closes a duplicate connection without touching the member's state;
    /// the reader's peer-gone notice destroys it.
    fn closeDupConn(self: *ClusterNode, conn_id: u64) void {
        const cs = self.conns.getPtr(conn_id) orelse return;
        if (cs.closing) return;
        cs.closing = true;
        cs.conn.shutdown(self.io);
    }

    fn nowMs(self: *ClusterNode) u64 {
        return @intCast(@max(@as(i64, 0), self.node.now(self.io)));
    }

    /// Elapsed-time measurements (the failure-detection windows, the
    /// heartbeat/dial/seed cadence): monotonic, so an NTP step or a manual
    /// clock change cannot satisfy a suspect/evict window in one tick or
    /// suspend the cadence until the clock catches up. Every reading here
    /// compares against another local reading — no instant crosses members —
    /// so the stamps and instants that do (slot, author, checkpoint) stay on
    /// the real clock via `nowMs`.
    fn elapsedMs(self: *ClusterNode) u64 {
        return @intCast(std.Io.Timestamp.now(self.io, .awake).toMilliseconds());
    }

    fn settingU64(self: *ClusterNode, comptime name: []const u8, default: u64) u64 {
        const key_index = schema.keyIndex(name) orelse return default;
        return self.node.control.settings.getU64(key_index);
    }

    fn settingU16(self: *ClusterNode, comptime name: []const u8, default: u16) u16 {
        const key_index = schema.keyIndex(name) orelse return default;
        return self.node.control.settings.getU16(key_index);
    }

    fn settingEnum(self: *ClusterNode, comptime name: []const u8, default: []const u8) []const u8 {
        const key_index = schema.keyIndex(name) orelse return default;
        return self.node.control.settings.getEnum(key_index);
    }

    fn updateTick(self: *ClusterNode) void {
        const heartbeat = self.settingU64("cluster.heartbeat_ms", 1000);
        const suspect = self.settingU64("cluster.suspect_after_ms", 5000);
        const min = @min(heartbeat, suspect);
        const tick: u32 = @intCast(@max(@min(@divFloor(min, 4), 1000), 10));
        self.tick_ms.store(tick, .release);
    }

    fn isLeader(self: *ClusterNode) bool {
        const epoch_state = self.node.control.epoch orelse return false;
        return std.mem.eql(u8, &epoch_state.leader, &self.node.member_id);
    }

    fn epochNumber(self: *ClusterNode) u64 {
        return if (self.node.control.epoch) |e| e.number else 0;
    }

    fn leaderId(self: *ClusterNode) [16]u8 {
        return if (self.node.control.epoch) |e| e.leader else [_]u8{0} ** 16;
    }

    // -- admission -----------------------------------------------------------

    /// Whether a hello is the node's own operator channel (the CLI client
    /// dials with this node's key): admitted, and never as a member peer.
    fn isSelfClient(self: *ClusterNode, h: message.Hello) bool {
        return std.mem.eql(u8, &h.member_id, &self.node.member_id) and
            std.mem.eql(u8, &h.public_key, &self.node.keypair.public_key.toBytes());
    }

    fn onHello(self: *ClusterNode, conn_id: u64, h: message.Hello) !void {
        const is_self_client = self.isSelfClient(h);
        // Admission first: until the hello is admitted it proves nothing
        // about who sent it, so it must not be able to touch another
        // member's state. A hello naming a member id the dialer does not
        // own would otherwise drop that member's live connection, and
        // `hello_ack` hands every dialer the leader's id to aim at.
        const ack = self.admission(h);
        if (!ack.admitted) {
            self.sendMessage(conn_id, .{ .hello_ack = ack }) catch {};
            self.closeConn(conn_id);
            return;
        }
        // A second connection for a member: replace the old one (a dead
        // conn whose peer_gone is still queued must not block the new dial).
        if (self.members.get(h.member_id)) |ms| {
            if (ms.conn_id != null and ms.conn_id.? != conn_id) {
                self.closeDupConn(ms.conn_id.?);
            }
        }

        try self.sendMessage(conn_id, .{ .hello_ack = ack });
        if (self.conns.getPtr(conn_id)) |cs| {
            // The node's own operator channel is not a member peer.
            if (is_self_client) {
                cs.role = .operator;
            } else {
                cs.member_id = h.member_id;
                cs.role = .member;
            }
        }
        if (is_self_client) return;

        if (self.members.getPtr(h.member_id)) |ms| {
            ms.conn_id = conn_id;
            ms.public_key = h.public_key;
            const updated = try self.allocator.dupe(u8, h.address);
            self.allocator.free(ms.address);
            ms.address = updated;
            ms.last_heard_ms = self.elapsedMs();
            ms.state = .member;
        } else {
            // A newcomer: the admitter appends its join, then it backfills.
            try self.members.put(self.allocator, h.member_id, .{
                .address = try self.allocator.dupe(u8, h.address),
                .public_key = h.public_key,
                .conn_id = conn_id,
                .last_heard_ms = self.elapsedMs(),
                .state = .member,
            });
            try self.admitNewcomer(h);
        }
    }

    /// The admission verdict for a hello: cluster match, then the mode.
    fn admission(self: *ClusterNode, h: message.Hello) message.HelloAck {
        // The id is derived from the key (PRD 0003 *Identity*); a hello that
        // names someone else's id with a different key is refused.
        const derived = chain.deriveMemberId(h.public_key);
        if (!std.mem.eql(u8, &h.member_id, &derived)) {
            return self.ackFor(false, .not_allowlisted);
        }
        // The address is refused here, before it can reach a `join` entry,
        // a dial or the operator's terminal.
        if (!addressSafe(h.address)) return self.ackFor(false, .not_allowlisted);
        // The node's own operator channel (the CLI client dials with this
        // node's key): admit without a join, and never as a member peer.
        if (self.isSelfClient(h)) return self.ackFor(true, .none);
        const my_genesis = self.node.group_hash;
        const have_chain = !std.mem.eql(u8, &my_genesis, &([_]u8{0} ** 32));
        const cluster_mismatch = have_chain and
            !std.mem.eql(u8, &h.genesis_hash, &([_]u8{0} ** 32)) and
            !std.mem.eql(u8, &h.genesis_hash, &my_genesis);
        if (cluster_mismatch) return self.ackFor(false, .wrong_genesis);
        // A member of the fold reconnecting is admitted by the chain itself,
        // but only with the key the chain already holds for that id.
        if (self.node.control.memberById(h.member_id)) |member| {
            if (!std.mem.eql(u8, &member.public_key, &h.public_key)) {
                return self.ackFor(false, .not_allowlisted);
            }
            return self.ackFor(true, .none);
        }
        if (self.members.get(h.member_id)) |ms| {
            const known = !std.mem.eql(u8, &ms.public_key, &([_]u8{0} ** 32));
            if (known and std.mem.eql(u8, &ms.public_key, &h.public_key)) {
                return self.ackFor(true, .none);
            }
        }
        const max_members = self.settingU16("cluster.max_members", 32);
        if (self.node.control.memberCount() >= max_members) {
            return self.ackFor(false, .max_members);
        }
        const mode = self.settingEnum("cluster.admission", "allowlist");
        if (std.mem.eql(u8, mode, "open")) return self.ackFor(true, .none);
        if (std.mem.eql(u8, mode, "prompt")) {
            // Record for the offline `coppiz admit`; refused until then.
            // A write failure must not claim the request is queued.
            self.recordPendingAdmit(h) catch return self.ackFor(false, .not_allowlisted);
            return self.ackFor(false, .prompt_pending);
        }
        // allowlist: the dialer's public key must be listed.
        for (self.options.allowlist) |key| {
            if (std.mem.eql(u8, &key, &h.public_key)) return self.ackFor(true, .none);
        }
        return self.ackFor(false, .not_allowlisted);
    }

    fn ackFor(self: *ClusterNode, admitted: bool, refusal: message.Refusal) message.HelloAck {
        return .{
            .admitted = admitted,
            .refusal = refusal,
            .member_id = self.node.member_id,
            .address = self.options.address,
            .genesis_hash = self.node.group_hash,
            .epoch = self.epochNumber(),
            .leader = self.leaderId(),
        };
    }

    /// Writes the newcomer's `join` entry (the fold admits any member, so
    /// whoever received the hello admits — PRD 0003 *Admission*).
    fn admitNewcomer(self: *ClusterNode, h: message.Hello) !void {
        const payload = try self.allocator.alloc(
            u8,
            membership.joinPayloadLen(.{
                .member_id = h.member_id,
                .public_key = h.public_key,
                .address = h.address,
            }),
        );
        defer self.allocator.free(payload);
        membership.encodeJoinPayload(
            .{ .member_id = h.member_id, .public_key = h.public_key, .address = h.address },
            payload,
        );
        _ = try self.authorControl(.join, payload);
    }

    fn recordPendingAdmit(self: *ClusterNode, h: message.Hello) !void {
        if (!addressSafe(h.address)) return;
        const line = try std.fmt.allocPrint(
            self.allocator,
            "{x} {x} {s}\n",
            .{ h.member_id, h.public_key, h.address },
        );
        defer self.allocator.free(line);
        const file = try self.node.store.data_dir.createFile(self.io, "pending.admit", .{
            .read = true,
            .truncate = false,
            .permissions = store.data_file_perm,
        });
        defer file.close(self.io);
        const len = try file.length(self.io);
        try file.writePositionalAll(self.io, line, len);
        try file.sync(self.io);
    }

    fn onHelloAck(self: *ClusterNode, conn_id: u64, a: message.HelloAck) !void {
        if (!a.admitted) {
            self.closeConn(conn_id);
            return;
        }
        if (self.conns.getPtr(conn_id)) |cs| {
            cs.member_id = a.member_id;
            cs.role = .member;
        }
        if (self.members.get(a.member_id)) |ms| {
            if (ms.conn_id != null and ms.conn_id.? != conn_id) {
                self.closeDupConn(ms.conn_id.?);
            }
        }
        const known_key = if (self.node.control.memberById(a.member_id)) |m|
            m.public_key
        else
            [_]u8{0} ** 32;
        if (self.members.getPtr(a.member_id)) |ms| {
            const updated = try self.allocator.dupe(u8, a.address);
            self.allocator.free(ms.address);
            ms.address = updated;
            if (!std.mem.eql(u8, &known_key, &([_]u8{0} ** 32))) ms.public_key = known_key;
            ms.conn_id = conn_id;
            ms.last_heard_ms = self.elapsedMs();
            ms.state = .member;
        } else {
            try self.members.put(self.allocator, a.member_id, .{
                .address = try self.allocator.dupe(u8, a.address),
                .public_key = known_key,
                .conn_id = conn_id,
                .last_heard_ms = self.elapsedMs(),
                .state = .member,
            });
        }
        // A chainless member was admitted: backfill from the responder.
        if (self.syncing) {
            if (!self.sync_cursors.contains(self.node.control.journal_id)) {
                try self.sync_cursors.put(
                    self.allocator,
                    self.node.control.journal_id,
                    .{ .epoch = 1, .seq = 1 },
                );
            }
        }
        // A newly reachable peer may be the leader that queued forwards
        // were waiting for.
        try self.reforwardQueue();
    }

    // -- the write path ------------------------------------------------------

    /// An embedded host's append (PRD 0005), processed in the loop exactly
    /// like a wire client's: build the entry as this member, queue it
    /// durably, then slot as leader or forward. The completion is posted
    /// exactly once on every path — a refusal or the slotted entry id.
    fn onLocalAppend(self: *ClusterNode, a: LocalAppend) void {
        const refuse = struct {
            fn go(c: *ClusterNode, completion: *LocalCompletion, refusal: []const u8) void {
                completeLocal(completion, c.io, undefined, refusal);
            }
        }.go;
        const jid = self.node.journalIdByName(a.journal) orelse {
            refuse(self, a.completion, "unknown_journal");
            return;
        };
        // The bound is the target journal's own setting (PRD 0004), the same
        // fold the wire append path reads — not the control journal's.
        const fold = self.foldFor(jid) orelse {
            refuse(self, a.completion, "unknown_journal");
            return;
        };
        const max_bytes = fold.settings.getU64(schema.keyIndex("journal.max_entry_bytes").?);
        if (a.payload.len > max_bytes) {
            refuse(self, a.completion, "too_large");
            return;
        }
        const en = self.signedEntry(.data, jid, a.payload, a.ttl_ms) catch |err| {
            refuse(self, a.completion, clientRefusalName(err));
            return;
        };
        self.node.queue.append(&en) catch |err| {
            refuse(self, a.completion, clientRefusalName(err));
            return;
        };
        self.noteBuilt(jid, en.author_seq) catch |err| {
            refuse(self, a.completion, clientRefusalName(err));
            return;
        };
        if (self.isLeader()) {
            _ = self.slotAndBroadcast(&en, false) catch |err| {
                refuse(self, a.completion, clientRefusalName(err));
                return;
            };
            completeLocal(a.completion, self.io, en.id(), "");
        } else {
            self.sendForward(&en) catch {};
            self.pending_locals.put(self.allocator, en.id(), a.completion) catch {
                refuse(self, a.completion, "internal");
                return;
            };
        }
    }

    /// Runs an embedded host's read over the loop's own state (no mutation
    /// can interleave — the loop is one thread) and copies the visible
    /// records into the host's completion. The host's callback never runs
    /// on this thread; it replays the copies on its own.
    fn onLocalRead(self: *ClusterNode, r: LocalRead) void {
        const completion = r.completion;
        self.node.readRange(
            r.journal_id,
            r.from,
            r.to,
            r.include_stale,
            r.include_expired,
            completion,
            struct {
                fn on(
                    c: *LocalReadCompletion,
                    sl: *const slot.Slot,
                    en: ?*const entry.Entry,
                ) anyerror!void {
                    const rec = try c.records.addOne(c.allocator);
                    rec.slot = sl.*;
                    rec.entry = null;
                    if (en) |e| {
                        rec.entry = .{
                            .kind = e.kind,
                            .journal = e.journal,
                            .author = e.author,
                            .author_seq = e.author_seq,
                            .author_ts_ms = e.author_ts_ms,
                            .ttl_ms = e.ttl_ms,
                            .payload_hash = e.payload_hash,
                            .signature = e.signature,
                            .payload_len = e.payload_len,
                            .payload_omitted = e.payload_omitted,
                            .payload = try c.allocator.dupe(u8, e.payload),
                        };
                    }
                }
            }.on,
        ) catch |err| {
            completeLocalRead(completion, self.io, err);
            return;
        };
        completeLocalRead(completion, self.io, null);
    }

    fn onAppend(self: *ClusterNode, conn_id: u64, a: message.Append) !void {
        const jid = self.node.journalIdByName(a.journal) orelse {
            try self.ackClient(conn_id, null, "unknown_journal");
            return;
        };
        const fold = self.foldFor(jid) orelse {
            try self.ackClient(conn_id, null, "unknown_journal");
            return;
        };
        const max_bytes = fold.settings.getU64(schema.keyIndex("journal.max_entry_bytes").?);
        if (a.payload.len > max_bytes) {
            try self.ackClient(conn_id, null, "too_large");
            return;
        }
        const en = self.signedEntry(.data, jid, a.payload, a.ttl_ms) catch |err| {
            try self.ackClient(conn_id, null, clientRefusalName(err));
            return;
        };
        self.node.queue.append(&en) catch |err| {
            try self.ackClient(conn_id, null, clientRefusalName(err));
            return;
        };
        self.noteBuilt(jid, en.author_seq) catch |err| {
            try self.ackClient(conn_id, null, clientRefusalName(err));
            return;
        };
        if (self.isLeader()) {
            _ = self.slotAndBroadcast(&en, false) catch |err| {
                try self.ackClient(conn_id, null, clientRefusalName(err));
                return;
            };
            try self.ackClient(conn_id, en.id(), "");
        } else {
            // Keep the client waiting on the durable queue; a send miss is
            // retried when a leader is reachable (reforwardQueue).
            self.sendForward(&en) catch {};
            try self.pending_clients.put(self.allocator, en.id(), conn_id);
        }
    }

    fn onForward(self: *ClusterNode, conn_id: u64, f: message.Forward) !void {
        const en = entry.decode(f.entry_bytes) catch {
            self.closeConn(conn_id);
            return;
        };
        if (self.isLeader()) {
            if (self.foldFor(en.journal) == null) {
                self.closeConn(conn_id);
                return;
            }
            if (self.entryKnown(en.journal, en.id())) return; // already slotted
            _ = try self.slotAndBroadcast(&en, false);
        } else if (self.leaderConnId()) |lid| {
            try self.sendMessage(lid, .{ .forward = f });
        }
    }

    /// Builds a signed entry as this member (the member you talk to is
    /// the author — the library API's shape, PRD 0005).
    fn signedEntry(
        self: *ClusterNode,
        kind: entry.Kind,
        journal_id: [16]u8,
        payload: []const u8,
        ttl_ms: u64,
    ) !entry.Entry {
        var en = entry.Entry{
            .kind = kind,
            .journal = journal_id,
            .author = self.node.member_id,
            .author_seq = self.nextAuthorSeq(journal_id),
            .author_ts_ms = self.nowMs(),
            .ttl_ms = ttl_ms,
            .payload_hash = entry.payloadHash(payload),
            .payload_len = @intCast(payload.len),
            .payload_omitted = false,
            .signature = undefined,
            .payload = payload,
        };
        en.signature = (try entry.sign(self.node.keypair, &en)).toBytes();
        return en;
    }

    /// The leader's slot step: position, store, fold, broadcast. Returns
    /// the slot (for acks). The record is encoded once and both the store
    /// write and the broadcast reuse the same bytes (the follower appends
    /// them verbatim), so a replicated slot costs one encode on the leader,
    /// not two.
    fn slotAndBroadcast(
        self: *ClusterNode,
        en: *const entry.Entry,
        reslotted: bool,
    ) !slot.Slot {
        const fold = self.foldFor(en.journal) orelse return error.UnknownJournal;
        const sl = try self.node.slotFor(fold, en);
        const prev_head = self.node.control.head;
        const record = try self.allocator.alloc(u8, segment.recordSize(&sl, en));
        defer self.allocator.free(record);
        segment.encodeRecord(&sl, en, record);
        try self.node.applyReplicated(en.journal, &sl, en, reslotted, record);
        if (en.kind == .epoch) {
            if (self.node.control.epoch) |ep| {
                if (sl.epoch > ep.number) {
                    self.branch_start = sl.position();
                    self.common_tail = prev_head;
                }
            }
        }
        self.broadcastToMembers(.{ .slot = .{
            .reslotted = reslotted,
            .record = record,
            .sl = sl,
            .en = en.*,
        } });
        return sl;
    }

    /// The leader's control-entry step for the control journal (join, merge,
    /// settings, leave): build, fold, store, broadcast. Returns the entry id
    /// and the slot (the merge needs the slot's seq and hash to chain its
    /// re-slots).
    fn authorControl(self: *ClusterNode, kind: entry.Kind, payload: []const u8) !Authored {
        return self.authorControlFold(&self.node.control, kind, payload);
    }

    /// authorControl for any chain: the control journal's, or a data
    /// journal's — journal-scoped control entries (`settings`, `stale`,
    /// `checkpoint`) live in the journal's own chain (PRD 0004), not the
    /// control journal's, where every member would refuse the scope.
    fn authorControlFold(
        self: *ClusterNode,
        fold: *chain.FoldState,
        kind: entry.Kind,
        payload: []const u8,
    ) !Authored {
        const en = try self.signedEntry(kind, fold.journal_id, payload, 0);
        try self.noteBuilt(fold.journal_id, en.author_seq);
        const sl = try self.slotAndBroadcast(&en, false);
        return .{ .id = en.id(), .sl = sl };
    }

    /// A new leader's first act: the epoch entry at (epoch+1, 1), signed by
    /// the new leader itself.
    fn appendEpoch(self: *ClusterNode, reason: epoch.Reason) !void {
        const fold = &self.node.control;
        const number = fold.epoch.?.number + 1;
        var payload: [epoch.epoch_payload_len]u8 = undefined;
        epoch.encodeEpochPayload(
            .{ .number = number, .reason = reason, .leader = self.node.member_id },
            &payload,
        );
        const en = try self.signedEntry(.epoch, fold.journal_id, &payload, 0);
        try self.noteBuilt(fold.journal_id, en.author_seq);
        var sl = slot.Slot{
            .epoch = number,
            .seq = 1,
            .slot_ts_ms = self.nowMs(),
            .entry_hash = entry.entryHash(&en),
            .prev_slot_hash = fold.head_slot_hash,
            .leader = self.node.member_id,
            .signature = undefined,
        };
        sl.signature = (try slot.sign(self.node.keypair, &sl)).toBytes();
        const prev_head = self.node.control.head;
        // Encode once for the store write and the broadcast, as in
        // `slotAndBroadcast`.
        const record = try self.allocator.alloc(u8, segment.recordSize(&sl, &en));
        defer self.allocator.free(record);
        segment.encodeRecord(&sl, &en, record);
        try self.node.applyReplicated(fold.journal_id, &sl, &en, false, record);
        self.branch_start = sl.position();
        self.common_tail = prev_head;
        self.broadcastToMembers(.{ .slot = .{
            .reslotted = false,
            .record = record,
            .sl = sl,
            .en = en,
        } });
        // Queued writes from the previous term: this member is now the
        // leader, so slot them rather than waiting for a forward target.
        try self.reforwardQueue();
    }

    /// Sends a queued entry to the leader (the durable forward step).
    fn sendForward(self: *ClusterNode, en: *const entry.Entry) !void {
        const lid = self.leaderConnId() orelse {
            // No leader reachable: the entry stays queued; it is re-forwarded
            // once a leader exists.
            return;
        };
        const cs = self.conns.get(lid) orelse return error.NoConn;
        // One allocation for the whole frame body (version | kind | u32 len |
        // entry) instead of an entry buffer copied into a second message
        // buffer.
        const entry_len = entry.header_len + en.payload.len;
        const body = try self.allocator.alloc(u8, 2 + 4 + entry_len);
        defer self.allocator.free(body);
        body[0] = message.version;
        body[1] = @intFromEnum(message.Kind.forward);
        std.mem.writeInt(u32, body[2..6], @intCast(entry_len), .little);
        try entry.encode(en, body[6..]);
        try cs.conn.send(self.io, body);
    }

    fn leaderConnId(self: *ClusterNode) ?u64 {
        // No epoch yet (a joiner before its first sync page): there is no
        // leader to forward to, which is a "not reachable" answer, not a
        // broken invariant — the caller keeps the entry queued.
        const epoch_state = self.node.control.epoch orelse return null;
        const ms = self.members.get(epoch_state.leader) orelse return null;
        return ms.conn_id;
    }

    fn clientRefusalName(err: anyerror) []const u8 {
        if (chain.refusalName(err)) |name| return name;
        return switch (err) {
            error.QueueFull => "queue_full",
            error.UnknownJournal => "unknown_journal",
            else => "failed",
        };
    }

    fn ackClient(self: *ClusterNode, conn_id: u64, id: ?entry.Id, refusal: []const u8) !void {
        const zero_id = entry.Id{ .author = [_]u8{0} ** 16, .author_seq = 0 };
        const position = if (id) |i|
            self.positionOf(i)
        else
            slot.Position{ .epoch = 0, .seq = 0 };
        try self.sendMessage(conn_id, .{ .ack = .{
            .id = id orelse zero_id,
            .position = position,
            .refusal = refusal,
        } });
    }

    fn positionOf(self: *ClusterNode, id: entry.Id) slot.Position {
        if (self.node.control.entries.get(id)) |info| return info.position;
        var it = self.node.journals.valueIterator();
        while (it.next()) |js| {
            if (js.*.fold.entries.get(id)) |info| return info.position;
        }
        return .{ .epoch = 0, .seq = 0 };
    }

    // -- replication in ------------------------------------------------------

    fn onSlot(self: *ClusterNode, conn_id: u64, m: message.SlotMsg) !void {
        const en = m.en orelse return;
        const jid = en.journal;
        // Sync pages carry everything; broadcasts are dropped while
        // backfilling or merging (the loser is still slotting its branch).
        if (self.syncing or self.merging_from != null) return;

        // The epoch's liveness half: a member that disagrees keeps its
        // previous view — a partition, resolved by the merge.
        if (en.kind == .epoch and !self.epochAccepted(&en, &m.sl)) {
            const payload = epoch.decodeEpochPayload(en.payload) catch {
                // A malformed epoch payload is a protocol violation: drop
                // the connection rather than silently keeping a stale view.
                self.closeConn(conn_id);
                return;
            };
            try self.onDivergence(conn_id, payload.leader, m.sl.epoch);
            return;
        }
        // Note my branch facts when an epoch folds (before the fold moves).
        var prev_head: ?slot.Position = null;
        if (en.kind == .epoch) prev_head = self.node.control.head;

        self.node.applyReplicated(jid, &m.sl, &en, m.reslotted, m.record) catch |err| switch (err) {
            error.BadPrevHash => {
                // The peer's chain does not chain to mine: a healed
                // partition, or a missed broadcast. From my own current
                // leader it is a redelivery only when the fold already
                // knows it — an unknown record is a gap in that journal,
                // caught up by a sync, not a merge (bug
                // 2026-08-28-follower-data-gap-stale; a different leader
                // stays the partition-merge path below).
                const my_leader = if (self.node.control.epoch) |ep| ep.leader else null;
                if (my_leader != null and
                    std.mem.eql(u8, &m.sl.leader, &my_leader.?) and
                    !self.entryKnown(jid, en.id()))
                {
                    try self.requestSync(conn_id, jid, self.headFor(jid).next());
                    return;
                }
                try self.onDivergence(conn_id, m.sl.leader, m.sl.epoch);
            },
            else => {
                // NotLeader (a stale leader's broadcast), DuplicateConflict,
                // etc. — the chain's own rules decide; nothing to do.
            },
        };
        // Branch facts only move for a *live* epoch (a new term); a
        // re-slotted epoch from a merge broadcast must not move them.
        if (en.kind == .epoch) {
            const ep = self.node.control.epoch orelse return;
            if (m.sl.epoch > ep.number and self.node.control.head != null) {
                self.branch_start = m.sl.position();
                self.common_tail = prev_head;
            }
        }
        // A client awaiting this entry's slot — the wire client or an
        // embedded host (PRD 0005).
        self.completePendingFor(&en);
    }

    /// Posts the ack/completion for an entry of mine that just folded — a
    /// wire client's ack and an embedded host's completion (PRD 0005).
    /// Called wherever the slot lands: a broadcast (onSlot), a sync page
    /// (onSyncPage), and the queue sweeps when the entry is already known
    /// (slotQueuedEntries / reforwardQueue). Without the sync-page and
    /// queue-sweep sites, a completion registered while backfilling is
    /// dropped by onSlot's sync guard and the host's write blocks forever
    /// (bug 2026-08-28-localappend-completion-lost).
    fn completePendingFor(self: *ClusterNode, en: *const entry.Entry) void {
        if (!std.mem.eql(u8, &en.author, &self.node.member_id)) return;
        if (self.pending_clients.fetchRemove(en.id())) |kv| {
            self.ackClient(kv.value, en.id(), "") catch {};
        }
        if (self.pending_locals.fetchRemove(en.id())) |kv| {
            completeLocal(kv.value, self.io, en.id(), "");
        }
    }

    fn nextHead(self: *ClusterNode) slot.Position {
        return (self.node.control.head orelse slot.Position{ .epoch = 0, .seq = 0 }).next();
    }

    fn onHeartbeat(self: *ClusterNode, conn_id: u64, hb: message.Heartbeat) !void {
        const cs = self.conns.get(conn_id) orelse return;
        const expected = cs.member_id orelse return;
        if (!std.mem.eql(u8, &hb.member_id, &expected)) return;
        const ms = self.members.getPtr(hb.member_id) orelse return;
        ms.last_heard_ms = self.elapsedMs();
        ms.head = hb.head;
        const my_head = self.node.control.head orelse slot.Position{ .epoch = 0, .seq = 0 };
        ms.state = if (slot.Position.order(hb.head, my_head) != .lt) .member else .syncing;
        // Gap catch-up: the peer is ahead of me.
        if (slot.Position.order(hb.head, my_head) == .gt) {
            const conn = ms.conn_id orelse return;
            self.requestSync(conn, self.node.control.journal_id, my_head.next()) catch {};
        }
    }

    // -- sync ----------------------------------------------------------------

    /// Requests one page of `journal_id` from `from` on the peer's conn.
    fn requestSync(
        self: *ClusterNode,
        conn_id: u64,
        journal_id: [16]u8,
        from: slot.Position,
    ) !void {
        if (self.sync_in_flight) return;
        self.sync_in_flight = true;
        self.sendMessage(conn_id, .{ .sync_req = .{
            .journal_id = journal_id,
            .from = from,
            .max_bytes = @min(provisional_page_bytes, net.framing.max_body_bytes),
        } }) catch {
            // The conn died mid-request; the failure detector will redial.
            self.sync_in_flight = false;
        };
    }

    fn onSyncReq(self: *ClusterNode, conn_id: u64, r: message.SyncReq) !void {
        // A chainless member asks for "the control journal" before it knows
        // the id; the zeros id means exactly that.
        const journal_id: [16]u8 = if (std.mem.eql(
            u8,
            &r.journal_id,
            &([_]u8{0} ** 16),
        ))
            self.node.control.journal_id
        else
            r.journal_id;
        if (std.mem.eql(u8, &journal_id, &([_]u8{0} ** 16))) {
            try self.sendMessage(conn_id, .{ .sync_page = .{
                .journal_id = r.journal_id,
                .next = r.from,
                .records = &.{},
            } });
            return;
        }
        var records = std.ArrayListUnmanaged(u8).empty;
        defer records.deinit(self.allocator);
        const Ctx = struct {
            self: *ClusterNode,
            from: slot.Position,
            records: *std.ArrayListUnmanaged(u8),
            next: slot.Position,
            bytes: usize,
            max_bytes: u32,
        };
        var ctx = Ctx{
            .self = self,
            .from = r.from,
            .records = &records,
            .next = r.from,
            .bytes = 0,
            .max_bytes = @min(r.max_bytes, net.framing.max_body_bytes),
        };
        self.node.store.scanFrom(journal_id, r.from, &ctx, struct {
            fn cb(c: *Ctx, sl: *const slot.Slot, en: ?*const entry.Entry) anyerror!void {
                if (slot.Position.order(sl.position(), c.from) == .lt) return;
                const e = en orelse return; // compacted records are not served (OQ 43)
                try c.self.encodeRecordIntoPage(c.records, sl, e, &c.bytes, c.max_bytes);
                c.next = sl.position().next();
            }
        }.cb) catch |err| switch (err) {
            error.StopServing => {},
            else => return err,
        };
        try self.sendMessage(conn_id, .{ .sync_page = .{
            .journal_id = journal_id,
            .next = ctx.next,
            .records = records.items,
        } });
    }

    fn onSyncPage(self: *ClusterNode, conn_id: u64, p: message.SyncPage) !void {
        self.sync_in_flight = false;
        // Merge mode: the survivor is fetching the loser's branch to re-slot
        // it; the records are buffered, never applied as-is.
        if (self.merging_from) |mconn| {
            if (conn_id != mconn) return; // drop other peers' pages while merging
            return self.mergePage(p, conn_id);
        }
        var off: usize = 0;
        while (off < p.records.len) {
            const rec = segment.decodeRecord(p.records[off..]) catch {
                self.closeConn(conn_id);
                return;
            };
            const e = rec.entry orelse {
                // A compacted record cannot be folded (OQ 43); refuse it.
                self.closeConn(conn_id);
                return;
            };
            // A gap-sync response can race broadcasts: records already
            // applied are skipped, never re-checked (the fold's dedup
            // cannot help — chain continuity fails first). A record at or
            // behind my head that the fold does NOT know means my head
            // advanced past a chain I never had — a divergence, not a
            // redelivery.
            const my_head = self.headFor(p.journal_id);
            if (slot.Position.order(rec.slot.position(), my_head) != .gt) {
                if (!self.entryKnown(p.journal_id, e.id())) {
                    try self.onDivergence(conn_id, rec.slot.leader, rec.slot.epoch);
                    return;
                }
                off += rec.next_offset;
                continue;
            }
            if (!std.mem.eql(
                u8,
                &rec.slot.prev_slot_hash,
                &self.headHashFor(p.journal_id),
            )) {
                // The peer's chain does not chain to mine: a healed
                // partition. Compute the survivor and act.
                try self.onDivergence(conn_id, rec.slot.leader, rec.slot.epoch);
                return;
            }
            // The epoch's liveness half (PRD 0003 *Epochs*): the claimed
            // leader must be what `leader(...)` returns for my liveness
            // view. A member that disagrees keeps its previous view — that
            // is a partition, and the merge resolves it.
            if (e.kind == .epoch and !self.epochAccepted(&e, &rec.slot)) {
                const payload = epoch.decodeEpochPayload(e.payload) catch {
                    self.closeConn(conn_id);
                    return;
                };
                try self.onDivergence(conn_id, payload.leader, rec.slot.epoch);
                return;
            }
            // The record bytes the page carried are the exact on-disk form,
            // so the store appends them verbatim (no re-encode).
            const raw = p.records[off .. off + rec.next_offset];
            self.node.applyReplicated(p.journal_id, &rec.slot, &e, false, raw) catch {
                self.closeConn(conn_id);
                return;
            };
            // A client or host awaiting this entry's slot: the broadcast
            // was dropped by the sync guard, so this apply is what must
            // post the ack/completion (bug
            // 2026-08-28-localappend-completion-lost).
            self.completePendingFor(&e);
            off += rec.next_offset;
        }
        if (self.syncing) {
            // Advance the cursor; a page that served nothing marks the
            // journal done.
            if (p.records.len > 0) {
                try self.sync_cursors.put(self.allocator, p.journal_id, p.next);
            } else {
                _ = self.sync_cursors.remove(p.journal_id);
                // The control chain is done: the fold now knows the data
                // journals, so start each one — a joiner's data cursors are
                // never seeded at admission (the fold is still empty then).
                if (std.mem.eql(u8, &p.journal_id, &self.node.control.journal_id)) {
                    var it = self.node.control.journals.iterator();
                    while (it.next()) |kv| {
                        if (!self.sync_cursors.contains(kv.key_ptr.*)) {
                            try self.sync_cursors.put(
                                self.allocator,
                                kv.key_ptr.*,
                                .{ .epoch = 1, .seq = 1 },
                            );
                        }
                    }
                }
            }
        }
    }

    /// Whether the fold already knows an entry id (the dedup test for
    /// redelivery versus divergence).
    fn entryKnown(self: *ClusterNode, journal_id: [16]u8, id: entry.Id) bool {
        const fold = self.foldFor(journal_id) orelse return false;
        return fold.entries.contains(id);
    }

    /// The current head of a journal's fold.
    fn headFor(self: *ClusterNode, journal_id: [16]u8) slot.Position {
        const fold = self.foldFor(journal_id) orelse return .{ .epoch = 0, .seq = 0 };
        return fold.head orelse .{ .epoch = 0, .seq = 0 };
    }

    /// The current head hash of a journal's fold (for the divergence check).
    fn headHashFor(self: *ClusterNode, journal_id: [16]u8) [32]u8 {
        const fold = self.foldFor(journal_id) orelse return [_]u8{0} ** 32;
        return fold.head_slot_hash;
    }

    // -- partition and merge -------------------------------------------------

    /// A healed partition: my chain and the peer's diverge. Both sides
    /// compute the same survivor (election.compareRank via epoch.survivor);
    /// the loser offers its branch, truncates to the common prefix and
    /// re-folds the survivor's chain; the survivor fetches and re-slots the
    /// loser's branch (PRD 0003 *Partition and merge*, OQ 44).
    fn onDivergence(
        self: *ClusterNode,
        conn_id: u64,
        peer_branch_leader: [16]u8,
        peer_branch_epoch: u64,
    ) !void {
        if (self.node.control.epoch == null) return;
        // A record from my own current leader is a redelivery, not a
        // partition branch; only a *different* elected leader diverges.
        if (std.mem.eql(u8, &peer_branch_leader, &self.node.control.epoch.?.leader)) return;
        const winner = self.survivorVs(peer_branch_leader) orelse {
            // The peer's branch leader is not a member: a forged chain.
            self.closeConn(conn_id);
            return;
        };
        if (winner == .a) {
            // I survive: fetch the peer's branch and re-slot it. (The loser
            // may not know it lost — only one side may have elected — so
            // the survivor initiates.)
            try self.beginMerge(conn_id, peer_branch_epoch);
            return;
        }
        try self.becomeLoser(conn_id);
    }

    /// The survivor's merge start: fetch the loser's branch from its first
    /// slot (every branch opens at `(branch_epoch, 1)`).
    fn beginMerge(self: *ClusterNode, conn_id: u64, branch_epoch: u64) !void {
        if (self.merging_from != null) return;
        self.merging_from = conn_id;
        const from: slot.Position = .{ .epoch = branch_epoch, .seq = 1 };
        try self.requestSync(conn_id, self.node.control.journal_id, from);
    }

    /// The loser's side of the merge: offer my branch to the survivor,
    /// truncate every journal to the common prefix, re-fold, and backfill
    /// the survivor's chain (which carries the merge and the re-slots).
    fn becomeLoser(self: *ClusterNode, conn_id: u64) !void {
        const my_leader = self.node.control.epoch.?.leader;
        const branch_head = self.node.control.head orelse return;
        if (self.common_tail == null) return; // no branch: just behind
        try self.sendMessage(conn_id, .{ .merge_offer = .{
            .branch_leader = my_leader,
            .branch_head = branch_head,
        } });
        // Truncate the control branch and re-fold now; the data branches are
        // truncated only after the survivor fetches them (merge_ack), or the
        // fetch would find them gone.
        // A failure here must surface: the merge_offer is already sent, so
        // silently keeping the branch would leave the survivor merging a
        // chain this side never truncated.
        try self.node.store.truncate(self.node.control.journal_id, self.common_tail.?);
        try self.node.refold();
        try self.resetMySeq();
        // My head just dropped below the survivor's; a peer whose advertised
        // head is still at or ahead of my new head is at head again.
        const my_head = self.node.control.head orelse slot.Position{ .epoch = 0, .seq = 0 };
        var mit = self.members.valueIterator();
        while (mit.next()) |ms| {
            if (ms.head.epoch != 0 or ms.head.seq != 0) {
                if (slot.Position.order(ms.head, my_head) != .lt) ms.state = .member;
            }
        }
        self.syncing = true;
        try self.sync_cursors.put(
            self.allocator,
            self.node.control.journal_id,
            self.common_tail.?.next(),
        );
    }

    /// The survivor fetched and re-slotted my data: truncate my data
    /// branches, re-fold, and re-sync them from the survivor.
    fn onMergeAck(self: *ClusterNode, conn_id: u64) !void {
        _ = conn_id;
        const tail = self.common_tail orelse return;
        var it = self.node.control.journals.iterator();
        while (it.next()) |kv| {
            const jid = kv.key_ptr.*;
            const pos = (try self.lastEpochPosition(jid, tail.epoch)) orelse
                slot.Position{ .epoch = 0, .seq = 0 };
            try self.node.store.truncate(jid, pos);
        }
        try self.node.refold();
        try self.resetMySeq();
        self.syncing = true;
        var dit = self.node.control.journals.iterator();
        while (dit.next()) |kv| {
            const jid = kv.key_ptr.*;
            const from = if (try self.lastEpochPosition(jid, tail.epoch)) |pos|
                pos.next()
            else
                slot.Position{ .epoch = 1, .seq = 1 };
            try self.sync_cursors.put(self.allocator, jid, from);
        }
    }

    /// The survivor's side: the loser offered its branch. Verify the
    /// survivor computation, then fetch the branch and re-slot it.
    fn onMergeOffer(self: *ClusterNode, conn_id: u64, offer: message.MergeOffer) !void {
        const winner = self.survivorVs(offer.branch_leader) orelse {
            self.closeConn(conn_id);
            return;
        };
        if (winner == .b) {
            // A race: the offerer computed the same survivor I did — but I
            // am the loser. (Both sides run the same pure rule, so this only
            // happens if my branch facts lagged; truncate and re-sync.)
            try self.becomeLoser(conn_id);
            return;
        }
        try self.beginMerge(conn_id, offer.branch_head.epoch);
    }

    /// Which branch survives, mine (`.a`) or the peer's (`.b`); null when
    /// the peer's branch leader is not a member (forged).
    fn survivorVs(self: *ClusterNode, peer_leader: [16]u8) ?epoch.Winner {
        const inputs = self.electionInputs();
        const my_leader = self.node.control.epoch.?.leader;
        const my_view = self.viewOf(my_leader) orelse return null;
        const peer_view = self.viewOf(peer_leader) orelse return null;
        return epoch.survivor(
            inputs,
            .{ .leader = my_leader, .leader_view = my_view },
            .{ .leader = peer_leader, .leader_view = peer_view },
        );
    }

    /// One member's election view from the fold's member table.
    fn viewOf(self: *ClusterNode, id: [16]u8) ?election.View {
        for (self.node.control.members.items) |m| {
            if (std.mem.eql(u8, &m.id, &id)) {
                return .{
                    .id = m.id,
                    .seniority = m.seniority,
                    .address = m.address,
                    .state = .member,
                    .last_ack = self.node.control.head orelse .{ .epoch = 0, .seq = 0 },
                };
            }
        }
        return null;
    }

    /// The last position of `epoch_no` in a journal's chain, if any.
    fn lastEpochPosition(self: *ClusterNode, journal_id: [16]u8, epoch_no: u64) !?slot.Position {
        const Ctx = struct {
            epoch_no: u64,
            last: ?slot.Position = null,
        };
        var ctx = Ctx{ .epoch_no = epoch_no };
        try self.node.store.scan(journal_id, &ctx, struct {
            fn cb(
                c: *Ctx,
                sl: *const slot.Slot,
                _: ?*const entry.Entry,
            ) anyerror!void {
                if (sl.epoch == c.epoch_no) c.last = sl.position();
            }
        }.cb);
        return ctx.last;
    }

    /// One page of the loser's branch (merge mode): buffer it; on the empty
    /// page the branch is complete — re-slot the control branch, then fetch
    /// and re-slot each data branch.
    fn mergePage(self: *ClusterNode, p: message.SyncPage, conn_id: u64) !void {
        const gop = try self.merge_buffers.getOrPut(self.allocator, p.journal_id);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.appendSlice(self.allocator, p.records);
        if (p.records.len > 0) {
            try self.requestSync(conn_id, p.journal_id, p.next);
            return;
        }
        const is_control = std.mem.eql(u8, &p.journal_id, &self.node.control.journal_id);
        if (is_control) {
            try self.doMergeControl(conn_id);
        } else {
            try self.doMergeData(conn_id, p.journal_id);
            try self.mergeNextData(conn_id);
        }
    }

    /// Appends the `merge` entry naming the loser's branch head, then
    /// re-slots the loser's control entries in branch order (reslotted, so
    /// settings/checkpoint/stale re-slot as no-ops — OQ 33).
    fn doMergeControl(self: *ClusterNode, conn_id: u64) !void {
        const control_id = self.node.control.journal_id;
        const buf_ptr = self.merge_buffers.getPtr(control_id) orelse {
            try self.mergeNextData(conn_id);
            return;
        };
        var decoded = std.ArrayListUnmanaged(struct {
            position: slot.Position,
            en: entry.Entry,
        }).empty;
        defer {
            for (decoded.items) |*d| self.allocator.free(d.en.payload);
            decoded.deinit(self.allocator);
        }
        const buf = buf_ptr.*;
        var off: usize = 0;
        while (off < buf.items.len) {
            // A record the peer sent that does not decode is a protocol
            // violation; erroring out (the loop closes the conn, and
            // peer-gone releases the merge) beats silently merging a
            // truncated branch.
            const rec = segment.decodeRecord(buf.items[off..]) catch
                return error.CorruptMergeBranch;
            const e = rec.entry orelse return error.CorruptMergeBranch;
            // The payload is copied: the buffer is freed when the merge
            // completes, but the re-slotted entries must survive it.
            try decoded.append(self.allocator, .{
                .position = rec.slot.position(),
                .en = .{
                    .kind = e.kind,
                    .journal = e.journal,
                    .author = e.author,
                    .author_seq = e.author_seq,
                    .author_ts_ms = e.author_ts_ms,
                    .ttl_ms = e.ttl_ms,
                    .payload_hash = e.payload_hash,
                    .signature = e.signature,
                    .payload_len = e.payload_len,
                    .payload_omitted = e.payload_omitted,
                    .payload = try self.allocator.dupe(u8, e.payload),
                },
            });
            off += rec.next_offset;
        }
        if (decoded.items.len == 0) {
            // An empty losing branch heals without a merge (G4).
            try self.mergeNextData(conn_id);
            return;
        }
        const head = decoded.items[decoded.items.len - 1].position;
        var merge_buf: [16]u8 = undefined;
        epoch.encodeMergePayload(
            .{ .branch_epoch = head.epoch, .branch_seq = head.seq },
            &merge_buf,
        );
        const authored = try self.authorControl(.merge, &merge_buf);
        // Re-slot in branch order, chained after the merge entry.
        var prev_hash = slot.slotHash(&authored.sl);
        var seq = authored.sl.seq + 1;
        for (decoded.items) |*d| {
            const en = d.en;
            const sl = try self.reslot(&en, prev_hash, seq, self.node.control.last_slot_ts_ms);
            try self.node.applyReplicated(control_id, &sl, &en, true, null);
            self.broadcastToMembers(.{ .slot = .{
                .reslotted = true,
                .record = &.{},
                .sl = sl,
                .en = en,
            } });
            prev_hash = slot.slotHash(&sl);
            seq += 1;
        }
        // Fetch each data branch next.
        var it = self.node.control.journals.iterator();
        while (it.next()) |kv| {
            try self.merge_pending.append(self.allocator, kv.key_ptr.*);
        }
        try self.mergeNextData(conn_id);
    }

    /// Re-slots one data branch into my data chain (new slots, same
    /// entries), then broadcasts.
    fn doMergeData(self: *ClusterNode, conn_id: u64, jid: [16]u8) !void {
        _ = conn_id;
        const buf_ptr = self.merge_buffers.getPtr(jid) orelse return;
        const js = self.node.journals.get(jid) orelse return;
        const fold = &js.fold;
        var prev_hash = fold.head_slot_hash;
        var seq: u64 = if (fold.head) |h|
            if (h.epoch == self.node.control.epoch.?.number) h.seq + 1 else 1
        else
            1;
        const buf = buf_ptr.*;
        var off: usize = 0;
        while (off < buf.items.len) {
            const rec = segment.decodeRecord(buf.items[off..]) catch
                return error.CorruptMergeBranch;
            const e = rec.entry orelse return error.CorruptMergeBranch;
            const sl = try self.reslot(&e, prev_hash, seq, fold.last_slot_ts_ms);
            try self.node.applyReplicated(jid, &sl, &e, false, null);
            self.broadcastToMembers(.{ .slot = .{
                .reslotted = false,
                .record = &.{},
                .sl = sl,
                .en = e,
            } });
            prev_hash = slot.slotHash(&sl);
            seq += 1;
            off += rec.next_offset;
        }
    }

    /// Fetches the next pending data branch, or completes the merge.
    fn mergeNextData(self: *ClusterNode, conn_id: u64) !void {
        if (self.merge_pending.items.len == 0) {
            self.merging_from = null;
            // The loser may truncate and re-sync its data now.
            self.sendMessage(conn_id, .merge_ack) catch {};
            var bit = self.merge_buffers.valueIterator();
            while (bit.next()) |buf| buf.deinit(self.allocator);
            self.merge_buffers.clearRetainingCapacity();
            return;
        }
        const jid = self.merge_pending.orderedRemove(0);
        // Every branch starts at the first slot of the post-common epoch.
        // A survivor that never elected has no common_tail of its own; its
        // current epoch *is* the common one (only the loser elected).
        const common_epoch = if (self.common_tail) |tail|
            tail.epoch
        else
            self.node.control.epoch.?.number;
        const from: slot.Position = .{ .epoch = common_epoch + 1, .seq = 1 };
        try self.requestSync(conn_id, jid, from);
    }

    /// A merge re-slot: the losing entry's unchanged bytes in a new slot
    /// signed by me, chained to `prev_hash` at `seq` (the simulator's
    /// reslot, PRD 0003 *Partition and merge*).
    fn reslot(
        self: *ClusterNode,
        en: *const entry.Entry,
        prev_hash: [32]u8,
        seq: u64,
        last_ts: u64,
    ) !slot.Slot {
        var sl = slot.Slot{
            .epoch = self.node.control.epoch.?.number,
            .seq = seq,
            // The live slot path clamps to the fold's last timestamp; a
            // regressed clock must not produce a re-slotted record older
            // than the fold's head (bug
            // 2026-08-29-merge-reslot-timestamp-unclamped).
            .slot_ts_ms = @max(self.nowMs(), last_ts),
            .entry_hash = entry.entryHash(en),
            .prev_slot_hash = prev_hash,
            .leader = self.node.member_id,
            .signature = undefined,
        };
        sl.signature = (try slot.sign(self.node.keypair, &sl)).toBytes();
        return sl;
    }

    // -- reads ---------------------------------------------------------------

    fn onReadReq(self: *ClusterNode, conn_id: u64, r: message.ReadReq) !void {
        const jid = self.node.journalIdByName(r.journal) orelse {
            // Refuse with a named refusal, matching the local read's
            // UnknownJournal, instead of answering with silent empty output
            // (bug 2026-08-28-sweep3-wire-read-unknown-journal).
            try self.sendMessage(conn_id, .{ .read_page = .{
                .next = .{ .epoch = 0, .seq = 0 },
                .records = &.{},
                .refusal = "unknown_journal",
            } });
            return;
        };
        var records = std.ArrayListUnmanaged(u8).empty;
        defer records.deinit(self.allocator);
        const from: ?slot.Position = if (r.from.epoch == 0 and r.from.seq == 0) null else r.from;
        const Ctx = struct {
            self: *ClusterNode,
            records: *std.ArrayListUnmanaged(u8),
            next: slot.Position,
            bytes: usize,
            stopped: bool,
            max_bytes: u32,
        };
        var ctx = Ctx{
            .self = self,
            .records = &records,
            .next = .{ .epoch = 0, .seq = 0 },
            .bytes = 0,
            .stopped = false,
            .max_bytes = @min(r.max_bytes, net.framing.max_body_bytes),
        };
        self.node.readRange(jid, from, null, r.include_stale, r.include_expired, &ctx, struct {
            fn cb(c: *Ctx, sl: *const slot.Slot, en: ?*const entry.Entry) anyerror!void {
                const e = en orelse {
                    // A retain=none compacted slot has no entry: emit the
                    // slot-only marker so the wire read matches the local
                    // read's (removed) row instead of silently dropping the
                    // position (bug 2026-08-29-wire-read-drops-compacted-slots).
                    const size = segment.slotOnlyRecordSize();
                    if (c.bytes > 0 and c.bytes + size > @as(usize, c.max_bytes)) {
                        c.stopped = true;
                        return;
                    }
                    const buf = try c.self.allocator.alloc(u8, size);
                    defer c.self.allocator.free(buf);
                    segment.encodeSlotOnlyRecord(sl, buf);
                    try c.records.appendSlice(c.self.allocator, buf);
                    c.bytes += size;
                    c.next = sl.position().next();
                    return;
                };
                c.self.encodeRecordIntoPage(c.records, sl, e, &c.bytes, c.max_bytes) catch |err| {
                    if (err == error.StopServing) c.stopped = true;
                    return err;
                };
                c.next = sl.position().next();
            }
        }.cb) catch |err| switch (err) {
            error.StopServing => {},
            else => return err,
        };
        const next: slot.Position = if (ctx.stopped)
            ctx.next
        else
            .{ .epoch = 0, .seq = 0 };
        try self.sendMessage(conn_id, .{ .read_page = .{
            .next = next,
            .records = records.items,
        } });
    }

    /// The member listing (`coppiz members` over the wire): the control
    /// fold's members, in fold order (seniority), plus this node's epoch
    /// and leader view.
    fn onMembersReq(self: *ClusterNode, conn_id: u64) !void {
        const fold = &self.node.control;
        const infos = try self.allocator.alloc(message.MemberInfo, fold.members.items.len);
        defer self.allocator.free(infos);
        for (fold.members.items, infos) |m, *info| {
            info.* = .{ .id = m.id, .seniority = m.seniority, .address = m.address };
        }
        try self.sendMessage(conn_id, .{ .members_page = .{
            .epoch = if (fold.epoch) |e| e.number else 0,
            .leader = if (fold.epoch) |e| e.leader else [_]u8{0} ** 16,
            .members = infos,
        } });
    }

    // -- settings ------------------------------------------------------------

    fn onSettings(self: *ClusterNode, conn_id: u64, s: message.Settings) !void {
        const jid = self.node.journalIdByName(s.journal) orelse {
            try self.ackClient(conn_id, null, "unknown_journal");
            return;
        };
        if (!self.isLeader()) {
            try self.ackClient(conn_id, null, "not_leader");
            return;
        }
        const changes = settings_fold.decodeChanges(self.allocator, s.changes, null) catch {
            try self.ackClient(conn_id, null, "invalid_settings");
            return;
        };
        defer {
            for (changes) |c| c.deinit(self.allocator);
            self.allocator.free(changes);
        }
        const is_control = std.mem.eql(u8, &jid, &self.node.control.journal_id);
        const payload = settings_fold.SettingsPayload{
            .scope = if (is_control) .cluster else .journal,
            .journal_id = if (is_control) [_]u8{0} ** 16 else jid,
            .changes = changes,
        };
        const buf = try self.allocator.alloc(u8, settings_fold.payloadLen(payload));
        defer self.allocator.free(buf);
        try settings_fold.encodePayload(payload, buf);
        // Journal-scoped changes are entries in the journal's own chain
        // (PRD 0004); cluster-scoped ones live in the control journal's.
        const authored =
            (if (is_control)
                self.authorControl(.settings, buf)
            else
                self.authorControlFold(
                    &self.node.journals.get(jid).?.fold,
                    .settings,
                    buf,
                )) catch |err| switch (err) {
                // A refused change must reach the caller as an ack, not leave
                // it waiting for a slot that never comes (a frozen leadership
                // key, an invalid value, a scope mismatch).
                error.NotLiveChangeable => {
                    try self.ackClient(conn_id, null, "not_live_changeable");
                    return;
                },
                error.InvalidSettings, error.ScopeMismatch => {
                    try self.ackClient(conn_id, null, "invalid_settings");
                    return;
                },
                else => {
                    try self.ackClient(conn_id, null, clientRefusalName(err));
                    return;
                },
            };
        try self.ackClient(conn_id, authored.id, "");
    }

    // -- election inputs -----------------------------------------------------

    /// Whether an epoch claiming `en`'s leader is what my liveness view
    /// elects; a syncing member accepts whatever chains (it has no view).
    /// Only a *live* epoch — one that opens a new term — is checked; a
    /// merge re-slot at the current epoch number is a no-op the inference
    /// applies regardless of who it claims.
    fn epochAccepted(self: *ClusterNode, en: *const entry.Entry, sl: *const slot.Slot) bool {
        if (self.syncing) return true;
        if (sl.epoch == self.node.control.epoch.?.number) return true;
        const payload = epoch.decodeEpochPayload(en.payload) catch return false;
        const inputs = self.electionInputs();
        const views = self.viewsFor() catch return false;
        defer self.allocator.free(views);
        const elected = election.leader(inputs, views) orelse return false;
        return std.mem.eql(u8, &elected, &payload.leader);
    }

    fn electionInputs(self: *ClusterNode) election.Inputs {
        const mode = self.settingEnum("leadership.mode", "seniority");
        const tiebreak = self.settingEnum("leadership.tiebreak", "seniority");
        const fallback = self.settingEnum("leadership.fallback", "stall");
        const authorities = self.node.control.settings.getList(
            schema.keyIndex("leadership.authorities").?,
        );
        return .{
            .mode = mode,
            .authorities = authorities,
            .tiebreak = tiebreak,
            .fallback = fallback,
        };
    }

    fn viewsFor(self: *ClusterNode) ![]election.View {
        const fold = &self.node.control;
        const views = try self.allocator.alloc(election.View, fold.members.items.len);
        errdefer self.allocator.free(views);
        for (fold.members.items, 0..) |member, i| {
            const is_me = std.mem.eql(u8, &member.id, &self.node.member_id);
            const state: election.State = if (is_me)
                if (self.syncing) .syncing else .member
            else if (self.members.get(member.id)) |ms|
                ms.state
            else
                .lost;
            views[i] = .{
                .id = member.id,
                .seniority = member.seniority,
                .address = member.address,
                .state = state,
                .last_ack = self.node.control.head orelse .{ .epoch = 0, .seq = 0 },
            };
        }
        return views;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const test_alloc = std.testing.allocator;
const tio = std.testing.io;

test "the loop serves a wire client over the hub: hello, append, read" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    tmp.dir.createDir(tio, "data", .default_dir) catch {};
    {
        // init's store takes ownership of the dir it opens and closes it.
        const data_dir = try tmp.dir.openDir(tio, "data", .{ .iterate = true });
        try journal.init(test_alloc, tio, data_dir, &.{}, "main", &journal.wallClock);
    }
    const data_dir = try tmp.dir.openDir(tio, "data", .{ .iterate = true });

    var hub = net.transport.Hub.init(test_alloc);
    defer hub.deinit(tio);
    const listener = try hub.listen(test_alloc, "node-a");
    const dialer = try hub.dialer(test_alloc, "node-a");

    var node = try journal.Node.open(test_alloc, tio, data_dir, .{ .replay_forward = true });
    defer node.deinit();
    var cn = try ClusterNode.init(test_alloc, tio, node, .{
        .transport = dialer,
        .listener = listener,
        .address = "node-a",
        .allowlist = &.{},
    });
    defer {
        cn.stop();
        cn.waitForStop();
        cn.deinit();
        listener.close(tio);
        dialer.deinit();
    }
    cn.start();

    // The node's own operator channel: same key, zero genesis.
    var client = try net.client.Client.connectTransport(
        test_alloc,
        tio,
        dialer,
        "node-a",
        node.member_id,
        node.keypair.public_key.toBytes(),
        [_]u8{0} ** 32,
        "",
    );
    defer client.deinit();
    const ack = try client.helloAck();
    try std.testing.expect(ack.admitted);

    const reply = try client.append("main", "hello", 0);
    try std.testing.expectEqual(@as(usize, 0), reply.refusal.len);
    try std.testing.expectEqual(@as(u64, 1), reply.id.author_seq);

    // The entry is in the node's chain, and a read over the wire sees it.
    const info = node.journals.get(node.journalIdByName("main").?).?.fold.entries.get(.{
        .author = node.member_id,
        .author_seq = 1,
    }).?;
    try std.testing.expectEqual(@as(u64, 1), info.position.seq);
    var seen = std.ArrayListUnmanaged([]const u8).empty;
    defer {
        for (seen.items) |p| test_alloc.free(p);
        seen.deinit(test_alloc);
    }
    try client.read("main", null, false, false, &seen, struct {
        fn cb(
            list: *std.ArrayListUnmanaged([]const u8),
            _: *const slot.Slot,
            en: ?*const entry.Entry,
        ) anyerror!void {
            if (en) |e| try list.append(test_alloc, try test_alloc.dupe(u8, e.payload));
        }
    }.cb);
    try std.testing.expectEqual(@as(usize, 1), seen.items.len);
    try std.testing.expectEqualStrings("hello", seen.items[0]);
}

test "append without hello is dropped and does not write" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    tmp.dir.createDir(tio, "data", .default_dir) catch {};
    {
        const data_dir = try tmp.dir.openDir(tio, "data", .{ .iterate = true });
        try journal.init(test_alloc, tio, data_dir, &.{}, "main", &journal.wallClock);
    }
    const data_dir = try tmp.dir.openDir(tio, "data", .{ .iterate = true });

    var hub = net.transport.Hub.init(test_alloc);
    defer hub.deinit(tio);
    const listener = try hub.listen(test_alloc, "node-a");
    const dialer = try hub.dialer(test_alloc, "node-a");

    var node = try journal.Node.open(test_alloc, tio, data_dir, .{ .replay_forward = true });
    defer node.deinit();
    var cn = try ClusterNode.init(test_alloc, tio, node, .{
        .transport = dialer,
        .listener = listener,
        .address = "node-a",
        .allowlist = &.{},
    });
    defer {
        cn.stop();
        cn.waitForStop();
        cn.deinit();
        listener.close(tio);
        dialer.deinit();
    }
    cn.start();

    var conn = try dialer.connect(tio, test_alloc, "node-a");
    defer conn.close(tio);
    const m = message.Message{ .append = .{
        .journal = "main",
        .payload = "unauthenticated",
        .ttl_ms = 0,
    } };
    const buf = try test_alloc.alloc(u8, message.encodedLen(m));
    defer test_alloc.free(buf);
    message.encode(m, buf);
    try conn.send(tio, buf);
    try std.testing.expectError(error.EndOfStream, conn.recv(tio, test_alloc));

    const jid = node.journalIdByName("main").?;
    try std.testing.expectEqual(@as(usize, 0), node.journals.get(jid).?.fold.entries.count());
}

test "hello whose member id does not derive from the key is refused" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    tmp.dir.createDir(tio, "data", .default_dir) catch {};
    {
        const data_dir = try tmp.dir.openDir(tio, "data", .{ .iterate = true });
        try journal.init(test_alloc, tio, data_dir, &.{}, "main", &journal.wallClock);
    }
    const data_dir = try tmp.dir.openDir(tio, "data", .{ .iterate = true });

    var hub = net.transport.Hub.init(test_alloc);
    defer hub.deinit(tio);
    const listener = try hub.listen(test_alloc, "node-a");
    const dialer = try hub.dialer(test_alloc, "node-a");

    var node = try journal.Node.open(test_alloc, tio, data_dir, .{ .replay_forward = true });
    defer node.deinit();
    var cn = try ClusterNode.init(test_alloc, tio, node, .{
        .transport = dialer,
        .listener = listener,
        .address = "node-a",
        .allowlist = &.{},
    });
    defer {
        cn.stop();
        cn.waitForStop();
        cn.deinit();
        listener.close(tio);
        dialer.deinit();
    }
    cn.start();

    var spoofed_id = node.member_id;
    spoofed_id[0] ^= 0xff;
    var client = try net.client.Client.connectTransport(
        test_alloc,
        tio,
        dialer,
        "node-a",
        spoofed_id,
        node.keypair.public_key.toBytes(),
        [_]u8{0} ** 32,
        "",
    );
    defer client.deinit();
    const ack = try client.helloAck();
    try std.testing.expect(!ack.admitted);
}

test "e2e (b): partition a 2-member seniority cluster, write on both sides, heal, merge" {
    // A founder and a joiner over the hub, with tiny failure-detector
    // timings from genesis. Join, partition, write on both sides, heal, and
    // assert one chain with every entry and identical folds (PRD 0003 G7).
    var tmp_a = std.testing.tmpDir(.{});
    defer tmp_a.cleanup();
    var tmp_b = std.testing.tmpDir(.{});
    defer tmp_b.cleanup();
    tmp_a.dir.createDir(tio, "data", .default_dir) catch {};
    tmp_b.dir.createDir(tio, "data", .default_dir) catch {};

    const heartbeat = schema.keyIndex("cluster.heartbeat_ms").?;
    const suspect = schema.keyIndex("cluster.suspect_after_ms").?;
    const genesis_changes = [_]validate.Change{
        .{ .key = heartbeat, .value = .{ .u64 = 50 } },
        // Suspect must outlast the loser's truncate+refold disk work.
        .{ .key = suspect, .value = .{ .u64 = 2000 } },
    };

    // A: founder with "main".
    {
        const data_dir = try tmp_a.dir.openDir(tio, "data", .{ .iterate = true });
        try journal.init(test_alloc, tio, data_dir, &genesis_changes, "main", &journal.wallClock);
    }
    const a_data_dir = try tmp_a.dir.openDir(tio, "data", .{ .iterate = true });
    var node_a = try journal.Node.open(test_alloc, tio, a_data_dir, .{ .replay_forward = true });
    var node_a_open = true;
    defer {
        if (node_a_open) node_a.deinit();
    }

    // B: a key-only joiner whose key A's allowlist admits.
    const b_kp = crypto.sign.Ed25519.KeyPair.generate(tio);
    {
        const data_dir = try tmp_b.dir.openDir(tio, "data", .{ .iterate = true });
        try journal.writeMemberKey(test_alloc, tio, data_dir, b_kp);
    }
    const b_data_dir = try tmp_b.dir.openDir(tio, "data", .{ .iterate = true });
    var node_b = try journal.Node.open(test_alloc, tio, b_data_dir, .{ .replay_forward = true });
    var node_b_open = true;
    defer {
        if (node_b_open) node_b.deinit();
    }

    var hub = net.transport.Hub.init(test_alloc);
    defer hub.deinit(tio);
    const listener_a = try hub.listen(test_alloc, "a");
    const dialer_a = try hub.dialer(test_alloc, "a");
    const listener_b = try hub.listen(test_alloc, "b");
    const dialer_b = try hub.dialer(test_alloc, "b");

    const b_key = b_kp.public_key.toBytes();
    var cn_a = try ClusterNode.init(test_alloc, tio, node_a, .{
        .transport = dialer_a,
        .listener = listener_a,
        .address = "a",
        .allowlist = &.{b_key},
    });
    var cn_a_stopped = false;
    defer {
        if (!cn_a_stopped) {
            cn_a.stop();
            cn_a.waitForStop();
        }
    }
    var cn_b = try ClusterNode.init(test_alloc, tio, node_b, .{
        .transport = dialer_b,
        .listener = listener_b,
        .address = "b",
        .seed_peers = &.{"a"},
    });
    var cn_b_stopped = false;
    defer {
        if (!cn_b_stopped) {
            cn_b.stop();
            cn_b.waitForStop();
        }
    }
    cn_a.start();
    cn_b.start();

    // Clients: each node's own operator channel.
    var client_a = try net.client.Client.connectTransport(
        test_alloc,
        tio,
        dialer_a,
        "a",
        node_a.member_id,
        node_a.keypair.public_key.toBytes(),
        [_]u8{0} ** 32,
        "",
    );
    defer client_a.deinit();
    var client_b = try net.client.Client.connectTransport(
        test_alloc,
        tio,
        dialer_b,
        "b",
        node_b.member_id,
        node_b.keypair.public_key.toBytes(),
        [_]u8{0} ** 32,
        "",
    );
    defer client_b.deinit();
    _ = try client_a.helloAck();
    _ = try client_b.helloAck();

    // Wait for B to be a member (its hello_ack epoch becomes 1).
    {
        const deadline = wallMs(tio) + 15_000;
        var joined = false;
        while (wallMs(tio) < deadline) {
            const ack = client_b.hello() catch {
                std.Io.sleep(tio, std.Io.Duration.fromMilliseconds(50), .awake) catch {};
                continue;
            };
            if (ack.epoch >= 1) {
                joined = true;
                break;
            }
            std.Io.sleep(tio, std.Io.Duration.fromMilliseconds(50), .awake) catch {};
        }
        try std.testing.expect(joined);
    }
    // Let B's backfill finish before the partition severs them: wait for
    // the node to stop syncing (control + data journals at the head)
    // instead of a fixed guess at the backfill time.
    {
        const deadline = wallMs(tio) + 10_000;
        var synced = false;
        while (wallMs(tio) < deadline) {
            if (!cn_b.syncing) {
                synced = true;
                break;
            }
            std.Io.sleep(tio, std.Io.Duration.fromMilliseconds(50), .awake) catch {};
        }
        try std.testing.expect(synced);
    }
    // Partition both ways.
    try hub.drop(test_alloc, tio, "a", "b");
    try hub.drop(test_alloc, tio, "b", "a");

    // Both sides elect: B (the follower) opens epoch 2.
    {
        const deadline = wallMs(tio) + 10_000;
        var elected = false;
        while (wallMs(tio) < deadline) {
            const ack = client_b.hello() catch {
                std.Io.sleep(tio, std.Io.Duration.fromMilliseconds(50), .awake) catch {};
                continue;
            };
            if (ack.epoch >= 2) {
                elected = true;
                break;
            }
            std.Io.sleep(tio, std.Io.Duration.fromMilliseconds(50), .awake) catch {};
        }
        try std.testing.expect(elected);
    }

    // Write on both sides during the partition.
    const reply_a = try client_a.append("main", "a1", 0);
    try std.testing.expectEqual(@as(usize, 0), reply_a.refusal.len);
    const reply_b = try client_b.append("main", "b1", 0);
    try std.testing.expectEqual(@as(usize, 0), reply_b.refusal.len);

    // Heal; the loops redial and the merge converges.
    try hub.heal(test_alloc, "a", "b");
    try hub.heal(test_alloc, "b", "a");

    // Poll: both nodes read both entries from "main".
    {
        const deadline = wallMs(tio) + 20_000;
        var converged = false;
        while (wallMs(tio) < deadline) {
            const have_a = try bothPayloads(&client_a, "main", "a1", "b1");
            const have_b = try bothPayloads(&client_b, "main", "a1", "b1");
            if (have_a and have_b) {
                converged = true;
                break;
            }
            std.Io.sleep(tio, std.Io.Duration.fromMilliseconds(100), .awake) catch {};
        }
        try std.testing.expect(converged);
    }

    // Stop both nodes and release their stores, then reopen and assert
    // identical folds (G7).
    cn_a.stop();
    cn_a.waitForStop();
    cn_b.stop();
    cn_b.waitForStop();
    cn_a_stopped = true;
    cn_b_stopped = true;
    cn_a.deinit();
    cn_b.deinit();
    listener_a.close(tio);
    listener_b.close(tio);
    dialer_a.deinit();
    dialer_b.deinit();
    node_a.deinit();
    node_b.deinit();
    node_a_open = false;
    node_b_open = false;
    {
        const dir_a = try tmp_a.dir.openDir(tio, "data", .{ .iterate = true });
        var na = try journal.Node.open(test_alloc, tio, dir_a, .{});
        defer na.deinit();
        const dir_b = try tmp_b.dir.openDir(tio, "data", .{ .iterate = true });
        var nb = try journal.Node.open(test_alloc, tio, dir_b, .{});
        defer nb.deinit();
        const hash_a = try na.control.hash(test_alloc);
        const hash_b = try nb.control.hash(test_alloc);
        try std.testing.expectEqualSlices(u8, &hash_a, &hash_b);
        // Every entry written on either side resolves on both.
        const main_a = na.journalIdByName("main").?;
        const main_b = nb.journalIdByName("main").?;
        var found_a: usize = 0;
        try na.readRange(main_a, null, null, true, true, &found_a, struct {
            fn cb(c: *usize, _: *const slot.Slot, _: ?*const entry.Entry) anyerror!void {
                c.* += 1;
            }
        }.cb);
        try std.testing.expectEqual(@as(usize, 2), found_a); // a1 + b1
        var found_b: usize = 0;
        try nb.readRange(main_b, null, null, true, true, &found_b, struct {
            fn cb(c: *usize, _: *const slot.Slot, _: ?*const entry.Entry) anyerror!void {
                c.* += 1;
            }
        }.cb);
        try std.testing.expectEqual(@as(usize, 2), found_b);
    }
}

fn bothPayloads(client: *net.client.Client, name: []const u8, a: []const u8, b: []const u8) !bool {
    const Ctx = struct {
        a: []const u8,
        b: []const u8,
        found_a: bool = false,
        found_b: bool = false,
    };
    var ctx = Ctx{ .a = a, .b = b };
    client.read(name, null, false, false, &ctx, struct {
        fn cb(c: *Ctx, _: *const slot.Slot, en: ?*const entry.Entry) anyerror!void {
            const e = en orelse return;
            if (std.mem.eql(u8, e.payload, c.a)) c.found_a = true;
            if (std.mem.eql(u8, e.payload, c.b)) c.found_b = true;
        }
    }.cb) catch return false;
    return ctx.found_a and ctx.found_b;
}

fn wallMs(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toMilliseconds();
}

/// A helper for the three-member tests: a node's harness (dir, node,
/// cluster, client). The caller owns everything and deinits in the given
/// order.
const TriNode = struct {
    tmp: std.testing.TmpDir,
    node: *journal.Node,
    cn: *ClusterNode,
    client: *net.client.Client,
};

fn triNodeInit(
    listen_addr: []const u8,
    seed: ?[]const u8,
    hub: *net.transport.Hub,
    keypair: ?crypto.sign.Ed25519.KeyPair,
    founded: ?std.testing.TmpDir,
    now: ?*const fn (std.Io) i64,
) !TriNode {
    var tmp = if (founded) |ft| ft else std.testing.tmpDir(.{});
    tmp.dir.createDir(tio, "data", .default_dir) catch {};
    const data_dir = try tmp.dir.openDir(tio, "data", .{ .iterate = true });
    if (keypair) |kp| try journal.writeMemberKey(test_alloc, tio, data_dir, kp);
    var node = try journal.Node.open(test_alloc, tio, data_dir, .{
        .replay_forward = true,
        .now = now orelse &journal.wallClock,
    });
    const listener = try hub.listen(test_alloc, listen_addr);
    const dialer = try hub.dialer(test_alloc, listen_addr);
    var cn = try ClusterNode.init(test_alloc, tio, node, .{
        .transport = dialer,
        .listener = listener,
        .address = listen_addr,
        .seed_peers = if (seed) |s| &.{s} else &.{},
    });
    cn.start();
    const client_ptr = try test_alloc.create(net.client.Client);
    client_ptr.* = try net.client.Client.connectTransport(
        test_alloc,
        tio,
        dialer,
        listen_addr,
        node.member_id,
        node.keypair.public_key.toBytes(),
        [_]u8{0} ** 32,
        "",
    );
    // Consume the connect-time hello reply; the first request must see its
    // own response.
    _ = try client_ptr.helloAck();
    return .{ .tmp = tmp, .node = node, .cn = cn, .client = client_ptr };
}

fn triNodeStop(t: *const TriNode) void {
    t.cn.stop();
    t.cn.waitForStop();
    if (t.cn.options.listener) |*l| l.close(t.cn.io);
    t.cn.options.transport.deinit_fn(t.cn.options.transport.ctx);
    t.cn.deinit();
    t.client.deinit();
    test_alloc.destroy(t.client);
    t.node.deinit();
    var tmp = t.tmp;
    tmp.cleanup();
}

test "e2e (c): configured leadership with a stall fallback never elects without its authority" {
    // A founds with open admission and fast failure detection; B and C join.
    const admission_key = schema.keyIndex("cluster.admission").?;
    const heartbeat = schema.keyIndex("cluster.heartbeat_ms").?;
    const suspect = schema.keyIndex("cluster.suspect_after_ms").?;
    const genesis_changes = [_]validate.Change{
        .{ .key = admission_key, .value = .{
            .enum_value = schema.enumValue(admission_key, "open").?,
        } },
        .{ .key = heartbeat, .value = .{ .u64 = 50 } },
        .{ .key = suspect, .value = .{ .u64 = 800 } },
    };
    var tmp_a = std.testing.tmpDir(.{});
    tmp_a.dir.createDir(tio, "data", .default_dir) catch {};
    {
        const data_dir = try tmp_a.dir.openDir(tio, "data", .{ .iterate = true });
        try journal.init(test_alloc, tio, data_dir, &genesis_changes, "main", &journal.wallClock);
    }
    var hub = net.transport.Hub.init(test_alloc);
    defer hub.deinit(tio);
    const dialer_a = try hub.dialer(test_alloc, "a");
    defer dialer_a.deinit();
    const a = try triNodeInit("a", null, &hub, null, tmp_a, null);
    defer triNodeStop(&a);
    const b_kp = crypto.sign.Ed25519.KeyPair.generate(tio);
    const b = try triNodeInit("b", "a", &hub, b_kp, null, null);
    defer triNodeStop(&b);
    const c_kp = crypto.sign.Ed25519.KeyPair.generate(tio);
    const c = try triNodeInit("c", "a", &hub, c_kp, null, null);
    defer triNodeStop(&c);

    // Both joiners reach the founder's view.
    const a_hex = try std.fmt.allocPrint(test_alloc, "{x}", .{a.node.member_id});
    defer test_alloc.free(a_hex);
    {
        const deadline = wallMs(tio) + 20_000;
        while (wallMs(tio) < deadline) {
            const hb = b.client.hello() catch continue;
            const hc = c.client.hello() catch continue;
            if (hb.epoch >= 1 and hc.epoch >= 1) break;
        }
        const hb = b.client.hello() catch return error.NotJoined;
        const hc = c.client.hello() catch return error.NotJoined;
        try std.testing.expect(hb.epoch >= 1);
        try std.testing.expect(hc.epoch >= 1);
    }

    // Reconfigure live: configured mode with A as the only authority.
    {
        const mode_key = schema.keyIndex("leadership.mode").?;
        const auth_key = schema.keyIndex("leadership.authorities").?;
        const mode_value = schema.enumValue(mode_key, "configured").?;
        const changes = [_]validate.Change{
            .{ .key = mode_key, .value = .{ .enum_value = mode_value } },
            .{ .key = auth_key, .value = .{ .string_list = &.{a_hex} } },
        };
        const len = settings_fold.changesLen(&changes);
        const buf = try test_alloc.alloc(u8, len);
        defer test_alloc.free(buf);
        try settings_fold.encodeChanges(&changes, buf);
        const reply = try a.client.settings("__cluster__", buf);
        try std.testing.expectEqual(@as(usize, 0), reply.refusal.len);
        // The settings must land on B and C before the partition severs
        // them; wait for the actual value on both control folds instead of
        // a fixed guess at the broadcast time (a poll is also robust on
        // slow machines — it waits until the broadcast has really landed).
        {
            const deadline = wallMs(tio) + 10_000;
            var landed = false;
            while (wallMs(tio) < deadline) {
                const b_mode = b.node.control.settings.getEnum(mode_key);
                const c_mode = c.node.control.settings.getEnum(mode_key);
                if (std.mem.eql(u8, b_mode, "configured") and
                    std.mem.eql(u8, c_mode, "configured"))
                {
                    landed = true;
                    break;
                }
                std.Io.sleep(tio, std.Io.Duration.fromMilliseconds(50), .awake) catch {};
            }
            try std.testing.expect(landed);
        }
    }

    // A still leads (the only authority).
    {
        const ack = try a.client.hello();
        try std.testing.expectEqual(@as(u64, 1), ack.epoch);
        try std.testing.expect(std.mem.eql(u8, &ack.leader, &a.node.member_id));
    }

    // Partition A from B and C.
    try hub.drop(test_alloc, tio, "a", "b");
    try hub.drop(test_alloc, tio, "b", "a");
    try hub.drop(test_alloc, tio, "a", "c");
    try hub.drop(test_alloc, tio, "c", "a");

    // Past the suspect timeout, neither B nor C elects: with no live
    // authority the stall fallback leaves the fold's leader unchanged.
    {
        std.Io.sleep(tio, std.Io.Duration.fromMilliseconds(2500), .awake) catch {};
        const hb = b.client.hello() catch return error.NoView;
        const hc = c.client.hello() catch return error.NoView;
        try std.testing.expectEqual(@as(u64, 1), hb.epoch);
        try std.testing.expect(std.mem.eql(u8, &hb.leader, &a.node.member_id));
        try std.testing.expectEqual(@as(u64, 1), hc.epoch);
        try std.testing.expect(std.mem.eql(u8, &hc.leader, &a.node.member_id));
    }

    // Heal: the same leader holds and everyone converges on it.
    try hub.heal(test_alloc, "a", "b");
    try hub.heal(test_alloc, "b", "a");
    try hub.heal(test_alloc, "a", "c");
    try hub.heal(test_alloc, "c", "a");
    {
        const deadline = wallMs(tio) + 20_000;
        var converged = false;
        while (wallMs(tio) < deadline) {
            const hb = b.client.hello() catch {
                std.Io.sleep(tio, std.Io.Duration.fromMilliseconds(100), .awake) catch {};
                continue;
            };
            if (hb.epoch == 1 and std.mem.eql(u8, &hb.leader, &a.node.member_id)) {
                converged = true;
                break;
            }
            std.Io.sleep(tio, std.Io.Duration.fromMilliseconds(100), .awake) catch {};
        }
        try std.testing.expect(converged);
    }
}

/// A wall-clock offset for the skew e2e (G6): the `now` the node's clock
/// function reports is shifted by a fixed offset, so the follower reads
/// through a different clock while its rate is unchanged.
fn skewedNow(comptime offset_ms: i64) *const fn (std.Io) i64 {
    return struct {
        fn now(io: std.Io) i64 {
            return journal.wallClock(io) + offset_ms;
        }
    }.now;
}

var test_ckpt_now: i64 = 1_000;

fn ckptFakeClock(_: std.Io) i64 {
    return test_ckpt_now;
}

test "driveCheckpoints skips MergeSettling instead of stopping the loop" {
    // Bug 2026-08-29-settle-rule-kills-checkpoint-cadence: the settle rule
    // is correct, but its only automatic caller treated the refusal as
    // fatal. A leader whose checkpoint is due inside merge.settle_ms of a
    // real merge must keep serving, then emit once the window has passed.
    test_ckpt_now = 1_000;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    tmp.dir.createDir(tio, "data", .default_dir) catch {};
    {
        const data_dir = try tmp.dir.openDir(tio, "data", .{ .iterate = true });
        try journal.init(test_alloc, tio, data_dir, &.{}, "main", &ckptFakeClock);
    }
    const data_dir = try tmp.dir.openDir(tio, "data", .{ .iterate = true });

    var hub = net.transport.Hub.init(test_alloc);
    defer hub.deinit(tio);
    const listener = try hub.listen(test_alloc, "node-a");
    const dialer = try hub.dialer(test_alloc, "node-a");

    var node = try journal.Node.open(test_alloc, tio, data_dir, .{
        .now = &ckptFakeClock,
        .replay_forward = true,
    });
    defer node.deinit();
    var cn = try ClusterNode.init(test_alloc, tio, node, .{
        .transport = dialer,
        .listener = listener,
        .address = "node-a",
        .allowlist = &.{},
    });
    defer {
        cn.deinit();
        listener.close(tio);
        dialer.deinit();
    }
    try std.testing.expect(cn.isLeader());

    const jid = node.journalIdByName("main").?;
    const enforce = schema.keyIndex("ttl.enforce").?;
    const ttl_default = schema.keyIndex("ttl.default_ms").?;
    const ttl_action = schema.keyIndex("ttl.action").?;
    const pending = schema.keyIndex("checkpoint.pending_bytes").?;
    test_ckpt_now = 2_000;
    const changes = [_]validate.Change{
        .{ .key = enforce, .value = .{
            .enum_value = schema.enumValue(enforce, "all").?,
        } },
        .{ .key = ttl_default, .value = .{ .u64 = 1000 } },
        .{ .key = ttl_action, .value = .{
            .enum_value = schema.enumValue(ttl_action, "delete").?,
        } },
        .{ .key = pending, .value = .{ .u64 = 1 } },
    };
    try node.changeSettings(jid, &changes);
    const expiring = try node.append(jid, "expiring", 0);

    test_ckpt_now = 4_000;
    var merge_buf: [16]u8 = undefined;
    epoch.encodeMergePayload(.{ .branch_epoch = 1, .branch_seq = 1 }, &merge_buf);
    try node.appendControl(.merge, &merge_buf, &node.control);
    try std.testing.expect(node.control.last_merge != null);

    const fold = &node.journals.get(jid).?.fold;
    try cn.driveCheckpoints();
    try std.testing.expectEqual(@as(usize, 0), fold.checkpoints.items.len);
    try std.testing.expect(cn.isLeader());
    try std.testing.expectEqual(@as(?u64, 4_000), cn.next_checkpoint_ms.get(jid));

    // Pending-bytes path: due time is still in the future, but the head
    // moved and pending >= cap. Must stay due after the skip.
    try cn.next_checkpoint_ms.put(cn.allocator, jid, 4_000 + 60_000);
    _ = cn.last_scan_head.remove(jid);
    try cn.driveCheckpoints();
    try std.testing.expectEqual(@as(usize, 0), fold.checkpoints.items.len);
    try std.testing.expectEqual(@as(?u64, 4_000), cn.next_checkpoint_ms.get(jid));

    test_ckpt_now = 4_000 + 30_000 + 1;
    try cn.driveCheckpoints();
    try std.testing.expect(fold.checkpoints.items.len >= 1);
    try std.testing.expect(fold.entries.get(expiring).?.removed);
}

// ---------------------------------------------------------------------------
// PRD 0002 phases 4-5 e2e: the leader's checkpoint cadence
// ---------------------------------------------------------------------------

const TtlTrio = struct {
    a: TriNode,
    b: TriNode,
    c: TriNode,
};

/// A three-member TTL cluster for the checkpoint e2e: A founds with open
/// admission and fast failure detection, "main" gets journal-scoped TTL
/// settings (per_entry expiry, delete action, a 150 ms cadence, the retain
/// value under test), and B and C join and settle. B's and C's clocks may be
/// skewed for the G6 case.
fn ttlTrioInit(
    hub: *net.transport.Hub,
    comptime retain: []const u8,
    b_now: ?*const fn (std.Io) i64,
    c_now: ?*const fn (std.Io) i64,
) !TtlTrio {
    const admission_key = schema.keyIndex("cluster.admission").?;
    const heartbeat = schema.keyIndex("cluster.heartbeat_ms").?;
    const suspect = schema.keyIndex("cluster.suspect_after_ms").?;
    const genesis_changes = [_]validate.Change{
        .{ .key = admission_key, .value = .{
            .enum_value = schema.enumValue(admission_key, "open").?,
        } },
        .{ .key = heartbeat, .value = .{ .u64 = 50 } },
        .{ .key = suspect, .value = .{ .u64 = 800 } },
    };
    var tmp_a = std.testing.tmpDir(.{});
    tmp_a.dir.createDir(tio, "data", .default_dir) catch {};
    {
        const data_dir = try tmp_a.dir.openDir(tio, "data", .{ .iterate = true });
        try journal.init(test_alloc, tio, data_dir, &genesis_changes, "main", &journal.wallClock);
    }
    var trio = TtlTrio{
        .a = try triNodeInit("a", null, hub, null, tmp_a, null),
        .b = undefined,
        .c = undefined,
    };
    errdefer triNodeStop(&trio.a);
    const b_kp = crypto.sign.Ed25519.KeyPair.generate(tio);
    trio.b = try triNodeInit("b", "a", hub, b_kp, null, b_now);
    errdefer triNodeStop(&trio.b);
    const c_kp = crypto.sign.Ed25519.KeyPair.generate(tio);
    trio.c = try triNodeInit("c", "a", hub, c_kp, null, c_now);
    errdefer triNodeStop(&trio.c);

    // Journal-scoped TTL settings on "main": per_entry expiry, delete
    // action, a fast cadence, and the retain value under test. (This is the
    // wire path for journal-scoped settings — the authoring side of the
    // fix that puts them in the journal's own chain.)
    const enforce = schema.keyIndex("ttl.enforce").?;
    const action = schema.keyIndex("ttl.action").?;
    const every = schema.keyIndex("checkpoint.every_ms").?;
    const retain_idx = schema.keyIndex("ttl.retain").?;
    const changes = [_]validate.Change{
        .{ .key = enforce, .value = .{
            .enum_value = schema.enumValue(enforce, "per_entry").?,
        } },
        .{ .key = action, .value = .{
            .enum_value = schema.enumValue(action, "delete").?,
        } },
        .{ .key = every, .value = .{ .u64 = 150 } },
        .{ .key = retain_idx, .value = .{
            .enum_value = schema.enumValue(retain_idx, retain).?,
        } },
    };
    const len = settings_fold.changesLen(&changes);
    const buf = try test_alloc.alloc(u8, len);
    defer test_alloc.free(buf);
    try settings_fold.encodeChanges(&changes, buf);
    const reply = try trio.a.client.settings("main", buf);
    if (reply.refusal.len != 0) return error.SettingsRefused;

    // Both joiners reach the founder's view.
    {
        const deadline = wallMs(tio) + 20_000;
        while (wallMs(tio) < deadline) {
            const hb = trio.b.client.hello() catch continue;
            const hc = trio.c.client.hello() catch continue;
            if (hb.epoch >= 1 and hc.epoch >= 1) break;
        }
        const hb = trio.b.client.hello() catch return error.NotJoined;
        const hc = trio.c.client.hello() catch return error.NotJoined;
        if (hb.epoch < 1 or hc.epoch < 1) return error.NotJoined;
    }
    // Let the joins and backfills settle before appends race them: wait for
    // every node to stop syncing instead of a fixed guess at the backfill
    // time.
    {
        const deadline = wallMs(tio) + 10_000;
        var settled = false;
        while (wallMs(tio) < deadline) {
            if (!trio.a.cn.syncing and !trio.b.cn.syncing and !trio.c.cn.syncing) {
                settled = true;
                break;
            }
            std.Io.sleep(tio, std.Io.Duration.fromMilliseconds(50), .awake) catch {};
        }
        try std.testing.expect(settled);
    }
    return trio;
}

fn ttlTrioStop(t: *const TtlTrio) void {
    triNodeStop(&t.a);
    triNodeStop(&t.b);
    triNodeStop(&t.c);
}

test "e2e (G4): three members remove the same set at the same checkpoint slot, both retain values" {
    const retains = [_][]const u8{ "header", "none" };
    inline for (retains) |retain| {
        var hub = net.transport.Hub.init(test_alloc);
        defer hub.deinit(tio);
        var trio = try ttlTrioInit(&hub, retain, null, null);
        defer ttlTrioStop(&trio);

        const main_id = trio.a.node.journalIdByName("main").?;
        // Three entries with 500 ms TTLs, appended through the leader and a
        // follower (forward + broadcast), so both write paths are covered.
        const payloads = [_][]const u8{ "t1", "t2", "t3" };
        var ids: [3]entry.Id = undefined;
        for (payloads, 0..) |p, i| {
            const client = if (i % 2 == 0) trio.a.client else trio.b.client;
            const reply = try client.append("main", p, 500);
            try std.testing.expectEqual(@as(usize, 0), reply.refusal.len);
            ids[i] = reply.id;
        }

        // Wait until every member's fold has removed all three entries.
        const deadline = wallMs(tio) + 20_000;
        var converged = false;
        while (wallMs(tio) < deadline) {
            const folds = [_]*chain.FoldState{
                &trio.a.node.journals.get(main_id).?.fold,
                &trio.b.node.journals.get(main_id).?.fold,
                &trio.c.node.journals.get(main_id).?.fold,
            };
            var all_removed = true;
            for (ids) |id| {
                for (folds) |f| {
                    const info = f.entries.get(id) orelse {
                        all_removed = false;
                        break;
                    };
                    if (!info.removed) all_removed = false;
                }
            }
            if (all_removed) {
                converged = true;
                break;
            }
            std.Io.sleep(tio, std.Io.Duration.fromMilliseconds(100), .awake) catch {};
        }
        try std.testing.expect(converged);

        const folds = [_]*chain.FoldState{
            &trio.a.node.journals.get(main_id).?.fold,
            &trio.b.node.journals.get(main_id).?.fold,
            &trio.c.node.journals.get(main_id).?.fold,
        };
        // The checkpoint that removed them is the same position on all
        // three — removal happened at the same chain position, not on each
        // member's clock.
        for (folds) |f| {
            try std.testing.expect(f.checkpoints.items.len >= 1);
        }
        const last_ckpt = folds[0].checkpoints.items[folds[0].checkpoints.items.len - 1];
        for (folds) |f| {
            try std.testing.expectEqual(
                last_ckpt,
                f.checkpoints.items[f.checkpoints.items.len - 1],
            );
        }

        // The payloads are gone from every member's store, per the retain
        // value: header-only (decodes with the payload omitted) or
        // slot-only (decodes with no entry at all). The fold marks removals
        // an instant before the member's own compaction runs, so this is a
        // poll, not a single read.
        const nodes = [_]*journal.Node{ trio.a.node, trio.b.node, trio.c.node };
        const compacted = struct {
            fn all(
                nodes_list: []const *journal.Node,
                jid: [16]u8,
                ids_list: []const entry.Id,
                comptime retain_val: []const u8,
            ) bool {
                for (nodes_list) |node| {
                    for (ids_list) |id| {
                        const info = node.journals.get(jid).?.fold.entries.get(id).?;
                        const size = 8 + slot.encoded_len + entry.header_len + info.payload_len;
                        const buf = node.allocator.alloc(u8, size) catch return false;
                        defer node.allocator.free(buf);
                        const rec =
                            (node.store.read(jid, info.position, buf) catch return false) orelse
                            return false;
                        if (std.mem.eql(u8, retain_val, "header")) {
                            const en = rec.entry orelse return false;
                            if (!en.payload_omitted or en.payload.len != 0) return false;
                        } else {
                            if (rec.entry != null) return false;
                        }
                    }
                }
                return true;
            }
        }.all;
        {
            const dl = wallMs(tio) + 10_000;
            var done = false;
            while (wallMs(tio) < dl) {
                if (compacted(&nodes, main_id, &ids, retain)) {
                    done = true;
                    break;
                }
                std.Io.sleep(tio, std.Io.Duration.fromMilliseconds(50), .awake) catch {};
            }
            try std.testing.expect(done);
        }

        // Identical folded state on all three (the same removal decisions).
        const hash_a = try folds[0].hash(test_alloc);
        const hash_b = try folds[1].hash(test_alloc);
        const hash_c = try folds[2].hash(test_alloc);
        try std.testing.expectEqualSlices(u8, &hash_a, &hash_b);
        try std.testing.expectEqualSlices(u8, &hash_a, &hash_c);

        // The pending-bytes early trigger: raise the cadence to "essentially
        // never" and lower the threshold to 1 byte. A fresh burst of TTL
        // entries must still produce a checkpoint well before the cadence
        // could — the trigger fires on the data it saw arrive.
        {
            const every_idx = schema.keyIndex("checkpoint.every_ms").?;
            const pending_idx = schema.keyIndex("checkpoint.pending_bytes").?;
            const changes = [_]validate.Change{
                .{ .key = every_idx, .value = .{ .u64 = 600_000 } },
                .{ .key = pending_idx, .value = .{ .u64 = 1 } },
            };
            const len = settings_fold.changesLen(&changes);
            const buf = try test_alloc.alloc(u8, len);
            defer test_alloc.free(buf);
            try settings_fold.encodeChanges(&changes, buf);
            const reply = try trio.a.client.settings("main", buf);
            try std.testing.expectEqual(@as(usize, 0), reply.refusal.len);
            // The leftover fast cadence fires once more with an empty set
            // (everything is already removed) and re-arms the next due to
            // the new 600 s cadence; wait it out so the burst below cannot
            // ride an old due time.
            {
                std.Io.sleep(tio, std.Io.Duration.fromMilliseconds(800), .awake) catch {};
            }
            // A streaming burst: each append moves the head, which is what
            // the pending-bytes probe rescans on.
            const burst_payloads = [_][]const u8{ "p1", "p2", "p3", "p4" };
            var burst: [4]entry.Id = undefined;
            for (burst_payloads, 0..) |p, i| {
                const reply2 = try trio.b.client.append("main", p, 300);
                try std.testing.expectEqual(@as(usize, 0), reply2.refusal.len);
                burst[i] = reply2.id;
                std.Io.sleep(tio, std.Io.Duration.fromMilliseconds(150), .awake) catch {};
            }
            // Well before the 600 s cadence, the pending trigger emits a
            // checkpoint that removes the burst.
            const dl2 = wallMs(tio) + 10_000;
            var pending_removed = false;
            while (wallMs(tio) < dl2) {
                const f = &trio.a.node.journals.get(main_id).?.fold;
                var ok = true;
                for (burst) |id| {
                    const info = f.entries.get(id) orelse {
                        ok = false;
                        break;
                    };
                    if (!info.removed) ok = false;
                }
                if (ok) {
                    pending_removed = true;
                    break;
                }
                std.Io.sleep(tio, std.Io.Duration.fromMilliseconds(100), .awake) catch {};
            }
            try std.testing.expect(pending_removed);
        }
    }
}

test "e2e (G6): a skewed follower's clock changes what it shows, not what it stores" {
    var hub = net.transport.Hub.init(test_alloc);
    defer hub.deinit(tio);
    var trio = try ttlTrioInit(&hub, "header", skewedNow(3_600_000), skewedNow(-3_600_000));
    defer ttlTrioStop(&trio);

    // No cadence removal during the observation window: the checkpoint
    // cadence is raised to "essentially never", so the entries expire on the
    // reader's clock but are not yet removed — the soft-visibility window a
    // checkpoint would close on every member alike (PRD 0002 failure modes).
    {
        const every_idx = schema.keyIndex("checkpoint.every_ms").?;
        const changes = [_]validate.Change{
            .{ .key = every_idx, .value = .{ .u64 = 600_000 } },
        };
        const len = settings_fold.changesLen(&changes);
        const buf = try test_alloc.alloc(u8, len);
        defer test_alloc.free(buf);
        try settings_fold.encodeChanges(&changes, buf);
        const reply = try trio.a.client.settings("main", buf);
        try std.testing.expectEqual(@as(usize, 0), reply.refusal.len);
    }

    const main_id = trio.a.node.journalIdByName("main").?;
    const payloads = [_][]const u8{ "s1", "s2", "s3" };
    for (payloads, 0..) |p, i| {
        const client = if (i % 2 == 0) trio.a.client else trio.b.client;
        const reply = try client.append("main", p, 1000);
        try std.testing.expectEqual(@as(usize, 0), reply.refusal.len);
    }

    // Past the expiry instant on the leader's clock (slot_ts + 1000 ms):
    // every member's fold has the same bytes, and no checkpoint has fired.
    {
        std.Io.sleep(tio, std.Io.Duration.fromMilliseconds(2500), .awake) catch {};
    }

    // The stored state is identical: all three folds hash the same.
    const folds = [_]*chain.FoldState{
        &trio.a.node.journals.get(main_id).?.fold,
        &trio.b.node.journals.get(main_id).?.fold,
        &trio.c.node.journals.get(main_id).?.fold,
    };
    const hash_a = try folds[0].hash(test_alloc);
    const hash_b = try folds[1].hash(test_alloc);
    const hash_c = try folds[2].hash(test_alloc);
    try std.testing.expectEqualSlices(u8, &hash_a, &hash_b);
    try std.testing.expectEqualSlices(u8, &hash_a, &hash_c);

    // What a default read shows differs with the reader's clock: A (real
    // time) and B (one hour ahead) hide the expired entries; C (one hour
    // behind) still shows them as live.
    const seen_a = try countMatchingPayloads(trio.a.client, "main", &payloads);
    const seen_b = try countMatchingPayloads(trio.b.client, "main", &payloads);
    const seen_c = try countMatchingPayloads(trio.c.client, "main", &payloads);
    try std.testing.expectEqual(@as(usize, 0), seen_a);
    try std.testing.expectEqual(@as(usize, 0), seen_b);
    try std.testing.expectEqual(@as(usize, 3), seen_c);
}

fn countMatchingPayloads(
    client: *net.client.Client,
    name: []const u8,
    wanted: []const []const u8,
) !usize {
    const Ctx = struct {
        wanted: []const []const u8,
        count: usize = 0,
    };
    var ctx = Ctx{ .wanted = wanted };
    try client.read(name, null, false, false, &ctx, struct {
        fn cb(c: *Ctx, _: *const slot.Slot, en: ?*const entry.Entry) anyerror!void {
            const e = en orelse return;
            for (c.wanted) |w| {
                if (std.mem.eql(u8, e.payload, w)) {
                    c.count += 1;
                    return;
                }
            }
        }
    }.cb);
    return ctx.count;
}

test "e2e: a newly elected leader slots its own queued entries" {
    // A founds with open admission and fast failure detection; B joins. The
    // partition is left unhealed on purpose: the merge path re-forwards the
    // loser's queue (becomeLoser -> resetMySeq), so only the leader path is
    // being asserted here.
    const admission_key = schema.keyIndex("cluster.admission").?;
    const heartbeat = schema.keyIndex("cluster.heartbeat_ms").?;
    const suspect = schema.keyIndex("cluster.suspect_after_ms").?;
    const genesis_changes = [_]validate.Change{
        .{ .key = admission_key, .value = .{
            .enum_value = schema.enumValue(admission_key, "open").?,
        } },
        .{ .key = heartbeat, .value = .{ .u64 = 50 } },
        .{ .key = suspect, .value = .{ .u64 = 800 } },
    };
    var tmp_a = std.testing.tmpDir(.{});
    tmp_a.dir.createDir(tio, "data", .default_dir) catch {};
    {
        const data_dir = try tmp_a.dir.openDir(tio, "data", .{ .iterate = true });
        try journal.init(test_alloc, tio, data_dir, &genesis_changes, "main", &journal.wallClock);
    }
    var hub = net.transport.Hub.init(test_alloc);
    defer hub.deinit(tio);
    const a = try triNodeInit("a", null, &hub, null, tmp_a, null);
    defer triNodeStop(&a);
    const b_kp = crypto.sign.Ed25519.KeyPair.generate(tio);
    const b = try triNodeInit("b", "a", &hub, b_kp, null, null);
    defer triNodeStop(&b);

    // B reaches the founder's view.
    {
        const deadline = wallMs(tio) + 20_000;
        var joined = false;
        while (wallMs(tio) < deadline) {
            const hb = b.client.hello() catch {
                std.Io.sleep(tio, std.Io.Duration.fromMilliseconds(50), .awake) catch {};
                continue;
            };
            if (hb.epoch >= 1) {
                joined = true;
                break;
            }
        }
        try std.testing.expect(joined);
    }
    // Let B's backfill settle before the partition: wait for the node to
    // stop syncing instead of a fixed guess at the backfill time.
    {
        const deadline = wallMs(tio) + 10_000;
        var synced = false;
        while (wallMs(tio) < deadline) {
            if (!b.cn.syncing) {
                synced = true;
                break;
            }
            std.Io.sleep(tio, std.Io.Duration.fromMilliseconds(50), .awake) catch {};
        }
        try std.testing.expect(synced);
    }

    try hub.drop(test_alloc, tio, "a", "b");
    try hub.drop(test_alloc, tio, "b", "a");

    // B is still a follower with A as the fold leader: the append is queued
    // durably and the forward cannot reach A. The ack only arrives once the
    // entry slots — which, on B's own election, is the leader's queue slot.
    const reply = try b.client.append("main", "b1", 0);
    try std.testing.expectEqual(@as(usize, 0), reply.refusal.len);

    // B elects itself (the failure detector passes the suspect timeout).
    {
        const deadline = wallMs(tio) + 15_000;
        var elected = false;
        while (wallMs(tio) < deadline) {
            const hb = b.client.hello() catch {
                std.Io.sleep(tio, std.Io.Duration.fromMilliseconds(50), .awake) catch {};
                continue;
            };
            if (hb.epoch >= 2) {
                elected = true;
                break;
            }
        }
        try std.testing.expect(elected);
    }

    // The queued entry is on B's own branch, slotted by the leader path.
    // "main" had no records before the partition, so its first slot in B's
    // branch is seq 1 — the branch itself (epoch 2) is the proof that B
    // slotted it as the elected leader.
    const main_id = b.node.journalIdByName("main").?;
    const fold = &b.node.journals.get(main_id).?.fold;
    const info = fold.entries.get(reply.id) orelse return error.QueueNeverSlotted;
    try std.testing.expectEqual(@as(u64, 2), info.position.epoch);
    try std.testing.expectEqual(@as(u64, 1), info.position.seq);
}

test "embedded host appends through the loop from its own thread (PRD 0005)" {
    // A founds with open admission and fast failure detection; B and C join.
    // The host — the test thread — appends through the loop of a follower
    // (B: queued, forwarded, slotted by A) and of the leader (A: slotted
    // directly), then both entries must be in every member's fold and read
    // back over the wire.
    const admission_key = schema.keyIndex("cluster.admission").?;
    const heartbeat = schema.keyIndex("cluster.heartbeat_ms").?;
    const suspect = schema.keyIndex("cluster.suspect_after_ms").?;
    const genesis_changes = [_]validate.Change{
        .{ .key = admission_key, .value = .{
            .enum_value = schema.enumValue(admission_key, "open").?,
        } },
        .{ .key = heartbeat, .value = .{ .u64 = 50 } },
        .{ .key = suspect, .value = .{ .u64 = 800 } },
    };
    var tmp_a = std.testing.tmpDir(.{});
    tmp_a.dir.createDir(tio, "data", .default_dir) catch {};
    {
        const data_dir = try tmp_a.dir.openDir(tio, "data", .{ .iterate = true });
        try journal.init(test_alloc, tio, data_dir, &genesis_changes, "main", &journal.wallClock);
    }
    var hub = net.transport.Hub.init(test_alloc);
    defer hub.deinit(tio);
    const a = try triNodeInit("a", null, &hub, null, tmp_a, null);
    defer triNodeStop(&a);
    const b_kp = crypto.sign.Ed25519.KeyPair.generate(tio);
    const b = try triNodeInit("b", "a", &hub, b_kp, null, null);
    defer triNodeStop(&b);
    const c_kp = crypto.sign.Ed25519.KeyPair.generate(tio);
    const c = try triNodeInit("c", "a", &hub, c_kp, null, null);
    defer triNodeStop(&c);

    // Both joiners reach the founder's view, then settle.
    {
        const deadline = wallMs(tio) + 20_000;
        while (wallMs(tio) < deadline) {
            const hb = b.client.hello() catch continue;
            const hc = c.client.hello() catch continue;
            if (hb.epoch >= 1 and hc.epoch >= 1) break;
        }
        const hb = b.client.hello() catch return error.NotJoined;
        const hc = c.client.hello() catch return error.NotJoined;
        if (hb.epoch < 1 or hc.epoch < 1) return error.NotJoined;
        // Settle = the joiners' backfills reached the head; wait for that
        // state instead of a fixed guess at the backfill time.
        const settle_deadline = wallMs(tio) + 10_000;
        var settled = false;
        while (wallMs(tio) < settle_deadline) {
            if (!b.cn.syncing and !c.cn.syncing) {
                settled = true;
                break;
            }
            std.Io.sleep(tio, std.Io.Duration.fromMilliseconds(50), .awake) catch {};
        }
        try std.testing.expect(settled);
    }

    // The host's own writes: through the follower (forwarded) and the
    // leader (slotted directly). Both block until the slot folds back.
    const id_follower = try b.cn.localAppend(tio, "main", "via-follower", 0);
    const id_leader = try a.cn.localAppend(tio, "main", "via-leader", 0);
    try std.testing.expect(std.mem.eql(u8, &id_follower.author, &b.node.member_id));
    try std.testing.expect(std.mem.eql(u8, &id_leader.author, &a.node.member_id));

    // Every member's fold has both entries.
    const main_id = a.node.journalIdByName("main").?;
    const deadline = wallMs(tio) + 15_000;
    var converged = false;
    while (wallMs(tio) < deadline) {
        const folds = [_]*chain.FoldState{
            &a.node.journals.get(main_id).?.fold,
            &b.node.journals.get(main_id).?.fold,
            &c.node.journals.get(main_id).?.fold,
        };
        var ok = true;
        for (folds) |f| {
            if (f.entries.get(id_follower) == null or f.entries.get(id_leader) == null) {
                ok = false;
            }
        }
        if (ok) {
            converged = true;
            break;
        }
        std.Io.sleep(tio, std.Io.Duration.fromMilliseconds(100), .awake) catch {};
    }
    try std.testing.expect(converged);

    // And they read back over the wire from a follower.
    const have = try bothPayloads(c.client, "main", "via-follower", "via-leader");
    try std.testing.expect(have);
}

test "embedded host reads through the loop from its own thread (PRD 0005)" {
    // A founds with open admission and fast failure detection; B joins. The
    // host — the test thread — appends through the loop (leader and
    // follower) exactly as the write-path test above, then reads the journal
    // back through its own member's loop: `localReadRange` posts the read to
    // the loop, which runs it over its own state and hands the host the
    // copied records — the host thread never touches the folds while the
    // loop runs.
    const admission_key = schema.keyIndex("cluster.admission").?;
    const heartbeat = schema.keyIndex("cluster.heartbeat_ms").?;
    const suspect = schema.keyIndex("cluster.suspect_after_ms").?;
    const genesis_changes = [_]validate.Change{
        .{ .key = admission_key, .value = .{
            .enum_value = schema.enumValue(admission_key, "open").?,
        } },
        .{ .key = heartbeat, .value = .{ .u64 = 50 } },
        .{ .key = suspect, .value = .{ .u64 = 800 } },
    };
    var tmp_a = std.testing.tmpDir(.{});
    tmp_a.dir.createDir(tio, "data", .default_dir) catch {};
    {
        const data_dir = try tmp_a.dir.openDir(tio, "data", .{ .iterate = true });
        try journal.init(test_alloc, tio, data_dir, &genesis_changes, "main", &journal.wallClock);
    }
    var hub = net.transport.Hub.init(test_alloc);
    defer hub.deinit(tio);
    const a = try triNodeInit("a", null, &hub, null, tmp_a, null);
    defer triNodeStop(&a);
    const b_kp = crypto.sign.Ed25519.KeyPair.generate(tio);
    const b = try triNodeInit("b", "a", &hub, b_kp, null, null);
    defer triNodeStop(&b);

    // The joiner reaches the founder's view, then settles.
    {
        const deadline = wallMs(tio) + 20_000;
        while (wallMs(tio) < deadline) {
            const hb = b.client.hello() catch continue;
            if (hb.epoch >= 1) break;
        }
        const hb = b.client.hello() catch return error.NotJoined;
        if (hb.epoch < 1) return error.NotJoined;
        // Settle = B's backfill reached the head; wait for that state
        // instead of a fixed guess at the backfill time.
        const settle_deadline = wallMs(tio) + 10_000;
        var settled = false;
        while (wallMs(tio) < settle_deadline) {
            if (!b.cn.syncing) {
                settled = true;
                break;
            }
            std.Io.sleep(tio, std.Io.Duration.fromMilliseconds(50), .awake) catch {};
        }
        try std.testing.expect(settled);
    }

    // The host's own writes: on the follower (forwarded) and on the leader
    // (slotted directly). Both block until the slot folds back.
    _ = try b.cn.localAppend(tio, "main", "via-follower", 0);
    _ = try a.cn.localAppend(tio, "main", "via-leader", 0);

    // Read back through the loop, polling until the follower's forwarded
    // entry replicates: the loop-routed read is the safe way to wait.
    const main_id = b.node.journalIdByName("main").?;
    const Seen = struct {
        payloads: [2][]const u8 = .{ "via-follower", "via-leader" },
        found: [2]bool = [_]bool{false} ** 2,
        ids: [2]entry.Id = undefined,
        count: usize = 0,
    };
    var seen = Seen{};
    const deadline = wallMs(tio) + 15_000;
    while (wallMs(tio) < deadline) {
        seen = .{};
        try b.cn.localReadRange(tio, main_id, null, null, false, false, &seen, struct {
            fn on(s: *Seen, _: *const slot.Slot, en: ?*const entry.Entry) anyerror!void {
                const e = en orelse return error.PayloadDropped;
                for (s.payloads, 0..) |p, i| {
                    if (std.mem.eql(u8, e.payload, p)) {
                        s.found[i] = true;
                        s.ids[i] = e.id();
                    }
                }
                s.count += 1;
            }
        }.on);
        if (seen.count == 2) break;
        std.Io.sleep(tio, std.Io.Duration.fromMilliseconds(100), .awake) catch {};
    }
    try std.testing.expectEqual(@as(usize, 2), seen.count);
    try std.testing.expect(seen.found[0] and seen.found[1]);
    // Each write is authored by the member that appended it.
    var saw_b = false;
    var saw_a = false;
    for (seen.ids[0..2]) |id| {
        if (std.mem.eql(u8, &id.author, &b.node.member_id)) saw_b = true;
        if (std.mem.eql(u8, &id.author, &a.node.member_id)) saw_a = true;
    }
    try std.testing.expect(saw_b and saw_a);

    // An empty window reads nothing.
    var empty: usize = 0;
    try b.cn.localReadRange(
        tio,
        main_id,
        .{ .epoch = 1, .seq = 1 },
        .{ .epoch = 1, .seq = 0 },
        false,
        false,
        &empty,
        struct {
            fn on(c: *usize, _: *const slot.Slot, _: ?*const entry.Entry) anyerror!void {
                c.* += 1;
            }
        }.on,
    );
    try std.testing.expectEqual(@as(usize, 0), empty);
}
