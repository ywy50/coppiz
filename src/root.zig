//! spine — a replicated, append-only ledger library.
//!
//! Nothing here is implemented yet. The design lives in docs/: start at
//! docs/README.md, then docs/prds/ for what each part is meant to be and
//! docs/open-questions.md for what is still undecided. This file exists so
//! `zig build test` has a root and so the module name `spine` is claimed.

const std = @import("std");
const build_options = @import("build_options");

/// The package version, read from build.zig.zon by build.zig. The zon file
/// is the single source of truth (see RELEASES.md).
pub const version: std.SemanticVersion = build_options.version;

comptime {
    // Every src/ module must be referenced here so its `test` blocks run.
    // (Zig 0.16 runs tests only from the root file.)
}

test "version is the one build.zig.zon declares" {
    try std.testing.expectEqual(@as(usize, 0), version.major);
}
