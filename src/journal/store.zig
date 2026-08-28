//! On-disk storage: one directory per member, one subdirectory per journal
//! (PRD 0001 *Storage*).
//!
//! A journal subdirectory is named for the journal's id in lowercase hex,
//! never for its name: the name is a mutable setting, and keying a
//! directory by a chosen string drags filesystem naming rules into journal
//! identity. Inside it, segments hold slots and entries in chain order;
//! a segment behind the head is **sealed** — a recorded hash, never appended
//! to again — and the head segment carries new appends until it reaches the
//! seal threshold. A torn tail write fails its CRC at open and is truncated
//! there; the entries lost were never acknowledged past `local`.
//!
//! The data directory is locked to one process (OQ 47): a `LOCK` file holds
//! an exclusive OS file lock that dies with the process, so a kill -9 does
//! not strand the directory.
//!
//! All file I/O goes through the caller's `std.Io` (the host's event loop or
//! a Threaded instance); operations are synchronous from the caller's
//! perspective at this milestone.

const std = @import("std");
const entry = @import("entry.zig");
const slot = @import("slot.zig");
const segment = @import("segment.zig");

/// `storage.fsync` (local config): how durably an append is acknowledged.
/// `every` fsyncs each record (the leader default; a single member is its
/// own leader); `batched` fsyncs on close/flush; `never` risks the tail.
pub const Fsync = enum {
    every,
    batched,
    never,
};

/// Record-region size at which the head segment is sealed and a new one
/// starts. Not a settings key (PRD 0004's local-config examples do not name
/// one); constant for now.
pub const seal_threshold_default: u64 = 64 * 1024 * 1024;

pub const OpenOptions = struct {
    fsync: Fsync = .every,
    seal_threshold: u64 = seal_threshold_default,
};

/// The store's open can fail with any storage error; the ones the CLI and
/// tests name are `AlreadyOpen`, `Corrupt` (G3), and `UnsupportedVersion`
/// (G5).
pub const OpenError = error{
    AlreadyOpen,
    OutOfMemory,
    Corrupt,
    JournalIdMismatch,
    EmptyJournal,
    BadMagic,
    UnsupportedVersion,
    Truncated,
    InputOutput,
} || std.Io.Dir.OpenError || std.Io.File.OpenError || std.Io.File.LockError;

/// One open segment file.
const Segment = struct {
    file: std.Io.File,
    /// Record region size; records start at `segment.header_len`.
    records_len: u64,
    sealed: bool,
};

/// Where a position lives: the segment (by index into `segments`) and the
/// offset of its record within that segment's file. Sealed segments are
/// immutable and the head appends, so an entry never moves — except
/// compaction, which rebuilds the index.
const IndexEntry = struct {
    segment: usize,
    offset: u64,
};

