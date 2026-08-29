//! TTL and staleness: the only two mutations (PRD 0002).
//!
//! Everything here is pure and I/O-free so it can be unit-tested and later
//! driven by the deterministic simulator (OQ 27). The rules in one line:
//!
//! - The time basis is the **slot**, never the author: an entry's expiry
//!   instant is `slot_ts_ms + effective TTL`, computed from the settings in
//!   force at the entry's slot — a `settings` entry takes effect only for
//!   slots after it, so enabling a cause can never retroactively remove
//!   entries appended before.
//! - Soft expiry (what a read hides) is a local-clock function of `now` and
//!   affects visibility on one member only, never bytes.
//! - Hard removal is a chain event: a checkpoint names a slot and the
//!   removal set below is computed from the fold, identically on every
//!   member.
//!
//! State machine (no arrow points backwards):
//!
//!   live --author stale--> stale --checkpoint (if stale.cleanup=delete)--> removed
//!   live --ttl reached, action=mark_stale--> stale --checkpoint (if delete)--> removed
//!   live --ttl reached, action=delete--> expired --checkpoint--> removed

const std = @import("std");
const schema = @import("../settings/schema.zig");
const entry = @import("entry.zig");
const slot = @import("slot.zig");

/// What expiry does at the expiry instant, per the journal's `ttl.action`
/// in force when the entry was slotted.
pub const TtlAction = enum {
    mark_stale,
    delete,
};

pub const k_ttl_enforce = schema.keyIndex("ttl.enforce").?;
pub const k_ttl_default = schema.keyIndex("ttl.default_ms").?;
pub const k_ttl_max = schema.keyIndex("ttl.max_ms").?;
pub const k_ttl_action = schema.keyIndex("ttl.action").?;
pub const k_stale_cleanup = schema.keyIndex("stale.cleanup").?;

/// The effective TTL for an entry, per the enforce x entry-ttl matrix
/// (PRD 0002). `null` means the entry never expires.
pub fn effectiveTtl(entry_ttl_ms: u64, settings: *const schema.SettingsState) ?u64 {
    const enforce = settings.getEnum(k_ttl_enforce);
    if (std.mem.eql(u8, enforce, "off")) return null;
    const requested: u64 = if (entry_ttl_ms > 0)
        entry_ttl_ms
    else if (std.mem.eql(u8, enforce, "per_entry"))
        return null // no TTL on the entry, per_entry: never expires
    else
        settings.getU64(k_ttl_default); // enforce=all: the journal's default
    const max_ms = settings.getU64(k_ttl_max);
    // 0 = unbounded; a larger ask is clamped to the cap.
    return if (max_ms == 0) requested else @min(requested, max_ms);
}

/// The expiry instant: `slot_ts_ms + effective TTL` (saturating), or null
/// for an entry that never expires.
pub fn expiresAt(slot_ts_ms: u64, entry_ttl_ms: u64, settings: *const schema.SettingsState) ?u64 {
    const ttl = effectiveTtl(entry_ttl_ms, settings) orelse return null;
    return slot_ts_ms +| ttl;
}

/// The expiry action in force for the entry's settings.
pub fn action(settings: *const schema.SettingsState) TtlAction {
    return if (std.mem.eql(u8, settings.getEnum(k_ttl_action), "delete"))
        .delete
    else
        .mark_stale;
}

/// Whether an entry that was never removed reads as stale at local time
/// `now`: author-marked, or past its expiry instant under `mark_stale`.
/// `grace_ms` is the read-side skew tolerance (expiry instant <= now - grace).
pub fn isStale(
    expires_at: ?u64,
    ttl_action: TtlAction,
    stale_marked: bool,
    now: u64,
    grace_ms: u64,
) bool {
    if (stale_marked) return true;
    if (ttl_action != .mark_stale) return false;
    const at = expires_at orelse return false;
    return at <= now -| grace_ms;
}

/// Whether an entry that was never removed reads as expired at local time
/// `now`: past its expiry instant under `delete`, awaiting a checkpoint.
pub fn isExpired(
    expires_at: ?u64,
    ttl_action: TtlAction,
    now: u64,
    grace_ms: u64,
) bool {
    if (ttl_action != .delete) return false;
    const at = expires_at orelse return false;
    return at <= now -| grace_ms;
}

/// The four states of PRD 0002's diagram, as a read sees them at `now`.
pub const EntryState = enum { live, stale, expired, removed };

