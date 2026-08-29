//! The fold and its validation rules (PRD 0001 phase 2).
//!
//! Everything the journal knows about itself is in the chain, folded
//! deterministically: membership and the epoch leader live in the cluster's
//! control journal, per-journal settings/stale/expiry in each data journal's
//! chain. `applyControl` and `applyData` are the pure rules every member
//! runs on a `(slot, entry)` pair before accepting it — a refusal names its
//! reason, and a bad entry is refused by every member independently, so a
//! single bad member cannot push it through.
//!
//! Kinds owned by PRD 0003 (`join`, `leave`, `epoch`, `merge`) fold here —
//! the rules live in `src/cluster/` (membership.zig, epoch.zig) and are
//! wired into `applyControl`; in a data journal they are refused
//! `wrong_journal_type` (they belong to the cluster's control chain). The
//! checkpoint settle rule (PRD 0002) refuses a checkpoint inside
//! `merge.settle_ms` of the last merge.

const std = @import("std");
const crypto = std.crypto;
const entry = @import("entry.zig");
const slot = @import("slot.zig");
const schema = @import("../settings/schema.zig");
const validate = @import("../settings/validate.zig");
const settings_fold = @import("../settings/fold.zig");
const SettingsPayload = settings_fold.SettingsPayload;
const expiry = @import("expiry.zig");
const membership = @import("../cluster/membership.zig");
const epoch = @import("../cluster/epoch.zig");

/// The refusals the fold can name. The error name *is* the refusal name;
/// `refusalName` maps it to the lowercase text used in messages and tests.
pub const Refusal = error{
    /// Entry or slot signature does not verify under the claimed author's /
    /// leader's key.
    BadSignature,
    /// Payload bytes do not hash to the signed payload_hash.
    BadPayloadHash,
    /// The slot's leader is not the current leader of its epoch.
    NotLeader,
    /// prev_slot_hash does not chain to this journal's verified head.
    BadPrevHash,
    /// (epoch, seq) continuity broken: a gap within an epoch, a seq that
    /// does not restart at 1 for a new epoch, or a first slot in the wrong
    /// epoch.
    BadPosition,
    /// slot_ts_ms went backwards in the chain.
    BadTimestamp,
    /// author_seq at or below the author's last, with a different hash.
    DuplicateConflict,
    /// The entry's author is not a member of the cluster.
    UnknownAuthor,
    /// The entry names a journal whose id does not match the chain it is in.
    WrongJournal,
    /// A stale mark names an entry this journal has never slotted.
    UnknownTarget,
    /// A stale mark authored by someone other than the target's author.
    NotAuthor,
    /// A stale mark while the journal has stale.enforce = off.
    StalenessDisabled,
    /// A settings entry whose changes fail the cross-key rules.
    InvalidSettings,
    /// A settings entry naming a key the schema does not have.
    UnknownSetting,
    /// A settings entry touching a key that is not live-changeable now.
    NotLiveChangeable,
    /// A settings entry whose key scope does not match its declared scope.
    ScopeMismatch,
    /// A payload larger than journal.max_entry_bytes.
    TooLarge,
    /// A join naming a key already a member (PRD 0003).
    AlreadyMember,
    /// A malformed join entry: bad payload, or a member id that does not
    /// derive from the claimed key.
    BadJoin,
    /// A malformed leave entry: unknown target, or authored by neither the
    /// target nor the leader.
    BadLeave,
    /// A malformed epoch entry: bad payload, wrong epoch number, or a
    /// claimed leader the chain cannot verify.
    BadEpoch,
    /// A malformed merge entry: bad payload, or a branch the fold cannot
    /// reconcile.
    BadMerge,
    /// A checkpoint within merge.settle_ms of the last merge.
    MergeSettling,
    /// A control-journal-only entry (genesis, create_journal, settings) or a
    /// data entry inside the control journal.
    WrongJournalType,
    /// A create_journal for a journal id the cluster already has.
    JournalExists,
    /// A create_journal with an empty or over-long name.
    BadJournalName,
    /// A create_journal past cluster.max_journals.
    TooManyJournals,
    /// A malformed or misplaced genesis entry.
    BadGenesis,
    /// A checkpoint whose expire_through is past its own slot.
    BadCheckpoint,
    /// A control entry (stale, checkpoint, settings) with a malformed payload.
    BadControlPayload,
};

pub const ApplyError = error{OutOfMemory} || Refusal;

/// Refusal names, lowercase, for messages, the CLI and the G3 "named by
/// position" reports.
pub fn refusalName(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.BadSignature => "bad_signature",
        error.BadPayloadHash => "bad_payload_hash",
        error.NotLeader => "not_leader",
        error.BadPrevHash => "bad_prev_hash",
        error.BadPosition => "bad_position",
        error.BadTimestamp => "bad_timestamp",
        error.DuplicateConflict => "duplicate_conflict",
        error.UnknownAuthor => "unknown_author",
        error.WrongJournal => "wrong_journal",
        error.UnknownTarget => "unknown_target",
        error.NotAuthor => "not_author",
        error.StalenessDisabled => "staleness_disabled",
        error.InvalidSettings => "invalid_settings",
        error.UnknownSetting => "unknown_setting",
        error.NotLiveChangeable => "not_live_changeable",
        error.ScopeMismatch => "scope_mismatch",
        error.TooLarge => "too_large",
        error.AlreadyMember => "already_member",
        error.BadJoin => "bad_join",
        error.BadLeave => "bad_leave",
        error.BadEpoch => "bad_epoch",
        error.BadMerge => "bad_merge",
        error.MergeSettling => "merge_settling",
        error.WrongJournalType => "wrong_journal_type",
        error.JournalExists => "journal_exists",
        error.BadJournalName => "bad_journal_name",
        error.TooManyJournals => "too_many_journals",
        error.BadGenesis => "bad_genesis",
        error.BadCheckpoint => "bad_checkpoint",
        error.BadControlPayload => "bad_control_payload",
        else => null,
    };
}

/// A member's 128-bit id is derived from its Ed25519 public key (first 16
/// bytes of the key's SHA-256), so the id cannot be chosen to collide (PRD
/// 0003 *Identity*).
pub fn deriveMemberId(public_key: [32]u8) [16]u8 {
    var hash: [32]u8 = undefined;
    crypto.hash.sha2.Sha256.hash(&public_key, &hash, .{});
    return hash[0..16].*;
}

/// Upper bound on a journal name (the name is a mutable setting; ids are
/// never names — see PRD 0001 *Storage*).
pub const max_journal_name = 256;

pub const Member = struct {
    id: [16]u8,
    public_key: [32]u8,
    /// The slot of the member's join (or genesis, for the founder); earlier
    /// = more senior. This is the whole unspoofable-join answer (RFC 0002):
    /// seniority is a chain position, never a reported timestamp.
    seniority: slot.Position,
    /// The address the member advertised in its join (owned); the founder
    /// advertises the empty string. An `authorities` entry may name it.
    address: []const u8,
};

pub const EpochState = struct {
    number: u64,
    leader: [16]u8,
    /// Why the epoch opened; "genesis" for epoch 1, otherwise the reason
    /// list PRD 0003 defines. Not owned.
    reason: []const u8,
};

pub const JournalMeta = struct {
    id: [16]u8,
    name: []const u8, // owned
    created_at: slot.Position,
};

pub const AuthorState = struct {
    /// The highest author_seq this journal has slotted for the author; the
    /// next append uses last_seq + 1. Dedup of redeliveries consults the
    /// entries table, which records every entry's bytes.
    last_seq: u64,
};

/// What the fold knows about one slotted entry. `expires_at_ms` and
/// `ttl_action` are fixed at slotting from the settings in force then (a
/// settings entry takes effect only for slots after it); the `stale_` fields
/// record the author-mark chain event. Everything else a read needs —
/// stale-by-TTL, expired, visible — is derived in expiry.zig from these
/// facts and the read-time clock.
pub const EntryInfo = struct {
    position: slot.Position,
    slot_ts_ms: u64,
    entry_hash: [32]u8,
    payload_len: u32,
    expires_at_ms: ?u64,
    ttl_action: expiry.TtlAction,
    stale_marked: bool,
    stale_position: ?slot.Position,
    removed: bool,
};

