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
    // Every src/ module must be referenced here (or from src/main.zig for
    // CLI-only code) so its `test` blocks run. Zig 0.16 runs tests only
    // from a test root; the lint gate enforces the reference.
}

test "version is the one build.zig.zon declares" {
    // Pre-1.0 pin: a major bump must not happen silently.
    try std.testing.expectEqual(@as(u32, 0), version.major);

    // Not just any version: the exact one parsed from build.zig.zon, so the
    // build cannot drift off the zon file as its source of truth.
    const declared = try std.SemanticVersion.parse(build_options.version_text);
    try std.testing.expect(version.order(declared) == .eq);
}