pub fn state(
    removed: bool,
    expires_at: ?u64,
    ttl_action: TtlAction,
    stale_marked: bool,
    now: u64,
    grace_ms: u64,
) EntryState {
    if (removed) return .removed;
    if (isStale(expires_at, ttl_action, stale_marked, now, grace_ms)) return .stale;
    if (isExpired(expires_at, ttl_action, now, grace_ms)) return .expired;
    return .live;
}

/// Whether default reads should show the entry at `now`; the `include_*`
/// flags reveal hidden-but-present entries (PRD 0002 goal 5).
pub fn isVisible(
    removed: bool,
    expires_at: ?u64,
    ttl_action: TtlAction,
    stale_marked: bool,
    now: u64,
    grace_ms: u64,
    include_stale: bool,
    include_expired: bool,
) bool {
    if (removed) return false;
    if (isStale(expires_at, ttl_action, stale_marked, now, grace_ms)) return include_stale;
    if (isExpired(expires_at, ttl_action, now, grace_ms)) return include_expired;
    return true;
}

/// A slot the fold has seen, with the facts a checkpoint needs: the entry's
/// id, its position, the leader's stamp, and the expiry/stale facts.
pub const SlottedEntry = struct {
    id: entry.Id,
    position: slot.Position,
    slot_ts_ms: u64,
    expires_at: ?u64,
    ttl_action: TtlAction,
    stale_marked: bool,
    stale_position: ?slot.Position,
};

/// Whether any removal is possible at all, so callers can skip the
/// O(entries) `expiryCandidates` + `removalSet` computation entirely (the
/// common default configuration, where nothing can ever be removed).
///
/// The two flags come from the fold and summarise the *frozen* facts
/// `removalSet` decides on: an entry's `expires_at` and `ttl_action` are
/// stamped when it is slotted and never revised. Reading `ttl.enforce`
/// here instead was wrong for exactly that reason - a journal switched
/// back to `ttl.enforce = off` still holds entries stamped `.delete` with
/// an expiry instant, and the skip made them permanently unremovable
/// (bug 2026-08-30-removal-guard-reads-live-settings).
///
/// - `expiry_deletes`: some entry is stamped `ttl_action = delete` with an
///   expiry instant. Such an entry is removable whatever the settings say
///   now, so this alone answers yes.
/// - `stale_removable`: some entry is author-marked stale, or is stamped
///   `mark_stale` with an expiry instant. Those are removable only while
///   `stale.cleanup = delete`, which is a live setting the removal set
///   itself reads, so it is read here too.
pub fn canRemoveAnything(
    settings: *const schema.SettingsState,
    expiry_deletes: bool,
    stale_removable: bool,
) bool {
    if (expiry_deletes) return true;
    return stale_removable and
        std.mem.eql(u8, settings.getEnum(k_stale_cleanup), "delete");
}

/// Whether an entry stamped with these frozen facts feeds
/// `canRemoveAnything`'s first flag: a `delete` action with an instant to
/// reach. Kept beside `removalSet` so the two cannot drift.
pub fn stampCanExpireDelete(expires_at: ?u64, ttl_action: TtlAction) bool {
    return expires_at != null and ttl_action == .delete;
}

/// Whether an entry stamped with these frozen facts feeds
/// `canRemoveAnything`'s second flag: anything `removalSet` collects only
/// under `stale.cleanup = delete`.
pub fn stampCanBecomeStale(expires_at: ?u64, ttl_action: TtlAction) bool {
    return expires_at != null and ttl_action == .mark_stale;
}