/// The folded state of one journal's chain. The same type serves the
/// cluster's control journal (scope .cluster; members, epoch, journals) and
/// each data journal (scope .journal; journal settings, stale/checkpoint
/// state). Owns everything the chain produced.
pub const FoldState = struct {
    allocator: std.mem.Allocator,
    journal_id: [16]u8,
    is_control: bool,

    head: ?slot.Position,
    head_slot_hash: [32]u8,
    last_slot_ts_ms: u64,

    settings: schema.SettingsState,
    authors: std.AutoHashMap([16]u8, AuthorState),
    entries: std.AutoHashMap(entry.Id, EntryInfo),

    // cluster scope (control journal only):
    members: std.ArrayListUnmanaged(Member),
    epoch: ?EpochState,
    journals: std.AutoHashMap([16]u8, JournalMeta),
    /// The last merge entry's slot, when a merge has happened; the
    /// checkpoint settle rule (PRD 0002) refuses a checkpoint until
    /// merge.settle_ms has passed since it.
    last_merge: ?MergeFact,

    // journal scope (data journals only):
    checkpoints: std.ArrayListUnmanaged(slot.Position),

    pub const MergeFact = struct {
        position: slot.Position,
        slot_ts_ms: u64,
    };

    pub fn init(allocator: std.mem.Allocator, is_control: bool, journal_id: [16]u8) !FoldState {
        return .{
            .allocator = allocator,
            .journal_id = journal_id,
            .is_control = is_control,
            .head = null,
            .head_slot_hash = slot.genesis_prev,
            .last_slot_ts_ms = 0,
            .settings = try schema.SettingsState.initDefaults(allocator),
            .authors = std.AutoHashMap([16]u8, AuthorState).init(allocator),
            .entries = std.AutoHashMap(entry.Id, EntryInfo).init(allocator),
            .members = .empty,
            .epoch = null,
            .journals = std.AutoHashMap([16]u8, JournalMeta).init(allocator),
            .last_merge = null,
            .checkpoints = .empty,
        };
    }

    pub fn deinit(self: *FoldState) void {
        self.settings.deinit();
        self.authors.deinit();
        self.entries.deinit();
        for (self.members.items) |member| self.allocator.free(member.address);
        self.members.deinit(self.allocator);
        var journal_it = self.journals.valueIterator();
        while (journal_it.next()) |meta| self.allocator.free(meta.name);
        self.journals.deinit();
        self.checkpoints.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn memberById(self: *const FoldState, id: [16]u8) ?Member {
        for (self.members.items) |member| {
            if (std.mem.eql(u8, &member.id, &id)) return member;
        }
        return null;
    }

    /// The member count the whole-state settings rules see (the
    /// authorities-empty exception at n = 1, PRD 0004).
    pub fn memberCount(self: *const FoldState) u32 {
        return @intCast(self.members.items.len);
    }

    /// Validates and folds one `(slot, entry)` of the control journal's
    /// chain. On refusal, the fold is untouched.
    pub fn applyControl(
        self: *FoldState,
        sl: *const slot.Slot,
        en: *const entry.Entry,
    ) ApplyError!void {
        try self.checkChainContinuity(sl);
        if (en.kind == .genesis) {
            try self.applyGenesis(sl, en);
            return;
        }
        if (!std.mem.eql(u8, &en.journal, &self.journal_id)) return error.WrongJournal;
        const leader = self.epoch.?.leader;

        // After a merge, the surviving leader re-slots the losing branch's
        // control entries (PRD 0003 *Partition and merge*; OQ 33). Their
        // slots are signed by the current leader, but the entries are not
        // the leader's — or they are the losing branch's `epoch` re-slotted
        // at the current epoch number, which the live epoch rule would
        // refuse as stale. The re-slot rule applies them as no-ops, or with
        // the idempotent join/leave variants. The test is sound by
        // construction: an entry the live rule accepts — leader-authored, or
        // a genuinely new epoch — never matches it, so a merged chain replays
        // identically after a restart without any side channel.
        const reslotted_epoch = en.kind == .epoch and sl.epoch == self.epoch.?.number;
        const reslotted_entry = en.kind != .epoch and !std.mem.eql(u8, &en.author, &leader);
        if (reslotted_epoch or reslotted_entry) {
            try self.applyControlReslotted(sl, en);
            return;
        }

        if (en.kind == .epoch) {
            // The epoch entry opens the new leader's term, so its slot is
            // signed by the *claimed* leader, not the current one (PRD 0003
            // *Epochs*); epoch.zig owns the special path. The liveness
            // half — the claimed leader must be what `leader(...)` returns
            // for the caller's liveness view — is checked by the caller
            // before offering the entry to the fold; a member that disagrees
            // keeps its previous view (that is a partition).
            try epoch.applyEpoch(self, sl, en);
            return;
        }
        if (!std.mem.eql(u8, &sl.leader, &leader)) return error.NotLeader;
        const leader_member = self.memberById(leader) orelse return error.NotLeader;
        try verifySlotSignature(leader_member, sl);
        try checkEntrySignature(self, en);
        try self.checkAuthorSeq(en);
        switch (en.kind) {
            .create_journal => try self.applyCreateJournal(sl, en),
            .settings => try self.applyClusterSettings(sl, en),
            .join => try membership.applyJoin(self, sl, en),
            .leave => try membership.applyLeave(self, en),
            .merge => try epoch.applyMerge(self, sl, en),
            .data, .stale, .checkpoint => return error.WrongJournalType,
            .genesis => unreachable, // handled above
            .epoch => unreachable, // handled above
        }
        try self.registerEntry(sl, en);
    }

    /// Folds one `(slot, entry)` of the control journal as a re-slot after a
    /// merge (PRD 0003 *Partition and merge*): the entry is unchanged and
    /// its id never moves, only its position does. `join` and `leave`
    /// re-slot with their normal validation and effect — the survivor's fold
    /// never saw the losing branch, so it must not accept what it would
    /// refuse live (membership.zig `applyJoinReslotted` /
    /// `applyLeaveReslotted`); `create_journal` with its normal rule;
    /// `data` is refused (the control chain has no data entries).
    /// `settings`, `stale`, `checkpoint`, `epoch` and `merge` re-slot as
    /// no-ops: the survivor's settings value wins (OQ 33), the losing
    /// branch's cleanup and branch mechanics have already served their
    /// purpose, and re-applying them at a new position would be wrong. The
    /// bytes are still validated — signature, payload hash, author — so a
    /// re-slot cannot smuggle anything a normal entry could not.
    pub fn applyControlReslotted(
        self: *FoldState,
        sl: *const slot.Slot,
        en: *const entry.Entry,
    ) ApplyError!void {
        try self.checkChainContinuity(sl);
        if (!std.mem.eql(u8, &en.journal, &self.journal_id)) return error.WrongJournal;
        const leader = self.epoch.?.leader;
        if (!std.mem.eql(u8, &sl.leader, &leader)) return error.NotLeader;
        const leader_member = self.memberById(leader) orelse return error.NotLeader;
        try verifySlotSignature(leader_member, sl);
        try checkEntrySignature(self, en);
        try self.checkAuthorSeq(en);
        switch (en.kind) {
            .join => try membership.applyJoinReslotted(self, sl, en),
            .leave => try membership.applyLeaveReslotted(self, en),
            .create_journal => try self.applyCreateJournalReslotted(sl, en),
            .settings, .stale, .checkpoint, .epoch, .merge => {},
            .data => return error.WrongJournalType,
            .genesis => return error.BadGenesis,
        }
        try self.registerEntry(sl, en);
    }

    /// Validates and folds one `(slot, entry)` of a data journal's chain.
    /// `cluster` is the control journal's fold, which owns the membership,
    /// the epoch leader and the journal registry.
    pub fn applyData(
        self: *FoldState,
        cluster: *const FoldState,
        sl: *const slot.Slot,
        en: *const entry.Entry,
    ) ApplyError!void {
        try self.checkChainContinuity(sl);
        // A journal's first record is written in the term that created it.
        // A future term's record (the losing branch of a partition) is
        // refused here and skipped by the refold; a *past* term's record is
        // the pre-failover data a follower kept when a new leader was
        // elected — it stays valid and folds against the later control.
        if (self.head == null and sl.epoch > cluster.epoch.?.number) return error.BadPosition;
        // The slot's leader must be a member whose signature verifies; it
        // does not have to be the *current* leader, because data written
        // before a failover keeps its original term's leader (the merge
        // re-slots it into the new term). The entry's author is still
        // checked against the member table, so nothing a non-member could
        // sign gets in.
        const slot_leader = cluster.memberById(sl.leader) orelse return error.NotLeader;
        try verifySlotSignature(slot_leader, sl);
        if (!std.mem.eql(u8, &en.journal, &self.journal_id)) return error.WrongJournal;
        try checkEntrySignature(cluster, en);
        try self.checkAuthorSeq(en);
        const max_bytes = self.settings.getU64(schema.keyIndex("journal.max_entry_bytes").?);
        if (en.payload.len > max_bytes) return error.TooLarge;
        switch (en.kind) {
            .data => {},
            .settings => try self.applyJournalSettings(sl, en, cluster),
            .stale => try self.applyStale(sl, en),
            .checkpoint => try self.applyCheckpoint(sl, en, cluster),
            .genesis, .create_journal => return error.WrongJournalType,
            .join, .leave, .epoch, .merge => return error.WrongJournalType,
        }
        try self.registerEntry(sl, en);
    }

    fn checkChainContinuity(self: *const FoldState, sl: *const slot.Slot) Refusal!void {
        if (!std.mem.eql(u8, &sl.prev_slot_hash, &self.head_slot_hash)) return error.BadPrevHash;
        if (sl.slot_ts_ms < self.last_slot_ts_ms) return error.BadTimestamp;
        if (self.head) |head| {
            const dense = if (sl.epoch == head.epoch)
                sl.seq == head.seq + 1
            else
                sl.epoch > head.epoch and sl.seq == 1;
            if (!dense) return error.BadPosition;
        } else if (sl.seq != 1) {
            return error.BadPosition;
        }
    }

    /// Advances the chain head over a slot-only record — the slot a
    /// `retain = none` compaction keeps when it drops the entry (PRD 0002).
    /// The fold cannot skip it: the next full record chains to this slot's
    /// hash, and a head that never moved would refuse it with BadPrevHash on
    /// reopen (bug 2026-08-28-retain-none-reopen-badprevhash). Only the head
    /// facts move — there is no entry to register.
    pub fn advanceHead(self: *FoldState, sl: *const slot.Slot) Refusal!void {
        try self.checkChainContinuity(sl);
        self.head = sl.position();
        self.head_slot_hash = slot.slotHash(sl);
        self.last_slot_ts_ms = sl.slot_ts_ms;
    }

    pub fn verifySlotSignature(member: Member, sl: *const slot.Slot) Refusal!void {
        const pk = crypto.sign.Ed25519.PublicKey.fromBytes(member.public_key) catch
            return error.BadSignature;
        slot.verify(pk, sl) catch return error.BadSignature;
    }

    /// The entry's author must be a member of the cluster, its signature
    /// must verify under that member's key, and the payload must hash to the
    /// signed payload_hash. `cluster` is the control journal's fold; the
    /// author lookup is against the cluster's member table even when `self`
    /// is a data journal (PRD 0003 *Identity*).
    pub fn checkEntrySignature(cluster: *const FoldState, en: *const entry.Entry) Refusal!void {
        const member = cluster.memberById(en.author) orelse return error.UnknownAuthor;
        const pk = crypto.sign.Ed25519.PublicKey.fromBytes(member.public_key) catch
            return error.BadSignature;
        entry.verify(pk, en) catch return error.BadSignature;
        // The signature pins payload_hash, but a compacted entry's payload
        // bytes are gone by design (PRD 0002 *retain*): the header —
        // signature and hash included — is what survives and still verifies.
        if (!en.payload_omitted and
            !std.mem.eql(u8, &en.payload_hash, &entry.payloadHash(en.payload)))
        {
            return error.BadPayloadHash;
        }
    }

    /// author_seq is monotone per (author, journal), never dense: a refused
    /// entry consumes a number and a crash after local assignment leaves a
    /// hole (OQ 11, gaps allowed). An entry at or below the author's last
    /// seq is accepted only when it is a byte-identical redelivery of an
    /// entry the journal has already slotted — the dedup that makes the
    /// unslotted queue's replay on restart harmless, and the rule that makes
    /// a merge's re-slots idempotent on the side that already had them. The
    /// entries table is the dedup store (its entry_hash is the recorded
    /// bytes).
    pub fn checkAuthorSeq(self: *const FoldState, en: *const entry.Entry) Refusal!void {
        const author = self.authors.get(en.author) orelse return;
        if (en.author_seq > author.last_seq) return;
        const existing = self.entries.get(en.id()) orelse return error.DuplicateConflict;
        const entry_hash = entry.entryHash(en);
        if (!std.mem.eql(u8, &entry_hash, &existing.entry_hash)) return error.DuplicateConflict;
    }

    pub fn checkAuthorIsLeader(en: *const entry.Entry, leader: [16]u8) Refusal!void {
        if (!std.mem.eql(u8, &en.author, &leader)) return error.NotLeader;
    }

    /// Registers the accepted slot: entry facts, author seq, head. Mutations
    /// happen only after every validation passed; an OutOfMemory here leaves
    /// the fold partially advanced, which the caller treats as fatal (the
    /// node cannot continue folding after an OOM anyway). A redelivered
    /// entry keeps the state facts the chain already recorded for it
    /// (stale/removed), only its slot moves.
    pub fn registerEntry(
        self: *FoldState,
        sl: *const slot.Slot,
        en: *const entry.Entry,
    ) ApplyError!void {
        const entry_hash = entry.entryHash(en);
        const expires_at = if (en.kind == .data)
            expiry.expiresAt(sl.slot_ts_ms, en.ttl_ms, &self.settings)
        else
            null;
        const ttl_action = if (en.kind == .data) expiry.action(&self.settings) else .mark_stale;
        const previous = self.entries.getPtr(en.id());
        const stale_marked = if (previous) |p| p.stale_marked else false;
        const stale_position = if (previous) |p| p.stale_position else null;
        const removed = if (previous) |p| p.removed else false;
        try self.entries.put(en.id(), .{
            .position = sl.position(),
            .slot_ts_ms = sl.slot_ts_ms,
            .entry_hash = entry_hash,
            .payload_len = en.payload_len,
            .expires_at_ms = expires_at,
            .ttl_action = ttl_action,
            .stale_marked = stale_marked,
            .stale_position = stale_position,
            .removed = removed,
        });
        // The author's high-water mark is monotone: a redelivered entry
        // below it must not lower it, or a conflicting entry between the
        // lowered mark and the true last seq would pass the seq check
        // without any dedup comparison (bug
        // 2026-08-28-redelivery-lowers-author-seq).
        const last_seq = if (self.authors.get(en.author)) |a|
            @max(a.last_seq, en.author_seq)
        else
            en.author_seq;
        try self.authors.put(en.author, .{ .last_seq = last_seq });
        self.head = sl.position();
        self.head_slot_hash = slot.slotHash(sl);
        self.last_slot_ts_ms = sl.slot_ts_ms;
    }

    // --- control journal kinds ---------------------------------------------

    fn applyGenesis(
        self: *FoldState,
        sl: *const slot.Slot,
        en: *const entry.Entry,
    ) ApplyError!void {
        if (self.head != null) return error.BadGenesis;
        if (sl.epoch != 1 or sl.seq != 1) return error.BadGenesis;
        var payload = decodeGenesisPayload(self.allocator, en.payload) catch
            return error.BadGenesis;
        defer payload.deinit(self.allocator);
        const founder_id = deriveMemberId(payload.founder_key);
        if (!std.mem.eql(u8, &en.author, &founder_id)) return error.BadGenesis;
        if (!std.mem.eql(u8, &sl.leader, &founder_id)) return error.BadGenesis;
        const pk = crypto.sign.Ed25519.PublicKey.fromBytes(payload.founder_key) catch
            return error.BadGenesis;
        entry.verify(pk, en) catch return error.BadSignature;
        slot.verify(pk, sl) catch return error.BadSignature;
        if (!std.mem.eql(u8, &en.payload_hash, &entry.payloadHash(en.payload))) {
            return error.BadPayloadHash;
        }
        settings_fold.applyGenesis(&self.settings, payload.changes) catch
            return error.InvalidSettings;
        try self.members.append(self.allocator, .{
            .id = founder_id,
            .public_key = payload.founder_key,
            .seniority = sl.position(),
            .address = try self.allocator.dupe(u8, ""),
        });
        self.epoch = .{ .number = 1, .leader = founder_id, .reason = "genesis" };
        self.journal_id = en.journal;
        try self.registerEntry(sl, en);
    }

    fn applyCreateJournal(
        self: *FoldState,
        sl: *const slot.Slot,
        en: *const entry.Entry,
    ) ApplyError!void {
        try checkAuthorIsLeader(en, self.epoch.?.leader);
        try self.applyCreateJournalValidated(sl, en);
    }

    /// The re-slotted variant: the entry's author is the losing branch's
    /// leader, never the survivor's, so the author check cannot hold — but
    /// the payload, name and max-journals rules still run, and the bytes
    /// were already signature-checked against the member table (bug
    /// 2026-08-28-reslotted-create-journal-refused).
    fn applyCreateJournalReslotted(
        self: *FoldState,
        sl: *const slot.Slot,
        en: *const entry.Entry,
    ) ApplyError!void {
        try self.applyCreateJournalValidated(sl, en);
    }

    fn applyCreateJournalValidated(
        self: *FoldState,
        sl: *const slot.Slot,
        en: *const entry.Entry,
    ) ApplyError!void {
        var payload = decodeCreateJournalPayload(self.allocator, en.payload) catch
            return error.BadControlPayload;
        defer payload.deinit(self.allocator);
        if (self.journals.contains(payload.journal_id)) return error.JournalExists;
        if (payload.name.len == 0 or payload.name.len > max_journal_name) {
            return error.BadJournalName;
        }
        const max_journals = self.settings.getU32(schema.keyIndex("cluster.max_journals").?);
        if (self.journals.count() >= max_journals) return error.TooManyJournals;
        // The initial journal settings are validated as a whole, like any
        // settings change, against a fresh journal-scoped state.
        var state = schema.SettingsState.initDefaults(self.allocator) catch
            return error.InvalidSettings;
        defer state.deinit();
        settings_fold.applyGenesis(&state, payload.changes) catch return error.InvalidSettings;
        try self.journals.put(payload.journal_id, .{
            .id = payload.journal_id,
            .name = try self.allocator.dupe(u8, payload.name),
            .created_at = sl.position(),
        });
        try self.registerEntry(sl, en);
    }

    fn applyClusterSettings(
        self: *FoldState,
        sl: *const slot.Slot,
        en: *const entry.Entry,
    ) ApplyError!void {
        const leader = self.epoch.?.leader;
        try checkAuthorIsLeader(en, leader);
        var payload = settings_fold.decodePayload(self.allocator, en.payload) catch |err|
            return mapSettingsDecodeError(err);
        defer payload.deinit(self.allocator);
        if (payload.scope != .cluster) return error.ScopeMismatch;
        settings_fold.applySettings(&self.settings, payload, self.memberCount()) catch |err|
            return mapSettingsApplyError(err);
        try self.registerEntry(sl, en);
    }

    // --- data journal kinds -------------------------------------------------

    fn applyJournalSettings(
        self: *FoldState,
        sl: *const slot.Slot,
        en: *const entry.Entry,
        cluster: *const FoldState,
    ) ApplyError!void {
        try checkAuthorIsLeader(en, cluster.epoch.?.leader);
        var payload = settings_fold.decodePayload(self.allocator, en.payload) catch |err|
            return mapSettingsDecodeError(err);
        defer payload.deinit(self.allocator);
        if (payload.scope != .journal or
            !std.mem.eql(u8, &payload.journal_id, &self.journal_id))
        {
            return error.ScopeMismatch;
        }
        settings_fold.applySettings(&self.settings, payload, cluster.memberCount()) catch |err|
            return mapSettingsApplyError(err);
        try self.registerEntry(sl, en);
    }

    fn applyStale(self: *FoldState, sl: *const slot.Slot, en: *const entry.Entry) ApplyError!void {
        const enforce = self.settings.getEnum(schema.keyIndex("stale.enforce").?);
        if (!std.mem.eql(u8, enforce, "author")) return error.StalenessDisabled;
        var payload = decodeStalePayload(en.payload) catch return error.BadControlPayload;
        if (!std.mem.eql(u8, &payload.target.author, &en.author)) return error.NotAuthor;
        const info = self.entries.getPtr(payload.target) orelse return error.UnknownTarget;
        // Idempotent: a mark for an already-stale or removed entry is a
        // no-op (a retried mark is harmless).
        if (!info.removed and !info.stale_marked) {
            info.stale_marked = true;
            info.stale_position = sl.position();
        }
        try self.registerEntry(sl, en);
    }

    fn applyCheckpoint(
        self: *FoldState,
        sl: *const slot.Slot,
        en: *const entry.Entry,
        cluster: *const FoldState,
    ) ApplyError!void {
        try checkAuthorIsLeader(en, cluster.epoch.?.leader);
        const payload = decodeCheckpointPayload(en.payload) catch return error.BadControlPayload;
        if (slot.Position.order(payload.expire_through, sl.position()) == .gt) {
            return error.BadCheckpoint;
        }
        // The merge settle rule (PRD 0002): a checkpoint is never emitted
        // for slots newer than the last merge until merge.settle_ms has
        // passed — the conservative rule that keeps a just-healed cluster
        // from deleting the other side's fresh writes on a clock it did not
        // stamp (OQ 60). `merge.settle_ms` is cluster-scoped, so the value
        // comes from the cluster's fold, not this journal's; the merge fact
        // itself lives on the control fold too (a data fold never sees a
        // merge entry — bug 2026-08-28-merge-settle-rule-dead).
        if (cluster.last_merge) |merge| {
            const settle = cluster.settings.getU64(schema.keyIndex("merge.settle_ms").?);
            if (sl.slot_ts_ms < merge.slot_ts_ms +| settle) return error.MergeSettling;
        }
        // The default configuration removes nothing (ttl.enforce = off,
        // stale.cleanup = keep): skip the O(entries) candidates pass, which
        // would otherwise materialize the whole entries table for an empty
        // set on every checkpoint of every journal.
        if (!expiry.canRemoveAnything(&self.settings)) {
            try self.checkpoints.append(self.allocator, sl.position());
            try self.registerEntry(sl, en);
            return;
        }
        const candidates = try self.expiryCandidates(self.allocator);
        defer self.allocator.free(candidates);
        const set = try expiry.removalSet(
            self.allocator,
            candidates,
            payload.expire_through,
            sl.slot_ts_ms,
            &self.settings,
        );
        defer self.allocator.free(set);
        for (set) |removed| {
            const info = self.entries.getPtr(removed.id) orelse continue;
            info.removed = true;
        }
        try self.checkpoints.append(self.allocator, sl.position());
        try self.registerEntry(sl, en);
    }

    /// The fold's entries as expiry candidates: the input both
    /// `applyCheckpoint` and the node's compaction feed to
    /// `expiry.removalSet`, so the set a checkpoint folds and the set
    /// compaction drops can never disagree. Caller owns the slice.
    pub fn expiryCandidates(
        self: *const FoldState,
        allocator: std.mem.Allocator,
    ) ![]expiry.SlottedEntry {
        const candidates = try allocator.alloc(expiry.SlottedEntry, self.entries.count());
        var index: usize = 0;
        var it = self.entries.iterator();
        while (it.next()) |kv| : (index += 1) {
            const info = kv.value_ptr.*;
            candidates[index] = .{
                .id = kv.key_ptr.*,
                .position = info.position,
                .slot_ts_ms = info.slot_ts_ms,
                .expires_at = info.expires_at_ms,
                .ttl_action = info.ttl_action,
                .stale_marked = info.stale_marked,
                .stale_position = info.stale_position,
            };
        }
        std.debug.assert(index == candidates.len);
        return candidates;
    }

    /// A deterministic hash of the folded state — the check behind "two
    /// members fold the same log to the same state" (PRD 0001 G2), and the
    /// value the store compares across reopens. Canonical: every component
    /// is emitted in a fixed order (map entries sorted by key), so the hash
    /// never depends on map iteration order.
    pub fn hash(self: *const FoldState, allocator: std.mem.Allocator) ![32]u8 {
        var canon = std.ArrayListUnmanaged(u8).empty;
        defer canon.deinit(allocator);

        const settings_hash = try self.settings.hash(allocator);
        try canon.appendSlice(allocator, &settings_hash);
        try canon.appendSlice(allocator, &self.head_slot_hash);
        var pos_buf: [16]u8 = undefined;
        if (self.head) |h| {
            std.mem.writeInt(u64, pos_buf[0..8], h.epoch, .little);
            std.mem.writeInt(u64, pos_buf[8..16], h.seq, .little);
        } else {
            @memset(&pos_buf, 0);
        }
        try canon.appendSlice(allocator, &pos_buf);

        // The epoch in force and the last merge — folded state a divergent
        // fold could get wrong even from the same chain (the chain covers
        // the slots; these are what the slots mean), so they are hashed
        // explicitly rather than left to the head hash.
        if (self.epoch) |e| {
            std.mem.writeInt(u64, pos_buf[0..8], e.number, .little);
            try canon.appendSlice(allocator, pos_buf[0..8]);
            try canon.appendSlice(allocator, &e.leader);
            std.mem.writeInt(u16, pos_buf[0..2], @intCast(e.reason.len), .little);
            try canon.appendSlice(allocator, pos_buf[0..2]);
            try canon.appendSlice(allocator, e.reason);
        } else {
            try canon.appendSlice(allocator, &[_]u8{0} ** 26);
        }
        if (self.last_merge) |m| {
            std.mem.writeInt(u64, pos_buf[0..8], m.position.epoch, .little);
            std.mem.writeInt(u64, pos_buf[8..16], m.position.seq, .little);
            try canon.appendSlice(allocator, &pos_buf);
            std.mem.writeInt(u64, pos_buf[0..8], m.slot_ts_ms, .little);
            try canon.appendSlice(allocator, pos_buf[0..8]);
        } else {
            try canon.appendSlice(allocator, &[_]u8{0} ** 24);
        }

        var count_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &count_buf, @intCast(self.members.items.len), .little);
        try canon.appendSlice(allocator, &count_buf);
        for (self.members.items) |member| {
            try canon.appendSlice(allocator, &member.id);
            std.mem.writeInt(u64, pos_buf[0..8], member.seniority.epoch, .little);
            std.mem.writeInt(u64, pos_buf[8..16], member.seniority.seq, .little);
            try canon.appendSlice(allocator, &pos_buf);
            std.mem.writeInt(u16, pos_buf[0..2], @intCast(member.address.len), .little);
            try canon.appendSlice(allocator, pos_buf[0..2]);
            try canon.appendSlice(allocator, member.address);
        }

        // Journals, sorted by id.
        {
            const ids = try self.sortedJournalIds(allocator);
            defer allocator.free(ids);
            std.mem.writeInt(u32, &count_buf, @intCast(ids.len), .little);
            try canon.appendSlice(allocator, &count_buf);
            for (ids) |id| {
                const meta = self.journals.get(id).?;
                try canon.appendSlice(allocator, &id);
                std.mem.writeInt(u16, pos_buf[0..2], @intCast(meta.name.len), .little);
                try canon.appendSlice(allocator, pos_buf[0..2]);
                try canon.appendSlice(allocator, meta.name);
                std.mem.writeInt(u64, pos_buf[0..8], meta.created_at.epoch, .little);
                std.mem.writeInt(u64, pos_buf[8..16], meta.created_at.seq, .little);
                try canon.appendSlice(allocator, &pos_buf);
            }
        }

        // Entries, sorted by id.
        {
            const ids = try self.sortedEntryIds(allocator);
            defer allocator.free(ids);
            std.mem.writeInt(u32, &count_buf, @intCast(ids.len), .little);
            try canon.appendSlice(allocator, &count_buf);
            for (ids) |id| {
                const info = self.entries.get(id).?;
                try canon.appendSlice(allocator, &id.author);
                std.mem.writeInt(u64, pos_buf[0..8], id.author_seq, .little);
                try canon.appendSlice(allocator, pos_buf[0..8]);
                std.mem.writeInt(u64, pos_buf[0..8], info.position.epoch, .little);
                std.mem.writeInt(u64, pos_buf[8..16], info.position.seq, .little);
                try canon.appendSlice(allocator, &pos_buf);
                try canon.appendSlice(allocator, &info.entry_hash);
                std.mem.writeInt(u64, pos_buf[0..8], info.expires_at_ms orelse 0, .little);
                try canon.appendSlice(allocator, pos_buf[0..8]);
                std.mem.writeInt(u8, pos_buf[0..1], @intFromBool(info.stale_marked), .little);
                std.mem.writeInt(u8, pos_buf[1..2], @intFromBool(info.removed), .little);
                try canon.appendSlice(allocator, pos_buf[0..2]);
            }
        }

        // Authors, sorted by author id.
        {
            const ids = try self.sortedAuthorIds(allocator);
            defer allocator.free(ids);
            std.mem.writeInt(u32, &count_buf, @intCast(ids.len), .little);
            try canon.appendSlice(allocator, &count_buf);
            for (ids) |id| {
                const author = self.authors.get(id).?;
                try canon.appendSlice(allocator, &id);
                std.mem.writeInt(u64, pos_buf[0..8], author.last_seq, .little);
                try canon.appendSlice(allocator, pos_buf[0..8]);
            }
        }

        var out: [32]u8 = undefined;
        crypto.hash.sha2.Sha256.hash(canon.items, &out, .{});
        return out;
    }

    fn sortedEntryIds(self: *const FoldState, allocator: std.mem.Allocator) ![]entry.Id {
        const ids = try allocator.alloc(entry.Id, self.entries.count());
        var i: usize = 0;
        var it = self.entries.keyIterator();
        while (it.next()) |id| {
            ids[i] = id.*;
            i += 1;
        }
        std.mem.sort(entry.Id, ids, {}, idLessThan);
        return ids;
    }

    fn sortedAuthorIds(self: *const FoldState, allocator: std.mem.Allocator) ![][16]u8 {
        const ids = try allocator.alloc([16]u8, self.authors.count());
        var i: usize = 0;
        var it = self.authors.keyIterator();
        while (it.next()) |id| {
            ids[i] = id.*;
            i += 1;
        }
        std.mem.sort([16]u8, ids, {}, id16LessThan);
        return ids;
    }

    fn sortedJournalIds(self: *const FoldState, allocator: std.mem.Allocator) ![][16]u8 {
        const ids = try allocator.alloc([16]u8, self.journals.count());
        var i: usize = 0;
        var it = self.journals.keyIterator();
        while (it.next()) |id| {
            ids[i] = id.*;
            i += 1;
        }
        std.mem.sort([16]u8, ids, {}, id16LessThan);
        return ids;
    }
};

