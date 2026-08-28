//! The journal node: the library API at tier 0 and the state owned by a
//! cluster member (PRD 0001 phase 4).
//!
//! One process is a complete journal and its own leader: `open` folds every
//! chain from the store, `append` runs the PRD write path (durable
//! unslotted queue, then slot as leader, then trim), and reads are always
//! local. At that tier the epoch is 1 and the leader is this member. The
//! cluster node uses the replicated-slot, control-entry, and re-fold seams
//! below to apply the same journal state after election and replication.
//!
//! The clock is injectable (`now`), which is what makes slot-stamping and
//! read visibility deterministic in tests; the default is the wall clock.

const std = @import("std");
const crypto = std.crypto;
/// Re-exported so a host reaching this module through the library root can
/// name entry and slot types without importing files directly.
pub const entry = @import("entry.zig");
pub const slot = @import("slot.zig");
pub const store = @import("store.zig");
const chain = @import("chain.zig");
const queue = @import("queue.zig");
const schema = @import("../settings/schema.zig");
const validate = @import("../settings/validate.zig");
const settings_fold = @import("../settings/fold.zig");
const expiry = @import("expiry.zig");
const config = @import("../config/local.zig");

/// How an entry is acknowledged. At n = 1 both coincide (the local member is
/// the leader, so `local` and `slotted` resolve in one call); the split
/// exists for the multi-member write path (OQ 3).
pub const Ack = enum { local, slotted };

/// The wall clock in milliseconds since the epoch, read through the io
/// (0.16's clock API is io-based). The node's default; tests inject a fake.
pub fn wallClock(io: std.Io) i64 {
    const ts = std.Io.Timestamp.now(io, .real);
    return @intCast(@divTrunc(ts.nanoseconds, std.time.ns_per_ms));
}

pub const OpenOptions = struct {
    /// Injectable wall clock (ms since epoch) for slot stamps and read
    /// visibility.
    now: *const fn (std.Io) i64 = wallClock,
    /// The unslotted-queue bound; defaults to the provisional value.
    unslotted_max_bytes: u64 = config.provisional_unslotted_max_bytes,
    fsync: store.Fsync = .every,
    /// Cluster-node restarts re-*forward* queued entries to the leader
    /// instead of slotting them locally (a follower re-slotting its own
    /// queue would fork the chain — PRD 0003 *Write path*). Tier-0 keeps
    /// the local replay.
    replay_forward: bool = false,
};

pub const OpenError = error{
    NoMemberKey,
    CorruptChain,
    NotGenesisFound,
} || store.OpenError;

/// A follower: pushed every new slot of its journal from its cursor.
pub const Follower = struct {
    journal_id: [16]u8,
    /// The next position to deliver (inclusive).
    next: slot.Position,
    ctx: *anyopaque,
    on_slot: *const fn (
        ctx: *anyopaque,
        journal_id: [16]u8,
        sl: *const slot.Slot,
        en: ?*const entry.Entry,
    ) void,
};

const JournalState = struct {
    fold: chain.FoldState,
};

