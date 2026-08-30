//! The deterministic simulator (OQ 27, roadmap item 5): a seeded,
//! single-threaded harness that drives the pure fold/election/merge
//! functions over N in-memory nodes with injected partitions, crashes,
//! clock skew and message reorder.
//!
//! It exists to exercise the *functions* the way the node loop will later be
//! driven by it — the roadmap places the simulator *before* the node loop so
//! the loop is written to be drivable by it. Nothing here touches a socket
//! or a disk: a `World` owns the nodes, the links between them, and the
//! messages; a node is a fold plus a liveness view; the scenario (the test)
//! tells the world when to partition, heal, crash and write.
//!
//! Scope: the control chain (membership, settings, epochs, merges). Data
//! journals share the same fold machinery (`applyControlReslotted`), and the
//! node-loop e2e exercises them; here the interesting entries are joins,
//! settings and epochs, which are exactly where merge semantics live.
//!
//! **The one non-obvious rule: on heal, every node re-folds from the last
//! common slot.** A member that folded the losing branch has branch entries
//! applied (a settings change, a join); the merged chain re-slots those
//! entries as no-ops (OQ 33), which converges the *survivor's* fold but
//! cannot undo what the loser already folded. Convergence therefore requires
//! the loser to discard its branch and fold the merged chain from the common
//! prefix — which is what `heal` does for every node. That is a fold
//! discipline, not a fold rule, and it is the part of PRD 0003 that the
//! simulator exists to pin down (see OQ 44).

const std = @import("std");
const crypto = std.crypto;
const entry = @import("../journal/entry.zig");
const slot = @import("../journal/slot.zig");
const chain = @import("../journal/chain.zig");
const schema = @import("../settings/schema.zig");
const validate = @import("../settings/validate.zig");
const settings_fold = @import("../settings/fold.zig");
const membership = @import("../cluster/membership.zig");
const election = @import("../cluster/election.zig");
const epoch = @import("../cluster/epoch.zig");
const cluster = @import("../cluster/node.zig");
const journal = @import("../journal/journal.zig");
const net = @import("../net/net.zig");

/// One message on the wire (and in a node's applied chain): a slot and its
/// entry. Owned by the world; nodes reference it. `reslotted` marks a
/// message produced by a merge (its slot is new, its entry is the losing
/// branch's unchanged bytes) so a fold replay knows which rule to apply.
pub const Message = struct {
    slot: slot.Slot,
    entry: entry.Entry,
    /// Owned by the world; `entry.payload` borrows it.
    payload: []u8,
    reslotted: bool,
};

pub const Node = struct {
    id: [16]u8,
    kp: crypto.sign.Ed25519.KeyPair,
    /// The advertised address (a borrowed literal in the scenarios).
    address: []const u8,
    alive: bool,
    /// This node's clock offset vs the world's: `now() = world.now + offset`.
    clock_offset_ms: i64,
    /// The control journal's fold.
    fold: chain.FoldState,
    /// The messages this node has folded, in chain order.
    chain: std.ArrayListUnmanaged(*const Message),
    /// Delivered but not yet chainable (reordered delivery, or a message
    /// whose predecessor has not arrived); processed on tick.
    inbox: std.ArrayListUnmanaged(*const Message),
};