/// The deterministic removal set a checkpoint names (PRD 0002): every entry
/// slotted at or before `expire_through` whose TTL action is `delete` and
/// whose expiry instant is at or before the checkpoint's own stamp, plus
/// every stale entry (author-marked, or TTL-reached under `mark_stale`) at
/// or before it when `stale.cleanup = delete`. The fold iterates its
/// entries and collects the matches; the caller owns the list.
pub fn removalSet(
    allocator: std.mem.Allocator,
    entries: []const SlottedEntry,
    expire_through: slot.Position,
    checkpoint_ts_ms: u64,
    settings: *const schema.SettingsState,
) ![]const SlottedEntry {
    const cleanup_delete = std.mem.eql(u8, settings.getEnum(k_stale_cleanup), "delete");
    var out = std.ArrayListUnmanaged(SlottedEntry).empty;
    errdefer out.deinit(allocator);
    for (entries) |se| {
        if (slot.Position.order(se.position, expire_through) == .gt) continue;
        const past = se.expires_at != null and se.expires_at.? <= checkpoint_ts_ms;
        const expired = se.ttl_action == .delete and past;
        const ttl_stale = se.ttl_action == .mark_stale and past;
        const author_stale = se.stale_marked and
            (se.stale_position == null or
                slot.Position.order(se.stale_position.?, expire_through) != .gt);
        if (expired or (cleanup_delete and (author_stale or ttl_stale))) {
            try out.append(allocator, se);
        }
    }
    return out.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const test_alloc = std.testing.allocator;

test "canRemoveAnything answers from the entries' frozen stamps, not the live settings" {
    var settings = try schema.SettingsState.initDefaults(test_alloc);
    defer settings.deinit();
    const cleanup = schema.keyIndex("stale.cleanup").?;

    // Nothing stamped: nothing can be removed, whatever the settings say.
    try std.testing.expect(!canRemoveAnything(&settings, false, false));
    try settings.set(cleanup, .{ .enum_value = schema.enumValue(cleanup, "delete").? });
    try std.testing.expect(!canRemoveAnything(&settings, false, false));

    // A stamp of delete + an instant is removable regardless of the
    // settings in force now - this is the case the old settings-only guard
    // got wrong after ttl.enforce went back to off.
    try settings.set(cleanup, .{ .enum_value = schema.enumValue(cleanup, "keep").? });
    try std.testing.expect(canRemoveAnything(&settings, true, false));

    // A stale-only stamp needs stale.cleanup = delete, which removalSet
    // reads live too.
    try std.testing.expect(!canRemoveAnything(&settings, false, true));
    try settings.set(cleanup, .{ .enum_value = schema.enumValue(cleanup, "delete").? });
    try std.testing.expect(canRemoveAnything(&settings, false, true));

    // The stamp predicates agree with removalSet's own tests.
    try std.testing.expect(stampCanExpireDelete(3000, .delete));
    try std.testing.expect(!stampCanExpireDelete(null, .delete));
    try std.testing.expect(!stampCanExpireDelete(3000, .mark_stale));
    try std.testing.expect(stampCanBecomeStale(3000, .mark_stale));
    try std.testing.expect(!stampCanBecomeStale(null, .mark_stale));
}

test "effectiveTtl matrix: enforce x entry ttl (PRD 0002 G1/G2)" {
    var settings = try schema.SettingsState.initDefaults(test_alloc);
    defer settings.deinit();

    const enforce = schema.keyIndex("ttl.enforce").?;
    const ttl_default = schema.keyIndex("ttl.default_ms").?;
    const ttl_max = schema.keyIndex("ttl.max_ms").?;
    const ttl_action = schema.keyIndex("ttl.action").?;

    // off: never, with or without a TTL.
    try std.testing.expectEqual(@as(?u64, null), effectiveTtl(0, &settings));
    try std.testing.expectEqual(@as(?u64, null), effectiveTtl(5000, &settings));

    // per_entry: only entries that carry a TTL.
    try settings.set(enforce, .{ .enum_value = schema.enumValue(enforce, "per_entry").? });
    try std.testing.expectEqual(@as(?u64, null), effectiveTtl(0, &settings));
    try std.testing.expectEqual(@as(?u64, 5000), effectiveTtl(5000, &settings));

    // all: entries without a TTL get the journal default.
    try settings.set(enforce, .{ .enum_value = schema.enumValue(enforce, "all").? });
    try settings.set(ttl_default, .{ .u64 = 7000 });
    try std.testing.expectEqual(@as(?u64, 7000), effectiveTtl(0, &settings));
    try std.testing.expectEqual(@as(?u64, 5000), effectiveTtl(5000, &settings));

    // max_ms caps a larger ask; 0 = unbounded.
    try settings.set(ttl_max, .{ .u64 = 3000 });
    try std.testing.expectEqual(@as(?u64, 3000), effectiveTtl(5000, &settings));
    try std.testing.expectEqual(@as(?u64, 3000), effectiveTtl(0, &settings));
    try settings.set(ttl_max, .{ .u64 = 0 });
    try std.testing.expectEqual(@as(?u64, 5000), effectiveTtl(5000, &settings));

    // The action is read from ttl.action.
    try std.testing.expectEqual(TtlAction.mark_stale, action(&settings));
    try settings.set(ttl_action, .{ .enum_value = schema.enumValue(ttl_action, "delete").? });
    try std.testing.expectEqual(TtlAction.delete, action(&settings));
}

test "state transitions follow the diagram, at and past the expiry instant" {
    // live -> stale under mark_stale once now reaches the instant.
    const now_before: u64 = 999;
    const now_at: u64 = 1000;
    const now_past: u64 = 1001;
    try std.testing.expectEqual(
        EntryState.live,
        state(false, 1000, .mark_stale, false, now_before, 0),
    );
    try std.testing.expectEqual(
        EntryState.stale,
        state(false, 1000, .mark_stale, false, now_at, 0),
    );
    try std.testing.expectEqual(
        EntryState.stale,
        state(false, 1000, .mark_stale, false, now_past, 0),
    );
    // live -> expired under delete.
    try std.testing.expectEqual(
        EntryState.expired,
        state(false, 1000, .delete, false, now_past, 0),
    );
    // author-marked is stale regardless of TTL.
    try std.testing.expectEqual(
        EntryState.stale,
        state(false, null, .delete, true, now_before, 0),
    );
    // removed is terminal: nothing resurrects it.
    try std.testing.expectEqual(
        EntryState.removed,
        state(true, null, .delete, false, now_before, 0),
    );
}

test "grace pushes the hiding instant later, never earlier" {
    // Instant at 1000, grace 5: hides only once now >= 1005.
    try std.testing.expectEqual(
        EntryState.live,
        state(false, 1000, .mark_stale, false, 1004, 5),
    );
    try std.testing.expectEqual(
        EntryState.stale,
        state(false, 1000, .mark_stale, false, 1005, 5),
    );
    // The grace clamp never underflows a small now.
    try std.testing.expectEqual(
        EntryState.live,
        state(false, 1000, .mark_stale, false, 1, 5),
    );
}

test "visibility honors include_stale and include_expired (PRD 0002 G5)" {
    const now_past: u64 = 1001;
    const f = isVisible;
    // Stale by author mark: hidden unless include_stale.
    try std.testing.expect(!f(false, null, .delete, true, now_past, 0, false, false));
    try std.testing.expect(f(false, null, .delete, true, now_past, 0, true, false));
    // Expired by TTL under delete: hidden unless include_expired.
    try std.testing.expect(!f(false, 1000, .delete, false, now_past, 0, false, false));
    try std.testing.expect(f(false, 1000, .delete, false, now_past, 0, false, true));
    // Removed is invisible under every flag.
    try std.testing.expect(!f(true, null, .delete, false, now_past, 0, true, true));
    // Live is always visible.
    try std.testing.expect(f(false, null, .delete, false, now_past, 0, false, false));
    // Under the defaults (enforce=off), nothing ever hides (G7): no
    // expires_at and no stale mark means visible at any now.
    try std.testing.expect(f(false, null, .mark_stale, false, 1 << 62, 0, false, false));
}

test "removalSet drops expired entries, and stale only under cleanup=delete" {
    var settings = try schema.SettingsState.initDefaults(test_alloc);
    defer settings.deinit();
    const stale_cleanup = schema.keyIndex("stale.cleanup").?;

    // A compact test constructor: one entry per slot in epoch 1, stamped at
    // 1000, with the facts the removal rule needs.
    const mk = struct {
        fn at(seq: u64, expires: ?u64, ttl_action: TtlAction, stale: bool) SlottedEntry {
            return .{
                .id = .{ .author = [_]u8{0xAA} ** 16, .author_seq = seq },
                .position = .{ .epoch = 1, .seq = seq },
                .slot_ts_ms = 1000,
                .expires_at = expires,
                .ttl_action = ttl_action,
                .stale_marked = stale,
                .stale_position = if (stale) .{ .epoch = 1, .seq = seq } else null,
            };
        }
    }.at;

    const entries = [_]SlottedEntry{
        mk(1, 1500, .delete, false), // expired before the checkpoint stamp
        mk(2, null, .mark_stale, true), // author-marked stale, TTL far away
        mk(4, 2000, .delete, false), // expires after the stamp: kept
        mk(5, 1500, .delete, false), // slotted after the checkpoint: kept
    };
    const checkpoint = slot.Position{ .epoch = 1, .seq = 4 };

    // cleanup=keep: only the TTL-expired entry is removed.
    const set = try removalSet(test_alloc, &entries, checkpoint, 1600, &settings);
    defer test_alloc.free(set);
    try std.testing.expectEqual(@as(usize, 1), set.len);
    try std.testing.expectEqual(@as(u64, 1), set[0].position.seq);

    // cleanup=delete: the stale-marked entry joins the set.
    try settings.set(stale_cleanup, .{ .enum_value = schema.enumValue(stale_cleanup, "delete").? });
    const set2 = try removalSet(test_alloc, &entries, checkpoint, 1600, &settings);
    defer test_alloc.free(set2);
    try std.testing.expectEqual(@as(usize, 2), set2.len);
}