fn idLessThan(_: void, a: entry.Id, b: entry.Id) bool {
    return entry.Id.lessThan(a, b);
}

fn id16LessThan(_: void, a: [16]u8, b: [16]u8) bool {
    return std.mem.order(u8, &a, &b) == .lt;
}

fn mapSettingsDecodeError(err: anyerror) ApplyError {
    return switch (err) {
        error.UnknownKey => error.UnknownSetting,
        error.ScopeMismatch => error.ScopeMismatch,
        else => error.InvalidSettings,
    };
}

fn mapSettingsApplyError(err: anyerror) ApplyError {
    return switch (err) {
        error.NotLiveChangeable => error.NotLiveChangeable,
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidSettings,
    };
}

// --- control entry payloads -------------------------------------------------
//
// Genesis:      founder public key 32 | change list (cluster scope)
// create_journal: journal id 16 | name_len u16 | name | change list (journal)
// stale:        target author 16 | target author_seq 8
// checkpoint:   expire_through epoch 8 | seq 8

pub const GenesisPayload = struct {
    founder_key: [32]u8,
    changes: []const validate.Change,

    pub fn deinit(self: GenesisPayload, allocator: std.mem.Allocator) void {
        for (self.changes) |change| change.deinit(allocator);
        allocator.free(self.changes);
    }
};

