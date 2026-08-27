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
        try self.growLinks(1);

        // Genesis: the founder creates the cluster and folds its initial
        // settings. The payload is handed to makeMessage, which owns it.
        const genesis_changes_ref = genesis_changes;
        const g_len = chain.genesisPayloadLen(.{
            .founder_key = founder_kp.public_key.toBytes(),
            .changes = genesis_changes_ref,
        });
        const g_buf = try allocator.alloc(u8, g_len);
        chain.encodeGenesisPayload(
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
        self.nodes.deinit(self.allocator);
        self.links.deinit(self.allocator);
        self.* = undefined;
    }

    fn derivedKey(_: *World, index: usize) !crypto.sign.Ed25519.KeyPair {
        var seed: [32]u8 = undefined;
        crypto.hash.sha2.Sha256.hash(&std.mem.toBytes(index), &seed, .{});
        return crypto.sign.Ed25519.KeyPair.generateDeterministic(seed);
    }

    fn growLinks(self: *World, n: usize) !void {
        while (self.links.items.len < n * n) {
            try self.links.append(self.allocator, false);
        }
        // New links start open; a partition closes the cross links and heal
        // reopens everything.
        var i: usize = 0;
        while (i < n) : (i += 1) {
            var j: usize = 0;
            while (j < n) : (j += 1) self.links.items[i * n + j] = true;
        }
    }

    /// Whether node `from` may send to node `to` right now.
    fn linkOpen(self: *World, from: usize, to: usize) bool {
        return self.links.items[from * self.nodes.items.len + to];
    }

    fn nodeIndex(self: *World, id: [16]u8) ?usize {
        for (self.nodes.items, 0..) |node, i| {
            if (std.mem.eql(u8, &node.id, &id)) return i;
        }
        return null;
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
        try self.growLinks(self.nodes.items.len);
        const newcomer = self.nodes.items.len - 1;

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
    settings_fold.encodePayload(pl, buf);
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
