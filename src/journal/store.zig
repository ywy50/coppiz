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

/// Owner-only mode for the store's data files (segments, and the queue and
/// pending-admission records the node writes beside them). `default_file`
/// is 0o666 masked by umask, which would leave the journal's contents
/// group- and world-readable — the same exposure `member.key` opts out of.
pub const data_file_perm: std.Io.File.Permissions = .fromMode(0o600);

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

/// One open journal: its segments in order (last = head), the
/// position -> (segment, offset) index, and the next unused segment
/// ordinal. Ordinals are monotone — a new segment always gets a number
/// no previous file used — because compaction rewrites segments to fresh
/// names and the count-based scheme (`len + 1`) collided with those names
/// (bug 2026-08-28-segment-ordinal-collision-after-compact).
const JournalDir = struct {
    dir: std.Io.Dir,
    segments: std.ArrayListUnmanaged(Segment),
    index: std.AutoHashMap(slot.Position, IndexEntry),
    head_records_len: u64,
    next_ordinal: u64,
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
        errdefer store.destroyJournals();

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
    /// Releases every loaded journal - segment descriptors, index, the
    /// directory handle and the struct - and the map itself. Shared with
    /// `open`'s error path, which would otherwise free the map's table and
    /// leak every journal already loaded when a later one refuses.
    fn destroyJournals(self: *Store) void {
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
    }

    pub fn deinit(self: *Store) void {
        self.destroyJournals();
        self.lock_file.unlock(self.io);
        self.lock_file.close(self.io);
        self.data_dir.close(self.io);
        self.allocator.destroy(self);
    }

    pub fn hasJournal(self: *const Store, journal_id: [16]u8) bool {
        return self.journals.contains(journal_id);
    }

    /// How many journals the directory already holds. `init` uses it to tell
    /// a fresh data directory from one that has already been bootstrapped.
    pub fn journalCount(self: *const Store) usize {
        return self.journals.count();
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
            .permissions = data_file_perm,
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
            .next_ordinal = 2,
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

    /// Appends a pre-encoded record (len | crc | slot | entry) verbatim:
    /// the bytes a peer sent over the wire are already the store's on-disk
    /// format, so replicating them skips a re-encode and its CRC per slot.
    /// `position` must be the record's own slot position — the index keys on
    /// it. The record's length prefix must agree with the slice length.
    pub fn appendRecord(
        self: *Store,
        journal_id: [16]u8,
        position: slot.Position,
        record: []const u8,
    ) !void {
        const jd = self.journals.get(journal_id) orelse return error.UnknownJournal;
        if (record.len < segment.record_prefix_len) return error.BadRecord;
        // usize arithmetic: `record_prefix_len` is a comptime_int, so a bare
        // sum computes in u32 and a length prefix near max u32 wraps past the
        // equality check (bug 2026-08-29-entry-decode-payload-len-overflow).
        const size = @as(usize, std.mem.readInt(u32, record[0..4], .little)) +
            segment.record_prefix_len;
        if (size != record.len) return error.BadRecord;
        if (jd.head_records_len >= self.seal_threshold) try self.sealHead(jd);

        const head = &jd.segments.items[jd.segments.items.len - 1];
        const offset = segment.header_len + jd.head_records_len;
        try head.file.writePositionalAll(self.io, record, offset);
        try jd.index.put(position, .{
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

        // A fresh ordinal, never a number an existing file already uses:
        // compaction renames segments to high ordinals, so the segment
        // count no longer bounds the names (bug
        // 2026-08-28-segment-ordinal-collision-after-compact). The ordinal
        // is consumed even if the create fails below — skipping a number is
        // harmless, reusing one is data loss.
        const ordinal = jd.next_ordinal;
        jd.next_ordinal += 1;
        const name_buf = try std.fmt.allocPrint(self.allocator, "seg-{d:0>8}", .{ordinal});
        defer self.allocator.free(name_buf);
        const file = try jd.dir.createFile(self.io, name_buf, .{
            .read = true,
            .permissions = data_file_perm,
        });
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
        if (n != prefix.len) return error.Truncated;
        const body_len = std.mem.readInt(u32, prefix[0..4], .little);
        const total = @as(usize, body_len) + segment.record_prefix_len;
        if (buf.len < total) return error.BufferTooSmall;
        const m = try seg.file.readPositionalAll(self.io, buf[0..total], where.offset);
        if (m != total) return error.Truncated;
        // The position is indexed, so the record was intact at open; a
        // record that no longer decodes is corruption, not absence.
        return segment.decodeRecord(buf[0..total]) catch return error.Corrupt;
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

    /// Iterates from `from` when it names an indexed record. A sync cursor
    /// always does after its first page, so later pages avoid rereading the
    /// journal prefix. An arbitrary non-indexed cursor retains `scan`'s
    /// full traversal semantics for callers that need to find the next slot.
    pub fn scanFrom(
        self: *const Store,
        journal_id: [16]u8,
        from: slot.Position,
        ctx: anytype,
        comptime on_record: fn (@TypeOf(ctx), *const slot.Slot, ?*const entry.Entry) anyerror!void,
    ) !void {
        const jd = self.journals.get(journal_id) orelse return error.UnknownJournal;
        const start = jd.index.get(from) orelse return self.scan(journal_id, ctx, on_record);
        for (jd.segments.items[start.segment..], start.segment..) |seg, seg_index| {
            const offset = if (seg_index == start.segment)
                start.offset - segment.header_len
            else
                0;
            const records = try self.readRecordRegion(&seg, offset, seg.records_len - offset);
            defer self.allocator.free(records);
            var off: usize = 0;
            while (off < records.len) {
                const rec = try segment.decodeRecord(records[off..]);
                try on_record(ctx, &rec.slot, if (rec.entry) |*en| en else null);
                off += rec.next_offset;
            }
        }
    }

    /// The kind of a journal's first record (null when the journal holds no
    /// records). The open fold's control-journal discovery needs only the
    /// first record — a genesis — to tell the control journal from data
    /// journals, and previously scanned the whole chain to find it.
    pub fn firstRecordKind(self: *const Store, journal_id: [16]u8) !?entry.Kind {
        const jd = self.journals.get(journal_id) orelse return error.UnknownJournal;
        const seg = &jd.segments.items[0];
        if (seg.records_len == 0) return null;
        var prefix: [segment.record_prefix_len]u8 = undefined;
        const n = try seg.file.readPositionalAll(self.io, &prefix, segment.header_len);
        if (n != prefix.len) return error.Truncated;
        const body_len = std.mem.readInt(u32, prefix[0..4], .little);
        const total = @as(usize, body_len) + segment.record_prefix_len;
        const buf = try self.allocator.alloc(u8, total);
        defer self.allocator.free(buf);
        const m = try seg.file.readPositionalAll(self.io, buf, segment.header_len);
        if (m != total) return error.Truncated;
        const rec = try segment.decodeRecord(buf);
        const e = rec.entry orelse return null; // a slot-only first record is not a genesis
        return e.kind;
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
        // Fresh names start at the next unused ordinal; every existing file
        // has a lower ordinal, so the createFile below can never truncate a
        // segment this store has open (bug
        // 2026-08-28-segment-ordinal-collision-after-compact).
        const first_new = jd.next_ordinal;
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

            const ordinal = first_new + new_segments.items.len;
            const name_buf = try std.fmt.allocPrint(self.allocator, "seg-{d:0>8}", .{ordinal});
            defer self.allocator.free(name_buf);
            // Truncate: a later compaction reuses these ordinals, and a
            // shorter rewrite over the old bytes would leave a stale tail
            // that the next open scans as records.
            const file = try jd.dir.createFile(self.io, name_buf, .{
                .read = true,
                .truncate = true,
                .permissions = data_file_perm,
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

        // Swap: adopt the new segments in memory first — the swap has no
        // failure points, so `jd.segments` can never be left empty (the
        // append panic, bug 2026-08-29-compact-not-crash-atomic) — then
        // delete the stale old files. A delete failure leaves the store in
        // the new state with stale files on disk; a crash in any window
        // leaves both generations, which the open-time run recovery resolves
        // (the new one has the higher ordinals). The closed old handles are
        // no longer owned — an error later in this call (the delete walk,
        // the index rebuild) must not leave them for deinit to close again;
        // truncate follows the same rule.
        for (jd.segments.items) |old| old.file.close(self.io);
        jd.segments.deinit(self.allocator);
        jd.segments = new_segments;
        jd.head_records_len = jd.segments.items[jd.segments.items.len - 1].records_len;
        jd.next_ordinal = first_new + old_count;
        adopted = true;
        var it = jd.dir.iterate();
        while (try it.next(self.io)) |dirent| {
            if (dirent.kind != .file) continue;
            if (std.mem.startsWith(u8, dirent.name, "seg-")) {
                // Every old file has an ordinal below the first new one
                // (ordinals are monotone); anything below it is stale.
                const ordinal = std.fmt.parseUnsigned(
                    u64,
                    dirent.name["seg-".len..],
                    10,
                ) catch continue;
                if (ordinal < first_new) {
                    try jd.dir.deleteFile(self.io, dirent.name);
                }
            }
        }
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

        // Rebuild: write the fresh head segment before touching anything, so
        // an error or a crash leaves either the old state or the new one —
        // never a half-deleted directory (bug
        // 2026-08-29-compact-not-crash-atomic). The fresh name is the next
        // monotone ordinal, which no existing file uses at runtime.
        const header = try self.readSegmentHeader(&jd.segments.items[0]);
        const fresh_ordinal = jd.next_ordinal;
        const fresh_name = try std.fmt.allocPrint(self.allocator, "seg-{d:0>8}", .{fresh_ordinal});
        defer self.allocator.free(fresh_name);
        const file = try jd.dir.createFile(self.io, fresh_name, .{
            .read = true,
            .permissions = data_file_perm,
        });
        // The fresh head file is adopted into jd.segments below; an errdefer
        // must not close it after adoption (Store.deinit closes it again —
        // bug 2026-08-28-sweep3-truncate-errdefer-double-close).
        var adopted = false;
        errdefer if (!adopted) file.close(self.io);
        var header_buf: [segment.header_len]u8 = undefined;
        segment.encodeHeader(header, &header_buf);
        try file.writePositionalAll(self.io, &header_buf, 0);
        if (kept.items.len > 0) {
            try file.writePositionalAll(self.io, kept.items, segment.header_len);
        }
        if (self.fsync != .never) try file.sync(self.io);

        // The in-memory swap has no failure points (bug
        // 2026-08-29-compact-not-crash-atomic).
        for (jd.segments.items) |old| old.file.close(self.io);
        var segments = std.ArrayListUnmanaged(Segment).empty;
        try segments.append(self.allocator, .{
            .file = file,
            .records_len = @intCast(kept.items.len),
            .sealed = false,
        });
        jd.segments.deinit(self.allocator);
        jd.segments = segments;
        jd.head_records_len = @intCast(kept.items.len);
        jd.next_ordinal = fresh_ordinal + 1;
        adopted = true;

        // Delete the stale files — everything but the fresh one. A failure
        // here leaves stale files on disk; the open-time run recovery folds
        // the surviving generation after a crash in any window.
        var it = jd.dir.iterate();
        while (try it.next(self.io)) |dirent| {
            if (dirent.kind != .file) continue;
            if (std.mem.startsWith(u8, dirent.name, "seg-") and
                !std.mem.eql(u8, dirent.name, fresh_name))
            {
                try jd.dir.deleteFile(self.io, dirent.name);
            }
        }
        try self.rebuildIndex(jd);
    }

    /// Rebuilds the position index from the (possibly rewritten) segments.
    fn rebuildIndex(self: *Store, jd: *JournalDir) !void {
        // A fresh map per rebuild: `clearRetainingCapacity` keeps the
        // backing table across rebuilds, and OQ 62's captured spin showed a
        // put probing at O(capacity) on a rebuilt index — consistent with
        // the map's `available` accounting drifting across clear+refill
        // cycles. A new map starts with correct accounting however the
        // previous rebuild ended, at the cost of one map allocation per
        // compaction (negligible next to the segment rewrites). Same
        // contents, same lookups; the exact root cause of the observed spin
        // is still open (OQ 62), so this is defensive hardening, not a
        // claimed fix.
        jd.index.deinit();
        jd.index = std.AutoHashMap(slot.Position, IndexEntry).init(self.allocator);
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

    /// The byte length of one segment file, without adopting it.
    fn segmentFileLen(self: *Store, sub: std.Io.Dir, seg_name: []const u8) !u64 {
        const file = try sub.openFile(self.io, seg_name, .{ .mode = .read_only });
        defer file.close(self.io);
        return file.length(self.io);
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
            .next_ordinal = 0,
        };
        // Everything below fills `jd` in place, and several steps refuse:
        // a corrupt or truncated segment (G3/G5) is a supported outcome, not
        // an exotic one. Without this the index table, the segment list and
        // the descriptors of the segments already adopted are all lost. The
        // directory handle is not closed here - the `errdefer sub.close`
        // above owns it, and `jd.dir` is the same handle.
        errdefer {
            for (jd.segments.items) |seg| seg.file.close(self.io);
            jd.segments.deinit(self.allocator);
            jd.index.deinit();
        }

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
            // A crash between `createFile` and the header write — the
            // window every segment writer has (createJournal, sealHead,
            // compact, truncate) — leaves a file shorter than one header.
            // It carries no header and no records, so there is nothing to
            // load and nothing to lose: drop it, and let the ordinal be
            // reused. Loading it instead refuses the open with `Truncated`
            // for a file that provably holds no data.
            if (try self.segmentFileLen(sub, f.name) < segment.header_len) {
                sub.deleteFile(self.io, f.name) catch {};
                continue;
            }
            try names.append(self.allocator, try self.allocator.dupe(u8, f.name));
        }
        std.mem.sort([]u8, names.items, {}, struct {
            fn lt(_: void, a: []u8, b: []u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lt);
        if (names.items.len == 0) return error.EmptyJournal;

        // A generation's first file always opens with the chain start (prev
        // = genesis_prev), so a later file whose first record starts the
        // chain means a crashed compaction left an older generation on disk
        // ahead of the newer one — compact writes the new generation at the
        // next monotone ordinals, contiguous with the old, so the two are
        // indistinguishable by name alone (bug
        // 2026-08-29-compact-not-crash-atomic). Keep the newest generation
        // that is *complete* and delete the stale files before it; the
        // common single-generation case never pays for the recovery.
        //
        // Completeness is the crash window's discriminator: compact writes
        // one new segment per old one and fsyncs each before the next, so a
        // new generation is complete only when its file count matches the
        // previous generation's and its head segment is not torn. A crash
        // after the first new segment (which always starts the chain) used
        // to make the recovery keep that single segment and delete the
        // complete old generation — every acknowledged slot in the later
        // segments silently gone (bug
        // 2026-08-30-generation-recovery-partial-new).
        var winner_start: usize = 0;
        var winner_end: usize = names.items.len;
        {
            var starts = std.ArrayListUnmanaged(usize).empty;
            defer starts.deinit(self.allocator);
            for (names.items, 0..) |n, i| {
                if (i == 0 or try self.fileStartsChain(sub, n)) {
                    try starts.append(self.allocator, i);
                }
            }
            // When no newer generation is complete, the first generation
            // wins and the partial newer ones are deleted with the stale
            // files below.
            if (starts.items.len > 1) winner_end = starts.items[1];
            var w = starts.items.len;
            while (w > 1) {
                w -= 1;
                const start = starts.items[w];
                const end = if (w + 1 < starts.items.len) starts.items[w + 1] else names.items.len;
                if (end - start != start - starts.items[w - 1]) continue; // partial
                if (!try self.fileDecodesFully(sub, names.items[end - 1])) continue; // torn head
                winner_start = start;
                winner_end = end;
                break;
            }
        }
        // Everything outside the winner's generation is stale — both the
        // older generations and any newer one that failed the completeness
        // check (a partial new generation left in place would fold on top
        // of the winner and refuse the open).
        if (winner_start > 0 or winner_end < names.items.len) {
            for (names.items, 0..) |n, i| {
                if (i < winner_start or i >= winner_end) {
                    sub.deleteFile(self.io, n) catch {};
                }
            }
            for (names.items[0..winner_start]) |n| self.allocator.free(n);
            for (names.items[winner_end..]) |n| self.allocator.free(n);
            names.items = names.items[winner_start..winner_end];
        }

        for (names.items, 0..) |seg_name, i| {
            // Read-write: the open scan may need to truncate a torn tail.
            const file = try sub.openFile(self.io, seg_name, .{ .mode = .read_write });
            errdefer file.close(self.io);
            const header = try self.readSegmentHeader(&.{
                .file = file,
                .records_len = 0,
                .sealed = false,
            });
            // The errdefer above owns the close; closing here too would
            // close the same descriptor twice on the way out.
            if (!std.mem.eql(u8, &header.journal_id, &journal_id)) {
                return error.JournalIdMismatch;
            }

            // The file is header + records (+ a seal trailer when sealed).
            const len = try file.length(self.io);
            const seal = try self.sealStatus(file, len);
            if (seal == .corrupt) return error.Corrupt;
            const sealed = seal == .valid;
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

        // Fresh segment names start one past the highest loaded ordinal.

        const last_name = names.items[names.items.len - 1];
        jd.next_ordinal =
            (try std.fmt.parseUnsigned(u64, last_name["seg-".len..], 10)) + 1;

        try self.journals.put(journal_id, jd);
    }

    const SealStatus = enum { absent, valid, corrupt };

    /// Whether the file ends in a valid seal trailer, and that its hash
    /// verifies against the records. `file_len` is the full file size.
    /// `absent` means the file is too short for a trailer or its last bytes
    /// are not a seal (a torn record tail); `corrupt` means a seal trailer
    /// is present but its hash does not verify — the sealed (acknowledged)
    /// prefix is damaged, and treating the trailer as records would silently
    /// truncate it (bug 2026-08-28-sweep3-hasseal-conflation).
    fn sealStatus(self: *Store, file: std.Io.File, file_len: u64) !SealStatus {
        if (file_len < segment.header_len + segment.seal_len) return .absent;
        const records_len = file_len - segment.header_len - segment.seal_len;
        var buf: [segment.seal_len]u8 = undefined;
        const n = try file.readPositionalAll(self.io, &buf, segment.header_len + records_len);
        if (n != buf.len) return .absent;
        const hash = segment.decodeSeal(&buf) catch return .absent;
        // Verify the seal against the records.
        const records = try self.allocator.alloc(u8, @intCast(records_len));
        defer self.allocator.free(records);
        const m = try file.readPositionalAll(self.io, records, segment.header_len);
        if (m != records.len) return .absent;
        if (!std.mem.eql(u8, &hash, &segment.recordsHash(records))) {
            // A trailer that does not verify is only evidence of damage if
            // it is a trailer at all. A record ends with its entry's
            // payload, and payload bytes are author-chosen, so an unsealed
            // segment whose last entry ends in 38 bytes spelling `CPST |
            // version | 32` is byte-identical here to a sealed segment
            // whose seal was corrupted. Calling that damage refuses the
            // open forever - and, since replication writes the same record
            // bytes everywhere, on every member of the group.
            //
            // A genuine trailer is written *past* the last record, so the
            // records region excluding it decodes as a whole number of
            // records and the region including it does not. A payload tail
            // is the other way round: the whole region decodes exactly and
            // the region short of 38 bytes cuts the last record. That is
            // the discriminator.
            if (try self.recordsDecodeExactly(file, file_len - segment.header_len)) {
                return .absent;
            }
            return .corrupt;
        }
        return .valid;
    }

    /// Whether `len` bytes of records, read from just past the segment
    /// header, decode as a whole number of records. `decodeRecord` bounds
    /// every step against the slice it is given, so a walk that never
    /// refuses has consumed exactly `len`.
    fn recordsDecodeExactly(self: *Store, file: std.Io.File, len: u64) !bool {
        if (len == 0) return true;
        const records = try self.allocator.alloc(u8, @intCast(len));
        defer self.allocator.free(records);
        const n = try file.readPositionalAll(self.io, records, segment.header_len);
        if (n != records.len) return false;
        var off: usize = 0;
        while (off < records.len) {
            const rec = segment.decodeRecord(records[off..]) catch return false;
            off += rec.next_offset;
        }
        return true;
    }

    /// Whether the file's first record starts the chain (its prev hash is
    /// the genesis prev) — the signal the open-time generation recovery uses
    /// (see loadJournal). A torn or empty file is not a generation start.
    fn fileStartsChain(
        self: *Store,
        sub: std.Io.Dir,
        seg_name: []const u8,
    ) !bool {
        const file = try sub.openFile(self.io, seg_name, .{ .mode = .read_write });
        defer file.close(self.io);
        const len = try file.length(self.io);
        // Shorter than a header: no records, and `records_len` below would
        // underflow. loadJournal drops such a file before it gets here; the
        // guard keeps the function total for any other caller.
        if (len < segment.header_len) return false;
        const seal = try self.sealStatus(file, len);
        if (seal == .corrupt) return false;
        const sealed = seal == .valid;
        const records_len = len - segment.header_len -
            if (sealed) @as(u64, segment.seal_len) else 0;
        if (records_len == 0) return false;
        const records = try self.allocator.alloc(u8, @intCast(records_len));
        defer self.allocator.free(records);
        const n = try file.readPositionalAll(self.io, records, segment.header_len);
        if (n != records.len) return false;
        const rec = segment.decodeRecord(records) catch return false;
        return std.mem.eql(u8, &rec.slot.prev_slot_hash, &slot.genesis_prev);
    }

    /// Whether the segment file's records all decode — no torn tail — the
    /// completeness check for a candidate generation's head segment (bug
    /// 2026-08-30-generation-recovery-partial-new).
    fn fileDecodesFully(
        self: *Store,
        sub: std.Io.Dir,
        seg_name: []const u8,
    ) !bool {
        const file = try sub.openFile(self.io, seg_name, .{ .mode = .read_write });
        defer file.close(self.io);
        const len = try file.length(self.io);
        if (len < segment.header_len) return false;
        const seal = try self.sealStatus(file, len);
        if (seal == .corrupt) return false;
        const sealed = seal == .valid;
        const records_len = len - segment.header_len -
            if (sealed) @as(u64, segment.seal_len) else 0;
        if (records_len == 0) return true; // an empty head: nothing to lose
        return self.recordsDecodeExactly(file, records_len);
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

/// A synthetic slot chained from the previous one (only seq 1 starts the
/// chain), so the fixtures model a real journal — the open-time generation
/// recovery reads the first record's prev hash, and an all-zeros prev on
/// every slot would make every file look like a generation start.
fn testSlot(seq: u64) slot.Slot {
    return .{
        .epoch = 1,
        .seq = seq,
        .slot_ts_ms = 1000,
        .entry_hash = [_]u8{0xAB} ** 32,
        .prev_slot_hash = if (seq > 1) blk: {
            const prev = testSlot(seq - 1);
            break :blk slot.slotHash(&prev);
        } else slot.genesis_prev,
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

test "scanFrom starts at an indexed position" {
    var env = TestEnv.init();
    defer env.deinit();
    const journal_id = "0123456789abcdef".*;
    const store = try env.openStore();
    defer store.deinit();
    try store.createJournal(journal_id, [_]u8{0} ** 32);
    try appendN(store, journal_id, 3);

    var seen = std.ArrayListUnmanaged(u64).empty;
    defer seen.deinit(test_alloc);
    try store.scanFrom(journal_id, .{ .epoch = 1, .seq = 2 }, &seen, struct {
        fn cb(
            list: *std.ArrayListUnmanaged(u64),
            sl: *const slot.Slot,
            _: ?*const entry.Entry,
        ) !void {
            try list.append(test_alloc, sl.seq);
        }
    }.cb);
    try std.testing.expectEqualSlices(u64, &.{ 2, 3 }, seen.items);
}

test "an indexed record with a bad CRC is Corrupt, not missing" {
    var env = TestEnv.init();
    defer env.deinit();
    const journal_id = "0123456789abcdef".*;
    const store = try env.openStore();
    defer store.deinit();
    try store.createJournal(journal_id, [_]u8{0} ** 32);
    try appendN(store, journal_id, 3);

    const jd = store.journals.get(journal_id).?;
    const where = jd.index.get(.{ .epoch = 1, .seq = 2 }).?;
    const seg = jd.segments.items[where.segment];
    // Flip a body byte (past the len/crc prefix) through the same fd `read` uses.
    const flip_at = where.offset + segment.record_prefix_len + 4;
    var one: [1]u8 = undefined;
    const n = try seg.file.readPositionalAll(tio, &one, flip_at);
    try std.testing.expectEqual(@as(usize, 1), n);
    one[0] ^= 0x40;
    try seg.file.writePositionalAll(tio, &one, flip_at);

    var buf: [512]u8 = undefined;
    try std.testing.expectError(
        error.Corrupt,
        store.read(journal_id, .{ .epoch = 1, .seq = 2 }, &buf),
    );
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

test "a sealed segment whose seal hash does not verify refuses to open" {
    // Bug 2026-08-28-sweep3-hasseal-conflation: hasSeal reported false for
    // a present-but-invalid seal trailer, so the trailer was scanned as
    // records and the sealed (acknowledged) prefix was silently truncated.
    var env = TestEnv.init();
    defer env.deinit();
    const journal_id = "0123456789abcdef".*;

    {
        const data_dir = try env.dataDir();
        const store = try Store.open(test_alloc, tio, data_dir, .{ .seal_threshold = 200 });
        defer store.deinit();
        try store.createJournal(journal_id, [_]u8{0} ** 32);
        try appendN(store, journal_id, 3); // the first two appends seal segments
    }

    // Damage the first (sealed) segment's seal trailer hash: the records
    // are intact, but the seal no longer verifies — corruption, not a torn
    // tail, and the open must refuse rather than drop the prefix.
    const seg_path = try std.fmt.allocPrint(test_alloc, "data/{x}/seg-00000001", .{journal_id});
    defer test_alloc.free(seg_path);
    const file = try env.tmp.dir.openFile(tio, seg_path, .{ .mode = .read_write });
    defer file.close(tio);
    const len = try file.length(tio);
    var one: [1]u8 = undefined;
    _ = try file.readPositionalAll(tio, &one, len - 10);
    one[0] ^= 0x40;
    try file.writePositionalAll(tio, &one, len - 10);

    try std.testing.expectError(error.Corrupt, env.openStore());
}

test "an entry payload ending in seal-trailer bytes does not brick the open" {
    // Bug 2026-08-31-payload-tail-mimics-seal-trailer: sealStatus decided
    // "sealed" from the file's last 38 bytes alone, and a record ends with
    // its entry's payload. A payload whose tail spells `CPST | version |
    // 32 bytes` therefore read as a seal whose hash does not verify, which
    // the open reports as Corrupt - permanently, and on every member,
    // because replication writes the same record bytes everywhere.
    var env = TestEnv.init();
    defer env.deinit();
    const journal_id = "0123456789abcdef".*;

    var payload = [_]u8{0} ** 64;
    var seal_buf: [segment.seal_len]u8 = undefined;
    segment.encodeSeal([_]u8{0xCD} ** 32, &seal_buf);
    @memcpy(payload[payload.len - segment.seal_len ..], &seal_buf);

    {
        const store = try env.openStore();
        defer store.deinit();
        try store.createJournal(journal_id, [_]u8{0} ** 32);
        const sl = testSlot(1);
        const en = testEntry(1, &payload);
        try store.append(journal_id, &sl, &en);
    }

    const store = try env.openStore();
    defer store.deinit();
    const Seen = struct {
        count: usize = 0,
        payload_len: usize = 0,
    };
    var seen = Seen{};
    try store.scanFrom(journal_id, .{ .epoch = 1, .seq = 1 }, &seen, struct {
        fn cb(s: *Seen, _: *const slot.Slot, en: ?*const entry.Entry) anyerror!void {
            s.count += 1;
            if (en) |e| s.payload_len = e.payload.len;
        }
    }.cb);
    try std.testing.expectEqual(@as(usize, 1), seen.count);
    try std.testing.expectEqual(payload.len, seen.payload_len);
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

test "a refused open frees the journal state it had already built" {
    // The G3 refusal is a supported outcome, and loadJournal builds the
    // JournalDir in place before it can happen: the index table, the
    // segment list and the descriptors of the segments already adopted were
    // all lost on the way out, and Store.open's own errdefer freed the
    // journals map without its values, so an earlier journal was lost whole.
    // std.testing.allocator reports the leak.
    var env = TestEnv.init();
    defer env.deinit();
    const bad_id = "0123456789abcdef".*;
    const good_id = "fedcba9876543210".*;

    {
        const store = try env.openStore();
        defer store.deinit();
        try store.createJournal(bad_id, [_]u8{0} ** 32);
        try appendN(store, bad_id, 3);
        // A second, healthy journal: whichever the directory scan reaches
        // first, one of the two error paths carries it.
        try store.createJournal(good_id, [_]u8{0} ** 32);
        try appendN(store, good_id, 2);
    }

    // Flip a byte inside the *second* record, so the scan indexes the first
    // one before it breaks - the index map is allocated by then - and a
    // valid third record after the break makes it mid-file corruption
    // rather than a torn tail.
    const seg_path = try std.fmt.allocPrint(test_alloc, "data/{x}/seg-00000001", .{bad_id});
    defer test_alloc.free(seg_path);
    const record_len = segment.record_prefix_len + slot.encoded_len +
        entry.header_len + "payload".len;
    const at = segment.header_len + record_len + 60;
    {
        const file = try env.tmp.dir.openFile(tio, seg_path, .{ .mode = .read_write });
        defer file.close(tio);
        var one: [1]u8 = undefined;
        const n = try file.readPositionalAll(tio, &one, at);
        try std.testing.expectEqual(@as(usize, 1), n);
        one[0] ^= 0x40;
        try file.writePositionalAll(tio, &one, at);
    }

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
    try std.testing.expectError(error.AlreadyOpen, env.openStore());
    store.deinit();

    const reopened = try env.openStore();
    defer reopened.deinit();
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

test "compact then seal and a second compact never collide with segment names" {
    // Bug 2026-08-28-segment-ordinal-collision-after-compact: sealHead named
    // the next segment from the segment count, which after a compaction
    // equals the journal's own first segment file and truncated it; the
    // second compaction rewrote over the currently-open files.
    var env = TestEnv.init();
    defer env.deinit();
    const journal_id = "0123456789abcdef".*;
    const author = "fedcba9876543210".*;

    {
        const data_dir = try env.dataDir();
        const store = try Store.open(test_alloc, tio, data_dir, .{ .seal_threshold = 200 });
        defer store.deinit();
        try store.createJournal(journal_id, [_]u8{0} ** 32);
        try appendN(store, journal_id, 5);
        try store.compact(journal_id, &.{
            .{ .author = author, .author_seq = 3 },
        }, .none);
        // The append crosses the threshold and seals the head; before the
        // fix the fresh segment name re-created the journal's own first
        // segment file (truncating it) and the seal failed with Truncated.
        const sl6 = testSlot(6);
        const en6 = testEntry(6, "payload");
        try store.append(journal_id, &sl6, &en6);
        const sl7 = testSlot(7);
        const en7 = testEntry(7, "payload");
        try store.append(journal_id, &sl7, &en7);
        // A second compaction is the rewrite-over-live-files variant.
        try store.compact(journal_id, &.{
            .{ .author = author, .author_seq = 5 },
        }, .none);
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
            if (en != null) try list.append(test_alloc, sl.seq);
        }
    }.cb);
    try std.testing.expectEqualSlices(u64, &.{ 1, 2, 4, 6, 7 }, seen.items);
}

test "open recovers a crashed compaction: the newer generation wins, stale files are deleted" {
    // Bug 2026-08-29-compact-not-crash-atomic: a crash between writing the
    // compacted generation and deleting the old one leaves both on disk,
    // and loadJournal used to fold both copies of the same slots (refusing
    // the open). The generation recovery keeps the newer generation — the
    // later file whose first record starts the chain — and deletes the
    // stale files before it.
    var env = TestEnv.init();
    defer env.deinit();
    const journal_id = "0123456789abcdef".*;

    var snap_names: [8][64]u8 = undefined;
    // The formatted path, not the whole 64-byte buffer: `bufPrint` writes a
    // 50-character path and leaves the tail undefined, and passing the array
    // by pointer handed `createFile` those bytes as part of the name.
    var snap_paths: [8][]const u8 = undefined;
    var snap_bytes: [8][]u8 = undefined;
    var snap_count: usize = 0;
    defer for (snap_bytes[0..snap_count]) |b| test_alloc.free(b);
    {
        const data_dir = try env.dataDir();
        const store = try Store.open(test_alloc, tio, data_dir, .{ .seal_threshold = 200 });
        defer store.deinit();
        try store.createJournal(journal_id, [_]u8{0} ** 32);
        try appendN(store, journal_id, 5);
        // Snapshot the pre-compaction generation (ordinals 1..k).
        const jd = store.journals.get(journal_id).?;
        for (jd.segments.items, 0..) |seg, i| {
            const len = try seg.file.length(tio);
            const buf = try test_alloc.alloc(u8, @intCast(len));
            const n = try seg.file.readPositionalAll(tio, buf, 0);
            try std.testing.expectEqual(@as(usize, @intCast(len)), n);
            snap_bytes[i] = buf;
            snap_paths[i] = try std.fmt.bufPrint(
                &snap_names[i],
                "data/{x}/seg-{d:0>8}",
                .{ journal_id, i + 1 },
            );
            snap_count = i + 1;
        }
        // A live compaction rewrites the generation to the next monotone
        // ordinals and deletes the originals. The crash we simulate is the
        // moment between those two steps, so the old generation is written
        // back below.
        try store.compact(journal_id, &.{}, .none);
    }

    for (snap_bytes[0..snap_count], 0..) |bytes, i| {
        const file = try env.tmp.dir.createFile(tio, snap_paths[i], .{
            .read = true,
            .truncate = true,
            .permissions = data_file_perm,
        });
        defer file.close(tio);
        try file.writePositionalAll(tio, bytes, 0);
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
            if (en != null) try list.append(test_alloc, sl.seq);
        }
    }.cb);
    // Each record folded exactly once — not the double-fold that refused
    // the open before the recovery.
    try std.testing.expectEqualSlices(u64, &.{ 1, 2, 3, 4, 5 }, seen.items);
    // The stale old generation was deleted: the on-disk file count equals
    // the surviving generation's segment count.
    const jd = store.journals.get(journal_id).?;
    var file_count: usize = 0;
    var it = jd.dir.iterate();
    while (try it.next(tio)) |f| {
        if (f.kind != .file) continue;
        if (std.mem.startsWith(u8, f.name, "seg-")) file_count += 1;
    }
    try std.testing.expectEqual(jd.segments.items.len, file_count);
}

test "open drops a segment file left shorter than its header by a crashed create" {
    // A crash between createFile and the header write leaves a segment
    // file with fewer than segment.header_len bytes. fileStartsChain
    // computed `len - segment.header_len` before looking at the length, so
    // the open trapped on the unsigned underflow instead of recovering —
    // and even without the trap, loading the file refuses the open with
    // Truncated for a file that holds nothing.
    for ([_]usize{ 0, 20 }) |partial| {
        var env = TestEnv.init();
        defer env.deinit();
        const journal_id = "0123456789abcdef".*;

        var next_ordinal: u64 = undefined;
        {
            const data_dir = try env.dataDir();
            const store = try Store.open(test_alloc, tio, data_dir, .{ .seal_threshold = 200 });
            defer store.deinit();
            try store.createJournal(journal_id, [_]u8{0} ** 32);
            try appendN(store, journal_id, 5);
            next_ordinal = store.journals.get(journal_id).?.next_ordinal;
        }

        const path = try std.fmt.allocPrint(
            test_alloc,
            "data/{x}/seg-{d:0>8}",
            .{ journal_id, next_ordinal },
        );
        defer test_alloc.free(path);
        {
            const file = try env.tmp.dir.createFile(tio, path, .{
                .read = true,
                .truncate = true,
                .permissions = data_file_perm,
            });
            defer file.close(tio);
            // `partial` bytes of a header that never finished being written.
            var header_buf: [segment.header_len]u8 = undefined;
            segment.encodeHeader(
                .{ .journal_id = journal_id, .group_id = [_]u8{0} ** 32 },
                &header_buf,
            );
            if (partial > 0) try file.writePositionalAll(tio, header_buf[0..partial], 0);
        }

        const store = try env.openStore();
        defer store.deinit();
        var count: usize = 0;
        try store.scan(journal_id, &count, struct {
            fn cb(c: *usize, _: *const slot.Slot, _: ?*const entry.Entry) anyerror!void {
                c.* += 1;
            }
        }.cb);
        try std.testing.expectEqual(@as(usize, 5), count);
        // The unusable file is gone, so its ordinal is free again.
        try std.testing.expectError(
            error.FileNotFound,
            env.tmp.dir.openFile(tio, path, .{ .mode = .read_only }),
        );
    }
}

test "a segment header naming another journal refuses the open once" {
    // The mismatch branch closed the segment file by hand while the
    // errdefer that owns it was still live, so the descriptor was closed
    // twice on the way out - an EBADF the Io layer reports as a
    // non-recoverable OS bug (a panic in debug builds), instead of the
    // JournalIdMismatch the caller should see.
    var env = TestEnv.init();
    defer env.deinit();
    const journal_id = "0123456789abcdef".*;
    {
        const data_dir = try env.dataDir();
        const store = try Store.open(test_alloc, tio, data_dir, .{ .seal_threshold = 200 });
        defer store.deinit();
        try store.createJournal(journal_id, [_]u8{0} ** 32);
        try appendN(store, journal_id, 2);
    }

    // Rewrite the header's journal id (bytes 6..22) to a different one, as
    // a directory renamed by hand or a segment copied from another journal
    // would look.
    const path = try std.fmt.allocPrint(test_alloc, "data/{x}/seg-00000001", .{journal_id});
    defer test_alloc.free(path);
    {
        const file = try env.tmp.dir.openFile(tio, path, .{ .mode = .read_write });
        defer file.close(tio);
        try file.writePositionalAll(tio, "fedcba9876543210", 6);
    }

    try std.testing.expectError(error.JournalIdMismatch, env.openStore());
}

test "open keeps the older generation when the newer one is still being written" {
    // Bug 2026-08-29-compact-not-crash-atomic: a crash right after the new
    // generation's first file is created leaves an empty segment ahead of
    // the complete old one. It does not start the chain, so the recovery
    // keeps the old generation and the empty file folds as an empty head.
    var env = TestEnv.init();
    defer env.deinit();
    const journal_id = "0123456789abcdef".*;

    var next_ordinal: u64 = undefined;
    const group_id = [_]u8{0} ** 32;
    {
        const data_dir = try env.dataDir();
        const store = try Store.open(test_alloc, tio, data_dir, .{ .seal_threshold = 200 });
        defer store.deinit();
        try store.createJournal(journal_id, [_]u8{0} ** 32);
        try appendN(store, journal_id, 5);
        next_ordinal = store.journals.get(journal_id).?.next_ordinal;
    }

    const path = try std.fmt.allocPrint(
        test_alloc,
        "data/{x}/seg-{d:0>8}",
        .{ journal_id, next_ordinal },
    );
    defer test_alloc.free(path);
    const file = try env.tmp.dir.createFile(tio, path, .{
        .read = true,
        .truncate = true,
        .permissions = data_file_perm,
    });
    defer file.close(tio);
    var header_buf: [segment.header_len]u8 = undefined;
    segment.encodeHeader(.{ .journal_id = journal_id, .group_id = group_id }, &header_buf);
    try file.writePositionalAll(tio, &header_buf, 0);

    const store = try env.openStore();
    defer store.deinit();
    var count: usize = 0;
    try store.scan(journal_id, &count, struct {
        fn cb(c: *usize, _: *const slot.Slot, _: ?*const entry.Entry) anyerror!void {
            c.* += 1;
        }
    }.cb);
    try std.testing.expectEqual(@as(usize, 5), count);
}

test "open keeps the complete old generation when a crash left only the new one's first segment" {
    // Bug 2026-08-30-generation-recovery-partial-new: the recovery kept the
    // last file that started the chain, so a crash after the new
    // generation's first segment (which always starts the chain) was
    // written but before the rest made it delete the complete old
    // generation and keep a one-segment chain — every acknowledged slot in
    // the later segments silently gone. A new generation is kept only when
    // it is complete: same segment count as the old, untorn head.
    var env = TestEnv.init();
    defer env.deinit();
    const journal_id = "0123456789abcdef".*;

    var old_names: [8][]const u8 = undefined;
    var old_bytes: [8][]u8 = undefined;
    var old_count: usize = 0;
    var first_new_name: ?[]const u8 = null;
    var first_new_bytes: ?[]u8 = null;
    defer for (old_names[0..old_count]) |n| test_alloc.free(n);
    defer for (old_bytes[0..old_count]) |b| test_alloc.free(b);
    defer if (first_new_bytes) |b| test_alloc.free(b);
    defer if (first_new_name) |n| test_alloc.free(n);
    {
        const data_dir = try env.dataDir();
        const store = try Store.open(test_alloc, tio, data_dir, .{ .seal_threshold = 200 });
        defer store.deinit();
        try store.createJournal(journal_id, [_]u8{0} ** 32);
        try appendN(store, journal_id, 5);
        const jd = store.journals.get(journal_id).?;
        // Snapshot the old generation (ordinals 1..k).
        for (jd.segments.items, 0..) |seg, i| {
            const len = try seg.file.length(tio);
            const buf = try test_alloc.alloc(u8, @intCast(len));
            const n = try seg.file.readPositionalAll(tio, buf, 0);
            try std.testing.expectEqual(@as(usize, @intCast(len)), n);
            old_bytes[i] = buf;
            old_names[i] = try std.fmt.allocPrint(
                test_alloc,
                "data/{x}/seg-{d:0>8}",
                .{ journal_id, i + 1 },
            );
            old_count = i + 1;
        }
        // The compacted generation: snapshot only its first segment, which
        // is what a crash after the first write leaves behind.
        try store.compact(journal_id, &.{}, .none);
        const new_first = store.journals.get(journal_id).?.segments.items[0];
        const len = try new_first.file.length(tio);
        first_new_bytes = try test_alloc.alloc(u8, @intCast(len));
        const n = try new_first.file.readPositionalAll(tio, first_new_bytes.?, 0);
        try std.testing.expectEqual(@as(usize, @intCast(len)), n);
        first_new_name = try std.fmt.allocPrint(
            test_alloc,
            "data/{x}/seg-{d:0>8}",
            .{ journal_id, old_count + 1 },
        );
    }
    // The crash state: the complete old generation plus the new
    // generation's first segment.
    for (old_bytes[0..old_count], 0..) |bytes, i| {
        const file = try env.tmp.dir.createFile(tio, old_names[i], .{
            .read = true,
            .truncate = true,
            .permissions = data_file_perm,
        });
        defer file.close(tio);
        try file.writePositionalAll(tio, bytes, 0);
    }
    {
        const file = try env.tmp.dir.createFile(tio, first_new_name.?, .{
            .read = true,
            .truncate = true,
            .permissions = data_file_perm,
        });
        defer file.close(tio);
        try file.writePositionalAll(tio, first_new_bytes.?, 0);
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
            if (en != null) try list.append(test_alloc, sl.seq);
        }
    }.cb);
    // Every slot of the old generation survives; the partial new segment
    // was deleted.
    try std.testing.expectEqualSlices(u64, &.{ 1, 2, 3, 4, 5 }, seen.items);
    const jd = store.journals.get(journal_id).?;
    var file_count: usize = 0;
    var it = jd.dir.iterate();
    while (try it.next(tio)) |f| {
        if (f.kind != .file) continue;
        if (std.mem.startsWith(u8, f.name, "seg-")) file_count += 1;
    }
    try std.testing.expectEqual(jd.segments.items.len, file_count);
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