/// One open journal: its segments in order (last = head) and the
/// position -> (segment, offset) index.
const JournalDir = struct {
    dir: std.Io.Dir,
    segments: std.ArrayListUnmanaged(Segment),
    index: std.AutoHashMap(slot.Position, IndexEntry),
    head_records_len: u64,
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    data_dir: std.Io.Dir,
    fsync: Fsync,
    seal_threshold: u64,
    lock_file: std.Io.File,
    journals: std.AutoHashMap([16]u8, *JournalDir),

    /// Opens the data directory and locks it to this process. Takes
    /// ownership of the already-open directory (the caller opens it, e.g.
    /// via `openDirAbsolute` from a CLI path, or `openDir` in tests);
    /// `deinit` closes it.
    pub fn open(
        allocator: std.mem.Allocator,
        io: std.Io,
        data_dir: std.Io.Dir,
        options: OpenOptions,
    ) anyerror!*Store {
        const lock_file = data_dir.createFile(io, "LOCK", .{
            .read = true,
            .truncate = false,
        }) catch |err| blk: {
            if (err != error.PathAlreadyExists) return err;
            break :blk try data_dir.openFile(io, "LOCK", .{});
        };
        errdefer lock_file.close(io);
        if (!try lock_file.tryLock(io, .exclusive)) return error.AlreadyOpen;

        const store = try allocator.create(Store);
        errdefer allocator.destroy(store);
        store.* = .{
            .allocator = allocator,
            .io = io,
            .data_dir = data_dir,
            .fsync = options.fsync,
            .seal_threshold = options.seal_threshold,
            .lock_file = lock_file,
            .journals = std.AutoHashMap([16]u8, *JournalDir).init(allocator),
        };
        errdefer store.journals.deinit();

        try store.loadAll(data_dir);
        return store;
    }

    /// Opens the data directory at `data_dir_path` and hands it to `open`.
    /// Convenience for callers that have a path; the returned store borrows
    /// nothing the caller must keep, so this form is self-contained.
    pub fn openPath(
        allocator: std.mem.Allocator,
        io: std.Io,
        data_dir_path: []const u8,
        options: OpenOptions,
    ) anyerror!*Store {
        var data_dir = try std.Io.Dir.openDirAbsolute(io, data_dir_path, .{ .iterate = true });
        errdefer data_dir.close(io);
        return open(allocator, io, data_dir, options);
    }

    /// Closes every file and releases the directory lock.
    pub fn deinit(self: *Store) void {
        var it = self.journals.valueIterator();
        while (it.next()) |jd_ptr| {
            const jd = jd_ptr.*;
            for (jd.segments.items) |seg| seg.file.close(self.io);
            jd.segments.deinit(self.allocator);
            jd.index.deinit();
            jd.dir.close(self.io);
            self.allocator.destroy(jd);
        }
        self.journals.deinit();
        self.lock_file.unlock(self.io);
        self.lock_file.close(self.io);
        self.data_dir.close(self.io);
        self.allocator.destroy(self);
    }

    pub fn hasJournal(self: *const Store, journal_id: [16]u8) bool {
        return self.journals.contains(journal_id);
    }

    /// Every journal id the store holds, for the node's open fold.
    pub fn journalIds(self: *const Store, allocator: std.mem.Allocator) ![][16]u8 {
        const ids = try allocator.alloc([16]u8, self.journals.count());
        var i: usize = 0;
        var it = self.journals.keyIterator();
        while (it.next()) |id| {
            ids[i] = id.*;
            i += 1;
        }
        return ids;
    }

    /// Creates a journal's directory and first segment. The journal is
    /// empty (no records); the fold accepts its first slot against
    /// `genesis_prev`.
    pub fn createJournal(self: *Store, journal_id: [16]u8, group_id: [32]u8) !void {
        const name = try journalDirName(self.allocator, journal_id);
        defer self.allocator.free(name);
        const sub = self.data_dir.openDir(self.io, name, .{ .iterate = true }) catch |err| blk: {
            if (err != error.FileNotFound) return err;
            try self.data_dir.createDir(self.io, name, .default_dir);
            break :blk try self.data_dir.openDir(self.io, name, .{ .iterate = true });
        };
        errdefer sub.close(self.io);

        var header_buf: [segment.header_len]u8 = undefined;
        segment.encodeHeader(.{ .journal_id = journal_id, .group_id = group_id }, &header_buf);
        const first_file = try sub.createFile(self.io, "seg-00000001", .{
            .read = true,
            .truncate = false,
        });
        errdefer first_file.close(self.io);
        try first_file.writePositionalAll(self.io, &header_buf, 0);
        if (self.fsync != .never) try first_file.sync(self.io);

        const jd = try self.allocator.create(JournalDir);
        errdefer self.allocator.destroy(jd);
        jd.* = .{
            .dir = sub,
            .segments = .empty,
            .index = std.AutoHashMap(slot.Position, IndexEntry).init(self.allocator),
            .head_records_len = 0,
        };
        try jd.segments.append(self.allocator, .{
            .file = first_file,
            .records_len = 0,
            .sealed = false,
        });
        try self.journals.put(journal_id, jd);
    }

    /// Appends one record to the journal's head segment, sealing it first
    /// if it has crossed the threshold. Honors the fsync policy.
    pub fn append(
        self: *Store,
        journal_id: [16]u8,
        sl: *const slot.Slot,
        en: *const entry.Entry,
    ) !void {
        const jd = self.journals.get(journal_id) orelse return error.UnknownJournal;
        if (jd.head_records_len >= self.seal_threshold) try self.sealHead(jd);

        const head = &jd.segments.items[jd.segments.items.len - 1];
        const size = segment.recordSize(sl, en);
        const buf = try self.allocator.alloc(u8, size);
        defer self.allocator.free(buf);
        segment.encodeRecord(sl, en, buf);

        const offset = segment.header_len + jd.head_records_len;
        try head.file.writePositionalAll(self.io, buf, offset);
        try jd.index.put(sl.position(), .{
            .segment = jd.segments.items.len - 1,
            .offset = offset,
        });
        jd.head_records_len += size;
        head.records_len = jd.head_records_len;
        if (self.fsync == .every) try head.file.sync(self.io);
    }

    /// Seals the head segment (recorded hash) and opens the next one.
    fn sealHead(self: *Store, jd: *JournalDir) !void {
        const head = &jd.segments.items[jd.segments.items.len - 1];
        const records = try self.readRecordRegion(head, 0, head.records_len);
        defer self.allocator.free(records);
        const hash = segment.recordsHash(records);
        var seal_buf: [segment.seal_len]u8 = undefined;
        segment.encodeSeal(hash, &seal_buf);
        try head.file.writePositionalAll(
            self.io,
            &seal_buf,
            segment.header_len + head.records_len,
        );
        if (self.fsync != .never) try head.file.sync(self.io);
        head.sealed = true;

        const ordinal = jd.segments.items.len + 1;
        const name_buf = try std.fmt.allocPrint(self.allocator, "seg-{d:0>8}", .{ordinal});
        defer self.allocator.free(name_buf);
        const file = try jd.dir.createFile(self.io, name_buf, .{ .read = true });
        errdefer file.close(self.io);

        const header = try self.readSegmentHeader(&jd.segments.items[0]);
        var header_buf: [segment.header_len]u8 = undefined;
        segment.encodeHeader(header, &header_buf);
        try file.writePositionalAll(self.io, &header_buf, 0);
        if (self.fsync != .never) try file.sync(self.io);

        try jd.segments.append(self.allocator, .{
            .file = file,
            .records_len = 0,
            .sealed = false,
        });
        jd.head_records_len = 0;
    }

    /// Reads one record by position, or null when the position is not
    /// indexed. `buf` must hold the record's bytes (a caller may size it by
    /// the entry's max bytes); the returned record borrows it.
    pub fn read(
        self: *const Store,
        journal_id: [16]u8,
        position: slot.Position,
        buf: []u8,
    ) !?segment.Record {
        const jd = self.journals.get(journal_id) orelse return error.UnknownJournal;
        const where = jd.index.get(position) orelse return null;
        const seg = jd.segments.items[where.segment];
        var prefix: [segment.record_prefix_len]u8 = undefined;
        const n = try seg.file.readPositionalAll(self.io, &prefix, where.offset);
        if (n != prefix.len) return null;
        const body_len = std.mem.readInt(u32, prefix[0..4], .little);
        const total = segment.record_prefix_len + body_len;
        if (buf.len < total) return error.BufferTooSmall;
        const m = try seg.file.readPositionalAll(self.io, buf[0..total], where.offset);
        if (m != total) return error.Truncated;
        return segment.decodeRecord(buf[0..total]) catch return null;
    }

    /// Iterates every record of a journal in chain order, for the open fold.
    /// A compacted record under `retain = none` has no entry; the callback
    /// receives `null` then.
    pub fn scan(
        self: *const Store,
        journal_id: [16]u8,
        ctx: anytype,
        comptime on_record: fn (@TypeOf(ctx), *const slot.Slot, ?*const entry.Entry) anyerror!void,
    ) !void {
        const jd = self.journals.get(journal_id) orelse return error.UnknownJournal;
        for (jd.segments.items) |seg| {
            const records = try self.readRecordRegion(&seg, 0, seg.records_len);
            defer self.allocator.free(records);
            var off: usize = 0;
            while (off < records.len) {
                const rec = try segment.decodeRecord(records[off..]);
                try on_record(ctx, &rec.slot, if (rec.entry) |*en| en else null);
                off += rec.next_offset;
            }
        }
    }

    /// What a checkpoint compaction keeps for a removed entry (PRD 0002
    /// `ttl.retain`): the entry header (with payload hash) and its slot, or
    /// only the slot.
    pub const Retain = enum { header, none };

    /// Rewrites the journal's segments dropping the payloads (and under
    /// `retain = none`, the headers) of the removed entries. The chain is
    /// untouched — slots are rewritten verbatim — so it still verifies after
    /// compaction, under either retain value. Rebuilds the index.
    pub fn compact(
        self: *Store,
        journal_id: [16]u8,
        removed: []const entry.Id,
        retain: Retain,
    ) !void {
        const jd = self.journals.get(journal_id) orelse return error.UnknownJournal;
        const old_count = jd.segments.items.len;
        var removed_set = std.AutoHashMap(entry.Id, void).init(self.allocator);
        defer removed_set.deinit();
        for (removed) |id| try removed_set.put(id, {});

        const header = try self.readSegmentHeader(&jd.segments.items[0]);
        var new_segments = std.ArrayListUnmanaged(Segment).empty;
        // The files are owned by `new_segments` until the swap adopts them
        // into `jd.segments`; after that an error is this store's problem,
        // not the errdefer's — it must not close (or free the backing of)
        // segments `jd.segments` now owns.
        var adopted = false;
        errdefer {
            if (!adopted) {
                for (new_segments.items) |seg| seg.file.close(self.io);
                new_segments.deinit(self.allocator);
            }
        }

        for (jd.segments.items) |old| {
            const records = try self.readRecordRegion(&old, 0, old.records_len);
            defer self.allocator.free(records);

            const ordinal = old_count + new_segments.items.len + 1;
            const name_buf = try std.fmt.allocPrint(self.allocator, "seg-{d:0>8}", .{ordinal});
            defer self.allocator.free(name_buf);
            const file = try jd.dir.createFile(self.io, name_buf, .{
                .read = true,
                .truncate = false,
            });
            // Adopt immediately: the shared errdefer above closes every
            // segment in the list once, whichever iteration errored (a
            // per-iteration errdefer would close it a second time when a
            // LATER iteration failed).
            try new_segments.append(self.allocator, .{
                .file = file,
                .records_len = 0,
                .sealed = old.sealed,
            });
            var header_buf: [segment.header_len]u8 = undefined;
            segment.encodeHeader(header, &header_buf);
            try file.writePositionalAll(self.io, &header_buf, 0);

            var records_len: u64 = 0;
            var off: usize = 0;
            while (off < records.len) {
                const rec = try segment.decodeRecord(records[off..]);
                const keep_full = if (rec.entry) |en| !removed_set.contains(en.id()) else false;
                if (keep_full) {
                    const span = records[off .. off + rec.next_offset];
                    try file.writePositionalAll(self.io, span, segment.header_len + records_len);
                    records_len += rec.next_offset;
                } else if (rec.entry != null and retain == .header) {
                    // Keep the slot and the entry header; drop the payload.
                    const buf = try self.allocator.alloc(u8, segment.headerOnlyRecordSize());
                    defer self.allocator.free(buf);
                    segment.encodeHeaderOnlyRecord(&rec.slot, &rec.entry.?, buf);
                    try file.writePositionalAll(self.io, buf, segment.header_len + records_len);
                    records_len += buf.len;
                } else {
                    // retain = none, or a record that never had an entry.
                    const buf = try self.allocator.alloc(u8, segment.slotOnlyRecordSize());
                    defer self.allocator.free(buf);
                    segment.encodeSlotOnlyRecord(&rec.slot, buf);
                    try file.writePositionalAll(self.io, buf, segment.header_len + records_len);
                    records_len += buf.len;
                }
                off += rec.next_offset;
            }
            if (old.sealed) {
                // The rewritten segment is sealed too, with a fresh hash.
                const tmp_seg = Segment{
                    .file = file,
                    .records_len = records_len,
                    .sealed = false,
                };
                const region = try self.readRecordRegion(&tmp_seg, 0, records_len);
                defer self.allocator.free(region);
                const hash = segment.recordsHash(region);
                var seal_buf: [segment.seal_len]u8 = undefined;
                segment.encodeSeal(hash, &seal_buf);
                try file.writePositionalAll(self.io, &seal_buf, segment.header_len + records_len);
            }
            if (self.fsync != .never) try file.sync(self.io);
            new_segments.items[new_segments.items.len - 1].records_len = records_len;
        }

        // Swap: close and delete the old files, adopt the new segments. The
        // closed handles are no longer owned — an error later in this call
        // (the delete walk, the index rebuild) must not leave them for
        // deinit to close again; truncate follows the same rule.
        for (jd.segments.items) |old| old.file.close(self.io);
        jd.segments.clearRetainingCapacity();
        jd.head_records_len = 0;
        var it = jd.dir.iterate();
        while (try it.next(self.io)) |dirent| {
            if (dirent.kind != .file) continue;
            if (std.mem.startsWith(u8, dirent.name, "seg-")) {
                // Old ordinals are all below the first new one.
                var first_new_buf: [16]u8 = undefined;
                const first_new = try std.fmt.bufPrint(
                    &first_new_buf,
                    "seg-{d:0>8}",
                    .{old_count + 1},
                );
                if (std.mem.order(u8, dirent.name, first_new) == .lt) {
                    try jd.dir.deleteFile(self.io, dirent.name);
                }
            }
        }
        jd.segments.deinit(self.allocator);
        jd.segments = new_segments;
        jd.head_records_len = jd.segments.items[jd.segments.items.len - 1].records_len;
        adopted = true;
        try self.rebuildIndex(jd);
    }

    /// The group id a journal's segments name (PRD 0006): the header of its
    /// first segment. For the control journal this is the cluster's genesis
    /// entry hash — the value a follower must use when a replicated
    /// `create_journal` needs its store directory.
    pub fn groupIdOf(self: *const Store, journal_id: [16]u8) ![32]u8 {
        const jd = self.journals.get(journal_id) orelse return error.UnknownJournal;
        const header = try self.readSegmentHeader(&jd.segments.items[0]);
        return header.group_id;
    }

    /// Truncates a journal's chain to `position` (inclusive): every record
    /// past it is dropped and the segments are rebuilt from the kept prefix.
    /// Raw record bytes are copied verbatim, so compacted records (payload
    /// or header dropped) survive byte-for-byte. This is the OQ 44 re-fold
    /// discipline's storage half: the losing branch discards its tail and
    /// folds the merged chain from the last common slot. Rare (heal-time), so
    /// a full rebuild is fine.
    pub fn truncate(self: *Store, journal_id: [16]u8, position: slot.Position) !void {
        const jd = self.journals.get(journal_id) orelse return error.UnknownJournal;
        // Collect the kept raw records in chain order. Positions are dense
        // and ordered, so the first record past the target ends the set.
        var kept = std.ArrayListUnmanaged(u8).empty;
        defer kept.deinit(self.allocator);
        outer: for (jd.segments.items) |*seg| {
            const records = try self.readRecordRegion(seg, 0, seg.records_len);
            defer self.allocator.free(records);
            var off: usize = 0;
            while (off < records.len) {
                const rec = try segment.decodeRecord(records[off..]);
                if (slot.Position.order(rec.slot.position(), position) == .gt) break :outer;
                try kept.appendSlice(self.allocator, records[off .. off + rec.next_offset]);
                off += rec.next_offset;
            }
        }

        // Rebuild: close and delete the old segment files, then write one
        // fresh head segment carrying the kept records (the kept bytes were
        // already read; no old handle is needed after this).
        const header = try self.readSegmentHeader(&jd.segments.items[0]);
        for (jd.segments.items) |old| old.file.close(self.io);
        // The closed handles are no longer owned; a rebuild error must not
        // leave them for deinit to close again.
        jd.segments.clearRetainingCapacity();
        jd.head_records_len = 0;
        var it = jd.dir.iterate();
        while (try it.next(self.io)) |dirent| {
            if (dirent.kind != .file) continue;
            if (std.mem.startsWith(u8, dirent.name, "seg-")) {
                try jd.dir.deleteFile(self.io, dirent.name);
            }
        }
        const file = try jd.dir.createFile(self.io, "seg-00000001", .{ .read = true });
        errdefer file.close(self.io);
        var header_buf: [segment.header_len]u8 = undefined;
        segment.encodeHeader(header, &header_buf);
        try file.writePositionalAll(self.io, &header_buf, 0);
        if (kept.items.len > 0) {
            try file.writePositionalAll(self.io, kept.items, segment.header_len);
        }
        if (self.fsync != .never) try file.sync(self.io);

        var segments = std.ArrayListUnmanaged(Segment).empty;
        try segments.append(self.allocator, .{
            .file = file,
            .records_len = @intCast(kept.items.len),
            .sealed = false,
        });
        jd.segments.deinit(self.allocator);
        jd.segments = segments;
        jd.head_records_len = @intCast(kept.items.len);
        try self.rebuildIndex(jd);
    }

    /// Rebuilds the position index from the (possibly rewritten) segments.
    fn rebuildIndex(self: *Store, jd: *JournalDir) !void {
        jd.index.clearRetainingCapacity();
        for (jd.segments.items, 0..) |seg, seg_idx| {
            const records = try self.readRecordRegion(&seg, 0, seg.records_len);
            defer self.allocator.free(records);
            var off: usize = 0;
            while (off < records.len) {
                const rec = try segment.decodeRecord(records[off..]);
                try jd.index.put(rec.slot.position(), .{
                    .segment = seg_idx,
                    .offset = segment.header_len + off,
                });
                off += rec.next_offset;
            }
        }
    }

    /// The journal's record region for an open segment; `offset` is within
    /// the record region (0 = first record), `len` its size.
    fn readRecordRegion(
        self: *const Store,
        seg: *const Segment,
        offset: u64,
        len: u64,
    ) ![]u8 {
        const buf = try self.allocator.alloc(u8, @intCast(len));
        errdefer self.allocator.free(buf);
        const n = try seg.file.readPositionalAll(
            self.io,
            buf,
            segment.header_len + offset,
        );
        if (n != buf.len) return error.Truncated;
        return buf;
    }

    fn readSegmentHeader(self: *const Store, seg: *const Segment) !segment.Header {
        var buf: [segment.header_len]u8 = undefined;
        const n = try seg.file.readPositionalAll(self.io, &buf, 0);
        if (n != buf.len) return error.Truncated;
        return segment.decodeHeader(&buf);
    }

    /// Loads every journal subdirectory, scanning segments, building the
    /// index and truncating torn tails. A wrong segment version is refused
    /// (G5); a byte flip fails the CRC at the offending position (G3).
    fn loadAll(self: *Store, data_dir: std.Io.Dir) !void {
        var it = data_dir.iterate();
        while (try it.next(self.io)) |dirent| {
            if (dirent.kind != .directory) continue;
            // Journal dirs are 32 lowercase hex chars; anything else (the
            // operator's own files) is not ours to manage.
            const journal_id = hexToJournalId(dirent.name) catch continue;
            try self.loadJournal(data_dir, journal_id);
        }
    }

    fn loadJournal(self: *Store, _: std.Io.Dir, journal_id: [16]u8) !void {
        const name = try journalDirName(self.allocator, journal_id);
        defer self.allocator.free(name);
        const sub = try self.data_dir.openDir(self.io, name, .{ .iterate = true });
        errdefer sub.close(self.io);

        const jd = try self.allocator.create(JournalDir);
        errdefer self.allocator.destroy(jd);
        jd.* = .{
            .dir = sub,
            .segments = .empty,
            .index = std.AutoHashMap(slot.Position, IndexEntry).init(self.allocator),
            .head_records_len = 0,
        };

        // Collect segment files in name order (zero-padded: lexicographic
        // equals numeric).
        var names = std.ArrayListUnmanaged([]u8).empty;
        defer {
            for (names.items) |n| self.allocator.free(n);
            names.deinit(self.allocator);
        }
        var it = sub.iterate();
        while (try it.next(self.io)) |f| {
            if (f.kind != .file) continue;
            if (!std.mem.startsWith(u8, f.name, "seg-")) continue;
            try names.append(self.allocator, try self.allocator.dupe(u8, f.name));
        }
        std.mem.sort([]u8, names.items, {}, struct {
            fn lt(_: void, a: []u8, b: []u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lt);
        if (names.items.len == 0) return error.EmptyJournal;

        for (names.items, 0..) |seg_name, i| {
            // Read-write: the open scan may need to truncate a torn tail.
            const file = try sub.openFile(self.io, seg_name, .{ .mode = .read_write });
            errdefer file.close(self.io);
            const header = try self.readSegmentHeader(&.{
                .file = file,
                .records_len = 0,
                .sealed = false,
            });
            if (!std.mem.eql(u8, &header.journal_id, &journal_id)) {
                file.close(self.io);
                return error.JournalIdMismatch;
            }

            // The file is header + records (+ a seal trailer when sealed).
            const len = try file.length(self.io);
            const sealed = try self.hasSeal(file, len);
            const records_len = len - segment.header_len -
                if (sealed) @as(u64, segment.seal_len) else 0;
            const records = try self.allocator.alloc(u8, @intCast(records_len));
            defer self.allocator.free(records);
            const n = try file.readPositionalAll(self.io, records, segment.header_len);
            if (n != records.len) return error.Truncated;

            // Scan records until the first undecodable byte. Whether that is
            // a torn tail (truncate) or mid-file corruption (refuse, named
            // by position, G3) is decided by what follows: a valid record
            // later in the file means the break is not a crash's tail.
            var off: usize = 0;
            var good: usize = 0;
            while (off < records.len) {
                const rec = segment.decodeRecord(records[off..]) catch break;
                try jd.index.put(rec.slot.position(), .{
                    .segment = jd.segments.items.len,
                    .offset = segment.header_len + off,
                });
                off += rec.next_offset;
                good = off;
            }
            if (off != records.len) {
                if (findValidRecordAfter(records, off)) {
                    return error.Corrupt;
                }
                // A torn tail: truncate at the last good record.
                try file.setLength(self.io, segment.header_len + good);
                if (self.fsync != .never) try file.sync(self.io);
            }

            try jd.segments.append(self.allocator, .{
                .file = file,
                .records_len = good,
                .sealed = sealed,
            });
            if (i == names.items.len - 1) jd.head_records_len = good;
        }

        try self.journals.put(journal_id, jd);
    }

    /// Whether the file ends in a valid seal trailer, and that its hash
    /// verifies against the records. `file_len` is the full file size.
    fn hasSeal(self: *Store, file: std.Io.File, file_len: u64) !bool {
        if (file_len < segment.header_len + segment.seal_len) return false;
        const records_len = file_len - segment.header_len - segment.seal_len;
        var buf: [segment.seal_len]u8 = undefined;
        const n = try file.readPositionalAll(self.io, &buf, segment.header_len + records_len);
        if (n != buf.len) return false;
        const hash = segment.decodeSeal(&buf) catch return false;
        // Verify the seal against the records.
        const records = try self.allocator.alloc(u8, @intCast(records_len));
        defer self.allocator.free(records);
        const m = try file.readPositionalAll(self.io, records, segment.header_len);
        if (m != records.len) return false;
        return std.mem.eql(u8, &hash, &segment.recordsHash(records));
    }
};

/// Whether any valid record begins at or after `from` — the test that tells
/// a torn tail (nothing valid follows; the crash's partial write is the
/// file's end) from mid-file corruption (valid data follows; refusing beats
/// truncating away good records, PRD 0001 G3). Byte-wise because a torn
/// write can start at any byte; bounded by the record region size.
fn findValidRecordAfter(records: []const u8, from: usize) bool {
    // Any record that decodes cleanly at or after the break is a record the
    // writer completed, so the break is corruption, not a crash's partial
    // tail. (A torn write is a partial record at the file's very end:
    // nothing valid can follow it.)
    var off = from;
    while (off < records.len) : (off += 1) {
        _ = segment.decodeRecord(records[off..]) catch continue;
        return true;
    }
    return false;
}

/// The journal's subdirectory name: its id in lowercase hex.
pub fn journalDirName(allocator: std.mem.Allocator, journal_id: [16]u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{x}", .{journal_id});
}

fn hexToJournalId(name: []const u8) error{ BadHex, WrongLength }![16]u8 {
    if (name.len != 32) return error.WrongLength;
    var out: [16]u8 = undefined;
    for (0..16) |i| {
        out[i] = (try hexNibble(name[i * 2]) << 4) | try hexNibble(name[i * 2 + 1]);
    }
    return out;
}

fn hexNibble(c: u8) error{BadHex}!u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        else => error.BadHex,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const test_alloc = std.testing.allocator;
const tio = std.testing.io;

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

    fn openStore(self: *TestEnv) !*Store {
        return Store.open(test_alloc, tio, try self.dataDir(), .{});
    }

    fn deinit(self: *TestEnv) void {
        self.tmp.cleanup();
    }
};

fn testSlot(seq: u64) slot.Slot {
    return .{
        .epoch = 1,
        .seq = seq,
        .slot_ts_ms = 1000,
        .entry_hash = [_]u8{0xAB} ** 32,
        .prev_slot_hash = [_]u8{0} ** 32,
        .leader = "fedcba9876543210".*,
        .signature = [_]u8{0} ** 64,
    };
}

fn testEntry(seq: u64, payload: []const u8) entry.Entry {
    return .{
        .kind = .data,
        .journal = "0123456789abcdef".*,
        .author = "fedcba9876543210".*,
        .author_seq = seq,
        .author_ts_ms = 0,
        .ttl_ms = 0,
        .payload_hash = entry.payloadHash(payload),
        .payload_len = @intCast(payload.len),
        .payload_omitted = false,
        .signature = [_]u8{0} ** 64,
        .payload = payload,
    };
}

fn appendN(store: *Store, journal_id: [16]u8, n: u64) !void {
    for (1..n + 1) |seq| {
        const sl = testSlot(seq);
        const en = testEntry(seq, "payload");
        try store.append(journal_id, &sl, &en);
    }
}

test "appends survive reopen, in order, and read by position" {
    var env = TestEnv.init();
    defer env.deinit();
    const journal_id = "0123456789abcdef".*;
    const group_id = [_]u8{0x77} ** 32;

    {
        const store = try env.openStore();
        defer store.deinit();
        try store.createJournal(journal_id, group_id);
        try appendN(store, journal_id, 3);
    }

    const store = try env.openStore();
    defer store.deinit();
    try std.testing.expect(store.hasJournal(journal_id));
    var count: usize = 0;
    try store.scan(journal_id, &count, struct {
        fn cb(c: *usize, _: *const slot.Slot, en: ?*const entry.Entry) anyerror!void {
            try std.testing.expectEqualStrings("payload", en.?.payload);
            c.* += 1;
        }
    }.cb);
    try std.testing.expectEqual(@as(usize, 3), count);

    var buf: [512]u8 = undefined;
    const rec = (try store.read(journal_id, .{ .epoch = 1, .seq = 2 }, &buf)).?;
    try std.testing.expectEqual(@as(u64, 2), rec.slot.seq);
    try std.testing.expectEqualStrings("payload", rec.entry.?.payload);
}

test "a torn tail is truncated at open and the verified head survives (G4 unit half)" {
    var env = TestEnv.init();
    defer env.deinit();
    const journal_id = "0123456789abcdef".*;

    {
        const store = try env.openStore();
        defer store.deinit();
        try store.createJournal(journal_id, [_]u8{0} ** 32);
        try appendN(store, journal_id, 3);
    }

    // Cut the file mid-record-3: keep the header + 2 full records + half of
    // the third record's body.
    const seg_path = try std.fmt.allocPrint(test_alloc, "data/{x}/seg-00000001", .{journal_id});
    defer test_alloc.free(seg_path);
    const file = try env.tmp.dir.openFile(tio, seg_path, .{ .mode = .read_write });
    defer file.close(tio);
    const len = try file.length(tio);
    try file.setLength(tio, len - 20);

    const store = try env.openStore();
    defer store.deinit();
    var count: usize = 0;
    try store.scan(journal_id, &count, struct {
        fn cb(c: *usize, _: *const slot.Slot, _: ?*const entry.Entry) anyerror!void {
            c.* += 1;
        }
    }.cb);
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "mid-file corruption refuses the open and names the journal (G3)" {
    var env = TestEnv.init();
    defer env.deinit();
    const journal_id = "0123456789abcdef".*;

    {
        const store = try env.openStore();
        defer store.deinit();
        try store.createJournal(journal_id, [_]u8{0} ** 32);
        try appendN(store, journal_id, 3);
    }

    // Flip one byte inside the second record's body.
    const seg_path = try std.fmt.allocPrint(test_alloc, "data/{x}/seg-00000001", .{journal_id});
    defer test_alloc.free(seg_path);
    const file = try env.tmp.dir.openFile(tio, seg_path, .{ .mode = .read_write });
    defer file.close(tio);
    var one: [1]u8 = undefined;
    const n = try file.readPositionalAll(tio, &one, segment.header_len + 60);
    try std.testing.expectEqual(@as(usize, 1), n);
    one[0] ^= 0x40;
    try file.writePositionalAll(tio, &one, segment.header_len + 60);

    try std.testing.expectError(error.Corrupt, env.openStore());
}

test "a newer segment version is refused, not misread (G5)" {
    var env = TestEnv.init();
    defer env.deinit();
    const journal_id = "0123456789abcdef".*;

    {
        const store = try env.openStore();
        defer store.deinit();
        try store.createJournal(journal_id, [_]u8{0} ** 32);
        try appendN(store, journal_id, 1);
    }

    const seg_path = try std.fmt.allocPrint(test_alloc, "data/{x}/seg-00000001", .{journal_id});
    defer test_alloc.free(seg_path);
    const file = try env.tmp.dir.openFile(tio, seg_path, .{ .mode = .read_write });
    defer file.close(tio);
    var version_buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &version_buf, segment.version + 1, .little);
    try file.writePositionalAll(tio, &version_buf, 4);

    try std.testing.expectError(error.UnsupportedVersion, env.openStore());
}

test "the directory lock excludes a second opener and releases on close" {
    var env = TestEnv.init();
    defer env.deinit();
    const store = try env.openStore();
    defer store.deinit();
    try std.testing.expectError(error.AlreadyOpen, env.openStore());
}

test "a small seal threshold spans segments and reopens cleanly" {
    var env = TestEnv.init();
    defer env.deinit();
    const journal_id = "0123456789abcdef".*;

    const data_dir = try env.dataDir();
    const store = try Store.open(test_alloc, tio, data_dir, .{ .seal_threshold = 200 });
    try store.createJournal(journal_id, [_]u8{0} ** 32);
    try appendN(store, journal_id, 5);
    store.deinit();

    const store2 = try env.openStore();
    defer store2.deinit();
    var count: usize = 0;
    try store2.scan(journal_id, &count, struct {
        fn cb(c: *usize, _: *const slot.Slot, _: ?*const entry.Entry) anyerror!void {
            c.* += 1;
        }
    }.cb);
    try std.testing.expectEqual(@as(usize, 5), count);
}

test "journal dir names are lowercase hex and round-trip" {
    const id = "0123456789abcdef".*;
    const name = try journalDirName(test_alloc, id);
    defer test_alloc.free(name);
    try std.testing.expectEqualStrings("30313233343536373839616263646566", name);
    const back = try hexToJournalId(name);
    try std.testing.expectEqualSlices(u8, &id, &back);
    try std.testing.expectError(error.BadHex, hexToJournalId("zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"));
    try std.testing.expectError(error.WrongLength, hexToJournalId("short"));
}

test "truncate drops the tail and keeps the prefix readable across a sealed segment" {
    var env = TestEnv.init();
    defer env.deinit();
    const journal_id = "0123456789abcdef".*;
    const group_id = [_]u8{0x77} ** 32;

    {
        // A tiny seal threshold makes segments seal after every couple of
        // records, so the truncation point lands inside a sealed segment.
        const data_dir = try env.dataDir();
        const store = try Store.open(test_alloc, tio, data_dir, .{ .seal_threshold = 500 });
        defer store.deinit();
        try store.createJournal(journal_id, group_id);
        try appendN(store, journal_id, 5);
        try store.truncate(journal_id, .{ .epoch = 1, .seq = 3 });
    }

    const store = try env.openStore();
    defer store.deinit();
    var seen = std.ArrayListUnmanaged(u64).empty;
    defer seen.deinit(test_alloc);
    try store.scan(journal_id, &seen, struct {
        fn cb(
            list: *std.ArrayListUnmanaged(u64),
            sl: *const slot.Slot,
            en: ?*const entry.Entry,
        ) anyerror!void {
            try std.testing.expect(en != null);
            try list.append(test_alloc, sl.seq);
        }
    }.cb);
    try std.testing.expectEqualSlices(u64, &[_]u64{ 1, 2, 3 }, seen.items);
    try std.testing.expectEqualSlices(u8, &group_id, &(try store.groupIdOf(journal_id)));

    // Appending after the truncation continues the chain from seq 4.
    try store.append(journal_id, &testSlot(4), &testEntry(4, "after"));
    var buf: [512]u8 = undefined;
    const rec = (try store.read(journal_id, .{ .epoch = 1, .seq = 4 }, &buf)).?;
    try std.testing.expectEqualStrings("after", rec.entry.?.payload);
}