pub const Node = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    store: *store.Store,
    queue: *queue.Queue,
    keypair: crypto.sign.Ed25519.KeyPair,
    member_id: [16]u8,
    now: *const fn (std.Io) i64,
    /// The control journal's genesis entry hash — the group identity (PRD
    /// 0006): the value every segment header names and the value a follower
    /// uses when a replicated `create_journal` needs its store directory.
    group_hash: [32]u8,
    /// The control journal's fold: members, epoch, cluster settings,
    /// journal registry.
    control: chain.FoldState,
    /// Data journal folds, keyed by journal id.
    journals: std.AutoHashMap([16]u8, *JournalState),
    followers: std.ArrayListUnmanaged(Follower),

    // -- open/close ---------------------------------------------------------

    /// Opens the data directory (locking it), loads the member key, folds
    /// every chain from the store, and replays the unslotted queue.
    pub fn open(
        allocator: std.mem.Allocator,
        io: std.Io,
        data_dir: std.Io.Dir,
        options: OpenOptions,
    ) anyerror!*Node {
        const st = try store.Store.open(allocator, io, data_dir, .{ .fsync = options.fsync });
        errdefer st.deinit();
        const q_value = try queue.Queue.open(allocator, io, data_dir, options.unslotted_max_bytes);
        const q = try allocator.create(queue.Queue);
        q.* = q_value;
        errdefer {
            q.deinit();
            allocator.destroy(q);
        }

        const keypair = loadMemberKey(allocator, io, data_dir) catch |err| switch (err) {
            error.FileNotFound => return error.NoMemberKey,
            else => return err,
        };

        const node = try allocator.create(Node);
        errdefer allocator.destroy(node);
        node.* = .{
            .allocator = allocator,
            .io = io,
            .store = st,
            .queue = q,
            .keypair = keypair,
            .member_id = chain.deriveMemberId(keypair.public_key.toBytes()),
            .now = options.now,
            .group_hash = [_]u8{0} ** 32,
            .control = try chain.FoldState.init(allocator, true, [_]u8{0} ** 16),
            .journals = std.AutoHashMap([16]u8, *JournalState).init(allocator),
            .followers = .empty,
        };
        errdefer {
            node.control.deinit();
            node.journals.deinit();
            node.followers.deinit(allocator);
        }

        try node.foldAll();
        if (std.mem.eql(u8, &node.control.journal_id, &([_]u8{0} ** 16))) {
            node.group_hash = [_]u8{0} ** 32;
        } else {
            node.group_hash = try node.store.groupIdOf(node.control.journal_id);
        }
        if (!options.replay_forward) try node.replayQueue();
        return node;
    }

    pub fn deinit(self: *Node) void {
        var it = self.journals.valueIterator();
        while (it.next()) |js_ptr| {
            const js = js_ptr.*;
            js.fold.deinit();
            self.allocator.destroy(js);
        }
        self.journals.deinit();
        self.followers.deinit(self.allocator);
        self.control.deinit();
        self.queue.deinit();
        self.allocator.destroy(self.queue);
        self.store.deinit();
        self.allocator.destroy(self);
    }

    /// The member id (derived from the key) and the folded leader.
    pub fn id(self: *const Node) [16]u8 {
        return self.member_id;
    }

    pub fn leader(self: *const Node) [16]u8 {
        return self.control.epoch.?.leader;
    }

    /// The cluster's current epoch number.
    pub fn epoch(self: *const Node) u64 {
        return self.control.epoch.?.number;
    }

    /// The cluster-scoped settings.
    pub fn settings(self: *const Node) *const schema.SettingsState {
        return &self.control.settings;
    }

    /// A journal's settings: cluster scope merged over journal scope.
    pub fn journalSettings(self: *const Node, journal_id: [16]u8) ?*const schema.SettingsState {
        const js = self.journals.get(journal_id) orelse return null;
        return &js.fold.settings;
    }

    /// Resolves a journal name to its id (the control fold's registry).
    pub fn journalIdByName(self: *const Node, name: []const u8) ?[16]u8 {
        // "__cluster__" is the control journal's canonical name (the CLI's
        // convention); the control journal is not in its own registry.
        if (std.mem.eql(u8, name, "__cluster__")) return self.control.journal_id;
        var it = self.control.journals.iterator();
        while (it.next()) |kv| {
            if (std.mem.eql(u8, kv.value_ptr.name, name)) return kv.key_ptr.*;
        }
        return null;
    }

    /// The head position of a journal (or the control journal when the id
    /// names it).
    pub fn head(self: *const Node, journal_id: [16]u8) ?slot.Position {
        if (std.mem.eql(u8, &journal_id, &self.control.journal_id)) {
            return self.control.head;
        }
        const js = self.journals.get(journal_id) orelse return null;
        return js.fold.head;
    }

    /// This member's next author_seq in a fold (author_seq is per
    /// (author, journal) and covers control entries too). The cluster node
    /// layers its queued-but-unslotted count on top of this.
    pub fn nextAuthorSeq(self: *const Node, fold: *const chain.FoldState) u64 {
        const author = fold.authors.get(self.member_id) orelse return 1;
        return author.last_seq + 1;
    }

    // -- write path ---------------------------------------------------------

    /// Appends a payload to a journal and returns its entry id. The write
    /// path is PRD 0001's: queue durably, slot as leader, trim the queue.
    pub fn append(
        self: *Node,
        journal_id: [16]u8,
        payload: []const u8,
        ttl_ms: u64,
    ) !entry.Id {
        const js = self.journals.get(journal_id) orelse return error.UnknownJournal;
        const fold = &js.fold;

        const max_bytes = fold.settings.getU64(schema.keyIndex("journal.max_entry_bytes").?);
        if (payload.len > max_bytes) return error.TooLarge;

        const author_seq = self.nextAuthorSeq(fold);
        var en = entry.Entry{
            .kind = .data,
            .journal = journal_id,
            .author = self.member_id,
            .author_seq = author_seq,
            .author_ts_ms = @intCast(@max(@as(i64, 0), self.now(self.io))),
            .ttl_ms = ttl_ms,
            .payload_hash = entry.payloadHash(payload),
            .payload_len = @intCast(payload.len),
            .payload_omitted = false,
            .signature = undefined,
            .payload = payload,
        };
        en.signature = (try entry.sign(self.keypair, &en)).toBytes();

        // 1. Durable local queue (bounded; refuses queue_full, OQ 55).
        try self.queue.append(&en);
        errdefer self.queue.remove(journal_id, en.id()) catch {};

        // 2. Slot as leader and append to the store.
        const sl = try self.slotFor(fold, &en);
        try self.store.append(journal_id, &sl, &en);
        try fold.applyData(&self.control, &sl, &en);
        try self.queue.clear();
        self.notifyFollowers(journal_id, &sl, &en);
        return en.id();
    }

    /// Creates a journal: a leader-authored `create_journal` entry in the
    /// control chain plus the journal's store directory and fold. Returns
    /// the new journal's id.
    pub fn createJournal(
        self: *Node,
        name: []const u8,
        initial: []const validate.Change,
    ) ![16]u8 {
        var journal_id: [16]u8 = undefined;
        self.io.random(&journal_id);
        const payload = try self.allocator.alloc(
            u8,
            chain.createJournalPayloadLen(.{
                .journal_id = journal_id,
                .name = name,
                .changes = initial,
            }),
        );
        defer self.allocator.free(payload);
        chain.encodeCreateJournalPayload(
            .{ .journal_id = journal_id, .name = name, .changes = initial },
            payload,
        );
        const group_id = self.group_hash;

        try self.appendControl(.create_journal, payload, &self.control);
        try self.store.createJournal(journal_id, group_id.entry_hash);

        var js = try self.allocator.create(JournalState);
        errdefer self.allocator.destroy(js);
        js.fold = try chain.FoldState.init(self.allocator, false, journal_id);
        try self.journals.put(journal_id, js);
        return journal_id;
    }

    /// Changes settings: a leader-authored `settings` entry in the control
    /// chain (cluster scope) or a data journal's chain (journal scope).
    pub fn changeSettings(
        self: *Node,
        journal_id: [16]u8,
        changes: []const validate.Change,
    ) !void {
        const is_control = std.mem.eql(u8, &journal_id, &self.control.journal_id);
        const payload = settings_fold.SettingsPayload{
            .scope = if (is_control) .cluster else .journal,
            .journal_id = if (is_control) [_]u8{0} ** 16 else journal_id,
            .changes = changes,
        };
        const buf = try self.allocator.alloc(u8, settings_fold.payloadLen(payload));
        defer self.allocator.free(buf);
        settings_fold.encodePayload(payload, buf);
        const target: *chain.FoldState = if (is_control)
            &self.control
        else
            &self.journals.get(journal_id).?.fold;
        try self.appendControl(.settings, buf, target);
    }

    /// Marks one of this member's own entries stale.
    pub fn markStale(self: *Node, journal_id: [16]u8, target: entry.Id) !void {
        var buf: [24]u8 = undefined;
        chain.encodeStalePayload(.{ .target = target }, &buf);
        const js = self.journals.get(journal_id) orelse return error.UnknownJournal;
        try self.appendControl(.stale, &buf, &js.fold);
    }

    /// Appends a checkpoint, then compacts the store (PRD 0002). Refuses to
    /// emit an empty removal set (G7: no checkpoint spam on an idle journal).
    pub fn checkpoint(self: *Node, journal_id: [16]u8) !void {
        const js = self.journals.get(journal_id) orelse return error.UnknownJournal;
        const fold = &js.fold;
        const through = fold.head orelse return;

        var buf: [16]u8 = undefined;
        chain.encodeCheckpointPayload(.{ .expire_through = through }, &buf);
        var en = entry.Entry{
            .kind = .checkpoint,
            .journal = journal_id,
            .author = self.member_id,
            .author_seq = self.nextAuthorSeq(fold),
            .author_ts_ms = @intCast(@max(@as(i64, 0), self.now(self.io))),
            .ttl_ms = 0,
            .payload_hash = entry.payloadHash(&buf),
            .payload_len = @intCast(buf.len),
            .payload_omitted = false,
            .signature = undefined,
            .payload = &buf,
        };
        en.signature = (try entry.sign(self.keypair, &en)).toBytes();
        const sl = try self.slotFor(fold, &en);

        // The removal set is computed against the checkpoint's own stamp —
        // the slot's timestamp, not the raw clock (PRD 0002: the leader's
        // clock chose the instant once, in the chain).
        const removed = try self.removalIds(fold, through, @intCast(sl.slot_ts_ms));
        defer self.allocator.free(removed);
        if (removed.len == 0) return; // never emit an empty removal set (G7)

        try fold.applyData(&self.control, &sl, &en);
        try self.store.append(journal_id, &sl, &en);
        self.notifyFollowers(journal_id, &sl, &en);

        const retain: store.Store.Retain = if (std.mem.eql(
            u8,
            fold.settings.getEnum(schema.keyIndex("ttl.retain").?),
            "none",
        )) .none else .header;
        try self.store.compact(journal_id, removed, retain);
    }

    /// The entries a checkpoint at `head` with stamp `now` would remove —
    /// the same set `applyCheckpoint` will fold, so compaction cannot drop
    /// a payload the fold still treats as present.
    fn removalIds(
        self: *Node,
        fold: *chain.FoldState,
        through: slot.Position,
        now: i64,
    ) ![]const entry.Id {
        var candidates = std.ArrayListUnmanaged(expiry.SlottedEntry).empty;
        defer candidates.deinit(self.allocator);
        var it = fold.entries.iterator();
        while (it.next()) |kv| {
            const info = kv.value_ptr.*;
            try candidates.append(self.allocator, .{
                .id = kv.key_ptr.*,
                .position = info.position,
                .slot_ts_ms = info.slot_ts_ms,
                .expires_at = info.expires_at_ms,
                .ttl_action = info.ttl_action,
                .stale_marked = info.stale_marked,
                .stale_position = info.stale_position,
            });
        }
        const set = try expiry.removalSet(
            self.allocator,
            candidates.items,
            through,
            @intCast(now),
            &fold.settings,
        );
        defer self.allocator.free(set);
        const ids = try self.allocator.alloc(entry.Id, set.len);
        for (set, 0..) |se, i| ids[i] = se.id;
        return ids;
    }

    /// Builds the next slot as the leader: current epoch, next seq (1 when
    /// this journal's head is a previous epoch), clamped slot_ts_ms (a
    /// backwards clock never moves the chain backwards). The cluster node's
    /// leader path slots forwarded entries with this.
    pub fn slotFor(self: *Node, fold: *chain.FoldState, en: *const entry.Entry) !slot.Slot {
        const now_ms = @as(u64, @intCast(@max(@as(i64, 0), self.now(self.io))));
        const now_epoch = self.epoch();
        const seq: u64 = if (fold.head) |fold_head|
            if (fold_head.epoch == now_epoch) fold_head.seq + 1 else 1
        else
            1;
        var sl = slot.Slot{
            .epoch = now_epoch,
            .seq = seq,
            .slot_ts_ms = @max(now_ms, fold.last_slot_ts_ms),
            .entry_hash = entry.entryHash(en),
            .prev_slot_hash = fold.head_slot_hash,
            .leader = self.member_id,
            .signature = undefined,
        };
        sl.signature = (try slot.sign(self.keypair, &sl)).toBytes();
        return sl;
    }

    /// Slots and appends a control entry (genesis excluded — that is
    /// `init`'s job). Public for the cluster node, which authors control
    /// entries (join, epoch, merge, settings) as leader.
    pub fn appendControl(
        self: *Node,
        kind: entry.Kind,
        payload: []const u8,
        fold: *chain.FoldState,
    ) !void {
        var en = entry.Entry{
            .kind = kind,
            .journal = fold.journal_id,
            .author = self.member_id,
            .author_seq = self.nextAuthorSeq(fold),
            .author_ts_ms = @intCast(@max(@as(i64, 0), self.now(self.io))),
            .ttl_ms = 0,
            .payload_hash = entry.payloadHash(payload),
            .payload_len = @intCast(payload.len),
            .payload_omitted = false,
            .signature = undefined,
            .payload = payload,
        };
        en.signature = (try entry.sign(self.keypair, &en)).toBytes();
        const sl = try self.slotFor(fold, &en);
        if (fold.is_control) {
            try fold.applyControl(&sl, &en);
        } else {
            try fold.applyData(&self.control, &sl, &en);
        }
        try self.store.append(fold.journal_id, &sl, &en);
        self.notifyFollowers(fold.journal_id, &sl, &en);
    }

    // -- open-time folding ---------------------------------------------------

    /// Applies one replicated slot — the single seam every incoming slot
    /// uses, whether a live broadcast or a backfill page. Validates against
    /// this member's fold, writes the record to the store, trims the
    /// unslotted queue when the entry is this member's own, and notifies
    /// local followers. `reslotted` selects the merge re-slot rule for the
    /// control chain (data re-slots use the normal rule; the entries-table
    /// dedup makes them idempotent — OQ 11).
    pub fn applyReplicated(
        self: *Node,
        journal_id: [16]u8,
        sl: *const slot.Slot,
        en: *const entry.Entry,
        reslotted: bool,
    ) !void {
        // A member with no chain yet folds its first record — the genesis —
        // into the control fold, which adopts the founder's journal id; a
        // chainless member cannot know the control id before that.
        const control_unset = std.mem.eql(u8, &self.control.journal_id, &([_]u8{0} ** 16));
        const is_control = std.mem.eql(u8, &journal_id, &self.control.journal_id) or
            (control_unset and en.kind == .genesis);
        if (is_control) {
            if (reslotted) {
                try self.control.applyControlReslotted(sl, en);
            } else {
                try self.control.applyControl(sl, en);
            }
            if (en.kind == .genesis) {
                // Bootstrap: this genesis founds the control journal's store
                // directory and names the group (PRD 0006).
                if (!self.store.hasJournal(journal_id)) {
                    const hash = entry.entryHash(en);
                    try self.store.createJournal(journal_id, hash);
                    self.group_hash = hash;
                }
            } else if (en.kind == .create_journal) {
                // A replicated create_journal records the journal in the
                // fold; the store directory and the data fold must exist for
                // its chain to land in.
                const payload = try chain.decodeCreateJournalPayload(self.allocator, en.payload);
                defer payload.deinit(self.allocator);
                try self.ensureJournalDir(payload.journal_id);
                if (!self.journals.contains(payload.journal_id)) {
                    var js = try self.allocator.create(JournalState);
                    errdefer self.allocator.destroy(js);
                    js.fold = try chain.FoldState.init(self.allocator, false, payload.journal_id);
                    try self.journals.put(payload.journal_id, js);
                }
            }
        } else {
            const js = self.journals.get(journal_id) orelse return error.UnknownJournal;
            try js.fold.applyData(&self.control, sl, en);
        }
        try self.store.append(journal_id, sl, en);
        if (std.mem.eql(u8, &en.author, &self.member_id)) {
            self.queue.remove(journal_id, en.id()) catch {};
        }
        self.notifyFollowers(journal_id, sl, en);
    }

    /// Creates the store directory for a journal the control fold just
    /// recorded (a replicated `create_journal` on a follower), naming the
    /// cluster's group hash exactly as the creator's `createJournal` did.
    pub fn ensureJournalDir(self: *Node, journal_id: [16]u8) !void {
        if (self.store.hasJournal(journal_id)) return;
        try self.store.createJournal(journal_id, self.group_hash);
    }

    /// Re-folds every journal from the store (the OQ 44 re-fold discipline):
    /// after the losing branch truncates its store to the last common slot,
    /// the fold is rebuilt from the surviving chain. The queue is untouched
    /// — the cluster node's replay policy owns it. Callers must hold no
    /// references into the old folds.
    pub fn refold(self: *Node) !void {
        const control_id = self.control.journal_id;
        var it = self.journals.valueIterator();
        while (it.next()) |js_ptr| {
            const js = js_ptr.*;
            js.fold.deinit();
            self.allocator.destroy(js);
        }
        self.journals.clearRetainingCapacity();
        self.control.deinit();
        self.control = try chain.FoldState.init(self.allocator, true, control_id);
        try self.foldAll();
    }

    fn foldAll(self: *Node) anyerror!void {
        const ids = try self.store.journalIds(self.allocator);
        defer self.allocator.free(ids);

        // The control journal is the one whose first record is a genesis
        // entry; every other journal folds as a data journal against the
        // control fold, so the control journal folds first. A member with a
        // key but no chain (a joiner before backfill) has nothing to fold.
        var control_id: ?[16]u8 = null;
        for (ids) |journal_id| {
            var is_control = false;
            try self.store.scan(journal_id, &is_control, struct {
                fn cb(flag: *bool, _: *const slot.Slot, en: ?*const entry.Entry) anyerror!void {
                    if (flag.*) return;
                    if (en) |e| {
                        if (e.kind == .genesis) flag.* = true;
                    }
                }
            }.cb);
            if (is_control) {
                control_id = journal_id;
                break;
            }
        }
        const cid = control_id orelse {
            self.control.journal_id = [_]u8{0} ** 16;
            return;
        };
        self.control.journal_id = cid;

        try self.foldJournal(&self.control, cid);
        for (ids) |journal_id| {
            if (std.mem.eql(u8, &journal_id, &cid)) continue;
            const js = try self.allocator.create(JournalState);
            errdefer self.allocator.destroy(js);
            js.fold = try chain.FoldState.init(self.allocator, false, journal_id);
            try self.foldJournal(&js.fold, journal_id);
            try self.journals.put(journal_id, js);
        }
    }

    /// Replays one journal's chain into its fold; data journals validate
    /// against the control fold (members, epoch leader).
    fn foldJournal(self: *Node, fold: *chain.FoldState, journal_id: [16]u8) anyerror!void {
        const Ctx = struct { node: *Node, fold: *chain.FoldState };
        var ctx = Ctx{ .node = self, .fold = fold };
        try self.store.scan(journal_id, &ctx, struct {
            fn cb(c: *Ctx, sl: *const slot.Slot, en: ?*const entry.Entry) anyerror!void {
                const e = en orelse return; // a retain=none removed record
                if (c.fold.is_control) {
                    try c.fold.applyControl(sl, e);
                } else {
                    // A losing branch truncates its control fold first; its
                    // own data records from the divergent epoch still sit in
                    // the store until the survivor fetches them (merge_ack).
                    // Their epoch exceeds the truncated control fold's, which
                    // applyData refuses (BadPosition) — skip them; the
                    // survivor re-slots them into the merged chain. A control
                    // epoch with no epoch entry yet cannot validate data at
                    // all, so it is skipped too.
                    if (c.node.control.epoch == null or
                        sl.epoch > c.node.control.epoch.?.number) return;
                    try c.fold.applyData(&c.node.control, sl, e);
                }
            }
        }.cb);
    }

    fn replayQueue(self: *Node) !void {
        const Ctx = struct {
            list: *std.ArrayListUnmanaged(entry.Entry),
            allocator: std.mem.Allocator,
        };
        var pending = std.ArrayListUnmanaged(entry.Entry).empty;
        defer {
            for (pending.items) |en| self.allocator.free(en.payload);
            pending.deinit(self.allocator);
        }
        var ctx = Ctx{ .list = &pending, .allocator = self.allocator };
        try self.queue.scan(&ctx, struct {
            fn cb(c: *Ctx, en: *const entry.Entry) anyerror!void {
                // The scan's buffer is freed when it returns; the payload
                // must survive in the collected copy.
                var copy = en.*;
                copy.payload = try c.allocator.dupe(u8, en.payload);
                try c.list.append(c.allocator, copy);
            }
        }.cb);
        // The queue stores borrowed entries; the fold needs the payload
        // while slotted. Re-slot each queued entry that is not already in
        // the chain (a crash after slotting but before the trim redelivers
        // it; the fold's dedup accepts it as a no-op).
        for (pending.items) |en| {
            const js = self.journals.get(en.journal) orelse continue;
            if (js.fold.entries.contains(en.id())) continue;
            const sl = try self.slotFor(&js.fold, &en);
            try self.store.append(en.journal, &sl, &en);
            try js.fold.applyData(&self.control, &sl, &en);
        }
        try self.queue.clear();
    }

    // -- reads ----------------------------------------------------------------

    /// Reads an entry by id; returns false when the journal does not have
    /// it. The callback receives the slot and (when present) the entry;
    /// removed entries under `retain = none` come with a null entry.
    pub fn readById(
        self: *Node,
        journal_id: [16]u8,
        target: entry.Id,
        include_stale: bool,
        include_expired: bool,
        ctx: anytype,
        comptime on_entry: fn (@TypeOf(ctx), *const slot.Slot, ?*const entry.Entry) anyerror!void,
    ) !bool {
        const fold = self.foldOf(journal_id) orelse return false;
        const info = fold.entries.get(target) orelse return false;
        const now_ms = self.now(self.io);
        if (!visible(fold, info, now_ms, include_stale, include_expired)) return false;
        return self.readRecord(journal_id, info, ctx, on_entry);
    }

    /// Reads slots in `[from, to]`, in chain order. `from` defaults to the
    /// journal's genesis, `to` to its head (inclusive).
    pub fn readRange(
        self: *Node,
        journal_id: [16]u8,
        from: ?slot.Position,
        to: ?slot.Position,
        include_stale: bool,
        include_expired: bool,
        ctx: anytype,
        comptime on_entry: fn (@TypeOf(ctx), *const slot.Slot, ?*const entry.Entry) anyerror!void,
    ) !void {
        const fold = self.foldOf(journal_id) orelse return;
        const start = from orelse slot.Position{ .epoch = 1, .seq = 1 };
        const end = to orelse fold.head orelse return;

        // The fold's entries, sorted by slot position (chain order).
        const ids = try self.sortedEntryIds(fold);
        defer self.allocator.free(ids);
        for (ids) |eid| {
            const info = fold.entries.get(eid).?;
            if (slot.Position.order(info.position, start) == .lt) continue;
            if (slot.Position.order(info.position, end) == .gt) break;
            const now_ms = self.now(self.io);
            if (!visible(fold, info, now_ms, include_stale, include_expired)) continue;
            _ = try self.readRecord(journal_id, info, ctx, on_entry);
        }
    }

    /// The control journal, or a data journal this node has folded.
    fn foldOf(self: *Node, journal_id: [16]u8) ?*chain.FoldState {
        if (std.mem.eql(u8, &journal_id, &self.control.journal_id)) {
            return &self.control;
        }
        const js = self.journals.get(journal_id) orelse return null;
        return &js.fold;
    }

    fn readRecord(
        self: *Node,
        journal_id: [16]u8,
        info: chain.EntryInfo,
        ctx: anytype,
        comptime on_entry: fn (@TypeOf(ctx), *const slot.Slot, ?*const entry.Entry) anyerror!void,
    ) !bool {
        const size = storeRecordSizeFor(info);
        const buf = try self.allocator.alloc(u8, size);
        defer self.allocator.free(buf);
        const rec = (try self.store.read(journal_id, info.position, buf)) orelse return false;
        try on_entry(ctx, &rec.slot, if (rec.entry) |*en| en else null);
        return true;
    }

    fn sortedEntryIds(self: *Node, fold: *chain.FoldState) ![]entry.Id {
        const ids = try self.allocator.alloc(entry.Id, fold.entries.count());
        var i: usize = 0;
        var it = fold.entries.keyIterator();
        while (it.next()) |eid| {
            ids[i] = eid.*;
            i += 1;
        }
        std.mem.sort(entry.Id, ids, fold, struct {
            fn lt(f: *chain.FoldState, a: entry.Id, b: entry.Id) bool {
                const pa = f.entries.get(a).?.position;
                const pb = f.entries.get(b).?.position;
                return slot.Position.order(pa, pb) == .lt;
            }
        }.lt);
        return ids;
    }

    // -- follow ---------------------------------------------------------------

    /// Registers a follower: delivers every slot of `journal_id` from
    /// `cursor` (existing ones first, then new ones as they land), then
    /// keeps pushing. Follow is push-on-append in this single-threaded
    /// milestone; background delivery lands with the node loop (PRD 0003).
    pub fn follow(
        self: *Node,
        journal_id: [16]u8,
        cursor: slot.Position,
        ctx: *anyopaque,
        on_slot: *const fn (
            ctx: *anyopaque,
            journal_id: [16]u8,
            sl: *const slot.Slot,
            en: ?*const entry.Entry,
        ) void,
    ) !void {
        const Init = struct {
            jid: [16]u8,
            ctx: *anyopaque,
            on_slot: *const fn (
                ctx: *anyopaque,
                journal_id: [16]u8,
                sl: *const slot.Slot,
                en: ?*const entry.Entry,
            ) void,
        };
        var init_ctx = Init{ .jid = journal_id, .ctx = ctx, .on_slot = on_slot };
        try self.readRange(journal_id, cursor, null, true, true, &init_ctx, struct {
            fn cb(c: *Init, sl: *const slot.Slot, en: ?*const entry.Entry) anyerror!void {
                c.on_slot(c.ctx, c.jid, sl, en);
            }
        }.cb);
        try self.followers.append(self.allocator, .{
            .journal_id = journal_id,
            .next = cursor,
            .ctx = ctx,
            .on_slot = on_slot,
        });
    }

    fn notifyFollowers(
        self: *Node,
        journal_id: [16]u8,
        sl: *const slot.Slot,
        en: *const entry.Entry,
    ) void {
        for (self.followers.items) |*f| {
            if (!std.mem.eql(u8, &f.journal_id, &journal_id)) continue;
            if (slot.Position.order(sl.position(), f.next) == .lt) continue;
            f.on_slot(f.ctx, journal_id, sl, en);
            f.next = sl.position().next();
        }
    }
};