pub const World = struct {
    allocator: std.mem.Allocator,
    prng: std.Random.DefaultPrng,
    now_ms: u64,
    control_id: [16]u8,
    nodes: std.ArrayListUnmanaged(Node),
    /// id -> index into `nodes`. Nodes are appended (init, addMember) and
    /// never removed — `crash` only marks them dead — so the map stays
    /// current for the world's lifetime. `nodeIndex` was a linear scan per
    /// lookup, and each `viewsFor` does one lookup per fold member per call.
    node_by_id: std.AutoHashMap([16]u8, usize),
    /// link[i * n + j]: whether node i may send to node j. A partition
    /// closes the links across its sets; self links are always open.
    links: std.ArrayListUnmanaged(bool),
    /// Deliver each broadcast in a shuffled order (only the receiving
    /// node's inbox order is shuffled; the fold is order-independent by
    /// design and holds non-chainable messages until their predecessor
    /// arrives).
    reorder: bool,
    /// The common head when the last partition started; `heal` re-folds
    /// every node from here.
    partition_head: ?slot.Position,
    /// The node indices per side of the last partition (exactly two sets);
    /// `heal` groups nodes by side, `reopenLinks` clears it.
    partition_sides: [2]std.ArrayListUnmanaged(usize),
    /// Every message ever built, owned here and freed at deinit.
    messages: std.ArrayListUnmanaged(*Message),

    pub fn init(
        allocator: std.mem.Allocator,
        seed: u64,
        control_id: [16]u8,
        genesis_changes: []const validate.Change,
    ) !World {
        var self = World{
            .allocator = allocator,
            .prng = std.Random.DefaultPrng.init(seed),
            .now_ms = 1000,
            .control_id = control_id,
            .nodes = .empty,
            .node_by_id = std.AutoHashMap([16]u8, usize).init(allocator),
            .links = .empty,
            .reorder = false,
            .partition_head = null,
            .partition_sides = .{ .empty, .empty },
            .messages = .empty,
        };
        errdefer self.deinit();

        // The founder: node 0, key derived from the seed so a scenario is
        // fully deterministic.
        const founder_kp = try self.derivedKey(0);
        const founder_id = chain.deriveMemberId(founder_kp.public_key.toBytes());
        try self.nodes.append(allocator, .{
            .id = founder_id,
            .kp = founder_kp,
            .address = "node-0",
            .alive = true,
            .clock_offset_ms = 0,
            .fold = try chain.FoldState.init(allocator, true, control_id),
            .chain = .empty,
            .inbox = .empty,
        });
        try self.node_by_id.put(founder_id, 0);
        try self.growLinks(1);

        // Genesis: the founder creates the cluster and folds its initial
        // settings. The payload is handed to makeMessage, which owns it.
        const genesis_changes_ref = genesis_changes;
        const g_len = chain.genesisPayloadLen(.{
            .founder_key = founder_kp.public_key.toBytes(),
            .changes = genesis_changes_ref,
        });
        const g_buf = try allocator.alloc(u8, g_len);
        try chain.encodeGenesisPayload(
            .{ .founder_key = founder_kp.public_key.toBytes(), .changes = genesis_changes_ref },
            g_buf,
        );
        const genesis = try self.makeMessage(0, .genesis, g_buf);
        try self.applyToNode(0, genesis);
        return self;
    }

    pub fn deinit(self: *World) void {
        for (self.messages.items) |msg| {
            self.allocator.free(msg.payload);
            self.allocator.destroy(msg);
        }
        self.messages.deinit(self.allocator);
        for (self.nodes.items) |*node| {
            node.fold.deinit();
            node.chain.deinit(self.allocator);
            node.inbox.deinit(self.allocator);
        }
        for (0..2) |i| self.partition_sides[i].deinit(self.allocator);
        self.node_by_id.deinit();
        self.nodes.deinit(self.allocator);
        self.links.deinit(self.allocator);
        self.* = undefined;
    }

    fn derivedKey(_: *World, index: usize) !crypto.sign.Ed25519.KeyPair {
        var seed: [32]u8 = undefined;
        crypto.hash.sha2.Sha256.hash(&std.mem.toBytes(index), &seed, .{});
        return crypto.sign.Ed25519.KeyPair.generateDeterministic(seed);
    }

    /// Extends the link matrix to n×n (n = the new member count). The
    /// matrix width changes with the count, so a flat extension would shift
    /// every existing cell's (row, column) meaning; the old values are
    /// rewritten at the new stride instead. New links start open; links a
    /// partition closed stay closed (bug
    /// 2026-08-28-sim-growlinks-reopens-partition).
    fn growLinks(self: *World, n: usize) !void {
        const old_n = n - 1;
        if (old_n > 0) {
            const old = try self.allocator.dupe(bool, self.links.items);
            defer self.allocator.free(old);
            try self.links.resize(self.allocator, n * n);
            var i: usize = 0;
            while (i < old_n) : (i += 1) {
                var j: usize = 0;
                while (j < old_n) : (j += 1) {
                    self.links.items[i * n + j] = old[i * old_n + j];
                }
            }
        } else {
            try self.links.resize(self.allocator, 1);
        }
        // The newcomer's row and column start open. Some of those cells sit
        // in the old matrix's range (a closed link's flat slot now means a
        // link to the newcomer), so they are set explicitly, not left to
        // the resize.
        var k: usize = 0;
        while (k <= old_n) : (k += 1) {
            self.links.items[k * n + old_n] = true;
            self.links.items[old_n * n + k] = true;
        }
    }

    /// Whether node `from` may send to node `to` right now.
    fn linkOpen(self: *World, from: usize, to: usize) bool {
        return self.links.items[from * self.nodes.items.len + to];
    }

    fn nodeIndex(self: *World, id: [16]u8) ?usize {
        return self.node_by_id.get(id);
    }

    pub fn nodeId(self: *World, index: usize) [16]u8 {
        return self.nodes.items[index].id;
    }

    pub fn setSkew(self: *World, index: usize, offset_ms: i64) void {
        self.nodes.items[index].clock_offset_ms = offset_ms;
    }

    pub fn crash(self: *World, index: usize) void {
        self.nodes.items[index].alive = false;
    }

    pub fn setReorder(self: *World, on: bool) void {
        self.reorder = on;
    }

    fn nodeNow(self: *World, index: usize) u64 {
        const offset: i64 = self.nodes.items[index].clock_offset_ms;
        const now: i64 = @intCast(self.now_ms);
        return @intCast(@max(now + offset, 0));
    }

    /// Builds a message: a signed entry and its slot, stamped by the node's
    /// clock, not yet folded or sent. The caller keeps ownership of the
    /// payload by handing it over here. A re-slot is built by `reslot`,
    /// which preserves the entry's bytes.
    fn makeMessage(self: *World, index: usize, kind: entry.Kind, payload: []u8) !*const Message {
        const node = &self.nodes.items[index];
        const seq: u64 = if (kind == .epoch)
            1
        else
            (node.fold.head orelse slot.Position{ .epoch = 0, .seq = 0 }).seq + 1;
        const ep: u64 = if (kind == .genesis)
            1
        else if (kind == .epoch)
            node.fold.epoch.?.number + 1
        else
            node.fold.epoch.?.number;

        var en = entry.Entry{
            .kind = kind,
            .journal = self.control_id,
            .author = node.id,
            .author_seq = nextAuthorSeq(&node.fold, node.id),
            .author_ts_ms = 0,
            .ttl_ms = 0,
            .payload_hash = entry.payloadHash(payload),
            .payload_len = @intCast(payload.len),
            .payload_omitted = false,
            .signature = undefined,
            .payload = payload,
        };
        en.signature = (try entry.sign(node.kp, &en)).toBytes();

        var sl = slot.Slot{
            .epoch = ep,
            .seq = seq,
            .slot_ts_ms = self.nodeNow(index),
            .entry_hash = entry.entryHash(&en),
            .prev_slot_hash = node.fold.head_slot_hash,
            .leader = node.id,
            .signature = undefined,
        };
        sl.signature = (try slot.sign(node.kp, &sl)).toBytes();

        const msg = try self.allocator.create(Message);
        msg.* = .{ .slot = sl, .entry = en, .payload = payload, .reslotted = false };
        try self.messages.append(self.allocator, msg);
        return msg;
    }

    /// Folds a message into a node and records it in the node's chain.
    fn applyToNode(self: *World, index: usize, msg: *const Message) !void {
        const node = &self.nodes.items[index];
        if (msg.reslotted) {
            try node.fold.applyControlReslotted(&msg.slot, &msg.entry);
        } else {
            try node.fold.applyControl(&msg.slot, &msg.entry);
        }
        try node.chain.append(self.allocator, msg);
    }

    /// Folds a fresh message locally (the node is its author and leader) and
    /// enqueues it to every reachable peer, shuffled when reorder is on.
    /// No leadership check — callers that require one check first. Takes
    /// ownership of `payload`.
    fn slotAndBroadcast(self: *World, index: usize, kind: entry.Kind, payload: []u8) !void {
        const msg = try self.makeMessage(index, kind, payload);
        try self.applyToNode(index, msg);
        var sent: [64]usize = undefined;
        var sent_count: usize = 0;
        for (self.nodes.items, 0..) |_, j| {
            if (j == index) continue;
            if (!self.nodes.items[j].alive) continue;
            if (!self.linkOpen(index, j)) continue;
            std.debug.assert(sent_count < sent.len);
            sent[sent_count] = j;
            sent_count += 1;
        }
        if (self.reorder) {
            self.prng.random().shuffle(usize, sent[0..sent_count]);
        }
        for (sent[0..sent_count]) |j| {
            try self.nodes.items[j].inbox.append(self.allocator, msg);
            if (self.reorder) {
                self.prng.random().shuffle(
                    *const Message,
                    self.nodes.items[j].inbox.items,
                );
            }
        }
    }

    /// The leader of a node's own liveness view: what `leader(...)` returns
    /// for that node. `null` under configured/combined with stall when no
    /// authority is live.
    pub fn leaderOf(self: *World, index: usize) !?[16]u8 {
        const node = &self.nodes.items[index];
        const views = try self.viewsFor(index);
        defer self.allocator.free(views);
        return election.leader(electionInputs(node), views);
    }

    /// This node's view of member `target_id`: lost when the link is closed
    /// or the node crashed; syncing when it has less than the observer;
    /// member otherwise.
    fn stateOf(self: *World, observer: usize, target_id: [16]u8) election.State {
        if (std.mem.eql(u8, &target_id, &self.nodes.items[observer].id)) return .member;
        const target = self.nodeIndex(target_id) orelse return .lost;
        if (!self.nodes.items[target].alive) return .lost;
        if (!self.linkOpen(observer, target)) return .lost;
        const target_head = self.nodes.items[target].fold.head orelse slot.Position{
            .epoch = 0,
            .seq = 0,
        };
        const observer_head = self.nodes.items[observer].fold.head orelse slot.Position{
            .epoch = 0,
            .seq = 0,
        };
        return if (slot.Position.order(target_head, observer_head) != .lt) .member else .syncing;
    }

    /// One election.View per fold member, from the observer's liveness
    /// view; `last_ack` is each member's own folded head (for freshest).
    fn viewsFor(self: *World, observer: usize) ![]election.View {
        const node = &self.nodes.items[observer];
        const views = try self.allocator.alloc(election.View, node.fold.members.items.len);
        errdefer self.allocator.free(views);
        for (node.fold.members.items, 0..) |member, i| {
            const head = if (std.mem.eql(u8, &member.id, &node.id))
                node.fold.head orelse slot.Position{ .epoch = 0, .seq = 0 }
            else blk: {
                const idx = self.nodeIndex(member.id) orelse break :blk slot.Position{
                    .epoch = 0,
                    .seq = 0,
                };
                break :blk self.nodes.items[idx].fold.head orelse slot.Position{
                    .epoch = 0,
                    .seq = 0,
                };
            };
            views[i] = .{
                .id = member.id,
                .seniority = member.seniority,
                .address = member.address,
                .state = self.stateOf(observer, member.id),
                .last_ack = head,
            };
        }
        return views;
    }

    /// A public append: only the leader of the caller's liveness view may
    /// write. Returns `not_leader` otherwise (the stall case — no leader at
    /// all — also lands here).
    pub fn append(self: *World, index: usize, kind: entry.Kind, payload: []const u8) !void {
        const leader = try self.leaderOf(index);
        const id = self.nodes.items[index].id;
        if (leader == null or !std.mem.eql(u8, &leader.?, &id)) return error.NotLeader;
        try self.slotAndBroadcast(index, kind, try self.allocator.dupe(u8, payload));
    }

    /// Adds a member: `admitter` — which must be the leader of its own
    /// liveness view — writes the newcomer's `join` entry, and the newcomer
    /// backfills the admitter's chain. Returns the newcomer's index. Works
    /// during a partition: the leader of a side admits, so the newcomer
    /// joins that side.
    pub fn addMember(
        self: *World,
        kp: crypto.sign.Ed25519.KeyPair,
        address: []const u8,
        admitter: usize,
    ) !usize {
        const leader = (try self.leaderOf(admitter)) orelse return error.NoLeader;
        if (!std.mem.eql(u8, &leader, &self.nodes.items[admitter].id)) {
            return error.NotLeader;
        }

        const id = chain.deriveMemberId(kp.public_key.toBytes());
        try self.nodes.append(self.allocator, .{
            .id = id,
            .kp = kp,
            .address = address,
            .alive = true,
            .clock_offset_ms = 0,
            .fold = try chain.FoldState.init(self.allocator, true, self.control_id),
            .chain = .empty,
            .inbox = .empty,
        });
        const newcomer = self.nodes.items.len - 1;
        try self.node_by_id.put(id, newcomer);
        try self.growLinks(self.nodes.items.len);

        const payload = try self.allocator.alloc(
            u8,
            membership.joinPayloadLen(.{
                .member_id = id,
                .public_key = kp.public_key.toBytes(),
                .address = address,
            }),
        );
        membership.encodeJoinPayload(
            .{ .member_id = id, .public_key = kp.public_key.toBytes(), .address = address },
            payload,
        );
        try self.slotAndBroadcast(admitter, .join, payload);

        // The newcomer folds the admitter's whole chain (backfill) and
        // drops whatever the broadcast queued for it — the join is already
        // in it.
        try self.syncNodeFrom(newcomer, admitter);
        return newcomer;
    }

    /// Rebuilds `target`'s fold from `source`'s chain (backfill / re-fold).
    fn syncNodeFrom(self: *World, target: usize, source: usize) !void {
        const src_chain = self.nodes.items[source].chain;
        const dst = &self.nodes.items[target];
        dst.fold.deinit();
        dst.fold = try chain.FoldState.init(self.allocator, true, self.control_id);
        for (src_chain.items) |msg| try self.applyToNode(target, msg);
        dst.inbox.clearRetainingCapacity();
    }

    /// Partitions the world into the given sets: links across sets close,
    /// so each side can only hear itself. Records the common head — every
    /// live node must be synced (same fold head) for a merge to be defined.
    pub fn partition(self: *World, sets: []const []const usize) !void {
        if (self.partition_head != null) return error.AlreadyPartitioned;
        const n = self.nodes.items.len;
        var common: ?slot.Position = null;
        for (self.nodes.items) |*node| {
            if (!node.alive) continue;
            const head = node.fold.head orelse slot.Position{ .epoch = 0, .seq = 0 };
            if (common) |c| {
                if (slot.Position.order(c, head) != .eq) return error.NotSynced;
            } else {
                common = head;
            }
        }
        if (sets.len > 2) return error.TooManySides;
        self.partition_head = common;
        for (sets, 0..) |set, i| {
            for (set) |node_idx| try self.partition_sides[i].append(self.allocator, node_idx);
        }
        for (sets, 0..) |set_a, i| {
            for (sets[i + 1 ..]) |set_b| {
                for (set_a) |a| {
                    for (set_b) |b| {
                        self.links.items[a * n + b] = false;
                        self.links.items[b * n + a] = false;
                    }
                }
            }
        }
    }

    /// The side's leader: the member its nodes' fold names, provided that
    /// member's own node is in the same side. A side whose fold still names
    /// a leader from the other side (the stall case — it never elected
    /// anyone) is leaderless and therefore wrote nothing.
    fn sideLeader(self: *World, side: usize) ?usize {
        const nodes = self.partition_sides[side].items;
        if (nodes.len == 0) return null;
        const leader_id = self.nodes.items[nodes[0]].fold.epoch.?.leader;
        const leader_idx = self.nodeIndex(leader_id) orelse return null;
        for (nodes) |i| {
            if (i == leader_idx) return leader_idx;
        }
        return null;
    }

    /// Heals the last partition: reopens the links and, if the two sides
    /// diverged, merges per the pure rule — every node re-folds the merged
    /// chain from the last common slot.
    pub fn heal(self: *World) !void {
        const head = self.partition_head orelse return error.NotPartitioned;
        const n = self.nodes.items.len;
        const common_len = blk: {
            var count: usize = 0;
            for (self.nodes.items[0].chain.items) |msg| {
                if (slot.Position.order(msg.slot.position(), head) == .gt) break;
                count += 1;
            }
            break :blk count;
        };

        // The sides come from the partition sets. A side whose fold names a
        // leader from the other side (the stall case) never elected anyone
        // and wrote nothing.
        const a_leader = self.sideLeader(0);
        const b_leader = self.sideLeader(1);
        if (a_leader == null and b_leader == null) {
            try self.reopenLinks();
            return;
        }

        var survivor_side: usize = 0;
        var loser_side: ?usize = null;
        if (a_leader == null) {
            survivor_side = 1;
        } else if (b_leader == null) {
            survivor_side = 0;
        } else {
            // Both sides elected: the side whose leader ranks higher under
            // the mode survives (epoch.survivor).
            const inputs = electionInputs(&self.nodes.items[0]);
            const winner = epoch.survivor(
                inputs,
                try self.branchOf(a_leader.?, head, self.tailOf(0)),
                try self.branchOf(b_leader.?, head, self.tailOf(1)),
            );
            if (winner == .a) {
                survivor_side = 0;
                loser_side = 1;
            } else {
                survivor_side = 1;
                loser_side = 0;
            }
        }
        const survivor_idx = self.sideLeader(survivor_side).?;

        var merged = std.ArrayListUnmanaged(*const Message).empty;
        defer merged.deinit(self.allocator);
        try merged.appendSlice(self.allocator, self.nodes.items[0].chain.items[0..common_len]);
        try merged.appendSlice(self.allocator, self.tailOf(survivor_side));

        if (loser_side) |ls| {
            const loser_tail = self.tailOf(ls);
            if (loser_tail.len > 0) {
                // The losing branch: a merge entry naming its head, then its
                // entries re-slotted in order. An empty losing branch heals
                // without a merge (G4: the stalled side rejoins without one).
                const loser_head = loser_tail[loser_tail.len - 1].slot.position();
                const merge_payload = try self.allocator.create([16]u8);
                epoch.encodeMergePayload(
                    .{ .branch_epoch = loser_head.epoch, .branch_seq = loser_head.seq },
                    merge_payload,
                );
                const merge_msg = try self.makeMessage(survivor_idx, .merge, merge_payload);
                try merged.append(self.allocator, merge_msg);

                // Re-slot the losing branch's entries, in that branch's
                // order, after the merge. The entry bytes are unchanged;
                // only the slot is new (the survivor's current epoch, seq
                // continuing, chained to the merge entry).
                var prev_hash = slot.slotHash(&merge_msg.slot);
                var seq = merge_msg.slot.seq + 1;
                for (loser_tail) |msg| {
                    const reslot_msg = try self.reslot(survivor_idx, msg, prev_hash, seq);
                    prev_hash = slot.slotHash(&reslot_msg.slot);
                    seq += 1;
                    try merged.append(self.allocator, reslot_msg);
                }
            }
        }

        // Every node re-folds the merged chain from the common prefix.
        for (0..n) |i| {
            if (!self.nodes.items[i].alive) continue;
            const dst = &self.nodes.items[i];
            dst.fold.deinit();
            dst.fold = try chain.FoldState.init(self.allocator, true, self.control_id);
            dst.chain.clearRetainingCapacity();
            dst.inbox.clearRetainingCapacity();
            for (merged.items) |msg| try self.applyToNode(i, msg);
        }
        try self.reopenLinks();
    }

    /// A side's chain tail after the common prefix (any node on the side
    /// shares the same chain).
    fn tailOf(self: *World, side: usize) []const *const Message {
        const node_idx = self.partition_sides[side].items[0];
        return self.nodes.items[node_idx].chain.items[self.commonPrefixLen()..];
    }

    fn commonPrefixLen(self: *World) usize {
        const head = self.partition_head.?;
        var count: usize = 0;
        for (self.nodes.items[0].chain.items) |msg| {
            if (slot.Position.order(msg.slot.position(), head) == .gt) break;
            count += 1;
        }
        return count;
    }

    /// A merge's re-slot: the losing entry's unchanged bytes in a new slot
    /// signed by the surviving leader, chained to `prev_hash` at `seq`.
    fn reslot(
        self: *World,
        survivor_idx: usize,
        msg: *const Message,
        prev_hash: [32]u8,
        seq: u64,
    ) !*const Message {
        const node = &self.nodes.items[survivor_idx];
        const payload = try self.allocator.dupe(u8, msg.payload);
        var en = msg.entry; // unchanged bytes, same entry id
        en.payload = payload;
        var sl = slot.Slot{
            .epoch = node.fold.epoch.?.number,
            .seq = seq,
            .slot_ts_ms = self.nodeNow(survivor_idx),
            .entry_hash = entry.entryHash(&en),
            .prev_slot_hash = prev_hash,
            .leader = node.id,
            .signature = undefined,
        };
        sl.signature = (try slot.sign(node.kp, &sl)).toBytes();
        const out = try self.allocator.create(Message);
        out.* = .{ .slot = sl, .entry = en, .payload = payload, .reslotted = true };
        try self.messages.append(self.allocator, out);
        return out;
    }

    fn branchOf(
        self: *World,
        leader_idx: usize,
        common_head: slot.Position,
        tail: []const *const Message,
    ) !epoch.Branch {
        const node = &self.nodes.items[leader_idx];
        const head = if (tail.len > 0)
            tail[tail.len - 1].slot.position()
        else
            node.fold.head orelse common_head;
        const member = node.fold.memberById(node.id) orelse return error.NotMember;
        return .{
            .leader = node.id,
            .leader_view = .{
                .id = node.id,
                .seniority = member.seniority,
                .address = member.address,
                .state = .member,
                .last_ack = head,
            },
        };
    }

    fn reopenLinks(self: *World) !void {
        self.partition_head = null;
        for (0..2) |i| self.partition_sides[i].clearRetainingCapacity();
        const n = self.nodes.items.len;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            var j: usize = 0;
            while (j < n) : (j += 1) self.links.items[i * n + j] = true;
        }
    }

    /// Advances the world clock and processes every alive node: apply what
    /// is chainable from the inbox, then run the loop's election half — a
    /// node that has become the leader (per its own liveness view) and is
    /// not already the current leader opens an epoch.
    pub fn tick(self: *World) !void {
        self.now_ms += 100;
        for (0..self.nodes.items.len) |i| {
            if (!self.nodes.items[i].alive) continue;
            try self.processInbox(i);
        }
        for (0..self.nodes.items.len) |i| {
            if (!self.nodes.items[i].alive) continue;
            try self.maybeOpenEpoch(i);
        }
    }

    fn processInbox(self: *World, index: usize) !void {
        const node = &self.nodes.items[index];
        var applied = true;
        while (applied) {
            applied = false;
            for (node.inbox.items, 0..) |msg, idx| {
                if (!std.mem.eql(u8, &msg.slot.prev_slot_hash, &node.fold.head_slot_hash)) {
                    continue; // not chainable yet: hold
                }
                if (msg.entry.kind == .epoch) {
                    // The liveness half of epoch validation: the claimed
                    // leader must be what *this* member's election returns.
                    // A member that disagrees drops the entry and keeps its
                    // previous view — that is a partition (PRD 0003).
                    const claimed = epoch.decodeEpochPayload(msg.entry.payload) catch
                        return error.BadEpoch;
                    const winner = try self.leaderOf(index);
                    if (winner == null or !std.mem.eql(u8, &winner.?, &claimed.leader)) {
                        _ = node.inbox.orderedRemove(idx);
                        applied = true;
                        break;
                    }
                }
                try self.applyToNode(index, msg);
                _ = node.inbox.orderedRemove(idx);
                applied = true;
                break;
            }
        }
    }

    /// The node loop's election half: a member that has become the leader
    /// per its own view and is not the folded leader opens an epoch.
    fn maybeOpenEpoch(self: *World, index: usize) !void {
        const node = &self.nodes.items[index];
        const winner = try self.leaderOf(index) orelse return;
        if (!std.mem.eql(u8, &winner, &node.id)) return;
        if (std.mem.eql(u8, &node.fold.epoch.?.leader, &node.id)) return;
        const payload = try self.allocator.create([epoch.epoch_payload_len]u8);
        epoch.encodeEpochPayload(
            .{ .number = node.fold.epoch.?.number + 1, .reason = .leader_lost, .leader = node.id },
            payload,
        );
        try self.slotAndBroadcast(index, .epoch, payload[0..]);
    }

    /// Every live node's fold hashes equal and heads agree.
    pub fn assertConverged(self: *World) !void {
        var reference: ?[32]u8 = null;
        var reference_head: ?slot.Position = null;
        for (self.nodes.items) |*node| {
            if (!node.alive) continue;
            const h = try node.fold.hash(self.allocator);
            if (reference) |r| {
                try std.testing.expectEqualSlices(u8, &r, &h);
            } else {
                reference = h;
            }
            if (reference_head) |rh| {
                try std.testing.expectEqual(rh, node.fold.head);
            } else {
                reference_head = node.fold.head;
            }
        }
    }

    /// Whether an entry id resolves in a node's fold.
    pub fn entryResolves(self: *World, index: usize, id: entry.Id) bool {
        return self.nodes.items[index].fold.entries.contains(id);
    }
};