pub fn genesisPayloadLen(payload: GenesisPayload) usize {
    return 32 + settings_fold.changesLen(payload.changes);
}

pub fn encodeGenesisPayload(payload: GenesisPayload, buf: []u8) error{SettingsTooLarge}!void {
    buf[0..32].* = payload.founder_key;
    try settings_fold.encodeChanges(payload.changes, buf[32..]);
}

pub fn decodeGenesisPayload(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) !GenesisPayload {
    if (bytes.len < 32) return error.InvalidLength;
    const changes = try settings_fold.decodeChanges(allocator, bytes[32..], .cluster);
    return .{ .founder_key = bytes[0..32].*, .changes = changes };
}

pub const CreateJournalPayload = struct {
    journal_id: [16]u8,
    /// Owned after decode; borrowed by the caller when encoding.
    name: []const u8,
    changes: []const validate.Change,

    pub fn deinit(self: CreateJournalPayload, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        for (self.changes) |change| change.deinit(allocator);
        allocator.free(self.changes);
    }
};

pub fn createJournalPayloadLen(payload: CreateJournalPayload) usize {
    return 16 + 2 + payload.name.len + settings_fold.changesLen(payload.changes);
}

pub fn encodeCreateJournalPayload(
    payload: CreateJournalPayload,
    buf: []u8,
) error{SettingsTooLarge}!void {
    // The name-length field is u16; a longer name cannot round-trip (bug
    // 2026-08-29-create-journal-name-codec-overflow).
    if (payload.name.len > std.math.maxInt(u16)) return error.SettingsTooLarge;
    buf[0..16].* = payload.journal_id;
    std.mem.writeInt(u16, buf[16..18], @intCast(payload.name.len), .little);
    @memcpy(buf[18 .. 18 + payload.name.len], payload.name);
    try settings_fold.encodeChanges(payload.changes, buf[18 + payload.name.len ..]);
}

pub fn decodeCreateJournalPayload(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) !CreateJournalPayload {
    if (bytes.len < 16 + 2) return error.InvalidLength;
    const name_len = std.mem.readInt(u16, bytes[16..18], .little);
    if (18 + name_len > bytes.len) return error.InvalidLength;
    const name = try allocator.dupe(u8, bytes[18 .. 18 + name_len]);
    errdefer allocator.free(name);
    const changes = try settings_fold.decodeChanges(allocator, bytes[18 + name_len ..], .journal);
    return .{ .journal_id = bytes[0..16].*, .name = name, .changes = changes };
}

pub const StalePayload = struct {
    target: entry.Id,
};

pub fn encodeStalePayload(payload: StalePayload, buf: *[24]u8) void {
    buf[0..16].* = payload.target.author;
    std.mem.writeInt(u64, buf[16..24], payload.target.author_seq, .little);
}

pub fn decodeStalePayload(bytes: []const u8) error{InvalidLength}!StalePayload {
    if (bytes.len != 24) return error.InvalidLength;
    return .{
        .target = .{
            .author = bytes[0..16].*,
            .author_seq = std.mem.readInt(u64, bytes[16..24], .little),
        },
    };
}

pub const CheckpointPayload = struct {
    expire_through: slot.Position,
};

pub fn encodeCheckpointPayload(payload: CheckpointPayload, buf: *[16]u8) void {
    std.mem.writeInt(u64, buf[0..8], payload.expire_through.epoch, .little);
    std.mem.writeInt(u64, buf[8..16], payload.expire_through.seq, .little);
}