/// The size a store record for this entry occupies after any compaction.
fn storeRecordSizeFor(info: chain.EntryInfo) usize {
    return 8 + slot.encoded_len + entry.header_len + info.payload_len;
}

pub fn visible(
    fold: *const chain.FoldState,
    info: chain.EntryInfo,
    now: i64,
    include_stale: bool,
    include_expired: bool,
) bool {
    const now_ms: u64 = @intCast(@max(@as(i64, 0), now));
    const grace = fold.settings.getU64(schema.keyIndex("ttl.grace_ms").?);
    return expiry.isVisible(
        info.removed,
        info.expires_at_ms,
        info.ttl_action,
        info.stale_marked,
        now_ms,
        grace,
        include_stale,
        include_expired,
    );
}

/// Loads this member's Ed25519 key from `member.key` (the raw 64-byte
/// secret key). `init` writes it; a fresh directory without one cannot open
/// (there is nothing to fold yet — run `coppiz init` first). Public for the
/// wire client, which reads the key while the serving node holds the
/// directory lock.
pub fn loadMemberKeyPublic(
    _: std.mem.Allocator,
    io: std.Io,
    data_dir: std.Io.Dir,
) !crypto.sign.Ed25519.KeyPair {
    const file = try data_dir.openFile(io, "member.key", .{});
    defer file.close(io);
    var buf: [64]u8 = undefined;
    const n = try file.readPositionalAll(io, &buf, 0);
    if (n != buf.len) return error.TruncatedKey;
    const sk = try crypto.sign.Ed25519.SecretKey.fromBytes(buf);
    return crypto.sign.Ed25519.KeyPair.fromSecretKey(sk);
}