fn nextAuthorSeq(fold: *const chain.FoldState, author: [16]u8) u64 {
    const current = fold.authors.get(author) orelse return 1;
    return current.last_seq + 1;
}

fn electionInputs(node: *const Node) election.Inputs {
    const settings = &node.fold.settings;
    return .{
        .mode = settings.getEnum(schema.keyIndex("leadership.mode").?),
        .authorities = settings.getList(schema.keyIndex("leadership.authorities").?),
        .tiebreak = settings.getEnum(schema.keyIndex("leadership.tiebreak").?),
        .fallback = settings.getEnum(schema.keyIndex("leadership.fallback").?),
    };
}

/// Encodes a one-change cluster settings payload into `buf` and returns the
/// used slice (borrowed by the caller).
fn settingsEntryPayload(buf: []u8, key: u16, value: schema.Value) []const u8 {
    const pl = settings_fold.SettingsPayload{
        .scope = .cluster,
        .journal_id = [_]u8{0} ** 16,
        .changes = &.{.{ .key = key, .value = value }},
    };
    const len = settings_fold.payloadLen(pl);
    std.debug.assert(buf.len >= len);
    settings_fold.encodePayload(pl, buf) catch unreachable;
    return buf[0..len];
}

// ---------------------------------------------------------------------------
// Scenarios
// ---------------------------------------------------------------------------

