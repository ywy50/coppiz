//! spine — a replicated, append-only ledger library.
//!
//! Nothing here is implemented yet. The design lives in docs/: start at
//! docs/README.md, then docs/prds/ for what each part is meant to be and
//! docs/open-questions.md for what is still undecided. This file exists so
//! `zig build test` has a root and so the module name `spine` is claimed.

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
}

test "version is pre-1.0" {
    // Pre-1.0 pin: a major bump must not happen silently.
    try std.testing.expectEqual(@as(u32, 0), version.major);
}