fn loadMemberKey(
    allocator: std.mem.Allocator,
    io: std.Io,
    data_dir: std.Io.Dir,
) !crypto.sign.Ed25519.KeyPair {
    return loadMemberKeyPublic(allocator, io, data_dir);
}

/// Owner-only mode for `member.key`. `default_file` is 0o666 masked by
/// umask, which would leave the secret group- and world-readable.
const member_key_perm: std.Io.File.Permissions = .fromMode(0o600);

/// Writes a fresh member key to `member.key`. Used by `init`.
pub fn writeMemberKey(
    _: std.mem.Allocator,
    io: std.Io,
    data_dir: std.Io.Dir,
    keypair: crypto.sign.Ed25519.KeyPair,
) !void {
    const file = data_dir.createFile(io, "member.key", .{
        .read = true,
        .truncate = false,
        .permissions = member_key_perm,
    }) catch |err| blk: {
        if (err != error.PathAlreadyExists) return err;
        break :blk try data_dir.openFile(io, "member.key", .{ .mode = .read_write });
    };
    defer file.close(io);
    try file.setPermissions(io, member_key_perm);
    const bytes = keypair.secret_key.toBytes();
    try file.writePositionalAll(io, &bytes, 0);
    try file.sync(io);
}

/// Bootstraps a cluster: writes the member key and the genesis entry
/// (control journal, epoch 1, founder = this member), then optionally a
/// first data journal. Refuses invalid initial settings before writing
/// anything (PRD 0004 G6). The store must be freshly opened on an empty
/// directory.
pub fn init(
    allocator: std.mem.Allocator,
    io: std.Io,
    data_dir: std.Io.Dir,
    initial: []const validate.Change,
    first_journal: ?[]const u8,
    now: *const fn (std.Io) i64,
) !void {
    // Validate the whole-state first: nothing is written until the genesis
    // would fold to a valid state (G6 writes no chain on refusal).
    var probe = try schema.SettingsState.initDefaults(allocator);
    defer probe.deinit();
    try settings_fold.applyGenesis(&probe, initial);

    var keypair = crypto.sign.Ed25519.KeyPair.generate(io);
    try writeMemberKey(allocator, io, data_dir, keypair);
    const member_id = chain.deriveMemberId(keypair.public_key.toBytes());

    const st = try store.Store.open(allocator, io, data_dir, .{});
    defer st.deinit();

    var control_id: [16]u8 = undefined;
    io.random(&control_id);

    const g_payload_len = chain.genesisPayloadLen(.{
        .founder_key = keypair.public_key.toBytes(),
        .changes = initial,
    });
    const payload = try allocator.alloc(u8, g_payload_len);
    defer allocator.free(payload);
    chain.encodeGenesisPayload(
        .{ .founder_key = keypair.public_key.toBytes(), .changes = initial },
        payload,
    );

    var en = entry.Entry{
        .kind = .genesis,
        .journal = control_id,
        .author = member_id,
        .author_seq = 1,
        .author_ts_ms = @intCast(@max(@as(i64, 0), now(io))),
        .ttl_ms = 0,
        .payload_hash = entry.payloadHash(payload),
        .payload_len = @intCast(payload.len),
        .payload_omitted = false,
        .signature = undefined,
        .payload = payload,
    };
    en.signature = (try entry.sign(keypair, &en)).toBytes();
    var sl = slot.Slot{
        .epoch = 1,
        .seq = 1,
        .slot_ts_ms = @intCast(@max(@as(i64, 0), now(io))),
        .entry_hash = entry.entryHash(&en),
        .prev_slot_hash = slot.genesis_prev,
        .leader = member_id,
        .signature = undefined,
    };
    sl.signature = (try slot.sign(keypair, &sl)).toBytes();

    try st.createJournal(control_id, entry.entryHash(&en));
    try st.append(control_id, &sl, &en);

    if (first_journal) |name| {
        var journal_id: [16]u8 = undefined;
        io.random(&journal_id);
        const cj_payload = try allocator.alloc(
            u8,
            chain.createJournalPayloadLen(.{
                .journal_id = journal_id,
                .name = name,
                .changes = &.{},
            }),
        );
        defer allocator.free(cj_payload);
        chain.encodeCreateJournalPayload(
            .{ .journal_id = journal_id, .name = name, .changes = &.{} },
            cj_payload,
        );
        var cj_en = entry.Entry{
            .kind = .create_journal,
            .journal = control_id,
            .author = member_id,
            .author_seq = 2,
            .author_ts_ms = @intCast(@max(@as(i64, 0), now(io))),
            .ttl_ms = 0,
            .payload_hash = entry.payloadHash(cj_payload),
            .payload_len = @intCast(cj_payload.len),
            .payload_omitted = false,
            .signature = undefined,
            .payload = cj_payload,
        };
        cj_en.signature = (try entry.sign(keypair, &cj_en)).toBytes();
        var cj_sl = slot.Slot{
            .epoch = 1,
            .seq = 2,
            .slot_ts_ms = @intCast(@max(@as(i64, 0), now(io))),
            .entry_hash = entry.entryHash(&cj_en),
            .prev_slot_hash = slot.slotHash(&sl),
            .leader = member_id,
            .signature = undefined,
        };
        cj_sl.signature = (try slot.sign(keypair, &cj_sl)).toBytes();
        try st.append(control_id, &cj_sl, &cj_en);
        try st.createJournal(journal_id, entry.entryHash(&en));
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const test_alloc = std.testing.allocator;
const tio = std.testing.io;

var test_now: i64 = 1_700_000_000_000;

fn fakeClock(_: std.Io) i64 {
    return test_now;
}

const TestEnv = struct {
    tmp: std.testing.TmpDir,

    fn init() TestEnv {
        return .{ .tmp = std.testing.tmpDir(.{}) };
    }

    fn dataDir(self: *TestEnv) !std.Io.Dir {
        self.tmp.dir.createDir(tio, "data", .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        return self.tmp.dir.openDir(tio, "data", .{ .iterate = true });
    }

    fn deinit(self: *TestEnv) void {
        self.tmp.cleanup();
    }
};

fn openNode(env: *TestEnv) !*Node {
    return Node.open(test_alloc, tio, try env.dataDir(), .{ .now = &fakeClock });
}

test "member.key is created owner-readable only" {
    var env = TestEnv.init();
    defer env.deinit();
    {
        const data_dir = try env.dataDir();
        try init(test_alloc, tio, data_dir, &.{}, "main", &fakeClock);
    }
    const file = try env.tmp.dir.openFile(tio, "data/member.key", .{});
    defer file.close(tio);
    const st = try file.stat(tio);
    try std.testing.expectEqual(
        @as(std.posix.mode_t, 0o600),
        st.permissions.toMode() & 0o777,
    );
}

test "init, append, read, head, reopen (the single-member journal)" {
    var env = TestEnv.init();
    defer env.deinit();
    test_now = 1_700_000_000_000;

    {
        const data_dir = try env.dataDir();
        try init(test_alloc, tio, data_dir, &.{}, "main", &fakeClock);
    }

    const main_id = "main".*;
    _ = main_id;

    const jid = blk: {
        var node = try openNode(&env);
        defer node.deinit();
        const j = node.journalIdByName("main").?;
        try std.testing.expect(!std.mem.eql(u8, &j, &[_]u8{0} ** 16));

        const id1 = try node.append(j, "hello", 0);
        try std.testing.expectEqual(@as(u64, 1), id1.author_seq);
        const id2 = try node.append(j, "world", 0);
        try std.testing.expectEqual(@as(u64, 2), id2.author_seq);
        try std.testing.expectEqual(@as(?slot.Position, .{ .epoch = 1, .seq = 2 }), node.head(j));

        var seen: usize = 0;
        _ = try node.readById(j, id1, false, false, &seen, struct {
            fn cb(c: *usize, _: *const slot.Slot, en: ?*const entry.Entry) anyerror!void {
                try std.testing.expectEqualStrings("hello", en.?.payload);
                c.* += 1;
            }
        }.cb);
        try std.testing.expectEqual(@as(usize, 1), seen);
        break :blk j;
    };

    // A reopen folds the same state from the store.
    var node2 = try openNode(&env);
    defer node2.deinit();
    try std.testing.expectEqual(@as(?slot.Position, .{ .epoch = 1, .seq = 2 }), node2.head(jid));
    var seen2: usize = 0;
    try node2.readRange(jid, null, null, true, true, &seen2, struct {
        fn cb(c: *usize, _: *const slot.Slot, _: ?*const entry.Entry) anyerror!void {
            c.* += 1;
        }
    }.cb);
    try std.testing.expectEqual(@as(usize, 2), seen2);
}

test "follow delivers existing slots from the cursor, then pushes new ones" {
    var env = TestEnv.init();
    defer env.deinit();
    test_now = 1_700_000_000_000;

    {
        const data_dir = try env.dataDir();
        try init(test_alloc, tio, data_dir, &.{}, "main", &fakeClock);
    }
    var node = try openNode(&env);
    defer node.deinit();
    const jid = node.journalIdByName("main").?;
    _ = try node.append(jid, "one", 0);
    _ = try node.append(jid, "two", 0);

    // Follow from the genesis: the two existing slots are delivered first.
    var delivered = std.ArrayListUnmanaged([]const u8).empty;
    defer delivered.deinit(test_alloc);
    try node.follow(jid, .{ .epoch = 1, .seq = 1 }, &delivered, struct {
        fn on(ctx: *anyopaque, _: [16]u8, _: *const slot.Slot, en: ?*const entry.Entry) void {
            const list: *std.ArrayListUnmanaged([]const u8) = @ptrCast(@alignCast(ctx));
            if (en) |e| list.append(test_alloc, e.payload) catch {};
        }
    }.on);
    try std.testing.expectEqual(@as(usize, 2), delivered.items.len);

    // A new append pushes to the follower.
    _ = try node.append(jid, "three", 0);
    try std.testing.expectEqual(@as(usize, 3), delivered.items.len);
    try std.testing.expectEqualStrings("three", delivered.items[2]);
}

test "settings change live and fold identically across reopen" {
    var env = TestEnv.init();
    defer env.deinit();
    test_now = 1_700_000_000_000;

    {
        const data_dir = try env.dataDir();
        try init(test_alloc, tio, data_dir, &.{}, "main", &fakeClock);
    }
    var node = try openNode(&env);
    const jid = node.journalIdByName("main").?;

    const ttl_default = schema.keyIndex("ttl.default_ms").?;
    const changes = [_]validate.Change{.{ .key = ttl_default, .value = .{ .u64 = 5000 } }};
    try node.changeSettings(jid, &changes);
    try std.testing.expectEqual(
        @as(u64, 5000),
        node.journalSettings(jid).?.getU64(ttl_default),
    );

    const before = try node.control.hash(test_alloc);
    node.deinit();

    var node2 = try openNode(&env);
    defer node2.deinit();
    try std.testing.expectEqual(
        @as(u64, 5000),
        node2.journalSettings(jid).?.getU64(ttl_default),
    );
    try std.testing.expectEqualSlices(u8, &before, &(try node2.control.hash(test_alloc)));
}

test "stale marks hide the entry from default reads; include_stale shows it (G5, G7)" {
    var env = TestEnv.init();
    defer env.deinit();
    test_now = 1_700_000_000_000;

    {
        const data_dir = try env.dataDir();
        try init(test_alloc, tio, data_dir, &.{}, "main", &fakeClock);
    }
    var node = try openNode(&env);
    defer node.deinit();
    const jid = node.journalIdByName("main").?;

    // With stale.enforce = off (the default), a stale mark is refused.
    const id = try node.append(jid, "to be marked", 0);
    try std.testing.expectError(error.StalenessDisabled, node.markStale(jid, id));

    const stale_enforce = schema.keyIndex("stale.enforce").?;
    const changes = [_]validate.Change{
        .{
            .key = stale_enforce,
            .value = .{ .enum_value = schema.enumValue(stale_enforce, "author").? },
        },
    };
    try node.changeSettings(jid, &changes);
    _ = try node.markStale(jid, id);

    var default_seen: usize = 0;
    _ = try node.readById(jid, id, false, false, &default_seen, struct {
        fn cb(c: *usize, _: *const slot.Slot, _: ?*const entry.Entry) anyerror!void {
            c.* += 1;
        }
    }.cb);
    try std.testing.expectEqual(@as(usize, 0), default_seen);

    var with_stale: usize = 0;
    _ = try node.readById(jid, id, true, false, &with_stale, struct {
        fn cb(c: *usize, _: *const slot.Slot, en: ?*const entry.Entry) anyerror!void {
            try std.testing.expectEqualStrings("to be marked", en.?.payload);
            c.* += 1;
        }
    }.cb);
    try std.testing.expectEqual(@as(usize, 1), with_stale);
}

test "checkpoint removes expired entries and compaction keeps the chain verifiable" {
    var env = TestEnv.init();
    defer env.deinit();
    test_now = 1_700_000_000_000;

    {
        const data_dir = try env.dataDir();
        try init(test_alloc, tio, data_dir, &.{}, "main", &fakeClock);
    }
    const s = blk: {
        var node = try openNode(&env);
        defer node.deinit();
        const j = node.journalIdByName("main").?;
        const enforce = schema.keyIndex("ttl.enforce").?;
        const ttl_default = schema.keyIndex("ttl.default_ms").?;
        const ttl_action = schema.keyIndex("ttl.action").?;
        const changes = [_]validate.Change{
            .{ .key = enforce, .value = .{ .enum_value = schema.enumValue(enforce, "all").? } },
            .{ .key = ttl_default, .value = .{ .u64 = 1000 } },
            .{
                .key = ttl_action,
                .value = .{ .enum_value = schema.enumValue(ttl_action, "delete").? },
            },
        };
        // Everything happens on one timeline: the settings entry (t=2000)
        // sets the chain's clock, so later slots are stamped from there.
        test_now = 2_000;
        try node.changeSettings(j, &changes);

        // "expiring" is slotted at t=2000 and expires at 3000.
        const expiring = try node.append(j, "expiring", 0);

        // An empty removal set emits no checkpoint (G7): at t=2500 nothing
        // has expired (the checkpoint would stamp 2500), so the head does
        // not move.
        test_now = 2_500;
        try node.checkpoint(j);
        try std.testing.expectEqual(@as(?slot.Position, .{ .epoch = 1, .seq = 2 }), node.head(j));

        // "staying" is slotted at t=3500 and expires at 4500, after the
        // checkpoint that removes "expiring".
        test_now = 3_500;
        _ = try node.append(j, "staying", 0);
        const staying = entry.Id{ .author = node.member_id, .author_seq = 3 };

        // Past "expiring"'s instant: the checkpoint removes and compacts.
        test_now = 4_000;
        try node.checkpoint(j);
        const info = node.journals.get(j).?.fold.entries.get(expiring).?;
        try std.testing.expect(info.removed);
        // The live entry is untouched by the checkpoint.
        const staying_info = node.journals.get(j).?.fold.entries.get(staying).?;
        try std.testing.expect(!staying_info.removed);

        // The store now holds a header-only record for the removed entry.
        var buf: [512]u8 = undefined;
        const rec = (try node.store.read(j, info.position, &buf)).?;
        const removed_en = rec.entry.?;
        try std.testing.expect(removed_en.payload_omitted);
        try std.testing.expectEqual(@as(usize, 0), removed_en.payload.len);
        try std.testing.expectEqual(@as(u32, 8), removed_en.payload_len);
        // The chain verifies and the fold state is stable across a reopen.
        const fold_hash = try node.journals.get(j).?.fold.hash(test_alloc);
        break :blk .{ .jid = j, .expiring = expiring, .fold_hash = fold_hash };
    };

    var node2 = try openNode(&env);
    defer node2.deinit();
    const info2 = node2.journals.get(s.jid).?.fold.entries.get(s.expiring).?;
    try std.testing.expect(info2.removed);
    const fold_hash2 = try node2.journals.get(s.jid).?.fold.hash(test_alloc);
    try std.testing.expectEqualSlices(u8, &s.fold_hash, &fold_hash2);
}

test "a backwards clock is clamped to the previous slot (failure mode)" {
    var env = TestEnv.init();
    defer env.deinit();
    test_now = 1_700_000_000_000;

    {
        const data_dir = try env.dataDir();
        try init(test_alloc, tio, data_dir, &.{}, "main", &fakeClock);
    }
    var node = try openNode(&env);
    defer node.deinit();
    const jid = node.journalIdByName("main").?;
    _ = try node.append(jid, "first", 0);
    test_now -= 5000;
    _ = try node.append(jid, "second", 0);
    const info = node.journals.get(jid).?.fold.entries.get(.{
        .author = node.member_id,
        .author_seq = 2,
    }).?;
    try std.testing.expectEqual(
        @as(u64, 1_700_000_000_000),
        info.slot_ts_ms,
    );
}

test "journal.max_entry_bytes and the queue bound trip at the node (G6)" {
    var env = TestEnv.init();
    defer env.deinit();
    test_now = 1_700_000_000_000;

    {
        const data_dir = try env.dataDir();
        try init(test_alloc, tio, data_dir, &.{}, "main", &fakeClock);
    }
    _ = blk: {
        var node = try openNode(&env);
        defer node.deinit();
        const j = node.journalIdByName("main").?;

        // max_entry_bytes: an oversized payload refuses before anything is
        // written.
        const max_bytes = schema.keyIndex("journal.max_entry_bytes").?;
        const changes = [_]validate.Change{.{ .key = max_bytes, .value = .{ .u64 = 8 } }};
        try node.changeSettings(j, &changes);
        try std.testing.expectError(
            error.TooLarge,
            node.append(j, "0123456789", 0),
        );
        break :blk j;
    };

    // The queue bound: a node opened with a tiny unslotted-queue bound
    // refuses the append at the queue step (G6 trips the bound).
    const data_dir = try env.dataDir();
    var tiny = try Node.open(test_alloc, tio, data_dir, .{
        .now = &fakeClock,
        .unslotted_max_bytes = 100,
    });
    defer tiny.deinit();
    const main_id = tiny.journalIdByName("main").?;
    try std.testing.expectError(error.QueueFull, tiny.append(main_id, "fits? no", 0));
}

test "slotFor restarts seq at 1 when the cluster epoch advances" {
    var env = TestEnv.init();
    defer env.deinit();
    test_now = 1_700_000_000_000;
    {
        const data_dir = try env.dataDir();
        try init(test_alloc, tio, data_dir, &.{}, "main", &fakeClock);
    }
    var node = try openNode(&env);
    defer node.deinit();
    const j = node.journalIdByName("main").?;
    _ = try node.append(j, "one", 0);
    try std.testing.expectEqual(@as(u64, 1), node.head(j).?.epoch);
    try std.testing.expectEqual(@as(u64, 1), node.head(j).?.seq);

    var ep = node.control.epoch.?;
    ep.number += 1;
    node.control.epoch = ep;
    const js = node.journals.get(j).?;
    var dummy = entry.Entry{
        .kind = .data,
        .journal = j,
        .author = node.member_id,
        .author_seq = 2,
        .author_ts_ms = 0,
        .ttl_ms = 0,
        .payload_hash = entry.payloadHash("x"),
        .payload_len = 1,
        .payload_omitted = false,
        .signature = [_]u8{0} ** 64,
        .payload = "x",
    };
    const sl = try node.slotFor(&js.fold, &dummy);
    try std.testing.expectEqual(@as(u64, 2), sl.epoch);
    try std.testing.expectEqual(@as(u64, 1), sl.seq);
}

test "applyReplicated replays another member's whole store onto a fresh member" {
    var env_a = TestEnv.init();
    defer env_a.deinit();
    var env_b = TestEnv.init();
    defer env_b.deinit();
    test_now = 1_700_000_000_000;

    // A: a founder with one data entry. The node lives for the whole test
    // (the replay borrows its folds).
    {
        const data_dir = try env_a.dataDir();
        try init(test_alloc, tio, data_dir, &.{}, "main", &fakeClock);
    }
    var a = try openNode(&env_a);
    defer a.deinit();
    _ = try a.append(a.journalIdByName("main").?, "hello", 0);
    _ = try a.append(a.journalIdByName("main").?, "world", 0);

    // B: a member with a key but no chain (the joiner's pre-backfill state).
    const b_keypair = crypto.sign.Ed25519.KeyPair.generate(tio);
    {
        const data_dir = try env_b.dataDir();
        try writeMemberKey(test_alloc, tio, data_dir, b_keypair);
    }
    var b = try openNode(&env_b);
    defer b.deinit();
    try std.testing.expect(std.mem.eql(u8, &b.control.journal_id, &([_]u8{0} ** 16)));
    try std.testing.expect(b.control.head == null);

    // Replay A's control chain (genesis, create_journal), then the data
    // chain, exactly as a backfill would deliver them.
    const Replay = struct {
        target: *Node,
        journal_id: [16]u8,
        fn cb(r: *@This(), sl: *const slot.Slot, en: ?*const entry.Entry) anyerror!void {
            const e = en orelse return; // compacted records have no entry (OQ 43)
            try r.target.applyReplicated(r.journal_id, sl, e, false);
        }
    };
    var control_replay = Replay{ .target = b, .journal_id = a.control.journal_id };
    try a.store.scan(a.control.journal_id, &control_replay, Replay.cb);

    const main_id = a.journalIdByName("main").?;
    var data_replay = Replay{ .target = b, .journal_id = main_id };
    try a.store.scan(main_id, &data_replay, Replay.cb);

    // The folds hash-equal and B reads the entry by id.
    const a_hash = try a.control.hash(test_alloc);
    const b_hash = try b.control.hash(test_alloc);
    try std.testing.expectEqualSlices(u8, &a_hash, &b_hash);
    try std.testing.expectEqual(a.head(main_id), b.head(main_id));
    try std.testing.expectEqualSlices(u8, &a.group_hash, &b.group_hash);

    var seen: usize = 0;
    _ = try b.readById(
        main_id,
        .{ .author = a.member_id, .author_seq = 2 },
        true,
        true,
        &seen,
        struct {
            fn cb(c: *usize, _: *const slot.Slot, en: ?*const entry.Entry) anyerror!void {
                try std.testing.expectEqualStrings("world", en.?.payload);
                c.* += 1;
            }
        }.cb,
    );
    try std.testing.expectEqual(@as(usize, 1), seen);

    // The merge discipline: truncate B's data chain past seq 1 and re-fold
    // — the losing branch's tail is gone and the head moves back.
    try b.store.truncate(main_id, .{ .epoch = 1, .seq = 1 });
    try b.refold();
    try std.testing.expectEqual(
        @as(?slot.Position, .{ .epoch = 1, .seq = 1 }),
        b.head(main_id),
    );
    try std.testing.expect(b.journals.get(main_id).?.fold.entries.get(.{
        .author = a.member_id,
        .author_seq = 2,
    }) == null);
}

test "replay_forward leaves queued entries for the leader instead of local re-slot" {
    var env = TestEnv.init();
    defer env.deinit();
    test_now = 1_700_000_000_000;
    {
        const data_dir = try env.dataDir();
        try init(test_alloc, tio, data_dir, &.{}, "main", &fakeClock);
    }

    // A follower's durable forward step: queue a signed entry without
    // slotting it (the leader has not answered yet).
    var main_id: [16]u8 = undefined;
    const queued_id = blk: {
        var node = try openNode(&env);
        defer node.deinit();
        main_id = node.journalIdByName("main").?;
        var en = entry.Entry{
            .kind = .data,
            .journal = main_id,
            .author = node.member_id,
            .author_seq = 1,
            .author_ts_ms = @intCast(test_now),
            .ttl_ms = 0,
            .payload_hash = entry.payloadHash("forwarded"),
            .payload_len = 9,
            .payload_omitted = false,
            .signature = undefined,
            .payload = "forwarded",
        };
        en.signature = (try entry.sign(node.keypair, &en)).toBytes();
        try node.queue.append(&en);
        break :blk en.id();
    };

    // Reopen with replay_forward: the entry stays queued (the loop will
    // re-forward it), the data chain is untouched.
    {
        var node = try Node.open(test_alloc, tio, try env.dataDir(), .{
            .now = &fakeClock,
            .replay_forward = true,
        });
        defer node.deinit();
        try std.testing.expectEqual(@as(?slot.Position, null), node.head(main_id));
        var queued: usize = 0;
        try node.queue.scan(&queued, struct {
            fn cb(c: *usize, en: *const entry.Entry) anyerror!void {
                try std.testing.expectEqualStrings("forwarded", en.payload);
                c.* += 1;
            }
        }.cb);
        try std.testing.expectEqual(@as(usize, 1), queued);
        _ = queued_id;
    }

    // Reopen with the tier-0 default: the queued entry is slotted locally.
    {
        var node = try openNode(&env);
        defer node.deinit();
        try std.testing.expectEqual(
            @as(?slot.Position, .{ .epoch = 1, .seq = 1 }),
            node.head(main_id),
        );
        var queued: usize = 0;
        try node.queue.scan(&queued, struct {
            fn cb(c: *usize, _: *const entry.Entry) anyerror!void {
                c.* += 1;
            }
        }.cb);
        try std.testing.expectEqual(@as(usize, 0), queued);
    }
}