const test_alloc = std.testing.allocator;

const test_control_id = "0123456789abcdef".*;
const max_journals = schema.keyIndex("cluster.max_journals").?;

fn memberKey(seed: u64) crypto.sign.Ed25519.KeyPair {
    var key_seed: [32]u8 = undefined;
    crypto.hash.sha2.Sha256.hash(&std.mem.toBytes(seed), &key_seed, .{});
    return crypto.sign.Ed25519.KeyPair.generateDeterministic(key_seed) catch unreachable;
}

/// The `changes` blob a `settings` wire message carries: one cluster-scoped
/// key set to `value`. `settingsEntryPayload` above wraps the same changes
/// in a chain payload; the wire message carries the changes alone.
fn settingsEntryChanges(buf: []u8, key: u16, value: schema.Value) []const u8 {
    const changes = [_]validate.Change{.{ .key = key, .value = value }};
    const len = settings_fold.changesLen(&changes);
    settings_fold.encodeChanges(&changes, buf[0..len]) catch unreachable;
    return buf[0..len];
}

/// The node key the world derives for a node index (member ids must be
/// predictable in the tests, so the derivation is exposed).
pub fn nodeKey(index: usize) crypto.sign.Ed25519.KeyPair {
    return memberKey(index);
}

/// Lowercase hex of a member id, for `authorities` entries.
fn idHex(id: [16]u8) [32]u8 {
    var buf: [32]u8 = undefined;
    const hex = "0123456789abcdef";
    for (id, 0..) |byte, i| {
        buf[i * 2] = hex[byte >> 4];
        buf[i * 2 + 1] = hex[byte & 0xf];
    }
    return buf;
}

