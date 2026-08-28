//! coppiz — a replicated, append-only store library.
//!
//! This module exposes the library's journal, cluster, settings, local
//! configuration, and replication APIs. The design records live in `docs/`:
//! start at `docs/README.md`, then use `docs/prds/` for intended behavior and
//! `docs/open-questions.md` for unsettled decisions. This file is also the
//! library test root: it gives `zig build test` its library half and claims
//! the module name `coppiz`.

const std = @import("std");
const build_options = @import("build_options");

/// The package version, parsed from the build.zig.zon value the build hands
/// over as build_options.version_text. The zon file is the single source of
/// truth (see RELEASES.md); a declaration that is not valid Semantic
/// Versioning fails the build right here.
pub const version: std.SemanticVersion =
    std.SemanticVersion.parse(build_options.version_text) catch
        @compileError(
            "build.zig.zon version is not semver: '" ++ build_options.version_text ++ "'",
        );

/// The library's single-member journal API and local configuration parser.
/// Settings and journal primitives are reachable through these modules.
pub const journal = @import("journal/journal.zig");
pub const config = @import("config/local.zig");
pub const render = @import("settings/render.zig");
pub const schema = @import("settings/schema.zig");
pub const settings_fold = @import("settings/fold.zig");
pub const validate = @import("settings/validate.zig");
/// The replication wire (PRD 0003 phase 4, OQ 19 decided): framing, the
/// message set, and the transport seam (TCP plus the in-memory hub the
/// node loop and the simulator share).
pub const net = @import("net/net.zig");
/// The cluster node loop (PRD 0003 phase 5): the failure detector, the
/// election -> epoch cycle, admission, and replication — one event loop per
/// member over the wire.
pub const cluster = @import("cluster/node.zig");
/// The pure cluster core (PRD 0003 phases 1–3): membership, election, and
/// the epoch/merge rules, exported for hosts and the CLI.
pub const membership = @import("cluster/membership.zig");
pub const election = @import("cluster/election.zig");
pub const epoch = @import("cluster/epoch.zig");

comptime {
    // Every src/ module should be referenced here (or from src/main.zig
    // for CLI-only code). Tests collect from any module transitively
    // reachable from a test root through analyzed imports, so a module only
    // another module imports has its tests run too. Registering here makes
    // this test root the module's direct importer, which is what obliges a
    // refAllDecls line for it in the analysis test below (next paragraph) —
    // an obligation indirect reachability never creates. The lint gate
    // fails when no chain of real @imports reaches a module.
    //
    // Registration alone collects a module's tests but does not check its
    // unreferenced declarations: Zig analyzes a `pub` declaration only once
    // something references it, so a type error in one reaches a green build.
    // Each registered module therefore also gets a line in the analysis
    // test below, whose import both registers it and forces every public
    // declaration through the semantic analyzer. The lint gate enforces the
    // pairing: a test-root import no refAllDecls call wraps fails the build.
}

test "all public declarations analyze" {
    // Zig's analyzer is lazy: an unreferenced `pub` declaration is compiled
    // into nothing and checked by nothing, so this test references them all.
    // New submodules go here as they are added:
    //     std.testing.refAllDecls(@import("sub/x.zig"));
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(@import("journal/entry.zig"));
    std.testing.refAllDecls(@import("journal/slot.zig"));
    std.testing.refAllDecls(@import("journal/expiry.zig"));
    std.testing.refAllDecls(@import("journal/chain.zig"));
    std.testing.refAllDecls(@import("journal/segment.zig"));
    std.testing.refAllDecls(@import("journal/store.zig"));
    std.testing.refAllDecls(@import("journal/queue.zig"));
    std.testing.refAllDecls(@import("settings/schema.zig"));
    std.testing.refAllDecls(@import("settings/validate.zig"));
    std.testing.refAllDecls(@import("settings/fold.zig"));
    std.testing.refAllDecls(@import("settings/render.zig"));
    std.testing.refAllDecls(@import("config/local.zig"));
    std.testing.refAllDecls(@import("journal/journal.zig"));
    std.testing.refAllDecls(@import("cluster/membership.zig"));
    std.testing.refAllDecls(@import("cluster/election.zig"));
    std.testing.refAllDecls(@import("cluster/epoch.zig"));
    std.testing.refAllDecls(@import("cluster/node.zig"));
    std.testing.refAllDecls(@import("sim/sim.zig"));
    std.testing.refAllDecls(@import("net/net.zig"));
    std.testing.refAllDecls(@import("net/framing.zig"));
    std.testing.refAllDecls(@import("net/message.zig"));
    std.testing.refAllDecls(@import("net/transport.zig"));
}

test "version round-trips the zon text the build hands over" {
    // RELEASES.md makes build.zig.zon the single source of truth, so what
    // the library exposes (and main prints) must be that text parsed back
    // out unchanged. major == 0 alone cannot see the wiring break: if
    // build.zig fed any other parseable value here, every test stayed green
    // while `coppiz` reported a version no release carries.
    var buffer: [64]u8 = undefined;
    const formatted = try std.fmt.bufPrint(&buffer, "{f}", .{version});
    try std.testing.expectEqualStrings(build_options.version_text, formatted);
}

test "version is pre-1.0" {
    // Pre-1.0 pin: a major bump must not happen silently.
    try std.testing.expectEqual(@as(u32, 0), version.major);
}