pub fn decodeCheckpointPayload(bytes: []const u8) error{InvalidLength}!CheckpointPayload {
    if (bytes.len != 16) return error.InvalidLength;
    return .{
        .expire_through = .{
            .epoch = std.mem.readInt(u64, bytes[0..8], .little),
            .seq = std.mem.readInt(u64, bytes[8..16], .little),
        },
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const test_alloc = std.testing.allocator;

/// One cluster's worth of identities for a test: the founder keypair and
/// the ids the fixtures build on.
const Fix = struct {
    io_state: std.Io.Threaded,
    founder: crypto.sign.Ed25519.KeyPair,
    founder_id: [16]u8,
    control_id: [16]u8,
    data_id: [16]u8,

    fn init() Fix {
        var io_state = std.Io.Threaded.init(test_alloc, .{});
        const founder = crypto.sign.Ed25519.KeyPair.generate(io_state.io());
        return .{
            .io_state = io_state,
            .founder = founder,
            .founder_id = deriveMemberId(founder.public_key.toBytes()),
            .control_id = "0123456789abcdef".*,
            .data_id = "abcdef0123456789".*,
        };
    }

    fn entryFor(
        self: *const Fix,
        kind: entry.Kind,
        journal: [16]u8,
        author_seq: u64,
        ttl_ms: u64,
        payload: []const u8,
    ) !entry.Entry {
        var e = entry.Entry{
            .kind = kind,
            .journal = journal,
            .author = self.founder_id,
            .author_seq = author_seq,
            .author_ts_ms = 0,
            .ttl_ms = ttl_ms,
            .payload_hash = entry.payloadHash(payload),
            .payload_len = @intCast(payload.len),
            .payload_omitted = false,
            .signature = undefined,
            .payload = payload,
        };
        e.signature = (try entry.sign(self.founder, &e)).toBytes();
        return e;
    }

    fn slotFor(
        self: *const Fix,
        ep: u64,
        seq: u64,
        entry_hash: [32]u8,
        prev: [32]u8,
        ts: u64,
    ) !slot.Slot {
        var s = slot.Slot{
            .epoch = ep,
            .seq = seq,
            .slot_ts_ms = ts,
            .entry_hash = entry_hash,
            .prev_slot_hash = prev,
            .leader = self.founder_id,
            .signature = undefined,
        };
        s.signature = (try slot.sign(self.founder, &s)).toBytes();
        return s;
    }

    /// Returns the encoded payload too: the entry borrows it, so the
    /// caller keeps it alive until after `applyControl`.
    fn genesisPair(
        self: *const Fix,
        changes: []const validate.Change,
    ) !struct { en: entry.Entry, sl: slot.Slot, payload: []u8 } {
        const payload = try test_alloc.alloc(
            u8,
            genesisPayloadLen(.{
                .founder_key = self.founder.public_key.toBytes(),
                .changes = changes,
            }),
        );
        encodeGenesisPayload(
            .{ .founder_key = self.founder.public_key.toBytes(), .changes = changes },
            payload,
        ) catch |e| return e;
        const en = try self.entryFor(.genesis, self.control_id, 1, 0, payload);
        const sl = try self.slotFor(1, 1, entry.entryHash(&en), slot.genesis_prev, 1000);
        return .{ .en = en, .sl = sl, .payload = payload };
    }
};

fn controlWithGenesis(fix: *const Fix) !FoldState {
    var fold = try FoldState.init(test_alloc, true, [_]u8{0} ** 16);
    errdefer fold.deinit();
    const pair = try fix.genesisPair(&.{});
    defer test_alloc.free(pair.payload);
    try fold.applyControl(&pair.sl, &pair.en);
    return fold;
}

/// A cluster whose control journal has genesis + one data journal ("main").
fn clusterWithDataJournal(fix: *const Fix) !struct { control: FoldState, data: FoldState } {
    var control = try FoldState.init(test_alloc, true, [_]u8{0} ** 16);
    errdefer control.deinit();
    const g = try fix.genesisPair(&.{});
    defer test_alloc.free(g.payload);
    try control.applyControl(&g.sl, &g.en);

    const payload = try test_alloc.alloc(
        u8,
        createJournalPayloadLen(.{ .journal_id = fix.data_id, .name = "main", .changes = &.{} }),
    );
    defer test_alloc.free(payload);
    encodeCreateJournalPayload(
        .{ .journal_id = fix.data_id, .name = "main", .changes = &.{} },
        payload,
    ) catch |e| return e;
    const en = try fix.entryFor(.create_journal, fix.control_id, 2, 0, payload);
    const sl = try fix.slotFor(1, 2, entry.entryHash(&en), slot.slotHash(&g.sl), 1001);
    try control.applyControl(&sl, &en);

    var data = try FoldState.init(test_alloc, false, fix.data_id);
    errdefer data.deinit();
    return .{ .control = control, .data = data };
}

/// The founder's next author_seq in a journal: one past the last slot it
/// has in that journal's chain (author_seq is per (author, journal) and
/// covers control entries too).
fn nextAuthorSeq(fold: *const FoldState, author: [16]u8) u64 {
    const current = fold.authors.get(author) orelse return 1;
    return current.last_seq + 1;
}

/// Appends a data entry to the data journal. Both counters derive from the
/// fold, so tests never drift: author_seq is the founder's next in this
/// journal, slot_seq the chain's next (they only coincide at n = 1).
fn appendData(
    fix: *const Fix,
    control: *FoldState,
    data: *FoldState,
    ttl_ms: u64,
    payload: []const u8,
    ts: u64,
) !void {
    const en = try fix.entryFor(
        .data,
        fix.data_id,
        nextAuthorSeq(data, fix.founder_id),
        ttl_ms,
        payload,
    );
    const sl = try fix.slotFor(
        1,
        (data.head orelse slot.Position{ .epoch = 1, .seq = 0 }).seq + 1,
        entry.entryHash(&en),
        data.head_slot_hash,
        ts,
    );
    try data.applyData(control, &sl, &en);
}

/// Appends a control entry (settings/stale/checkpoint) to the data journal.
fn appendControl(
    fix: *const Fix,
    control: *FoldState,
    data: *FoldState,
    kind: entry.Kind,
    payload: []const u8,
    ts: u64,
) !void {
    const en = try fix.entryFor(
        kind,
        fix.data_id,
        nextAuthorSeq(data, fix.founder_id),
        0,
        payload,
    );
    const sl = try fix.slotFor(
        1,
        (data.head orelse slot.Position{ .epoch = 1, .seq = 0 }).seq + 1,
        entry.entryHash(&en),
        data.head_slot_hash,
        ts,
    );
    try data.applyData(control, &sl, &en);
}

/// Builds the next control-journal slot (the caller builds the entry, which
/// needs the entry hash first).
fn nextControlSlot(
    fix: *const Fix,
    fold: *const FoldState,
    entry_hash: [32]u8,
    ts: u64,
) !slot.Slot {
    return fix.slotFor(1, fold.head.?.seq + 1, entry_hash, fold.head_slot_hash, ts);
}

test "genesis folds the founder, epoch 1, and the control journal id" {
    var fix = Fix.init();
    var fold = try controlWithGenesis(&fix);
    defer fold.deinit();

    try std.testing.expectEqual(@as(usize, 1), fold.members.items.len);
    try std.testing.expectEqualSlices(u8, &fix.founder_id, &fold.members.items[0].id);
    try std.testing.expectEqual(@as(u64, 1), fold.epoch.?.number);
    try std.testing.expectEqualSlices(u8, &fix.founder_id, &fold.epoch.?.leader);
    try std.testing.expectEqualSlices(u8, &fix.control_id, &fold.journal_id);
    try std.testing.expectEqual(@as(?slot.Position, .{ .epoch = 1, .seq = 1 }), fold.head);
}

test "genesis is refused when misplaced or forged" {
    var fix = Fix.init();
    {
        // Not the first slot: prev hash not zeros.
        var fold = try FoldState.init(test_alloc, true, [_]u8{0} ** 16);
        defer fold.deinit();
        const g = try fix.genesisPair(&.{});
        defer test_alloc.free(g.payload);
        var sl = g.sl;
        sl.prev_slot_hash = [_]u8{1} ** 32;
        sl.signature = (try slot.sign(fix.founder, &sl)).toBytes();
        try std.testing.expectError(error.BadPrevHash, fold.applyControl(&sl, &g.en));
    }
    {
        // Wrong epoch or seq for a first slot.
        var fold = try FoldState.init(test_alloc, true, [_]u8{0} ** 16);
        defer fold.deinit();
        const g = try fix.genesisPair(&.{});
        defer test_alloc.free(g.payload);
        var sl = g.sl;
        sl.epoch = 2;
        sl.signature = (try slot.sign(fix.founder, &sl)).toBytes();
        try std.testing.expectError(error.BadGenesis, fold.applyControl(&sl, &g.en));
    }
    {
        // A second genesis on a live chain is refused.
        var fold = try controlWithGenesis(&fix);
        defer fold.deinit();
        const g = try fix.genesisPair(&.{});
        defer test_alloc.free(g.payload);
        // The genesis slot cannot chain onto a live head: prev must be the
        // head's hash, and genesis only ever sits at the very start.
        try std.testing.expectError(error.BadPrevHash, fold.applyControl(&g.sl, &g.en));
    }
}

test "the control journal holds only control entries" {
    var fix = Fix.init();
    var fold = try controlWithGenesis(&fix);
    defer fold.deinit();
    const en = try fix.entryFor(.data, fix.control_id, 2, 0, "data in the control chain");
    const sl = try fix.slotFor(1, 2, entry.entryHash(&en), fold.head_slot_hash, 1001);
    try std.testing.expectError(error.WrongJournalType, fold.applyControl(&sl, &en));
}

test "create_journal registers the journal and enforces its rules" {
    var fix = Fix.init();
    var fold = try controlWithGenesis(&fix);
    defer fold.deinit();

    const mk_payload = struct {
        fn of(_: *const Fix, id: [16]u8, name: []const u8) ![]u8 {
            const buf = try test_alloc.alloc(
                u8,
                createJournalPayloadLen(.{ .journal_id = id, .name = name, .changes = &.{} }),
            );
            encodeCreateJournalPayload(
                .{ .journal_id = id, .name = name, .changes = &.{} },
                buf,
            ) catch |e| return e;
            return buf;
        }
    }.of;

    {
        const payload = try mk_payload(&fix, fix.data_id, "main");
        defer test_alloc.free(payload);
        const en = try fix.entryFor(.create_journal, fix.control_id, 2, 0, payload);
        const sl = try fix.slotFor(1, 2, entry.entryHash(&en), fold.head_slot_hash, 1001);
        try fold.applyControl(&sl, &en);
        try std.testing.expect(fold.journals.contains(fix.data_id));
    }
    {
        // Duplicate id.
        const payload = try mk_payload(&fix, fix.data_id, "other");
        defer test_alloc.free(payload);
        const en = try fix.entryFor(.create_journal, fix.control_id, 3, 0, payload);
        const sl = try fix.slotFor(1, 3, entry.entryHash(&en), fold.head_slot_hash, 1002);
        try std.testing.expectError(error.JournalExists, fold.applyControl(&sl, &en));
    }
    {
        // Empty name.
        const payload = try mk_payload(&fix, "fedcba9876543210".*, "");
        defer test_alloc.free(payload);
        const en = try fix.entryFor(.create_journal, fix.control_id, 3, 0, payload);
        const sl = try fix.slotFor(1, 3, entry.entryHash(&en), fold.head_slot_hash, 1002);
        try std.testing.expectError(error.BadJournalName, fold.applyControl(&sl, &en));
    }
    {
        // Past cluster.max_journals: lower the cap to 1 with a real
        // settings entry, then a second journal is refused.
        const max_journals = schema.keyIndex("cluster.max_journals").?;
        const changes = [_]validate.Change{.{ .key = max_journals, .value = .{ .u32 = 1 } }};
        const pl = SettingsPayload{
            .scope = .cluster,
            .journal_id = [_]u8{0} ** 16,
            .changes = &changes,
        };
        const pl_buf = try test_alloc.alloc(u8, settings_fold.payloadLen(pl));
        defer test_alloc.free(pl_buf);
        try settings_fold.encodePayload(pl, pl_buf);
        const en = try fix.entryFor(.settings, fix.control_id, 3, 0, pl_buf);
        const sl = try fix.slotFor(1, 3, entry.entryHash(&en), fold.head_slot_hash, 1002);
        try fold.applyControl(&sl, &en);

        const payload = try mk_payload(&fix, "fedcba9876543210".*, "second");
        defer test_alloc.free(payload);
        const en2 = try fix.entryFor(.create_journal, fix.control_id, 4, 0, payload);
        const sl2 = try fix.slotFor(1, 4, entry.entryHash(&en2), fold.head_slot_hash, 1003);
        try std.testing.expectError(error.TooManyJournals, fold.applyControl(&sl2, &en2));
    }
}

test "settings: cluster changes apply, frozen leadership refuses, bad keys name themselves" {
    var fix = Fix.init();
    var fold = try controlWithGenesis(&fix);
    defer fold.deinit();

    const mk_settings = struct {
        fn of(
            f: *const Fix,
            seq: u64,
            changes: []const validate.Change,
        ) !struct { payload: []u8, en: entry.Entry, sl: slot.Slot } {
            const pl = SettingsPayload{
                .scope = .cluster,
                .journal_id = [_]u8{0} ** 16,
                .changes = changes,
            };
            const buf = try test_alloc.alloc(u8, settings_fold.payloadLen(pl));
            try settings_fold.encodePayload(pl, buf);
            const en = try f.entryFor(.settings, f.control_id, seq, 0, buf);
            // The slot is built by the caller (it needs the fold's head).
            return .{ .payload = buf, .en = en, .sl = undefined };
        }
    }.of;

    // A live change to a non-leadership key is accepted.
    {
        const max_journals = schema.keyIndex("cluster.max_journals").?;
        const changes = [_]validate.Change{.{ .key = max_journals, .value = .{ .u32 = 64 } }};
        const m = try mk_settings(&fix, 2, &changes);
        defer test_alloc.free(m.payload);
        const sl = try fix.slotFor(1, 2, entry.entryHash(&m.en), fold.head_slot_hash, 1001);
        try fold.applyControl(&sl, &m.en);
        try std.testing.expectEqual(@as(u32, 64), fold.settings.getU32(max_journals));
    }

    // An unknown key is refused by name.
    {
        const bad = [_]validate.Change{.{ .key = 9999, .value = .{ .u64 = 1 } }};
        const m = try mk_settings(&fix, 3, &bad);
        defer test_alloc.free(m.payload);
        const sl = try nextControlSlot(&fix, &fold, entry.entryHash(&m.en), 1002);
        try std.testing.expectError(error.UnknownSetting, fold.applyControl(&sl, &m.en));
    }

    // A journal-scoped key inside a cluster-scoped entry refuses by scope.
    {
        const ttl = schema.keyIndex("ttl.enforce").?;
        const changes = [_]validate.Change{
            .{ .key = ttl, .value = .{ .enum_value = schema.enumValue(ttl, "all").? } },
        };
        const m = try mk_settings(&fix, 4, &changes);
        defer test_alloc.free(m.payload);
        const sl = try nextControlSlot(&fix, &fold, entry.entryHash(&m.en), 1003);
        try std.testing.expectError(error.ScopeMismatch, fold.applyControl(&sl, &m.en));
    }

    // leadership.mode changes while reconfigurable=false are refused.
    {
        const reconfigurable = schema.keyIndex("leadership.reconfigurable").?;
        const changes = [_]validate.Change{
            .{ .key = reconfigurable, .value = .{ .boolean = false } },
        };
        const m = try mk_settings(&fix, 5, &changes);
        defer test_alloc.free(m.payload);
        const sl = try nextControlSlot(&fix, &fold, entry.entryHash(&m.en), 1004);
        try fold.applyControl(&sl, &m.en);

        const mode = schema.keyIndex("leadership.mode").?;
        const mode_changes = [_]validate.Change{
            .{ .key = mode, .value = .{ .enum_value = schema.enumValue(mode, "configured").? } },
        };
        const m2 = try mk_settings(&fix, 6, &mode_changes);
        defer test_alloc.free(m2.payload);
        const sl2 = try nextControlSlot(&fix, &fold, entry.entryHash(&m2.en), 1005);
        try std.testing.expectError(error.NotLiveChangeable, fold.applyControl(&sl2, &m2.en));
    }
}

test "data entries: valid appends, and each refusal names its reason" {
    var fix = Fix.init();
    var cluster = try clusterWithDataJournal(&fix);
    defer {
        cluster.control.deinit();
        cluster.data.deinit();
    }

    // A valid append folds.
    try appendData(&fix, &cluster.control, &cluster.data, 0, "hello", 1002);
    try std.testing.expectEqual(@as(usize, 1), cluster.data.entries.count());
    const id = entry.Id{ .author = fix.founder_id, .author_seq = 1 };
    try std.testing.expect(cluster.data.entries.contains(id));

    // author_seq is monotone, gaps allowed (OQ 11): a hand-built seq 3
    // after seq 1 is accepted even though 2 was never written.
    const gap = try fix.entryFor(.data, fix.data_id, 3, 0, "gap");
    const gap_sl = try fix.slotFor(
        1,
        (cluster.data.head orelse slot.Position{ .epoch = 1, .seq = 0 }).seq + 1,
        entry.entryHash(&gap),
        cluster.data.head_slot_hash,
        1003,
    );
    try cluster.data.applyData(&cluster.control, &gap_sl, &gap);
    try std.testing.expect(cluster.data.entries.contains(.{
        .author = fix.founder_id,
        .author_seq = 3,
    }));

    // The same author_seq with a different payload is a conflict (dedup
    // is by recorded bytes, not by position).
    const conflict = try fix.entryFor(.data, fix.data_id, 3, 0, "different");
    const conflict_sl = try fix.slotFor(
        1,
        (cluster.data.head orelse slot.Position{ .epoch = 1, .seq = 0 }).seq + 1,
        entry.entryHash(&conflict),
        cluster.data.head_slot_hash,
        1004,
    );
    try std.testing.expectError(
        error.DuplicateConflict,
        cluster.data.applyData(&cluster.control, &conflict_sl, &conflict),
    );
    // A redelivery of an already-slotted entry (same id, same bytes) is an
    // idempotent accept — the unslotted-queue replay path after a crash.
    const redelivered = try fix.entryFor(.data, fix.data_id, 1, 0, "hello");
    const redelivered_sl = try fix.slotFor(
        1,
        cluster.data.head.?.seq + 1,
        entry.entryHash(&redelivered),
        cluster.data.head_slot_hash,
        1004,
    );
    try cluster.data.applyData(&cluster.control, &redelivered_sl, &redelivered);
}

test "data entries: a non-member cannot author, a tampered entry cannot pass" {
    var fix = Fix.init();
    var cluster = try clusterWithDataJournal(&fix);
    defer {
        cluster.control.deinit();
        cluster.data.deinit();
    }

    // A stranger's key is not a member.
    var io_state = std.Io.Threaded.init(test_alloc, .{});
    const stranger = crypto.sign.Ed25519.KeyPair.generate(io_state.io());
    const payload = "by a stranger";
    var en = entry.Entry{
        .kind = .data,
        .journal = fix.data_id,
        .author = deriveMemberId(stranger.public_key.toBytes()),
        .author_seq = 1,
        .author_ts_ms = 0,
        .ttl_ms = 0,
        .payload_hash = entry.payloadHash(payload),
        .payload_len = @intCast(payload.len),
        .payload_omitted = false,
        .signature = undefined,
        .payload = payload,
    };
    en.signature = (try entry.sign(stranger, &en)).toBytes();
    const sl = try fix.slotFor(1, 1, entry.entryHash(&en), cluster.data.head_slot_hash, 1002);
    try std.testing.expectError(
        error.UnknownAuthor,
        cluster.data.applyData(&cluster.control, &sl, &en),
    );

    // A signed entry whose payload is swapped fails the payload hash.
    const original = try fix.entryFor(.data, fix.data_id, 1, 0, "original");
    const tampered = entry.Entry{
        .kind = original.kind,
        .journal = original.journal,
        .author = original.author,
        .author_seq = original.author_seq,
        .author_ts_ms = original.author_ts_ms,
        .ttl_ms = original.ttl_ms,
        .payload_hash = original.payload_hash,
        .payload_len = original.payload_len,
        .payload_omitted = false,
        .signature = original.signature,
        .payload = "TAMPERED",
    };
    const sl2 = try fix.slotFor(
        1,
        1,
        entry.entryHash(&tampered),
        cluster.data.head_slot_hash,
        1002,
    );
    try std.testing.expectError(
        error.BadPayloadHash,
        cluster.data.applyData(&cluster.control, &sl2, &tampered),
    );

    // An entry naming another journal is refused by chain.
    const other = try fix.entryFor(.data, "deadbeefdeadbeef".*, 1, 0, "other journal");
    const sl3 = try fix.slotFor(1, 1, entry.entryHash(&other), cluster.data.head_slot_hash, 1002);
    try std.testing.expectError(
        error.WrongJournal,
        cluster.data.applyData(&cluster.control, &sl3, &other),
    );
}

test "an oversized payload is refused with too_large before anything is folded" {
    var fix = Fix.init();
    var cluster = try clusterWithDataJournal(&fix);
    defer {
        cluster.control.deinit();
        cluster.data.deinit();
    }
    const max_bytes = schema.keyIndex("journal.max_entry_bytes").?;
    try cluster.data.settings.set(max_bytes, .{ .u64 = 8 });
    const head_before = cluster.data.head;
    const head_hash_before = cluster.data.head_slot_hash;
    const entry_count_before = cluster.data.entries.count();
    try std.testing.expectError(
        error.TooLarge,
        appendData(&fix, &cluster.control, &cluster.data, 0, "0123456789", 1002),
    );
    try std.testing.expectEqual(head_before, cluster.data.head);
    try std.testing.expectEqualSlices(u8, &head_hash_before, &cluster.data.head_slot_hash);
    try std.testing.expectEqual(entry_count_before, cluster.data.entries.count());
}

test "chain continuity: bad prev, gapped seq, and backwards clocks are refused" {
    var fix = Fix.init();
    var cluster = try clusterWithDataJournal(&fix);
    defer {
        cluster.control.deinit();
        cluster.data.deinit();
    }
    try appendData(&fix, &cluster.control, &cluster.data, 0, "a", 1002);

    const en = try fix.entryFor(.data, fix.data_id, 2, 0, "b");
    // Bad prev hash.
    var sl = try fix.slotFor(1, 2, entry.entryHash(&en), [_]u8{1} ** 32, 1003);
    try std.testing.expectError(
        error.BadPrevHash,
        cluster.data.applyData(&cluster.control, &sl, &en),
    );
    // A gapped slot seq.
    sl = try fix.slotFor(1, 3, entry.entryHash(&en), cluster.data.head_slot_hash, 1003);
    try std.testing.expectError(
        error.BadPosition,
        cluster.data.applyData(&cluster.control, &sl, &en),
    );
    // A backwards slot clock.
    sl = try fix.slotFor(1, 2, entry.entryHash(&en), cluster.data.head_slot_hash, 1001);
    try std.testing.expectError(
        error.BadTimestamp,
        cluster.data.applyData(&cluster.control, &sl, &en),
    );
}

test "stale: gated by enforce, author-only, idempotent (PRD 0002 G3, G7)" {
    var fix = Fix.init();
    var cluster = try clusterWithDataJournal(&fix);
    defer {
        cluster.control.deinit();
        cluster.data.deinit();
    }
    try appendData(&fix, &cluster.control, &cluster.data, 0, "target", 1002);

    const target_id = entry.Id{ .author = fix.founder_id, .author_seq = 1 };

    // While stale.enforce = off (the default), a stale entry is refused.
    {
        const payload: [24]u8 = undefined;
        var buf: [24]u8 = undefined;
        encodeStalePayload(.{ .target = target_id }, &buf);
        _ = payload;
        const en = try fix.entryFor(.stale, fix.data_id, 2, 0, &buf);
        const sl = try fix.slotFor(1, 2, entry.entryHash(&en), cluster.data.head_slot_hash, 1003);
        try std.testing.expectError(
            error.StalenessDisabled,
            cluster.data.applyData(&cluster.control, &sl, &en),
        );
    }

    // Enable author-marked staleness.
    const stale_enforce = schema.keyIndex("stale.enforce").?;
    const changes = [_]validate.Change{
        .{ .key = stale_enforce, .value = .{
            .enum_value = schema.enumValue(stale_enforce, "author").?,
        } },
    };
    const pl = SettingsPayload{ .scope = .journal, .journal_id = fix.data_id, .changes = &changes };
    const pl_buf = try test_alloc.alloc(u8, settings_fold.payloadLen(pl));
    defer test_alloc.free(pl_buf);
    try settings_fold.encodePayload(pl, pl_buf);
    const en_s = try fix.entryFor(.settings, fix.data_id, 2, 0, pl_buf);
    const sl_s = try fix.slotFor(1, 2, entry.entryHash(&en_s), cluster.data.head_slot_hash, 1003);
    try cluster.data.applyData(&cluster.control, &sl_s, &en_s);

    // A stale for the author's own entry is accepted and marks it.
    {
        var buf: [24]u8 = undefined;
        encodeStalePayload(.{ .target = target_id }, &buf);
        const en = try fix.entryFor(.stale, fix.data_id, 3, 0, &buf);
        const sl = try fix.slotFor(1, 3, entry.entryHash(&en), cluster.data.head_slot_hash, 1004);
        try cluster.data.applyData(&cluster.control, &sl, &en);
        try std.testing.expect(cluster.data.entries.get(target_id).?.stale_marked);
    }

    // A stale for someone else's entry is refused with not_author. The
    // target is authored by the founder; a stranger's stale for it fails
    // before the author check (unknown author), so forge the author instead:
    // an entry by the founder targeting a NON-member's entry id.
    {
        var buf: [24]u8 = undefined;
        encodeStalePayload(.{ .target = .{ .author = [_]u8{0xBB} ** 16, .author_seq = 1 } }, &buf);
        const en = try fix.entryFor(.stale, fix.data_id, 4, 0, &buf);
        const sl = try fix.slotFor(1, 4, entry.entryHash(&en), cluster.data.head_slot_hash, 1005);
        try std.testing.expectError(
            error.NotAuthor,
            cluster.data.applyData(&cluster.control, &sl, &en),
        );
    }

    // A stale for an unknown entry is refused with unknown_target.
    {
        var buf: [24]u8 = undefined;
        encodeStalePayload(.{ .target = .{ .author = fix.founder_id, .author_seq = 99 } }, &buf);
        const en = try fix.entryFor(.stale, fix.data_id, 4, 0, &buf);
        const sl = try fix.slotFor(1, 4, entry.entryHash(&en), cluster.data.head_slot_hash, 1005);
        try std.testing.expectError(
            error.UnknownTarget,
            cluster.data.applyData(&cluster.control, &sl, &en),
        );
    }

    // Re-marking an already-stale entry is an accepted no-op.
    {
        var buf: [24]u8 = undefined;
        encodeStalePayload(.{ .target = target_id }, &buf);
        const en = try fix.entryFor(.stale, fix.data_id, 4, 0, &buf);
        const sl = try fix.slotFor(1, 4, entry.entryHash(&en), cluster.data.head_slot_hash, 1005);
        try cluster.data.applyData(&cluster.control, &sl, &en);
    }
}

test "checkpoint: removes expired entries deterministically, and validates its range" {
    var fix = Fix.init();
    var cluster = try clusterWithDataJournal(&fix);
    defer {
        cluster.control.deinit();
        cluster.data.deinit();
    }

    // ttl.enforce=all, default 1000 ms, action=delete.
    const enforce = schema.keyIndex("ttl.enforce").?;
    const ttl_default = schema.keyIndex("ttl.default_ms").?;
    const ttl_action = schema.keyIndex("ttl.action").?;
    const changes = [_]validate.Change{
        .{ .key = enforce, .value = .{ .enum_value = schema.enumValue(enforce, "all").? } },
        .{ .key = ttl_default, .value = .{ .u64 = 1000 } },
        .{ .key = ttl_action, .value = .{
            .enum_value = schema.enumValue(ttl_action, "delete").?,
        } },
    };
    const pl = SettingsPayload{ .scope = .journal, .journal_id = fix.data_id, .changes = &changes };
    const pl_buf = try test_alloc.alloc(u8, settings_fold.payloadLen(pl));
    defer test_alloc.free(pl_buf);
    try settings_fold.encodePayload(pl, pl_buf);
    try appendControl(&fix, &cluster.control, &cluster.data, .settings, pl_buf, 1000);

    // Entry slotted at ts 2000, expires at 3000; checkpoint at ts 4000
    // removes it.
    try appendData(&fix, &cluster.control, &cluster.data, 0, "expiring", 2000);
    const expiring_id = entry.Id{ .author = fix.founder_id, .author_seq = 2 };
    try std.testing.expectEqual(
        @as(?u64, 3000),
        cluster.data.entries.get(expiring_id).?.expires_at_ms,
    );

    var cp_buf: [16]u8 = undefined;
    encodeCheckpointPayload(.{ .expire_through = .{ .epoch = 1, .seq = 2 } }, &cp_buf);
    try appendControl(&fix, &cluster.control, &cluster.data, .checkpoint, &cp_buf, 4000);
    try std.testing.expect(cluster.data.entries.get(expiring_id).?.removed);

    // A checkpoint past its own slot is refused.
    var bad_cp: [16]u8 = undefined;
    encodeCheckpointPayload(.{ .expire_through = .{ .epoch = 1, .seq = 99 } }, &bad_cp);
    try std.testing.expectError(
        error.BadCheckpoint,
        appendControl(&fix, &cluster.control, &cluster.data, .checkpoint, &bad_cp, 4001),
    );
}

test "a settings change applies only to slots after it (PRD 0004 G4)" {
    var fix = Fix.init();
    var cluster = try clusterWithDataJournal(&fix);
    defer {
        cluster.control.deinit();
        cluster.data.deinit();
    }

    // Before the change (enforce=off): no expiry instant is computed.
    try appendData(&fix, &cluster.control, &cluster.data, 0, "before", 1000);
    const before_id = entry.Id{ .author = fix.founder_id, .author_seq = 1 };
    try std.testing.expectEqual(
        @as(?u64, null),
        cluster.data.entries.get(before_id).?.expires_at_ms,
    );

    // Turn enforcement on; only later slots get an expiry instant.
    const enforce = schema.keyIndex("ttl.enforce").?;
    const ttl_default = schema.keyIndex("ttl.default_ms").?;
    const changes = [_]validate.Change{
        .{ .key = enforce, .value = .{ .enum_value = schema.enumValue(enforce, "all").? } },
        .{ .key = ttl_default, .value = .{ .u64 = 5000 } },
    };
    const pl = SettingsPayload{ .scope = .journal, .journal_id = fix.data_id, .changes = &changes };
    const pl_buf = try test_alloc.alloc(u8, settings_fold.payloadLen(pl));
    defer test_alloc.free(pl_buf);
    try settings_fold.encodePayload(pl, pl_buf);
    try appendControl(&fix, &cluster.control, &cluster.data, .settings, pl_buf, 2000);

    try appendData(&fix, &cluster.control, &cluster.data, 0, "after", 2000);
    const after_id = entry.Id{ .author = fix.founder_id, .author_seq = 3 };
    try std.testing.expectEqual(
        @as(?u64, 7000),
        cluster.data.entries.get(after_id).?.expires_at_ms,
    );
    // The earlier entry keeps no expiry instant: nothing retroactive.
    try std.testing.expectEqual(
        @as(?u64, null),
        cluster.data.entries.get(before_id).?.expires_at_ms,
    );
}

test "membership kinds belong to the control chain, never a data journal" {
    var fix = Fix.init();
    var cluster = try clusterWithDataJournal(&fix);
    defer {
        cluster.control.deinit();
        cluster.data.deinit();
    }
    for ([_]entry.Kind{ .join, .leave, .epoch, .merge }) |kind| {
        const en = try fix.entryFor(kind, fix.data_id, 2, 0, "payload");
        const sl = try fix.slotFor(
            1,
            1,
            entry.entryHash(&en),
            cluster.data.head_slot_hash,
            1002,
        );
        try std.testing.expectError(
            error.WrongJournalType,
            cluster.data.applyData(&cluster.control, &sl, &en),
        );
    }
}

test "a non-leader is refused when the fold names a different leader" {
    var fix = Fix.init();
    var fold = try controlWithGenesis(&fix);
    defer fold.deinit();

    // Fabricate a second member (as a join entry would, in PRD 0003) and
    // make it the leader; the founder's entries then fail the leader check.
    var io_state = std.Io.Threaded.init(test_alloc, .{});
    const second = crypto.sign.Ed25519.KeyPair.generate(io_state.io());
    const second_id = deriveMemberId(second.public_key.toBytes());
    try fold.members.append(test_alloc, .{
        .id = second_id,
        .public_key = second.public_key.toBytes(),
        .seniority = .{ .epoch = 1, .seq = 2 },
        .address = try test_alloc.dupe(u8, ""),
    });
    fold.epoch = .{ .number = 2, .leader = second_id, .reason = "test" };

    const payload = "not the leader's";
    const en = try fix.entryFor(.settings, fix.control_id, 2, 0, payload);
    const sl = try fix.slotFor(1, 2, entry.entryHash(&en), fold.head_slot_hash, 1002);
    try std.testing.expectError(error.NotLeader, fold.applyControl(&sl, &en));
}

test "fold hash is deterministic over the same chain and changes with it" {
    var fix = Fix.init();
    var cluster = try clusterWithDataJournal(&fix);
    defer {
        cluster.control.deinit();
        cluster.data.deinit();
    }
    try appendData(&fix, &cluster.control, &cluster.data, 0, "one", 1002);
    try appendData(&fix, &cluster.control, &cluster.data, 0, "two", 1003);

    const h1 = try cluster.control.hash(test_alloc);
    const h2 = try cluster.data.hash(test_alloc);

    // A second fold of the same chain (replay from genesis) matches: build
    // a fresh cluster and append the identical chain.
    var fresh = try clusterWithDataJournal(&fix);
    defer {
        fresh.control.deinit();
        fresh.data.deinit();
    }
    try appendData(&fix, &fresh.control, &fresh.data, 0, "one", 1002);
    try appendData(&fix, &fresh.control, &fresh.data, 0, "two", 1003);
    try std.testing.expectEqualSlices(u8, &h1, &(try fresh.control.hash(test_alloc)));
    try std.testing.expectEqualSlices(u8, &h2, &(try fresh.data.hash(test_alloc)));

    // A different payload changes the data fold's hash.
    try appendData(&fix, &cluster.control, &cluster.data, 0, "three", 1004);
    const h3 = try cluster.data.hash(test_alloc);
    try std.testing.expect(!std.mem.eql(u8, &h2, &h3));
}

test "control payload codecs round-trip" {
    const changes = [_]validate.Change{
        .{ .key = schema.keyIndex("cluster.max_journals").?, .value = .{ .u32 = 42 } },
    };
    const g = GenesisPayload{ .founder_key = [_]u8{7} ** 32, .changes = &changes };
    const g_buf = try test_alloc.alloc(u8, genesisPayloadLen(g));
    defer test_alloc.free(g_buf);
    try encodeGenesisPayload(g, g_buf);
    var g2 = try decodeGenesisPayload(test_alloc, g_buf);
    defer g2.deinit(test_alloc);
    try std.testing.expectEqualSlices(u8, &g.founder_key, &g2.founder_key);
    try std.testing.expectEqual(@as(usize, 1), g2.changes.len);

    const ttl_default = schema.keyIndex("ttl.default_ms").?;
    const j_changes = [_]validate.Change{
        .{ .key = ttl_default, .value = .{ .u64 = 1000 } },
    };
    const cj = CreateJournalPayload{
        .journal_id = [_]u8{9} ** 16,
        .name = "main",
        .changes = &j_changes,
    };
    const cj_buf = try test_alloc.alloc(u8, createJournalPayloadLen(cj));
    defer test_alloc.free(cj_buf);
    try encodeCreateJournalPayload(cj, cj_buf);
    var cj2 = try decodeCreateJournalPayload(test_alloc, cj_buf);
    defer cj2.deinit(test_alloc);
    try std.testing.expectEqualSlices(u8, &cj.journal_id, &cj2.journal_id);
    try std.testing.expectEqualStrings("main", cj2.name);

    var stale_buf: [24]u8 = undefined;
    encodeStalePayload(.{ .target = .{ .author = [_]u8{1} ** 16, .author_seq = 5 } }, &stale_buf);
    const stale = try decodeStalePayload(&stale_buf);
    try std.testing.expectEqual(@as(u64, 5), stale.target.author_seq);

    var cp_buf: [16]u8 = undefined;
    encodeCheckpointPayload(.{ .expire_through = .{ .epoch = 2, .seq = 3 } }, &cp_buf);
    const cp = try decodeCheckpointPayload(&cp_buf);
    try std.testing.expectEqual(@as(u64, 2), cp.expire_through.epoch);
    try std.testing.expectEqual(@as(u64, 3), cp.expire_through.seq);
}

test "a create-journal name past the u16 codec cap is refused at encode" {
    // Bug 2026-08-29-create-journal-name-codec-overflow: the name-length
    // field is u16, so a name of 65,536 bytes used to panic in debug via
    // an unchecked @intCast (and wrap in release).
    const big = try test_alloc.alloc(u8, 65_536);
    defer test_alloc.free(big);
    @memset(big, 'a');
    const payload = CreateJournalPayload{
        .journal_id = [_]u8{9} ** 16,
        .name = big,
        .changes = &.{},
    };
    const buf = try test_alloc.alloc(u8, createJournalPayloadLen(payload));
    defer test_alloc.free(buf);
    try std.testing.expectError(
        error.SettingsTooLarge,
        encodeCreateJournalPayload(payload, buf),
    );
}

test "a re-slotted control entry is inferred from its author and epoch (OQ 33 replay)" {
    var fix = Fix.init();
    var fold = try controlWithGenesis(&fix);
    defer fold.deinit();

    var io_state = std.Io.Threaded.init(test_alloc, .{});
    const second = crypto.sign.Ed25519.KeyPair.generate(io_state.io());
    const second_id = deriveMemberId(second.public_key.toBytes());

    // The second member joins (admitted by the founder).
    const join_payload = try test_alloc.alloc(
        u8,
        membership.joinPayloadLen(.{
            .member_id = second_id,
            .public_key = second.public_key.toBytes(),
            .address = "node-2",
        }),
    );
    defer test_alloc.free(join_payload);
    membership.encodeJoinPayload(
        .{
            .member_id = second_id,
            .public_key = second.public_key.toBytes(),
            .address = "node-2",
        },
        join_payload,
    );
    const join_en = try fix.entryFor(.join, fix.control_id, 2, 0, join_payload);
    const join_sl = try fix.slotFor(1, 2, entry.entryHash(&join_en), fold.head_slot_hash, 1001);
    try fold.applyControl(&join_sl, &join_en);

    // The founder (leader) changes a setting live; the live rule applies it.
    // The key is cluster-scoped — a cluster settings entry cannot touch a
    // journal-scoped key (fold.zig's scope filter).
    const heartbeat = schema.keyIndex("cluster.heartbeat_ms").?;
    const settings_payload = try test_alloc.alloc(
        u8,
        settings_fold.payloadLen(.{
            .scope = .cluster,
            .journal_id = [_]u8{0} ** 16,
            .changes = &[_]validate.Change{.{ .key = heartbeat, .value = .{ .u64 = 5000 } }},
        }),
    );
    defer test_alloc.free(settings_payload);
    try settings_fold.encodePayload(
        .{
            .scope = .cluster,
            .journal_id = [_]u8{0} ** 16,
            .changes = &[_]validate.Change{.{ .key = heartbeat, .value = .{ .u64 = 5000 } }},
        },
        settings_payload,
    );
    const live_en = try fix.entryFor(.settings, fix.control_id, 3, 0, settings_payload);
    const live_sl = try fix.slotFor(1, 3, entry.entryHash(&live_en), fold.head_slot_hash, 1002);
    try fold.applyControl(&live_sl, &live_en);
    try std.testing.expectEqual(@as(u64, 5000), fold.settings.getU64(heartbeat));

    // A merge re-slot: the losing branch's settings entry, authored by the
    // second member and re-slotted by the founder at the current epoch. The
    // live rule would refuse it (not the leader); the re-slot inference
    // applies it as a no-op — the survivor's value wins (OQ 33).
    const other_payload = try test_alloc.alloc(
        u8,
        settings_fold.payloadLen(.{
            .scope = .cluster,
            .journal_id = [_]u8{0} ** 16,
            .changes = &[_]validate.Change{.{ .key = heartbeat, .value = .{ .u64 = 9000 } }},
        }),
    );
    defer test_alloc.free(other_payload);
    try settings_fold.encodePayload(
        .{
            .scope = .cluster,
            .journal_id = [_]u8{0} ** 16,
            .changes = &[_]validate.Change{.{ .key = heartbeat, .value = .{ .u64 = 9000 } }},
        },
        other_payload,
    );
    var re_en = entry.Entry{
        .kind = .settings,
        .journal = fix.control_id,
        .author = second_id,
        .author_seq = 1,
        .author_ts_ms = 0,
        .ttl_ms = 0,
        .payload_hash = entry.payloadHash(other_payload),
        .payload_len = @intCast(other_payload.len),
        .payload_omitted = false,
        .signature = undefined,
        .payload = other_payload,
    };
    re_en.signature = (try entry.sign(second, &re_en)).toBytes();
    const re_sl = try fix.slotFor(1, 4, entry.entryHash(&re_en), fold.head_slot_hash, 1003);
    try fold.applyControl(&re_sl, &re_en);
    try std.testing.expectEqual(@as(u64, 5000), fold.settings.getU64(heartbeat));
    try std.testing.expect(fold.entries.get(re_en.id()) != null);

    // A re-slotted epoch at the current number is a no-op too: the losing
    // branch's epoch entry names the second member, but the founder's term
    // survives.
    var epoch_buf: [epoch.epoch_payload_len]u8 = undefined;
    epoch.encodeEpochPayload(
        .{ .number = 1, .reason = .leader_lost, .leader = second_id },
        &epoch_buf,
    );
    var ep_en = entry.Entry{
        .kind = .epoch,
        .journal = fix.control_id,
        .author = second_id,
        .author_seq = 2,
        .author_ts_ms = 0,
        .ttl_ms = 0,
        .payload_hash = entry.payloadHash(&epoch_buf),
        .payload_len = epoch.epoch_payload_len,
        .payload_omitted = false,
        .signature = undefined,
        .payload = &epoch_buf,
    };
    ep_en.signature = (try entry.sign(second, &ep_en)).toBytes();
    const ep_sl = try fix.slotFor(1, 5, entry.entryHash(&ep_en), fold.head_slot_hash, 1004);
    try fold.applyControl(&ep_sl, &ep_en);
    try std.testing.expectEqual(@as(u64, 1), fold.epoch.?.number);
    try std.testing.expectEqualSlices(u8, &fix.founder_id, &fold.epoch.?.leader);
}

test "a re-slotted create_journal is accepted and registers the journal" {
    // Bug 2026-08-28-reslotted-create-journal-refused: the re-slot routing
    // sent every non-leader-authored create_journal to the live rule, whose
    // author check can never hold for a re-slot — the author is the losing
    // branch's leader, not the survivor's — so the merge stalled whenever
    // the losing branch had created a journal during the partition.
    var fix = Fix.init();
    var fold = try controlWithGenesis(&fix);
    defer fold.deinit();

    var io_state = std.Io.Threaded.init(test_alloc, .{});
    const second = crypto.sign.Ed25519.KeyPair.generate(io_state.io());
    const second_id = deriveMemberId(second.public_key.toBytes());

    // The second member joins (admitted by the founder).
    const join_payload = try test_alloc.alloc(
        u8,
        membership.joinPayloadLen(.{
            .member_id = second_id,
            .public_key = second.public_key.toBytes(),
            .address = "node-2",
        }),
    );
    defer test_alloc.free(join_payload);
    membership.encodeJoinPayload(
        .{
            .member_id = second_id,
            .public_key = second.public_key.toBytes(),
            .address = "node-2",
        },
        join_payload,
    );
    const join_en = try fix.entryFor(.join, fix.control_id, 2, 0, join_payload);
    const join_sl = try fix.slotFor(1, 2, entry.entryHash(&join_en), fold.head_slot_hash, 1001);
    try fold.applyControl(&join_sl, &join_en);

    // The losing branch's create_journal, re-slotted by the survivor. The
    // payload, name and max-journals rules still run; only the author check
    // is relaxed (the bytes are already signature-checked against the
    // member table).
    const new_journal_id = "fedcba9876543210".*;
    const cj_payload = try test_alloc.alloc(
        u8,
        createJournalPayloadLen(.{ .journal_id = new_journal_id, .name = "side", .changes = &.{} }),
    );
    defer test_alloc.free(cj_payload);
    try encodeCreateJournalPayload(
        .{ .journal_id = new_journal_id, .name = "side", .changes = &.{} },
        cj_payload,
    );
    var cj_en = entry.Entry{
        .kind = .create_journal,
        .journal = fix.control_id,
        .author = second_id,
        .author_seq = 1,
        .author_ts_ms = 0,
        .ttl_ms = 0,
        .payload_hash = entry.payloadHash(cj_payload),
        .payload_len = @intCast(cj_payload.len),
        .payload_omitted = false,
        .signature = undefined,
        .payload = cj_payload,
    };
    cj_en.signature = (try entry.sign(second, &cj_en)).toBytes();
    const cj_sl = try fix.slotFor(1, 3, entry.entryHash(&cj_en), fold.head_slot_hash, 1002);
    try fold.applyControl(&cj_sl, &cj_en);
    try std.testing.expect(fold.journals.contains(new_journal_id));
    try std.testing.expect(fold.entries.get(cj_en.id()) != null);
}

test "a checkpoint inside merge.settle_ms of a real merge entry is refused" {
    // Bug 2026-08-28-merge-settle-rule-dead: applyCheckpoint read the data
    // fold's last_merge, which no code ever sets — the merge fact lives on
    // the control fold. A real merge entry folds here, then a data
    // checkpoint within settle_ms must be refused.
    var fix = Fix.init();
    var cluster = try clusterWithDataJournal(&fix);
    defer {
        cluster.control.deinit();
        cluster.data.deinit();
    }

    var merge_buf: [16]u8 = undefined;
    epoch.encodeMergePayload(.{ .branch_epoch = 1, .branch_seq = 2 }, &merge_buf);
    const merge_en = try fix.entryFor(.merge, fix.control_id, 3, 0, &merge_buf);
    const merge_sl = try fix.slotFor(
        1,
        3,
        entry.entryHash(&merge_en),
        cluster.control.head_slot_hash,
        2000,
    );
    try cluster.control.applyControl(&merge_sl, &merge_en);
    try std.testing.expect(cluster.control.last_merge != null);

    var cp_buf: [16]u8 = undefined;
    encodeCheckpointPayload(.{ .expire_through = .{ .epoch = 1, .seq = 1 } }, &cp_buf);
    const cp_en = try fix.entryFor(
        .checkpoint,
        fix.data_id,
        nextAuthorSeq(&cluster.data, fix.founder_id),
        0,
        &cp_buf,
    );
    // 3000 ms after the merge's slot: inside settle_ms (default 30000).
    const cp_sl = try fix.slotFor(1, 1, entry.entryHash(&cp_en), slot.genesis_prev, 5000);
    try std.testing.expectError(
        error.MergeSettling,
        cluster.data.applyData(&cluster.control, &cp_sl, &cp_en),
    );

    // Once settle_ms has passed, the same checkpoint is accepted.
    const late_sl = try fix.slotFor(1, 1, entry.entryHash(&cp_en), slot.genesis_prev, 40_000);
    try cluster.data.applyData(&cluster.control, &late_sl, &cp_en);
}

test "a redelivery below the author's last_seq does not lower it" {
    // Bug 2026-08-28-redelivery-lowers-author-seq: registerEntry wrote
    // last_seq unconditionally, so a redelivered old entry lowered the
    // high-water mark and a *conflicting* entry between the lowered mark
    // and the true last seq passed the seq check without any dedup
    // comparison.
    var fix = Fix.init();
    var cluster = try clusterWithDataJournal(&fix);
    defer {
        cluster.control.deinit();
        cluster.data.deinit();
    }
    const j = fix.data_id;

    const e1 = try fix.entryFor(.data, j, 5, 0, "one");
    const e2 = try fix.entryFor(.data, j, 6, 0, "two");
    const sl1 = try fix.slotFor(1, 1, entry.entryHash(&e1), slot.genesis_prev, 1000);
    const sl2 = try fix.slotFor(1, 2, entry.entryHash(&e2), slot.slotHash(&sl1), 1001);
    try cluster.data.applyData(&cluster.control, &sl1, &e1);
    try cluster.data.applyData(&cluster.control, &sl2, &e2);

    // A re-slot redelivers E1 (byte-identical) at a new position.
    const sl1r = try fix.slotFor(1, 3, entry.entryHash(&e1), slot.slotHash(&sl2), 1002);
    try cluster.data.applyData(&cluster.control, &sl1r, &e1);

    // A conflicting entry with E2's id must still be refused: the
    // redelivery must not have lowered the high-water mark below 6.
    const e2_conflict = try fix.entryFor(.data, j, 6, 0, "conflict");
    const sl4 = try fix.slotFor(
        1,
        4,
        entry.entryHash(&e2_conflict),
        slot.slotHash(&sl1r),
        1003,
    );
    try std.testing.expectError(
        error.DuplicateConflict,
        cluster.data.applyData(&cluster.control, &sl4, &e2_conflict),
    );
}