test "partition under seniority heals into one chain with every entry (G7 core)" {
    var world = try World.init(test_alloc, 0x5EED, test_control_id, &.{});
    defer world.deinit();
    const a: usize = 0;
    const b = try world.addMember(memberKey(1), "node-b", a);

    // A writes before the partition; B writes during it. The survivor is A
    // (senior), so after the merge A's value wins and B's settings entry
    // re-slots as a no-op (OQ 33) — on both folds.
    var buf: [128]u8 = undefined;
    try world.append(a, .settings, settingsEntryPayload(&buf, max_journals, .{ .u32 = 21 }));
    try world.tick(); // B receives the broadcast
    try world.assertConverged();

    try world.partition(&.{ &[_]usize{a}, &[_]usize{b} });
    try world.tick(); // B notices A is gone, opens epoch 2
    try world.tick();
    try std.testing.expectEqualSlices(u8, &world.nodeId(b), &(try world.leaderOf(b)).?);
    try std.testing.expectEqualSlices(u8, &world.nodeId(a), &(try world.leaderOf(a)).?);

    try world.append(b, .settings, settingsEntryPayload(&buf, max_journals, .{ .u32 = 42 }));
    try world.heal();
    for (0..4) |_| try world.tick();

    try world.assertConverged();
    const b_id = world.nodeId(b);
    try std.testing.expect(world.entryResolves(a, .{ .author = b_id, .author_seq = 2 }));
    try std.testing.expect(world.entryResolves(b, .{ .author = b_id, .author_seq = 2 }));
    // The survivor's value wins everywhere; the loser's settings re-slotted
    // as a no-op.
    for (world.nodes.items) |*node| {
        try std.testing.expectEqual(
            @as(u32, 21),
            node.fold.settings.getU32(max_journals),
        );
    }
    // A merge happened and was folded identically on both sides.
    try std.testing.expect(world.nodes.items[a].fold.last_merge != null);
}

test "partitioned joins merge with deterministic seniority (RFC 0002)" {
    var world = try World.init(test_alloc, 0xBEEF, test_control_id, &.{});
    defer world.deinit();
    const a: usize = 0;
    const b = try world.addMember(memberKey(1), "node-b", a);
    try world.assertConverged();

    try world.partition(&.{ &[_]usize{a}, &[_]usize{b} });
    try world.tick();
    try world.tick();

    // Both sides admit during the partition: A admits D, B admits C.
    const c = try world.addMember(memberKey(2), "node-c", b);
    const d = try world.addMember(memberKey(3), "node-d", a);
    const c_id = world.nodeId(c);
    const d_id = world.nodeId(d);

    try world.heal();
    for (0..4) |_| try world.tick();
    try world.assertConverged();

    // Both members are present on both folds; the survivor-side admission
    // (D, via A) is senior to the losing-side one (C, via B), because the
    // merge re-slots the losing branch's joins after the survivor's.
    for (world.nodes.items) |*node| {
        const c_member = node.fold.memberById(c_id).?;
        const d_member = node.fold.memberById(d_id).?;
        try std.testing.expect(
            slot.Position.order(d_member.seniority, c_member.seniority) == .lt,
        );
    }
}

test "growLinks keeps a partition's closed links closed when a member joins" {
    // Bug 2026-08-28-sim-growlinks-reopens-partition: growLinks filled the
    // whole matrix with `true`, silently healing every link `partition`
    // closed — the sides could hear each other again mid-partition.
    var world = try World.init(test_alloc, 0xABCD, test_control_id, &.{});
    defer world.deinit();
    const a: usize = 0;
    const b = try world.addMember(memberKey(1), "node-b", a);
    try world.assertConverged();
    try world.partition(&.{ &[_]usize{a}, &[_]usize{b} });
    try world.tick();
    try world.tick();

    const c = try world.addMember(memberKey(2), "node-c", b);

    // The partition's cross links survive the join.
    try std.testing.expect(!world.linkOpen(a, b));
    try std.testing.expect(!world.linkOpen(b, a));
    // The newcomer can reach its admitting side, and it was admitted.
    try std.testing.expect(world.linkOpen(b, c));
    try std.testing.expect(world.linkOpen(c, b));
}

test "leader crash: the survivors elect and continue without a merge" {
    var world = try World.init(test_alloc, 0x0BAD, test_control_id, &.{});
    defer world.deinit();
    const a: usize = 0;
    const b = try world.addMember(memberKey(1), "node-b", a);

    var buf: [128]u8 = undefined;
    try world.append(a, .settings, settingsEntryPayload(&buf, max_journals, .{ .u32 = 5 }));
    try world.tick(); // B receives the broadcast
    try world.assertConverged();

    world.crash(a);
    try world.tick(); // B notices, opens epoch 2
    try world.tick();
    try std.testing.expectEqualSlices(u8, &world.nodeId(b), &(try world.leaderOf(b)).?);
    try world.append(b, .settings, settingsEntryPayload(&buf, max_journals, .{ .u32 = 6 }));

    // B's fold holds A's pre-crash entry and its own; no merge ever
    // happened (nothing healed).
    try std.testing.expect(world.entryResolves(b, .{ .author = world.nodeId(a), .author_seq = 2 }));
    try std.testing.expectEqual(@as(u64, 2), world.nodes.items[b].fold.epoch.?.number);
    try std.testing.expect(world.nodes.items[b].fold.last_merge == null);
}

test "reordered delivery still converges" {
    var world = try World.init(test_alloc, 0x5EED, test_control_id, &.{});
    defer world.deinit();
    const a: usize = 0;
    _ = try world.addMember(memberKey(1), "node-b", a);
    const c = try world.addMember(memberKey(2), "node-c", a);
    world.setReorder(true);

    var buf: [128]u8 = undefined;
    var i: u32 = 1;
    while (i <= 5) : (i += 1) {
        try world.append(a, .settings, settingsEntryPayload(&buf, max_journals, .{ .u32 = i }));
    }
    for (0..10) |_| try world.tick();
    try world.assertConverged();
    try std.testing.expectEqual(
        @as(u32, 5),
        world.nodes.items[c].fold.settings.getU32(max_journals),
    );
}

test "configured + stall: the non-authority side refuses writes (G4 core)" {
    const mode = schema.keyIndex("leadership.mode").?;
    const authorities = schema.keyIndex("leadership.authorities").?;
    const fallback = schema.keyIndex("leadership.fallback").?;
    const genesis = [_]validate.Change{
        .{ .key = mode, .value = .{ .enum_value = schema.enumValue(mode, "configured").? } },
        .{ .key = authorities, .value = .{
            .string_list = &[_][]const u8{
                &idHex(chain.deriveMemberId(nodeKey(0).public_key.toBytes())),
            },
        } },
        .{ .key = fallback, .value = .{ .enum_value = schema.enumValue(fallback, "stall").? } },
    };
    var world = try World.init(test_alloc, 0xF00D, test_control_id, &genesis);
    defer world.deinit();
    const a: usize = 0;
    const b = try world.addMember(memberKey(1), "node-b", a);

    try world.partition(&.{ &[_]usize{a}, &[_]usize{b} });
    try world.tick();
    try world.tick();

    // B is not an authority; with stall it has no leader and refuses writes.
    try std.testing.expect((try world.leaderOf(b)) == null);
    var buf: [128]u8 = undefined;
    try std.testing.expectError(
        error.NotLeader,
        world.append(b, .settings, settingsEntryPayload(&buf, max_journals, .{ .u32 = 42 })),
    );

    // A (the authority) still writes.
    try world.append(a, .settings, settingsEntryPayload(&buf, max_journals, .{ .u32 = 21 }));

    // Healing needs no merge — B never wrote — and everyone converges on
    // A's value.
    try world.heal();
    for (0..4) |_| try world.tick();
    try world.assertConverged();
    for (world.nodes.items) |*node| {
        try std.testing.expectEqual(@as(u32, 21), node.fold.settings.getU32(max_journals));
        try std.testing.expect(node.fold.last_merge == null);
    }
}

test "clock skew does not disturb the merge (re-fold discipline)" {
    var world = try World.init(test_alloc, 0x5EED, test_control_id, &.{});
    defer world.deinit();
    const a: usize = 0;
    const b = try world.addMember(memberKey(1), "node-b", a);
    // B's clock runs 5 seconds ahead of the world's.
    world.setSkew(b, 5000);

    try world.partition(&.{ &[_]usize{a}, &[_]usize{b} });
    try world.tick();
    try world.tick();
    var buf: [128]u8 = undefined;
    try world.append(b, .settings, settingsEntryPayload(&buf, max_journals, .{ .u32 = 42 }));
    try world.heal();
    for (0..4) |_| try world.tick();

    // The loser's branch is discarded and re-folded from the merged chain,
    // whose stamps are the survivor's clock — the skew never meets a
    // cross-clock comparison (that is why merge.settle_ms exists only at the
    // checkpoint level).
    try world.assertConverged();
}

test "three-member partition: the losing side's follower converges too (PRD 0003)" {
    // PRD 0003's *Status* carries this as a known issue, found 2026-08-27
    // while exercising the loop from `examples/embed-cluster`:
    //
    // > a **three-member partition that elects a second leader does not
    // > reliably converge on heal** - the survivor's branch fetch or the
    // > losers' re-sync can stall without retry (the two-member merge, e2e
    // > (b), converges; three members - two losers - surfaced a stall). The
    // > e2e matrix's (b) is two-member; the three-member merge needs the
    // > simulator over the loop (OQ 27's second half) and a deterministic
    // > scenario before it can be pinned.
    //
    // This is that deterministic scenario, over the pure rules. Every
    // existing partition scenario splits one node against one node, so the
    // shape the issue is about - a losing *side* with a follower on it,
    // which must end up holding the survivor's chain without ever having
    // spoken to the survivor's leader - had no coverage at all.
    var world = try World.init(test_alloc, 0x3EED, test_control_id, &.{});
    defer world.deinit();
    const a: usize = 0;
    const b = try world.addMember(memberKey(1), "node-b", a);
    const c = try world.addMember(memberKey(2), "node-c", a);

    // A leads under seniority and everyone is at the same head.
    var buf: [128]u8 = undefined;
    try world.append(a, .settings, settingsEntryPayload(&buf, max_journals, .{ .u32 = 11 }));
    for (0..3) |_| try world.tick();
    try world.assertConverged();
    try std.testing.expectEqualSlices(u8, &world.nodeId(a), &(try world.leaderOf(a)).?);

    // The senior member is cut off from the other two. B and C keep each
    // other, so their side elects: B is the senior of the pair.
    try world.partition(&.{ &[_]usize{a}, &[_]usize{ b, c } });
    for (0..3) |_| try world.tick();
    try std.testing.expectEqualSlices(u8, &world.nodeId(a), &(try world.leaderOf(a)).?);
    try std.testing.expectEqualSlices(u8, &world.nodeId(b), &(try world.leaderOf(b)).?);
    // C follows B, not A: the losing side has a real follower on it.
    try std.testing.expectEqualSlices(u8, &world.nodeId(b), &(try world.leaderOf(c)).?);

    // Both sides write. C's copy of B's branch is what the heal has to
    // undo and re-fold.
    try world.append(a, .settings, settingsEntryPayload(&buf, max_journals, .{ .u32 = 22 }));
    try world.append(b, .settings, settingsEntryPayload(&buf, max_journals, .{ .u32 = 33 }));
    for (0..3) |_| try world.tick();
    try std.testing.expectEqual(
        @as(u32, 33),
        world.nodes.items[c].fold.settings.getU32(max_journals),
    );

    try world.heal();
    for (0..6) |_| try world.tick();

    // One chain on all three, folds hash-equal (assertConverged), and the
    // survivor A's value wins: B's settings entry re-slotted as a no-op on
    // every node, including the follower that had already folded it live.
    try world.assertConverged();
    for (world.nodes.items) |*node| {
        try std.testing.expectEqual(@as(u32, 22), node.fold.settings.getU32(max_journals));
    }

    // Every entry written on either side resolves everywhere - the losing
    // side's entries kept their ids and only moved slot (PRD 0003 G7).
    const a_second = entry.Id{ .author = world.nodeId(a), .author_seq = 3 };
    const b_branch = entry.Id{ .author = world.nodeId(b), .author_seq = 2 };
    for (0..3) |i| {
        try std.testing.expect(world.entryResolves(i, a_second));
        try std.testing.expect(world.entryResolves(i, b_branch));
    }
    // A merge really happened, and C - which never spoke to A during the
    // partition - folded it.
    try std.testing.expect(world.nodes.items[c].fold.last_merge != null);
}

// ---------------------------------------------------------------------------
// The loop world (OQ 27's second half)
// ---------------------------------------------------------------------------

/// A deterministic driver for the **node loop**, not just the pure rules.
///
/// `World` above drives `membership`/`election`/`epoch` directly: it is the
/// reference implementation of the merge discipline, and it converges a
/// three-member partition without complaint. PRD 0003's *Status* records a
/// known issue that it therefore cannot see:
///
/// > a **three-member partition that elects a second leader does not
/// > reliably converge on heal** ... The e2e matrix's (b) is two-member; the
/// > three-member merge needs the simulator over the loop (OQ 27's second
/// > half) and a deterministic scenario before it can be pinned.
///
/// `LoopWorld` is that second half. It runs real `cluster.ClusterNode`s over
/// real stores, and drives them *without* `start()`: no loop task, no timer
/// task, no reader task, no sockets. The world owns three things the node
/// would otherwise get from the outside, and owns them synchronously:
///
/// - **the wire.** Each ordered pair of nodes has a queue. A node's
///   connection appends the frames it sends; `pump` hands each queued frame
///   to the peer's `onFrame` and repeats until the queues are empty, so a
///   request and its reply resolve inside one call in a fixed order.
/// - **connectivity.** `cut` and `restore` decide which queues deliver.
///   Because the world owns this, the node's own redial is suppressed:
///   `dial_at_ms` is cleared before each tick, so `onTick` never reaches
///   `spawnDial` and no task is ever spawned.
/// - **liveness.** `elapsedMs` reads the real monotonic clock and has no
///   seam, so the failure detector cannot be driven by advancing a fake
///   clock. `cut` instead backdates the peer's `last_heard_ms`, which is
///   what a missed heartbeat does, and the suspect branch then fires on the
///   very next tick.
///
/// What it does *not* model: the reader task's concurrency (frames are
/// delivered on the driving thread, in order), real timing, and the dial
/// path. Those are the e2e matrix's job. What it does model is the loop's
/// own state machine, which is where the known issue lives.
pub const LoopWorld = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    nodes: std.ArrayListUnmanaged(LoopNode) = .empty,
    /// `links[i * n + j]`: whether frames queued from i to j are delivered.
    links: std.ArrayListUnmanaged(bool) = .empty,
    /// One outbound queue per ordered pair, indexed like `links`.
    wires: std.ArrayListUnmanaged(Wire) = .empty,
    /// Connections, indexed like `links`: the id node i uses for its link
    /// to node j, or null when the pair is not connected.
    conn_ids: std.ArrayListUnmanaged(?u64) = .empty,
    size: usize,

    const Wire = struct {
        frames: std.ArrayListUnmanaged([]u8) = .empty,
    };

    /// One node: its data directory, store and loop, plus the per-peer
    /// connection contexts (stable addresses, so `Conn.ctx` stays valid).
    const LoopNode = struct {
        tmp: std.testing.TmpDir,
        node: *journal.Node,
        cn: *cluster.ClusterNode,
        ctxs: []LinkCtx,
        /// Borrowed by `cn.options.address`, so the world owns it.
        address: []u8,
    };

    const LinkCtx = struct {
        world: *LoopWorld,
        from: usize,
        to: usize,
    };

    fn wireIndex(self: *LoopWorld, from: usize, to: usize) usize {
        return from * self.size + to;
    }

    fn sendFrame(ctx: *anyopaque, _: std.Io, body: []const u8) net.transport.SendError!void {
        const link: *LinkCtx = @ptrCast(@alignCast(ctx));
        const self = link.world;
        const idx = self.wireIndex(link.from, link.to);
        if (!self.links.items[idx]) return; // partitioned: the frame is lost
        const copy = self.allocator.dupe(u8, body) catch return error.SendFailed;
        self.wires.items[idx].frames.append(self.allocator, copy) catch {
            self.allocator.free(copy);
            return error.SendFailed;
        };
    }

    fn recvFrame(
        _: *anyopaque,
        _: std.Io,
        _: std.mem.Allocator,
    ) net.transport.RecvError![]u8 {
        // Nothing reads: the world delivers into `onFrame` directly.
        return error.EndOfStream;
    }

    fn nopConn(_: *anyopaque, _: std.Io) void {}

    fn nullConnect(
        _: *anyopaque,
        _: std.Io,
        _: std.mem.Allocator,
        _: []const u8,
    ) anyerror!net.transport.Conn {
        // The world makes every connection; a node never dials.
        return error.ConnectionRefused;
    }

    fn nopTransport(_: *anyopaque) void {}

    /// `size` nodes: node 0 founds the cluster with `genesis_changes`, the
    /// rest hold only a member key and join by handshake, exactly as a real
    /// joiner does.
    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        size: usize,
        genesis_changes: []const validate.Change,
    ) !*LoopWorld {
        const self = try allocator.create(LoopWorld);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .io = io, .size = size };

        try self.links.appendNTimes(allocator, true, size * size);
        try self.wires.appendNTimes(allocator, .{}, size * size);
        try self.conn_ids.appendNTimes(allocator, null, size * size);

        for (0..size) |i| {
            var tmp = std.testing.tmpDir(.{});
            tmp.dir.createDir(io, "data", .default_dir) catch {};
            {
                // `journal.init` takes the directory handle; `writeMemberKey`
                // borrows it, so only the joiner's copy is closed here.
                const dd = try tmp.dir.openDir(io, "data", .{ .iterate = true });
                if (i == 0) {
                    try journal.init(
                        allocator,
                        io,
                        dd,
                        genesis_changes,
                        "main",
                        &journal.wallClock,
                    );
                } else {
                    defer dd.close(io);
                    const kp = crypto.sign.Ed25519.KeyPair.generateDeterministic(
                        deterministicSeed(i),
                    ) catch unreachable;
                    try journal.writeMemberKey(allocator, io, dd, kp);
                }
            }
            const dd = try tmp.dir.openDir(io, "data", .{ .iterate = true });
            const node = try journal.Node.open(allocator, io, dd, .{ .fsync = .never });
            // `ClusterNode` borrows the address; it has to outlive the node.
            const address = try std.fmt.allocPrint(allocator, "sim-{d}", .{i});
            const cn = try cluster.ClusterNode.init(allocator, io, node, .{
                .transport = .{
                    .ctx = self,
                    .connect_fn = nullConnect,
                    .deinit_fn = nopTransport,
                },
                .address = address,
            });
            const ctxs = try allocator.alloc(LinkCtx, size);
            for (ctxs, 0..) |*c, j| c.* = .{ .world = self, .from = i, .to = j };
            try self.nodes.append(allocator, .{
                .tmp = tmp,
                .node = node,
                .cn = cn,
                .ctxs = ctxs,
                .address = address,
            });
        }
        // Each node keeps one operator connection - the channel a CLI or a
        // wire client would hold. It is the self-link, whose `links` entry
        // is false, so everything written to it is discarded: a scenario
        // needs somewhere for an ack to go, not the ack itself.
        for (0..size) |i| {
            self.links.items[self.wireIndex(i, i)] = false;
            const id = try self.nodes.items[i].cn.simRegisterConn(self.connFor(i, i), false);
            self.conn_ids.items[self.wireIndex(i, i)] = id;
        }
        return self;
    }

    fn deterministicSeed(i: usize) [32]u8 {
        var seed: [32]u8 = undefined;
        crypto.hash.sha2.Sha256.hash(&std.mem.toBytes(@as(u64, i)), &seed, .{});
        return seed;
    }

    pub fn deinit(self: *LoopWorld) void {
        for (self.nodes.items) |*n| {
            n.cn.deinit();
            n.node.deinit();
            self.allocator.free(n.ctxs);
            self.allocator.free(n.address);
            var tmp = n.tmp;
            tmp.cleanup();
        }
        self.nodes.deinit(self.allocator);
        for (self.wires.items) |*w| {
            for (w.frames.items) |f| self.allocator.free(f);
            w.frames.deinit(self.allocator);
        }
        self.wires.deinit(self.allocator);
        self.links.deinit(self.allocator);
        self.conn_ids.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn connFor(self: *LoopWorld, from: usize, to: usize) net.transport.Conn {
        return .{
            .ctx = &self.nodes.items[from].ctxs[to],
            .recv_frame = recvFrame,
            .send_frame = sendFrame,
            .shutdown_fn = nopConn,
            .close_fn = nopConn,
        };
    }

    /// Opens the connection `dialer` -> `admitter` and runs the handshake to
    /// completion: the dialer's `hello` reaches the admitter, whose
    /// `hello_ack` comes back, and (for a newcomer) the admitter's `join`
    /// goes onto the chain.
    pub fn connect(self: *LoopWorld, dialer: usize, admitter: usize) !void {
        const d = self.nodes.items[dialer].cn;
        const a = self.nodes.items[admitter].cn;
        const d_conn = try d.simRegisterConn(self.connFor(dialer, admitter), true);
        const a_conn = try a.simRegisterConn(self.connFor(admitter, dialer), false);
        self.conn_ids.items[self.wireIndex(dialer, admitter)] = d_conn;
        self.conn_ids.items[self.wireIndex(admitter, dialer)] = a_conn;
        try d.simSendHello(d_conn);
        try self.pump();
    }

    /// Delivers every queued frame, in node order, until the queues are
    /// empty. A frame that a partition has cut was never queued.
    pub fn pump(self: *LoopWorld) !void {
        var rounds: usize = 0;
        while (rounds < 64) : (rounds += 1) {
            var moved = false;
            for (0..self.size) |from| {
                for (0..self.size) |to| {
                    if (from == to) continue;
                    const idx = self.wireIndex(from, to);
                    const wire = &self.wires.items[idx];
                    if (wire.frames.items.len == 0) continue;
                    const body = wire.frames.orderedRemove(0);
                    defer self.allocator.free(body);
                    moved = true;
                    const conn_id = self.conn_ids.items[self.wireIndex(to, from)] orelse continue;
                    self.nodes.items[to].cn.simDeliver(conn_id, body);
                }
            }
            if (!moved) return;
        }
        return error.WireDidNotSettle;
    }

    /// One round: every node runs its periodic work, then the wire settles.
    /// Redials are suppressed first - the world owns connectivity.
    pub fn tick(self: *LoopWorld) !void {
        for (self.nodes.items) |*n| n.cn.simClearRedials();
        for (self.nodes.items) |*n| try n.cn.simTick();
        try self.pump();
        self.reapClosedConns();
    }

    /// A connection the loop shut down is destroyed by its reader's
    /// peer-gone notice; with no reader, the world plays that part.
    fn reapClosedConns(self: *LoopWorld) void {
        for (0..self.size) |i| {
            for (0..self.size) |j| {
                if (i == j) continue; // the operator connection is not a peer
                const idx = self.wireIndex(i, j);
                const conn_id = self.conn_ids.items[idx] orelse continue;
                if (!self.nodes.items[i].cn.simConnClosing(conn_id)) continue;
                self.nodes.items[i].cn.simPeerGone(conn_id);
                self.conn_ids.items[idx] = null;
            }
        }
    }

    /// Severs both directions between `i` and `j` and backdates the
    /// heartbeat each holds for the other, so the suspect branch fires on
    /// the next tick rather than after a real 5 s.
    pub fn cut(self: *LoopWorld, i: usize, j: usize) void {
        self.links.items[self.wireIndex(i, j)] = false;
        self.links.items[self.wireIndex(j, i)] = false;
        self.nodes.items[i].cn.simExpireHeartbeat(self.nodes.items[j].node.member_id);
        self.nodes.items[j].cn.simExpireHeartbeat(self.nodes.items[i].node.member_id);
    }

    /// Reopens both directions and re-runs the handshake, which is what a
    /// successful redial would have done.
    pub fn restore(self: *LoopWorld, i: usize, j: usize) !void {
        self.links.items[self.wireIndex(i, j)] = true;
        self.links.items[self.wireIndex(j, i)] = true;
        try self.connect(i, j);
    }

    /// The fold digest of every node, which is what "converged" means (PRD
    /// 0003 G7: one chain, hash-equal folds).
    pub fn assertConverged(self: *LoopWorld) !void {
        var all: [16]usize = undefined;
        for (0..self.size) |i| all[i] = i;
        try self.assertConvergedAmong(all[0..self.size]);
    }

    /// The same, over a subset - for a scenario in which part of the
    /// cluster is known not to have converged yet.
    pub fn assertConvergedAmong(self: *LoopWorld, indices: []const usize) !void {
        try std.testing.expect(try self.convergedAmong(indices));
    }

    /// Whether every listed node's control fold hashes identically. The
    /// loop sim drives the nodes through a threaded io, so the completion
    /// ordering - and therefore the tick at which a merge finishes - is not
    /// fixed; scenarios that assert convergence poll this with a bound
    /// instead of assuming a tick count (the fixed-count version flaked,
    /// bug 2026-08-30-loopworld-convergence-window).
    pub fn convergedAmong(self: *LoopWorld, indices: []const usize) !bool {
        var reference: ?[32]u8 = null;
        for (indices) |i| {
            const h = try self.nodes.items[i].cn.node.control.hash(self.allocator);
            if (reference) |r| {
                if (!std.mem.eql(u8, &r, &h)) return false;
            } else {
                reference = h;
            }
        }
        return true;
    }

    pub fn leaderOf(self: *LoopWorld, i: usize) ?[16]u8 {
        const e = self.nodes.items[i].cn.node.control.epoch orelse return null;
        return e.leader;
    }

    /// A cluster-scoped settings write on node `i`, over its operator
    /// connection - the write a CLI or a wire client makes. A partitioned
    /// node can still be written to, which is the point: both sides of a
    /// partition take writes.
    pub fn settingsWrite(self: *LoopWorld, i: usize, changes: []const u8) !void {
        const conn_id = self.conn_ids.items[self.wireIndex(i, i)] orelse return error.NoConn;
        try self.nodes.items[i].cn.simSettings(conn_id, changes);
        try self.pump();
    }

    pub fn memberId(self: *LoopWorld, i: usize) [16]u8 {
        return self.nodes.items[i].node.member_id;
    }
};

test "LoopWorld: three members join and replicate over the real loop" {
    // The first scenario over the node loop itself (OQ 27's second half):
    // real stores, the real state machine, no threads and no sockets.
    var owned = std.Io.Threaded.init(test_alloc, .{ .async_limit = .limited(8) });
    defer owned.deinit();
    const oio = owned.io();

    const admission = schema.keyIndex("cluster.admission").?;
    const genesis = [_]validate.Change{.{
        .key = admission,
        .value = .{ .enum_value = schema.enumValue(admission, "open").? },
    }};
    var world = try LoopWorld.init(test_alloc, oio, 3, &genesis);
    defer world.deinit();

    try world.connect(1, 0);
    try world.connect(2, 0);
    try world.connect(2, 1);
    for (0..8) |_| try world.tick();

    // The founder leads under seniority and every member folded both joins.
    try std.testing.expectEqualSlices(u8, &world.memberId(0), &world.leaderOf(0).?);
    for (0..3) |i| {
        try std.testing.expectEqualSlices(u8, &world.memberId(0), &world.leaderOf(i).?);
        try std.testing.expectEqual(
            @as(usize, 3),
            world.nodes.items[i].cn.node.control.members.items.len,
        );
    }
    try world.assertConverged();
}

test "LoopWorld: a three-member partition elects a second leader and heals" {
    // PRD 0003 *Status* records this as a known issue found 2026-08-27 from
    // `examples/embed-cluster`: "a three-member partition that elects a
    // second leader does not reliably converge on heal ... the three-member
    // merge needs the simulator over the loop (OQ 27's second half) and a
    // deterministic scenario before it can be pinned." This is that
    // scenario, over the loop rather than over the pure rules.
    var owned = std.Io.Threaded.init(test_alloc, .{ .async_limit = .limited(8) });
    defer owned.deinit();
    const oio = owned.io();

    const admission = schema.keyIndex("cluster.admission").?;
    const genesis = [_]validate.Change{.{
        .key = admission,
        .value = .{ .enum_value = schema.enumValue(admission, "open").? },
    }};
    var world = try LoopWorld.init(test_alloc, oio, 3, &genesis);
    defer world.deinit();

    // Join through the founder first: a hello landing on a member that has
    // not yet folded the newcomer's join is not an admission (bug
    // 2026-08-28-sweep3-follower-admitter-join-fails), so the mesh link
    // between the two joiners is opened once both are members.
    try world.connect(1, 0);
    try world.connect(2, 0);
    for (0..8) |_| try world.tick();
    try world.connect(2, 1);
    for (0..4) |_| try world.tick();
    try world.assertConverged();
    try std.testing.expectEqualSlices(u8, &world.memberId(0), &world.leaderOf(0).?);

    // Cut the senior member off; 1 and 2 keep each other, so their side can
    // elect. 1 is the senior of the pair.
    world.cut(0, 1);
    world.cut(0, 2);
    for (0..6) |_| try world.tick();
    try std.testing.expectEqualSlices(u8, &world.memberId(0), &world.leaderOf(0).?);
    try std.testing.expectEqualSlices(u8, &world.memberId(1), &world.leaderOf(1).?);
    try std.testing.expectEqualSlices(u8, &world.memberId(1), &world.leaderOf(2).?);
    // Node 2 is a follower on the losing side: it folded 1's epoch without
    // ever hearing from 0. That is the shape the known issue is about, and
    // no scenario had it before.
    try std.testing.expect(world.nodes.items[2].cn.node.control.epoch.?.number > 1);

    // Both sides write. `max_journals` is a cluster-scoped setting, so the
    // two values are directly comparable after the heal.
    var buf: [128]u8 = undefined;
    try world.settingsWrite(0, settingsEntryChanges(&buf, max_journals, .{ .u32 = 21 }));
    try world.settingsWrite(1, settingsEntryChanges(&buf, max_journals, .{ .u32 = 42 }));
    for (0..4) |_| try world.tick();
    try std.testing.expectEqual(
        @as(u32, 21),
        world.nodes.items[0].cn.node.control.settings.getU32(max_journals),
    );
    for (1..3) |i| {
        try std.testing.expectEqual(
            @as(u32, 42),
            world.nodes.items[i].cn.node.control.settings.getU32(max_journals),
        );
    }

    try world.restore(0, 1);
    try world.restore(0, 2);
    for (0..10) |_| try world.tick();

    // Reconnecting is not enough on its own: after ten ticks with the links
    // back up, node 0 is still on its epoch-1 branch and nodes 1 and 2 on
    // their epoch-2 one. Heartbeats carry the peer's head and nothing
    // compares it, so nothing detects the divergence until a record fails
    // `prev_slot_hash`.
    try std.testing.expectEqual(
        @as(u64, 1),
        world.nodes.items[0].cn.node.control.epoch.?.number,
    );
    try std.testing.expectEqual(
        @as(u64, 2),
        world.nodes.items[1].cn.node.control.epoch.?.number,
    );

    // A write after the heal is what starts the merge. Convergence takes a
    // variable number of ticks - the threaded io's completion ordering is
    // not fixed, so a fixed 30-tick window flaked (bug
    // 2026-08-30-loopworld-convergence-window) - poll with a bound.
    try world.settingsWrite(1, settingsEntryChanges(&buf, max_journals, .{ .u32 = 99 }));
    var merged = false;
    for (0..1000) |_| {
        try world.tick();
        if (try world.convergedAmong(&.{ 0, 1, 2 })) {
            merged = true;
            break;
        }
    }
    if (!merged) {
        for (0..3) |i| {
            const n = world.nodes.items[i].cn;
            std.debug.print(
                "SIMDBG node={} epoch={} head={any} leader={any} syncing={} merging={}\n",
                .{
                    i,
                    if (n.node.control.epoch) |e| e.number else 0,
                    n.node.control.head,
                    if (n.node.control.epoch) |e| e.leader else [_]u8{0} ** 16,
                    n.syncing,
                    n.merging_from != null,
                },
            );
        }
    }
    try std.testing.expect(merged);

    // The survivor and the losing branch's *leader* converge: node 1
    // discarded its branch, re-folded node 0's chain, and both hold node 0
    // as leader with the survivor's value.
    try world.assertConvergedAmong(&.{ 0, 1 });
    try std.testing.expectEqualSlices(u8, &world.memberId(0), &world.leaderOf(0).?);
    try std.testing.expectEqualSlices(u8, &world.memberId(0), &world.leaderOf(1).?);
    try std.testing.expectEqual(
        @as(u32, 21),
        world.nodes.items[0].cn.node.control.settings.getU32(max_journals),
    );

    // The losing branch's *follower* converges too: node 2 folded node 1's
    // epoch only from backfill, so it used to carry no branch facts and
    // becomeLoser refused to act - the strand this scenario pinned (PRD
    // 0003's known issue, reported at
    // docs/reports/bugs/2026-08-30-three-member-merge-strands-the-losing-follower.md).
    // The sync path now records the branch facts an epoch fold implies, so
    // all three members discard their branches, re-fold node 0's chain and
    // hold node 0 as leader with the survivor's value.
    try world.assertConvergedAmong(&.{ 0, 1, 2 });
    try std.testing.expectEqualSlices(u8, &world.memberId(0), &world.leaderOf(2).?);
    try std.testing.expectEqual(
        @as(u64, 1),
        world.nodes.items[2].cn.node.control.epoch.?.number,
    );
    try std.testing.expectEqual(
        @as(u32, 21),
        world.nodes.items[2].cn.node.control.settings.getU32(max_journals),
    );
}
