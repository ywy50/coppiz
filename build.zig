const std = @import("std");

// coppiz builds two things from one tree, on purpose: the library module
// (`coppiz`, src/root.zig) a host such as clanker fetches as a dependency,
// and the `coppiz` executable (src/main.zig) that wraps that same library
// as a standalone node. Which of the two leads the design is RFC 0001.
pub fn build(b: *std.Build) void {
    enforceToolchainFloor();
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const options = b.addOptions();
    // The raw zon declaration only: the library parses it where `coppiz.version`
    // is defined (src/root.zig), so the single-source-of-truth value is never
    // carried twice in lockstep (RELEASES.md).
    options.addOption([]const u8, "version_text", @import("build.zig.zon").version);

    const lib_mod = b.addModule("coppiz", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_mod.addOptions("build_options", options);

    const exe = b.addExecutable(.{
        .name = "coppiz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "coppiz", .module = lib_mod },
            },
        }),
    });
    b.installArtifact(exe);

    // addRunArtifact already ties the run to the freshly built binary; no
    // step here needs the install performed first.
    const run_step = b.step("run", "Build and run the coppiz node");
    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    // `zig build docs` regenerates docs/configuration.md from the settings
    // schema (PRD 0004 phase 5). The docgen exe writes the file directly, so
    // the step needs no shell redirection; the pinned test in render.zig
    // fails the build when the checked-in file drifts from the schema.
    const docgen = b.addExecutable(.{
        .name = "docgen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/settings/docgen.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const docgen_run = b.addRunArtifact(docgen);
    docgen_run.addFileArg(b.path("docs/configuration.md"));
    const docs_step = b.step("docs", "Regenerate docs/configuration.md from the settings schema");
    docs_step.dependOn(&docgen_run.step);

    // Examples (PRD 0005): `zig build examples` builds and runs each host.
    // The same modules are each a test root in addChecks, so `zig build
    // test` runs them too.
    const examples_step = b.step(
        "examples",
        "Build and run the example hosts (embed-single, embed-cluster, sidecar)",
    );
    for (example_names) |name| {
        const mod = exampleModule(b, lib_mod, target, optimize, name);
        const example_exe = b.addExecutable(.{ .name = name, .root_module = mod });
        b.installArtifact(example_exe);
        examples_step.dependOn(&b.addRunArtifact(example_exe).step);
    }

    addChecks(b, lib_mod, exe, target, optimize);
}

/// One example host module: the example's main.zig importing the library
/// exactly as a fetched host would (`coppiz` by name).
fn exampleModule(
    b: *std.Build,
    lib_mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
) *std.Build.Module {
    const path = b.fmt("examples/{s}/main.zig", .{name});
    return b.createModule(.{
        .root_source_file = b.path(path),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "coppiz", .module = lib_mod }},
    });
}

/// Fails the build when the toolchain executing it is older than the floor
/// declared in build.zig.zon. Zig itself never checks that field for a tree
/// built directly (verified on 0.16.0: a floor of 99.0.0 builds silently);
/// only a consumer fetching coppiz as a dependency gets it checked. Yet every
/// gate in addChecks assumes the declared toolchain's semantics — zig fmt's
/// output and --ast-check, std.zig.Tokenizer's lexing behind the test
/// registration check, test-block collection from module roots — so an
/// undeclared toolchain would analyze with the wrong rules. Fail loudly
/// instead, before any gate can half-run.
fn enforceToolchainFloor() void {
    const floor_text = @import("build.zig.zon").minimum_zig_version;
    if (!meetsZigFloor(@import("builtin").zig_version, floor_text))
        std.debug.panic(
            "coppiz requires Zig {s} or newer; running {f}",
            .{ floor_text, @import("builtin").zig_version },
        );
}

/// True when `running` satisfies the semver floor spelled by `floor_text`.
/// I/O-free so tests drive it directly. An unparseable floor satisfies
/// nothing: broken configuration fails loudly, never permissively.
fn meetsZigFloor(running: std.SemanticVersion, floor_text: []const u8) bool {
    const floor = std.SemanticVersion.parse(floor_text) catch return false;
    return running.order(floor) != .lt;
}

test "meetsZigFloor accepts the floor itself and newer, rejects older" {
    const floor = "0.16.0";
    try std.testing.expect(meetsZigFloor(try std.SemanticVersion.parse("0.16.0"), floor));
    try std.testing.expect(meetsZigFloor(try std.SemanticVersion.parse("0.17.0"), floor));
    try std.testing.expect(!meetsZigFloor(try std.SemanticVersion.parse("0.15.9"), floor));

    // Semver orders a prerelease before its own release, so a dev toolchain
    // below the named release is rejected too.
    try std.testing.expect(
        !meetsZigFloor(try std.SemanticVersion.parse("0.16.0-dev.1+abc"), floor),
    );

    // The mirror side: a release toolchain satisfies a prerelease floor of
    // the same release — the boundary where the floor itself is a dev tag.
    try std.testing.expect(
        meetsZigFloor(try std.SemanticVersion.parse("0.16.0"), "0.16.0-dev.1"),
    );

    // Build metadata orders equal, so it neither admits nor rejects — on
    // either side: a tagged toolchain satisfies a plain floor, and a plain
    // toolchain satisfies a tagged floor.
    try std.testing.expect(
        meetsZigFloor(try std.SemanticVersion.parse("0.16.0+rust"), floor),
    );
    try std.testing.expect(
        meetsZigFloor(try std.SemanticVersion.parse("0.16.0"), "0.16.0+rust"),
    );

    // A floor that does not parse cannot be satisfied by any toolchain —
    // broken configuration, not permission to proceed.
    try std.testing.expect(!meetsZigFloor(try std.SemanticVersion.parse("0.16.0"), "no-semver"));
}

/// Wires the `test` and `lint` steps onto the artifacts built above: unit
/// tests for every test module plus the analysis gates. Split from `build`
/// so the build script reads as two jobs — produce and check — with this
/// one owning all of the checking.
fn addChecks(
    b: *std.Build,
    lib_mod: *std.Build.Module,
    exe: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    // Zig 0.16 collects `test` blocks from a test module's root file and
    // from every module its analyzed imports reach, so every gated Zig file
    // must be reachable from a test-module root — src/root.zig's comptime
    // reference block, src/main.zig, or build.zig itself (a root in its own
    // right through the build_tests module below), directly or through
    // another module — or its tests silently never run.
    const lib_tests = b.addTest(.{ .root_module = lib_mod });
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    // The build file carries lint-gate logic with its own tests; compiling
    // it as a plain module (not as the build script) runs them.
    const build_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("build.zig"),
        .target = b.resolveTargetQuery(.{}),
    }) });
    const test_step = b.step("test", "Run unit tests and the lint gates");
    test_step.dependOn(&b.addRunArtifact(lib_tests).step);
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);
    test_step.dependOn(&b.addRunArtifact(build_tests).step);
    // The examples are each a test (PRD 0005), so their test binaries join
    // the gate: a change that breaks an example breaks the build. They
    // import the library by name, like a fetched host would.
    for (example_names) |name| {
        const mod = exampleModule(b, lib_mod, target, optimize, name);
        const example_tests = b.addTest(.{ .root_module = mod });
        test_step.dependOn(&b.addRunArtifact(example_tests).step);
    }
    // The process-level e2e tests spawn the installed binary.
    test_step.dependOn(b.getInstallStep());

    // Analysis gates. Until CI decides what it gates (OQ 45), `zig build
    // test` is the one blocking entry point, so it carries the checks: the
    // formatter (`zig fmt --check --ast-check`, run with the toolchain that
    // is executing this build, not whatever is first on PATH), a hard
    // 100-column cap matching zig fmt's own wrap target, test
    // registration (a module no chain of imports reaches from a test root
    // loses its tests silently, and a root import never wrapped in
    // refAllDecls loses every semantic check of the module's public
    // declarations), and gate coverage (the checked paths are an allowlist,
    // so a .zig file outside them is analyzed by nothing — the complement
    // is failed loudly instead of skipped silently).
    const lint_step = b.step(
        "lint",
        "Check formatting, line length, test registration, declaration analysis and gate coverage",
    );

    // The file list comes from `checked_paths` through the same dispatcher
    // as the column cap, coverage and registration gates, so every
    // file-covering surface can never drift apart about what is analyzed.
    const fmt_check = b.addSystemCommand(fmtArgs(
        b.build_root.handle,
        b.graph.io,
        b.allocator,
        b.graph.zig_exe,
        &checked_paths,
    ));
    fmt_check.setName("zig fmt --check --ast-check");
    // The paths above are relative to the build root; pin the child there so
    // `zig build` invoked from a subdirectory (the runner walks up to find
    // build.zig but does not change directory) checks this project's files.
    fmt_check.setCwd(b.path("."));
    lint_step.dependOn(&fmt_check.step);

    lint_step.dependOn(&LineLengthStep.create(b).step);
    lint_step.dependOn(&TestRegistrationStep.create(b).step);
    lint_step.dependOn(&GateCoverageStep.create(b).step);
    test_step.dependOn(lint_step);
}

/// The paths every analysis gate covers, relative to the build root: all
/// Zig sources under `src/`, the two build files at the top level, and the
/// example hosts under `examples/` (PRD 0005 — each is built by `zig build
/// examples` and each is a test). One list serves every file-covering
/// surface — `zig fmt --check --ast-check` (via fmtArgs' expansion), the
/// 100-column cap, the test-registration walk and the coverage-completeness
/// walk — so they can never disagree about what is analyzed: a new source
/// directory or file is added once and all of them pick it up. A path here
/// that stops existing fails each of them loudly rather than silently
/// checking nothing.
const checked_paths = [_][]const u8{ "src", "build.zig", "build.zig.zon", "examples" };

/// The example hosts (PRD 0005): one per host shape. Each is built by `zig
/// build examples` and each is a test run by `zig build test` — a change
/// that breaks an example breaks the build.
const example_names = [_][]const u8{ "embed-single", "embed-cluster", "sidecar" };

/// Every file a checking step covers, derived from its gate paths: a listed
/// directory contributes its .zig descendants; any other entry is taken
/// whole (build.zig.zon has no .zig suffix but must still be capped). One
/// dispatcher serves every step that enumerates files — the 100-column cap,
/// the test-registration walk, the coverage-completeness walk and fmtArgs'
/// `zig fmt` expansion — so their coverage rules
/// cannot drift apart.
///
/// All paths go through `root_dir` — the build root — not the process cwd:
/// the runner walks up to find build.zig without changing directory, so a
/// `zig build` invoked from anywhere under the project must still read this
/// project's files. Symlinks are resolved wherever they are met: a listed
/// path is statted through (`statFile` follows links), and inside a walked
/// directory each link — and each entry the filesystem could not classify —
/// is resolved by `appendZigFilesUnder`, which analyzes a linked .zig file
/// like a real one and fails a gate rather than leave a linked directory's
/// subtree silently unchecked.
/// `gate_paths` is a parameter rather than a read of `checked_paths` so a
/// test can drive the dispatch against a temporary tree, the same way `separator`
/// is a parameter below; every production caller — the formatter expansion,
/// the column cap, the test-registration walk and the coverage-completeness
/// gate — hands in `&checked_paths`.
///
/// On failure `failed_path` names what stopped the enumeration: the gate
/// path that could not be stat'd, or — inside a walked directory — the
/// walked entry appendZigFilesUnder names when one entry owns the failure,
/// so the operator is not sent back to a whole directory (the same rule
/// appendProjectZigFiles follows for its walk; a bare error name would
/// leave them to find it by hand, the way the read failures in
/// loadCheckedSources name their file). An error belonging to no single
/// path — allocation alone, here — leaves it unset, and the caller falls
/// back to a generic subject. Callers that fall back without ever naming
/// the failing path pass null (fmtArgs): the outlived contract is visible
/// in the type instead of a local its reader cannot see consumed.
fn checkedFiles(
    root_dir: std.Io.Dir,
    io: std.Io,
    arena: std.mem.Allocator,
    gate_paths: []const []const u8,
    failed_path: ?*?[]const u8,
) ![][]const u8 {
    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    for (gate_paths) |path| {
        // follow_symlinks is the load-bearing choice, not the ambient
        // default: a listed path that links a directory must contribute its
        // subtree (the test "checkedFiles resolves a listed path that
        // symlinks a directory" pins it), so the flag is spelled here rather
        // than inherited.
        const stat = root_dir.statFile(io, path, .{ .follow_symlinks = true }) catch |err| {
            if (failed_path) |out| out.* = path;
            return err;
        };
        if (stat.kind == .directory) {
            var failed_entry: ?[]const u8 = null;
            appendZigFilesUnder(
                root_dir,
                io,
                arena,
                path,
                &paths,
                &failed_entry,
                false,
            ) catch |err| {
                if (failed_path) |out| out.* = failed_entry orelse path;
                return err;
            };
        } else {
            try paths.append(arena, path);
        }
    }
    return paths.toOwnedSlice(arena);
}

/// What one walked entry is, once its real kind is known: the shared
/// decision both file walks act on, so their collection rules cannot drift
/// apart.
const WalkedEntry = union(enum) {
    /// A .zig source file: `path` is the entry's path under `root_dir`,
    /// freshly allocated, in the form both gates report and read back.
    zig_source: []const u8,
    /// A directory the walk may descend into: the kind is either the
    /// walker's answer or the probe's — statFile followed a link or an
    /// unclassifiable entry (`DT_UNKNOWN` reaches Zig as `.unknown`) and
    /// resolved a directory behind it. A selective walker refuses enter()
    /// for any kind but `.directory`, so callers enter with the kind
    /// forced: skipping drops a d_type-less mount's subtree from every
    /// gate silently (and rejecting fails every conforming tree there).
    directory,
    /// A link resolving to a directory: neither walker may descend into it
    /// (following it would need cycle protection no current tree
    /// justifies), so its subtree would escape every gate silently — the
    /// covering walks reject it loudly, and the coverage walk follows it
    /// one hop only where the allowlist already lists it (appendProjectZigFiles).
    linked_directory,
    /// Anything else: not a Zig source.
    other,
};

/// Classifies one walked entry against the policy both walks share. The
/// kind is probed through links and filesystem-unclassifiable entries via
/// `root_dir.statFile`, which follows links: iteration reports a link as
/// `.sym_link`, never the kind of its target (verified on 0.16.0 — Linux's
/// getdents64 d_type is never statted), and an entry the OS could not
/// classify (`DT_UNKNOWN` reaches Zig as `.unknown`; verified on 0.16.0 in
/// std.Io.Threaded's dirReadLinux, and real on XFS with ftype=0 and some
/// NFS/FUSE mounts) answers nothing — filtering on the raw kind drops real
/// sources from every gate while they stay green. The probe joins the
/// entry's walked path under `prefix` — the gate path for the covering
/// walk, "" for the coverage walk, whose paths are already build-root
/// relative — and is built only when the raw kind demands it; the returned
/// `.zig_source` path joins the same way, so it is freshly allocated and
/// survives the walker invalidating its slices.
fn classifyWalkedEntry(
    root_dir: std.Io.Dir,
    io: std.Io,
    arena: std.mem.Allocator,
    prefix: []const u8,
    entry: std.Io.Dir.Walker.Entry,
) !WalkedEntry {
    var kind = entry.kind;
    if (kind == .sym_link or kind == .unknown) {
        const probe_path = try std.fs.path.join(arena, &.{ prefix, entry.path });
        // The probe must follow the link — that following is what reveals
        // the target's kind — so it is spelled here rather than inherited
        // from StatFileOptions' default.
        kind = (try root_dir.statFile(io, probe_path, .{ .follow_symlinks = true })).kind;
    }
    if (kind == .directory) {
        // A link is the one entry whose raw kind is known yet names a
        // directory it must not be descended into; anything else the probe
        // revealed descends like a walker-reported directory.
        if (entry.kind == .sym_link) return .linked_directory;
        return .directory;
    }
    if (kind != .file) return .other;
    if (!std.mem.endsWith(u8, entry.basename, ".zig")) return .other;
    return .{ .zig_source = try std.fs.path.join(arena, &.{ prefix, entry.path }) };
}

/// Enters `entry` — classified .directory by classifyWalkedEntry — into the
/// selective walk, with the entry's kind forced to .directory on the copy.
/// Entering is explicit with a selective walker, and enter() refuses any
/// kind but .directory, while a probed directory's walked-in raw kind is a
/// link or .unknown — so the forced copy is the only way its subtree stays
/// covered on a kind-less mount (XFS ftype=0, some NFS/FUSE); skipping it
/// drops the subtree from every gate silently, and rejecting it fails every
/// conforming tree there. One copy serves both file walks so the hack and
/// its rationale cannot drift apart between them.
fn enterForcedDirectory(
    walker: *std.Io.Dir.SelectiveWalker,
    io: std.Io,
    entry: std.Io.Dir.Walker.Entry,
) !void {
    var descend = entry;
    descend.kind = .directory;
    try walker.enter(io, descend);
}

/// Rewrites filesystem separators to '/' — the only form inside an @import
/// string, and the form `checked_paths` is written in. A no-op where the
/// separator is already '/'. One copy serves every walked-path-vs-listed-path
/// comparison (the test roots', and the coverage walk's linked-directory
/// check against the gate paths) so they cannot drift apart; `separator` is a
/// parameter so any platform can be simulated in a test.
fn normalizeSeparators(arena: std.mem.Allocator, path: []const u8, separator: u8) ![]const u8 {
    if (separator == '/') return path;
    return std.mem.replaceOwned(u8, arena, path, &.{separator}, "/");
}

/// True when `list` holds an entry byte-equal to `path`: the membership
/// question the test-root match, the listed-linked-directory check and the
/// coverage comparison each ask of their path lists. One copy serves all of
/// them so their equality rules cannot drift apart.
fn listContainsPath(list: []const []const u8, path: []const u8) bool {
    for (list) |entry| {
        if (std.mem.eql(u8, entry, path)) return true;
    }
    return false;
}

/// Appends every .zig file under the directory `dir_path`, as a path from
/// the build root ("src/foo.zig"), in walker order. The walk is selective
/// so directories are entered explicitly: a d_type-less mount (XFS with
/// ftype=0, some NFS/FUSE — classifyWalkedEntry's `.unknown` note) reports
/// every entry kind-less, the plain walker auto-enters only entries
/// reported as directories, and there every real directory's subtree fell
/// out of both covering gates while they stayed green. A linked directory
/// is still rejected loudly instead of half-checked.
///
/// On failure `failed_path` names the walked entry that could not be
/// handled — the link or unclassifiable entry whose resolution failed, or
/// the linked directory the walk rejects — joined under `dir_path`, the
/// build-root-relative form both gates report, so the caller can name it
/// instead of leaving the operator to find it inside `dir_path` by hand
/// (the same rule appendProjectZigFiles' `failed_path` follows for its
/// walk; next() invalidates its slices, so each name is copied out before
/// returning). A failure belonging to no single entry — allocation alone —
/// leaves it unset, and checkedFiles falls back to naming the gate path.
///
/// `include_near_miss` widens the collection by exactly one class: a file
/// whose name names a Zig source in a spelling every covering gate's filter
/// skips ("Legacy.ZIG", "root.zig~"; zigNearMissName's whole set) classifies
/// as .other and is appended as a candidate beside the sources. The covering
/// gates pass false — those files are invisible to them by design, and
/// collecting them here would change what they check; the coverage walk's
/// followed linked directories pass true, so a near-miss source behind a
/// listed link is reported exactly like one behind a listed real directory.
fn appendZigFilesUnder(
    root_dir: std.Io.Dir,
    io: std.Io,
    arena: std.mem.Allocator,
    dir_path: []const u8,
    paths: *std.ArrayListUnmanaged([]const u8),
    failed_path: *?[]const u8,
    include_near_miss: bool,
) !void {
    var dir = try root_dir.openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walkSelectively(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        // entry.path is relative to the walked directory, while root_dir
        // stands at the build root: classification probes and collects
        // through dir_path joined onto it, the form both gates report.
        const classified = classifyWalkedEntry(root_dir, io, arena, dir_path, entry) catch |err| {
            failed_path.* = try std.fs.path.join(arena, &.{ dir_path, entry.path });
            return err;
        };
        switch (classified) {
            .zig_source => |path| try paths.append(arena, path),
            .linked_directory => {
                failed_path.* = try std.fs.path.join(arena, &.{ dir_path, entry.path });
                return error.LinkedDirectoryNotWalked;
            },
            .directory => try enterForcedDirectory(&walker, io, entry),
            .other => if (include_near_miss and zigNearMissName(entry.basename)) {
                // The widened collection include_near_miss asks for: joined
                // under dir_path like a source's path, the form the coverage
                // walk reports and compares against its covered set. The join
                // is freshly allocated, so it survives next() invalidating
                // the walker's slices — the same rule the .zig_source branch
                // follows through classifyWalkedEntry.
                try paths.append(arena, try std.fs.path.join(arena, &.{ dir_path, entry.path }));
            },
        }
    }
}

/// One file a gate covers: its path as checkedFiles hands it out
/// (build-root-relative, platform separators) and its full text.
const Source = struct {
    path: []const u8,
    text: []const u8,
};

/// Builds the `zig fmt --check --ast-check` argument list: `zig_exe`
/// followed by every file `gate_paths` expands to through checkedFiles, so
/// the formatter covers exactly what the column-cap and test-registration
/// walks collect. Handing zig fmt the raw gate paths instead left a
/// symlinked `.zig` source outside the formatter while those two walks
/// still analyzed it: zig fmt's own directory walk does not
/// follow symlinks (verified on 0.16.0: with `src/link.zig` pointing at an
/// unformatted real source, `zig fmt --check src` passed while
/// `zig fmt --check src/link.zig` failed), and the walk is also what let a
/// wrong-case `.ZIG` name escape — the expansion keeps both exclusions the
/// dispatcher already decides rather than re-deriving them.
///
/// Expansion runs at configure time because a run step's argv is fixed
/// there; when it fails (a checked path missing), the raw gate paths go out
/// unchanged instead of failing the build script, and the failure stays
/// loud anyway: zig fmt errors on the missing path at make time, and the
/// make-time gates enumerate independently through loadCheckedSources.
/// Allocation uses the builder's allocator, like every other configure-time
/// structure; the slice lives as long as the build, so no single append is
/// ever freed — the role the gpa name carries. The failing path goes
/// unnamed here (null to checkedFiles): whatever stopped the expansion, the
/// fallback is the same raw list.
fn fmtArgs(
    root_dir: std.Io.Dir,
    io: std.Io,
    gpa: std.mem.Allocator,
    zig_exe: []const u8,
    gate_paths: []const []const u8,
) []const []const u8 {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    argv.appendSlice(gpa, &.{ zig_exe, "fmt", "--check", "--ast-check" }) catch @panic("OOM");
    if (checkedFiles(root_dir, io, gpa, gate_paths, null)) |paths| {
        argv.appendSlice(gpa, paths) catch @panic("OOM");
    } else |_| {
        argv.appendSlice(gpa, gate_paths) catch @panic("OOM");
    }
    return argv.toOwnedSlice(gpa) catch @panic("OOM");
}

/// The link target and the path to create the link at, as one named pair so
/// they cannot be swapped at a call site: creating the link backwards still
/// succeeds everywhere links work and just points it the wrong way. The same
/// rule Source applies to its path/text pair.
const SymLinkPair = struct { target: []const u8, link: []const u8 };

/// Creates the link in `pair` pointing at its target inside `dir`, skipping
/// the calling test when the host cannot make symlinks at all. Creating one
/// is a privilege on Windows (unprivileged users are refused unless Developer
/// Mode is enabled) and some mounted filesystems refuse them outright, so the
/// gate fixtures that exercise link handling — links followed as sources,
/// linked directories rejected, dangling links named — would otherwise die in
/// setup on such hosts instead of passing where links exist and skipping where
/// they cannot be made. The skip is decided by capability, never by OS name:
/// when the requested link fails, a control link with known-good arguments is
/// attempted beside it. The control failing too means the environment lacks
/// the capability and the test skips (`error.SkipZigTest`); the control
/// succeeding means links work here, so the original error was that call's
/// own and propagates — a broken fixture still fails loudly wherever links
/// can be created.
///
/// `flags` is forwarded to the creation call untouched: SymLinkFlags is
/// ignored on every host but Windows, and there `is_directory` is the
/// difference between a working directory link and one that cannot be
/// traversed as a directory — a fixture linking a directory must spell it,
/// or it dies in setup on exactly the link-capable hosts this helper exists
/// to test on. The capability probe keeps file defaults: it only asks
/// whether any link can be made here.
fn symLinkOrSkip(
    dir: std.Io.Dir,
    io: std.Io,
    pair: SymLinkPair,
    flags: std.Io.Dir.SymLinkFlags,
) !void {
    if (dir.symLink(io, pair.target, pair.link, flags)) |_| return else |err| {
        const probe = ".sym-link-capability-probe";
        if (dir.symLink(io, "capability-probe-target", probe, .{})) |_| {
            dir.deleteFile(io, probe) catch {};
            return err;
        } else |_| {
            return error.SkipZigTest;
        }
    }
}

test "symLinkOrSkip creates the link, and skips only where links cannot be made" {
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // The working direction: the created link carries its target verbatim —
    // verified by reading the link itself (readLink), which does not follow
    // it, where a stat would resolve straight past to the target's kind.
    try tmp.dir.writeFile(io, .{ .sub_path = "real.zig", .data = "" });
    try symLinkOrSkip(tmp.dir, io, .{ .target = "real.zig", .link = "link.zig" }, .{});
    var link_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const read = try tmp.dir.readLink(io, "link.zig", &link_buf);
    try std.testing.expectEqualStrings("real.zig", link_buf[0..read]);

    // The directory direction: SymLinkFlags is ignored off Windows and
    // load-bearing on it, so forwarding is what lets a directory-linking
    // fixture run on a link-capable Windows host instead of dying in setup.
    // readLink reads the link itself either way, so the pin holds everywhere.
    (try tmp.dir.createDirPathOpen(io, "real-dir", .{})).close(io);
    try symLinkOrSkip(
        tmp.dir,
        io,
        .{ .target = "real-dir", .link = "link-dir" },
        .{ .is_directory = true },
    );
    const read_dir = try tmp.dir.readLink(io, "link-dir", &link_buf);
    try std.testing.expectEqualStrings("real-dir", link_buf[0..read_dir]);

    // The loud-failure direction: a link whose parent directory does not
    // exist fails with that call's own error wherever links work — the
    // control probe succeeds beside it, so a broken fixture must not be
    // mistaken for an environment without symlinks and silently skipped.
    try std.testing.expectError(
        error.FileNotFound,
        symLinkOrSkip(tmp.dir, io, .{ .target = "real.zig", .link = "nowhere/link.zig" }, .{}),
    );

    // The skip direction needs an environment that refuses every symlink
    // creation; none can be synthesized portably here, so it is exercised
    // by running the suite on such a host (Windows without Developer Mode).
}

/// Makes `sub_path` unreadable for the calling process, skipping the calling
/// test where no mode can deny a read. Running as root (Linux's
/// CAP_DAC_OVERRIDE) or on a filesystem that ignores mode bits reads any
/// file whatever its permissions, so the denial is probed before it is
/// trusted: a probe open succeeding means the environment grants every read
/// and the test skips (`error.SkipZigTest`) — the same capability rule
/// symLinkOrSkip applies to link creation, decided by behavior never OS
/// name. The mode is restored on the skip path so tmpDir cleanup sees an
/// ordinary file; the consuming test restores it on the proceed path.
fn setUnreadableOrSkip(dir: std.Io.Dir, io: std.Io, sub_path: []const u8) !void {
    // Mode 0o000 — every bit cleared; legal because Permissions is
    // non-exhaustive (`_`), and unreadable wherever a mode can deny a read.
    const unreadable: std.Io.File.Permissions = @enumFromInt(0);
    try dir.setFilePermissions(io, sub_path, unreadable, .{});
    if (dir.openFile(io, sub_path, .{})) |file| {
        file.close(io);
        dir.setFilePermissions(io, sub_path, .default_file, .{}) catch {};
        return error.SkipZigTest;
    } else |_| {}
}

test "setUnreadableOrSkip propagates its own errors where permission changes work" {
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // The loud-failure direction, mirror of symLinkOrSkip's: a permission
    // change on a path that does not exist fails with that call's own error
    // everywhere setFilePermissions resolves paths — a broken fixture must
    // surface as itself, never as an environment skip.
    try std.testing.expectError(
        error.FileNotFound,
        setUnreadableOrSkip(tmp.dir, io, "nowhere.zig"),
    );
}

test "fmtArgs hands zig fmt every covered file, links included" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // The false-pass this closes: link.zig points at an unformatted real
    // source, the shape zig fmt's directory walk skipped while the other
    // gates collected it. The expanded argv must name the link itself, which
    // zig fmt checks through to the target when given the path explicitly.
    // checked_paths covers src/ and examples/; both must exist in the
    // fixture for the gates' enumeration to reach what the test exercises.
    (try tmp.dir.createDirPathOpen(io, "src", .{})).close(io);
    (try tmp.dir.createDirPathOpen(io, "examples", .{})).close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = "src/real.zig", .data = "" });
    try symLinkOrSkip(tmp.dir, io, .{ .target = "real.zig", .link = "src/link.zig" }, .{});
    try tmp.dir.writeFile(io, .{ .sub_path = "src/main.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig.zon", .data = "" });
    const gate_paths = [_][]const u8{"src"};

    const argv = fmtArgs(tmp.dir, io, arena, "zig", &gate_paths);

    // The fixed prefix, then the walked files in walker order — membership
    // compared per path, since the walker's order is filesystem-dependent
    // (the same rule the appendZigFilesUnder tests apply).
    try std.testing.expectEqual(@as(usize, 7), argv.len);
    try std.testing.expectEqualStrings("zig", argv[0]);
    try std.testing.expectEqualStrings("fmt", argv[1]);
    try std.testing.expectEqualStrings("--check", argv[2]);
    try std.testing.expectEqualStrings("--ast-check", argv[3]);
    const files = argv[4..];
    // Joined with the platform separator, the form classifyWalkedEntry hands
    // out on every host.
    const sep_str = std.fs.path.sep_str;
    const want = [_][]const u8{
        "src" ++ sep_str ++ "link.zig",
        "src" ++ sep_str ++ "main.zig",
        "src" ++ sep_str ++ "real.zig",
    };
    try std.testing.expectEqual(files.len, want.len);
    for (want) |path| {
        try std.testing.expect(listContainsPath(files, path));
    }
}

test "fmtArgs falls back to the raw gate paths when expansion fails" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A missing checked path cannot be expanded, so the unchanged list goes
    // out and zig fmt's own failure on that path keeps the gate loud — no
    // configure-time panic, no silently empty formatter run.
    const gate_paths = [_][]const u8{ "gone", "build.zig" };

    const argv = fmtArgs(tmp.dir, io, arena, "zig", &gate_paths);

    // The unchanged list means unchanged end to end: the fixed prefix in its
    // pinned order — a reordered flag would still hand zig fmt the same set
    // of words while meaning something different — then the raw gate paths.
    const want = [_][]const u8{
        "zig", "fmt", "--check", "--ast-check", "gone", "build.zig",
    };
    try std.testing.expectEqual(@as(usize, want.len), argv.len);
    for (want, argv) |expected, actual| {
        try std.testing.expectEqualStrings(expected, actual);
    }
}

/// Reports a checkedFiles enumeration failure through `step`, naming the
/// gate path that stopped it when there is one and falling back to a
/// generic subject when none belongs to the error. Every caller of
/// checkedFiles reports through this one copy, so the wording and the
/// unnamed-path fallback cannot drift apart between the gates.
fn failEnumeration(
    step: *std.Build.Step,
    err: anyerror,
    failed_path: ?[]const u8,
) error{ OutOfMemory, MakeFailed } {
    return step.fail("cannot enumerate '{s}': {s}", .{
        failed_path orelse "the checked paths",
        @errorName(err),
    });
}

/// Allocates one custom analysis step whose make() lives on `T`: the body
/// all three steps' constructors share, differing only in type and display
/// name — every step struct names its maker `make`, so the function comes
/// off `T` and no caller passes it separately. One copy serves all three so
/// their wiring cannot drift apart, the same rule failEnumeration and
/// loadCheckedSources follow for their shared plumbing.
fn newCustomStep(
    b: *std.Build,
    comptime T: type,
    name: []const u8,
) *T {
    const self = b.allocator.create(T) catch @panic("OOM");
    self.* = .{
        .step = std.Build.Step.init(.{
            .id = .custom,
            .name = name,
            .owner = b,
            .makeFn = T.make,
        }),
    };
    return self;
}

/// The shared front half of both analysis steps' make(): enumerates the
/// files `gate_paths` covers and reads each whole, reporting both failure
/// modes — a gate path that cannot be enumerated (failEnumeration), a
/// covered file that cannot be read — through step.fail with the offending
/// path named. One copy serves both steps so the report wording and the
/// fallback for an unnamed path cannot drift apart.
fn loadCheckedSources(
    step: *std.Build.Step,
    root_dir: std.Io.Dir,
    io: std.Io,
    arena: std.mem.Allocator,
    gate_paths: []const []const u8,
) ![]Source {
    var failed_path: ?[]const u8 = null;
    const paths = checkedFiles(root_dir, io, arena, gate_paths, &failed_path) catch |err|
        return failEnumeration(step, err, failed_path);
    const sources = try arena.alloc(Source, paths.len);
    for (paths, 0..) |path, i| {
        sources[i] = .{
            .path = path,
            .text = root_dir.readFileAlloc(io, path, arena, .unlimited) catch |err|
                return step.fail("cannot read '{s}': {s}", .{ path, @errorName(err) }),
        };
    }
    return sources;
}

/// Fails the build when any checked source line exceeds `columns_max`.
/// Columns are Unicode code points; invalid UTF-8 falls back to byte count.
const LineLengthStep = struct {
    step: std.Build.Step,

    const columns_max = 100;

    fn create(b: *std.Build) *LineLengthStep {
        return newCustomStep(
            b,
            LineLengthStep,
            // Computed from columns_max so the displayed name cannot drift
            // from the cap it describes.
            std.fmt.comptimePrint("{d}-column cap", .{columns_max}),
        );
    }

    fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) anyerror!void {
        _ = options;
        const b = step.owner;
        const io = b.graph.io;
        var arena_state = std.heap.ArenaAllocator.init(b.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var report: std.ArrayListUnmanaged(u8) = .empty;
        const sources = try loadCheckedSources(
            step,
            b.build_root.handle,
            io,
            arena,
            &checked_paths,
        );
        for (sources) |source| try checkLineLengths(arena, source, &report);
        // One report line per violation (pinned by the exact-string tests
        // below), so the tally is the newline count — no second output to
        // keep in lockstep with the appends.
        const violations = std.mem.count(u8, report.items, "\n");
        if (violations > 0)
            return step.fail("{d} line(s) exceed {d} columns:\n{s}", .{
                violations, columns_max, report.items,
            });
    }

    /// The cap itself, I/O-free so tests can drive it directly. Appends one
    /// report line per offending line. Takes the whole `Source` rather than
    /// separate text and path arguments so the pair cannot be swapped at a
    /// call site — they are same-typed strings reported together.
    fn checkLineLengths(
        arena: std.mem.Allocator,
        source: Source,
        report: *std.ArrayListUnmanaged(u8),
    ) !void {
        var line_no: usize = 0;
        var lines = std.mem.splitScalar(u8, source.text, '\n');
        while (lines.next()) |line| {
            line_no += 1;
            // Every code point costs at least one byte, so a line at or
            // under the cap in bytes cannot exceed it in columns and needs
            // no UTF-8 decode — the common case in a conforming tree.
            if (line.len <= columns_max) continue;
            if ((std.unicode.utf8CountCodepoints(line) catch line.len) <= columns_max) continue;
            try report.print(arena, "  {s}:{d}\n", .{ source.path, line_no });
        }
    }
};

test "column cap admits a line at exactly the limit" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var report: std.ArrayListUnmanaged(u8) = .empty;

    const exact = "a" ** LineLengthStep.columns_max;
    try LineLengthStep.checkLineLengths(
        arena,
        .{ .path = "f.zig", .text = exact ++ "\nsecond\n" },
        &report,
    );

    try std.testing.expectEqual(@as(usize, 0), report.items.len);
}

test "column cap flags the first line past the limit, with path and line number" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var report: std.ArrayListUnmanaged(u8) = .empty;

    const over = "a" ** (LineLengthStep.columns_max + 1);
    // Two violations, both reported in order: a checker that stops at the
    // first offense cannot pass. The second violation is also the file's
    // last line with no trailing '\n': a file not ending in a newline must
    // still have that final line checked, the boundary where a line-walking
    // refactor most easily drops the tail.
    try LineLengthStep.checkLineLengths(
        arena,
        .{ .path = "f.zig", .text = "ok\n" ++ over ++ "\nalso ok\n" ++ over },
        &report,
    );

    try std.testing.expectEqualStrings("  f.zig:2\n  f.zig:4\n", report.items);
}

test "column cap measures code points, not bytes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var report: std.ArrayListUnmanaged(u8) = .empty;

    // 60 two-byte code points: 120 bytes, but only 60 columns.
    try LineLengthStep.checkLineLengths(
        arena,
        .{ .path = "f.zig", .text = "\u{00e9}" ** 60 },
        &report,
    );
    try std.testing.expectEqual(@as(usize, 0), report.items.len);

    // The boundary itself on the decoded side: exactly the cap in code
    // points while over it in bytes. A comparison that drops to '<' here
    // flags this line — the ASCII exact-limit case cannot catch it, because
    // a sub-cap byte line never reaches the decode at all.
    try LineLengthStep.checkLineLengths(
        arena,
        .{ .path = "f.zig", .text = "\u{00e9}" ** LineLengthStep.columns_max },
        &report,
    );
    try std.testing.expectEqual(@as(usize, 0), report.items.len);

    // The invalid side of the same boundary: 101 code points is over the cap
    // whatever the encoding, so wide characters are not skipped wholesale.
    const wide_over = "\u{00e9}" ** (LineLengthStep.columns_max + 1);
    try LineLengthStep.checkLineLengths(
        arena,
        .{ .path = "f.zig", .text = wide_over },
        &report,
    );
    try std.testing.expectEqualStrings("  f.zig:1\n", report.items);
}

test "column cap falls back to byte count on invalid UTF-8" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var report: std.ArrayListUnmanaged(u8) = .empty;

    const bad = "\xff" ** (LineLengthStep.columns_max + 1);
    try LineLengthStep.checkLineLengths(
        arena,
        .{ .path = "f.zig", .text = bad },
        &report,
    );

    // Same path:line report as the valid-UTF-8 over-limit case.
    try std.testing.expectEqualStrings("  f.zig:1\n", report.items);
}

/// The files whose `test` blocks Zig collects (the test-module roots). One
/// list serves both uses in the gate below: the seeds of the reachability
/// walk, and the files exempt from requiring reachability. build.zig
/// belongs beside the two src/ roots: addChecks compiles it as its own
/// plain-module test binary (build_tests), so its test blocks run like
/// theirs — and a build script importing a src/ module owes that module the
/// same refAllDecls pairing any other root owes.
const test_roots = [_][]const u8{
    "src/root.zig",
    "src/main.zig",
    "build.zig",
    "examples/embed-single/main.zig",
    "examples/embed-cluster/main.zig",
    "examples/sidecar/main.zig",
};

/// Fails the build when no chain of real @imports reaches a gated Zig
/// module from a test-module root (src/root.zig, src/main.zig or
/// build.zig): only such a chain makes Zig 0.16 collect the module's `test`
/// blocks, so an unreachable module's tests silently never run while
/// `zig build test` stays green. The walk spans every gated Zig file, not
/// only src/: a source directory added to checked_paths joins the
/// registration obligation together with the formatter and column-cap
/// coverage it gains, never one without the other. The step also fails when
/// a test root imports a src/ module
/// but never wraps that import in refAllDecls: registration alone collects
/// tests and analyzes nothing, an unreferenced `pub` declaration is
/// compiled into nothing, so the module's public surface would reach no
/// semantic check. Collection follows analyzed imports transitively — verified
/// on 0.16.0: with root.zig importing a.zig importing b.zig, b's tests run;
/// an import in a declaration that is never analyzed (an unused
/// container-level const) collects nothing — so the gate walks real
/// @import calls across every walked module (collectImports), resolving each
/// to the canonical form std.fs.path.resolvePosix defines for recorded
/// imports — the resolver importBetween reaches through relativePosix, so
/// both sides of every comparison meet in one form.
/// Only a literal `@import("path")` call counts: a mention inside a comment
/// or any string literal registers nothing. A third half (caseMismatchLines)
/// reports an import that differs from the walked module it resolves to only
/// by letter case — it compiles on a case-insensitive filesystem and fails on
/// a case-sensitive one, and hides behind any other chain reaching the module.
const TestRegistrationStep = struct {
    step: std.Build.Step,

    fn create(b: *std.Build) *TestRegistrationStep {
        return newCustomStep(b, TestRegistrationStep, "test registration and declaration analysis");
    }

    fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) anyerror!void {
        _ = options;
        const b = step.owner;
        const io = b.graph.io;
        var arena_state = std.heap.ArenaAllocator.init(b.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var report: std.ArrayListUnmanaged(u8) = .empty;
        // Every gated module's text, straight from checked_paths: the walk
        // owns the whole allowlist, so a source directory added there later
        // joins this gate's obligation together with the formatter and
        // column-cap coverage it gains — never coverage while its tests
        // stay silently uncollected. Enumeration goes through
        // loadCheckedSources, so every file-covering surface shares the
        // dispatcher and its failure reporting. build.zig.zon rides the
        // allowlist whole for the column cap but is not a Zig module; the
        // .zig filter drops it (a wrong-case suffix cannot appear — the
        // coverage gate rejects one before it could settle here). build.zig
        // stays and counts as a test root: addChecks compiles it as its own
        // test module.
        const loaded = try loadCheckedSources(step, b.build_root.handle, io, arena, &checked_paths);
        var sources: std.ArrayListUnmanaged(Source) = .empty;
        for (loaded) |source| {
            if (std.mem.endsWith(u8, source.path, ".zig")) try sources.append(arena, source);
        }
        try classifyModules(arena, sources.items, std.fs.path.sep, &report);
        var analysis_report: std.ArrayListUnmanaged(u8) = .empty;
        try declarationAnalysisGaps(arena, sources.items, std.fs.path.sep, &analysis_report);
        var case_report: std.ArrayListUnmanaged(u8) = .empty;
        try caseMismatchLines(arena, sources.items, std.fs.path.sep, &case_report);
        // Each core appends one report line per finding (pinned by the
        // exact-string tests below), so each tally is a newline count — no
        // second output to keep in lockstep with the appends.
        var message: std.ArrayListUnmanaged(u8) = .empty;
        try appendSection(
            arena,
            &message,
            "module(s) whose tests never run",
            report.items,
        );
        try appendSection(
            arena,
            &message,
            "module(s) whose public declarations are never analyzed",
            analysis_report.items,
        );
        try appendSection(
            arena,
            &message,
            "import(s) that resolve only on a case-insensitive filesystem",
            case_report.items,
        );
        if (message.items.len > 0)
            return step.fail("{s}", .{message.items});
    }

    /// Appends one counted section of make()'s assembled failure message:
    /// "{count} {header}:" followed by the section's report lines, separated
    /// from any earlier section by a blank line. The count is the body's
    /// newline tally — derived here, beside the body it describes, so a
    /// caller cannot hand in the two out of lockstep. One copy serves all
    /// three sections so their join and skip-when-empty rules cannot drift
    /// apart.
    fn appendSection(
        arena: std.mem.Allocator,
        message: *std.ArrayListUnmanaged(u8),
        header: []const u8,
        body: []const u8,
    ) !void {
        const count = std.mem.count(u8, body, "\n");
        if (count == 0) return;
        if (message.items.len > 0) try message.append(arena, '\n');
        try message.print(arena, "{d} {s}:\n{s}", .{ count, header, body });
    }

    /// The gate's decision core, I/O-free so tests drive it directly, the
    /// way checkLineLengths serves the column cap: from the test roots, follow
    /// real imports across `sources` and append one report line per module
    /// no chain reaches. Each dequeued module's text is tokenized once and
    /// its recorded imports resolved against the same importTargetsByName map
    /// the gate's other two halves read — the self-skip and the
    /// first-candidate-wins tie-break live there, not here, so the halves
    /// cannot drift apart about what reaches what.
    /// `separator` is a parameter so any platform can be simulated in a test.
    fn classifyModules(
        arena: std.mem.Allocator,
        sources: []const Source,
        separator: u8,
        report: *std.ArrayListUnmanaged(u8),
    ) !void {
        // The walk works in indices into `sources`, so the queue can hold no
        // path that lacks a text and a module is marked reached exactly when
        // it is enqueued — every index enters the queue once and is visited
        // once, so an importer reached twice cannot enqueue its target twice.
        const reached = try arena.alloc(bool, sources.len);
        @memset(reached, false);
        // Path -> position, resolving the targets importTargetsByName names
        // back to the index whose reached flag the queue protocol owns.
        // First wins on a duplicated path, matching importTargetsByName's
        // documented tie-break.
        var index_of: std.StringArrayHashMapUnmanaged(usize) = .empty;
        for (sources, 0..) |source, i| {
            if (!index_of.contains(source.path)) try index_of.put(arena, source.path, i);
        }
        var queue: std.ArrayListUnmanaged(usize) = .empty;
        for (sources, 0..) |source, i| {
            if (!try isTestRoot(arena, source.path, separator)) continue;
            reached[i] = true;
            try queue.append(arena, i);
        }
        var cursor: usize = 0;
        while (cursor < queue.items.len) : (cursor += 1) {
            const from = sources[queue.items[cursor]];
            const targets = try importTargetsByName(arena, sources, from.path, separator, false);
            for (try collectImports(arena, from.text)) |ref| {
                const target_path = targets.get(ref.path) orelse continue;
                const target_index = index_of.get(target_path).?;
                if (reached[target_index]) continue;
                reached[target_index] = true;
                try queue.append(arena, target_index);
            }
        }
        // Every test root was seeded as reached above, so anything still
        // unreached here is an ordinary module no chain reaches.
        for (sources, 0..) |source, i| {
            if (reached[i]) continue;
            try report.print(arena, "  {s}: not reachable from a test root\n", .{source.path});
        }
    }

    /// appendZigFilesUnder joins with the platform separator ('\') on Windows, while
    /// test_roots is written with '/', so a byte-equal comparison never matches there:
    /// the roots would be checked as ordinary modules and fail the gate (nothing
    /// @imports them as files). Normalize the walked path to '/' separators first —
    /// the same translation importBetween applies after resolving. `separator` is a
    /// parameter so any platform can be simulated in a test.
    fn isTestRoot(
        arena: std.mem.Allocator,
        path: []const u8,
        separator: u8,
    ) !bool {
        const normalized = try normalizeSeparators(arena, path, separator);
        return listContainsPath(&test_roots, normalized);
    }

    /// The importer and the imported file, as one named pair so they cannot
    /// be swapped at a call site — the import string between two files reads
    /// backwards if they trade places. The same rule Source applies to its
    /// path/text pair.
    const ImportPair = struct { from: []const u8, to: []const u8 };

    /// The @import string that reaches `pair.to` from `pair.from`:
    /// relative to the importing file's directory and
    /// '/'-separated, the only form an import string may hold — "sub/x.zig"
    /// from a root-level importer, "y.zig" beside the importer,
    /// "../other/y.zig" across branches (a submodule importing a sibling
    /// tree climbs out). Both paths come from one walk of "src/", so
    /// neither carries a drive or leading separator; `separator` is a parameter
    /// so any platform can be simulated in a test.
    ///
    /// The Posix flavors are called directly, not the dispatching
    /// `std.fs.path.relative`, so the computation stays in the '/' world on
    /// every host: a native-flavor call would emit '\' separators on Windows
    /// and never match the recorded import strings. The empty cwd makes the
    /// resolution purely build-root-relative — no process-cwd leak into a
    /// gate run from a subdirectory.
    fn importBetween(
        arena: std.mem.Allocator,
        pair: ImportPair,
        separator: u8,
    ) ![]const u8 {
        const from = try normalizeSeparators(arena, pair.from, separator);
        const to = try normalizeSeparators(arena, pair.to, separator);
        // Resolution is anchored at the importing file's directory, so the
        // filename comes off before the relative walk: "src/root.zig"
        // reaches its neighbor as "sub/x.zig", not "../sub/x.zig". A
        // root-level importer has no directory to strip, so its import
        // string is already build-root-relative.
        const from_dir = std.fs.path.dirnamePosix(from) orelse "";
        if (from_dir.len == 0) return to;
        // relativePosix resolves both sides (collapsing "." and ".."), walks
        // the common component prefix, and keeps leading ".." runs — the same
        // canonical form resolvePosix gives collectImports' recorded imports.
        return std.fs.path.relativePosix(arena, "", from_dir, to);
    }

    /// The map both analysis halves resolve reported imports against: the
    /// import string from `importer_path` to every other walked module,
    /// mapped to that module's path, in walk order. One copy owns the
    /// decisions both halves must agree on — the self-skip, the
    /// first-candidate-wins tie-break (two candidates collide only if
    /// `sources` lists a path twice, which a filesystem walk never does but
    /// a hand-edited checked_paths could) and the derivation through
    /// importBetween. `exclude_test_roots` marks candidates that cannot be
    /// import targets for the asking half (one root importing another is no
    /// registration); the case half keeps roots among its targets, since a
    /// wrong-case import of another root reports just the same.
    fn importTargetsByName(
        arena: std.mem.Allocator,
        sources: []const Source,
        importer_path: []const u8,
        separator: u8,
        exclude_test_roots: bool,
    ) !std.StringArrayHashMapUnmanaged([]const u8) {
        var named: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
        for (sources) |candidate| {
            if (std.mem.eql(u8, candidate.path, importer_path)) continue;
            if (exclude_test_roots and try isTestRoot(arena, candidate.path, separator)) continue;
            const wanted = try importBetween(
                arena,
                .{ .from = importer_path, .to = candidate.path },
                separator,
            );
            if (!named.contains(wanted)) try named.put(arena, wanted, candidate.path);
        }
        return named;
    }

    /// One real `@import("path")` call found in a token stream: `path` is the
    /// literal between the quotes, resolved to its canonical form
    /// (std.fs.path.resolvePosix — the resolver importBetween reaches through
    /// relativePosix, so recorded and computed import strings always meet in
    /// one form) and `wrapped` whether the call sits directly inside a
    /// `std.testing.refAllDecls`/`refAllDeclsRecursive` argument
    /// list — the form that forces the target's public declarations through
    /// the analyzer, not merely collects its tests. Comments and every kind
    /// of string literal yield nothing, and only a literal path argument
    /// counts — one collector serving both questions, does this file import X
    /// and is the import wrapped, so they cannot drift apart. Four tokens of
    /// look-behind span any whitespace:
    /// `refAllDecls` `(` `@import` `(` `path`. The identifier spelling is
    /// matched exactly, so `myRefAllDecls(@import("x"))` is not a wrapper.
    const ImportRef = struct {
        path: []const u8,
        wrapped: bool,
    };

    fn collectImports(arena: std.mem.Allocator, text: []const u8) ![]ImportRef {
        const terminated = try arena.dupeZ(u8, text);
        var lexer = std.zig.Tokenizer.init(terminated);
        var prev_tags: [4]std.zig.Token.Tag = .{ .eof, .eof, .eof, .eof };
        var prev_slices: [4][]const u8 = .{ "", "", "", "" };
        var refs: std.ArrayListUnmanaged(ImportRef) = .empty;
        while (true) {
            const token = lexer.next();
            if (token.tag == .eof) return refs.toOwnedSlice(arena);
            // While `token` is read, prev_*[3] is one token back, [2] two,
            // and so on: `@import` at [2] with `(` at [3] is a call, and a
            // wrapper adds `refAllDecls` at [0] behind another `(` at [1].
            if (token.tag == .string_literal and
                prev_tags[2] == .builtin and std.mem.eql(u8, prev_slices[2], "@import") and
                prev_tags[3] == .l_paren)
            {
                const wrapped = prev_tags[1] == .l_paren and prev_tags[0] == .identifier and
                    (std.mem.eql(u8, prev_slices[0], "refAllDecls") or
                        std.mem.eql(u8, prev_slices[0], "refAllDeclsRecursive"));
                try refs.append(arena, .{
                    .path = try std.fs.path.resolvePosix(
                        arena,
                        &.{terminated[token.loc.start + 1 .. token.loc.end - 1]},
                    ),
                    .wrapped = wrapped,
                });
            }
            prev_tags[0] = prev_tags[1];
            prev_tags[1] = prev_tags[2];
            prev_tags[2] = prev_tags[3];
            prev_tags[3] = token.tag;
            prev_slices[0] = prev_slices[1];
            prev_slices[1] = prev_slices[2];
            prev_slices[2] = prev_slices[3];
            prev_slices[3] = terminated[token.loc.start..token.loc.end];
        }
    }

    /// The gate's second half: a module a test root imports but that root
    /// never wraps in `refAllDecls`/`refAllDeclsRecursive` is reported.
    /// Registration alone collects a module's tests and analyzes nothing —
    /// Zig compiles an unreferenced `pub` declaration into nothing — so the
    /// pairing src/root.zig documents (register AND a line in the "all
    /// public declarations analyze" test) is what gets declarations
    /// semantically checked, and dropping the second half used to be
    /// invisible to every gate while `zig build test` stayed green. Only the
    /// test roots are constrained: that is where the documented
    /// convention puts both halves, while an intermediate module's imports
    /// are ordinary use. An import resolving to no walked module (`std`,
    /// `build_options`, the `coppiz` package) needs no wrapper. One report
    /// line per distinct import string per root, whatever the number of bare
    /// occurrences.
    fn declarationAnalysisGaps(
        arena: std.mem.Allocator,
        sources: []const Source,
        separator: u8,
        report: *std.ArrayListUnmanaged(u8),
    ) !void {
        for (sources) |root_source| {
            if (!try isTestRoot(arena, root_source.path, separator)) continue;

            // Resolve every other module's import string from this root up
            // front: the string depends on (root, candidate) alone, so
            // deriving it per import would redo identical work. A candidate
            // that is itself a test root is absent — one root importing the
            // other is not a registration and asks for no wrapper.
            const named =
                try importTargetsByName(arena, sources, root_source.path, separator, true);

            const imports = try collectImports(arena, root_source.text);
            var wrapped_paths: std.StringArrayHashMapUnmanaged(void) = .empty;
            for (imports) |ref| {
                if (ref.wrapped) try wrapped_paths.put(arena, ref.path, {});
            }
            var reported: std.StringArrayHashMapUnmanaged(void) = .empty;
            for (imports) |ref| {
                if (wrapped_paths.contains(ref.path)) continue;
                if (reported.contains(ref.path)) continue;
                const candidate_path = named.get(ref.path) orelse continue;
                try reported.put(arena, ref.path, {});
                try report.print(
                    arena,
                    "  {s}: imported by {s} without forced declaration analysis\n",
                    .{ candidate_path, root_source.path },
                );
            }
        }
    }

    /// The gate's third half, I/O-free so tests drive it directly beside
    /// classifyModules and declarationAnalysisGaps: appends one report line
    /// per real @import whose spelling differs from the walked module it
    /// resolves to only by letter case. Such an import compiles on a
    /// case-insensitive filesystem (macOS's default APFS, Windows NTFS) and
    /// fails to resolve on a case-sensitive one (Linux — the musl static
    /// binary is the strictest declared host, ADR 0001), and whenever any
    /// other chain reaches the target module neither earlier half says
    /// anything: the walk compares exact bytes, so the wrong-case string
    /// matches nothing and exempts itself. Every gated module's imports are
    /// scanned, not only the test roots': resolution correctness is not a
    /// roots-only convention, and an ordinary module's wrong-case import
    /// hides behind another module's correct one just the same. The
    /// wrong-case *filename* counterpart lives in GateCoverageStep
    /// (violationLines); this covers the import strings. One report line per
    /// distinct import string per importing file, whatever the number of
    /// occurrences. `separator` is a parameter so any platform can be
    /// simulated in a test.
    fn caseMismatchLines(
        arena: std.mem.Allocator,
        sources: []const Source,
        separator: u8,
        report: *std.ArrayListUnmanaged(u8),
    ) !void {
        for (sources) |source| {
            // The import string from this importer to every walked module,
            // keyed exactly (named) and case-folded (folded): an import
            // matching named resolves everywhere and needs no report; one
            // matching folded alone resolves only where the filesystem
            // ignores case. Package and builtin imports ("std",
            // "build_options", the coppiz package) match neither and stay
            // out, as does anything pointing outside the walked tree. Roots
            // stay among the candidates: a wrong-case import of another root
            // reports just the same. The folded map is derived from named's
            // entries in their insertion order, so its first-wins rule
            // follows the candidate order importTargetsByName fixed.
            const named = try importTargetsByName(arena, sources, source.path, separator, false);
            var folded: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
            var named_it = named.iterator();
            while (named_it.next()) |entry| {
                const key = try std.ascii.allocLowerString(arena, entry.key_ptr.*);
                if (!folded.contains(key)) try folded.put(arena, key, entry.key_ptr.*);
            }
            var reported: std.StringArrayHashMapUnmanaged(void) = .empty;
            for (try collectImports(arena, source.text)) |ref| {
                if (named.contains(ref.path)) continue;
                const canonical =
                    folded.get(try std.ascii.allocLowerString(arena, ref.path)) orelse continue;
                if (reported.contains(ref.path)) continue;
                try reported.put(arena, ref.path, {});
                try report.print(
                    arena,
                    "  {s}: imported by {s} as \"{s}\"; " ++
                        "only \"{s}\" resolves on every filesystem\n",
                    .{ named.get(canonical).?, source.path, ref.path, canonical },
                );
            }
        }
    }
};

test "collectImports records import strings in resolvePosix's canonical form" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Every right-hand spelling reaches the same file as the left-hand one
    // (verified on 0.16.0: @import("./sub/x.zig") collects the target's
    // tests), so an exact-byte comparison reported a reachable module as
    // unreachable — and hid bare imports behind wrappers spelled with "./".
    // Canonicalization is std.fs.path.resolvePosix over the lone string, the
    // resolver importBetween reaches through relativePosix, so recorded and
    // computed import strings always meet in one form.
    const cases = [_][2][]const u8{
        .{ "sub/x.zig", "sub/x.zig" },
        .{ "./sub/x.zig", "sub/x.zig" },
        .{ "sub//x.zig", "sub/x.zig" },
        .{ "sub/", "sub" },
        .{ "sub/./x.zig", "sub/x.zig" },
        .{ "sub/../sub/x.zig", "sub/x.zig" },
        .{ "a/b/../../c.zig", "c.zig" },
        // Leading ".." runs climb out of the importer's directory: nothing
        // above them to pop, so they survive verbatim.
        .{ "../other/y.zig", "../other/y.zig" },
        .{ "../../..", "../../.." },
        .{ "a/../../b.zig", "../b.zig" },
        // Package and builtin names pass through untouched.
        .{ "std", "std" },
        // An empty spelling resolves to ".": it matches no walked module,
        // like any package name.
        .{ "", "." },
    };
    for (cases) |case| {
        const text =
            try std.fmt.allocPrint(arena, "_ = @import(\"{s}\");\n", .{case[0]});
        const refs = try TestRegistrationStep.collectImports(arena, text);
        try std.testing.expectEqual(@as(usize, 1), refs.len);
        try std.testing.expectEqualStrings(case[1], refs[0].path);
    }
}

test "test-registration gate matches imports spelled with a redundant '.' or '..'" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Both imports are real calls whose targets' tests run; only their
    // spelling differs from the canonical form importBetween computes.
    // ghost.zig has no importer: naming it alone is what separates "the
    // variants matched" from a walk gone silent that reports nothing at
    // all — the same non-vacuity guard the refAllDecls test carries.
    const sources = [_]Source{
        .{
            .path = "src\\main.zig",
            .text = "comptime {\n" ++
                "    _ = @import(\"./helper.zig\");\n" ++
                "    _ = @import(\"sub/../lateral.zig\");\n" ++
                "}\n",
        },
        .{ .path = "src\\root.zig", .text = "" },
        .{ .path = "src\\helper.zig", .text = "" },
        .{ .path = "src\\lateral.zig", .text = "" },
        .{ .path = "src\\ghost.zig", .text = "" },
    };

    var report: std.ArrayListUnmanaged(u8) = .empty;
    try TestRegistrationStep.classifyModules(arena, &sources, '\\', &report);

    try std.testing.expectEqualStrings(
        "  src\\ghost.zig: not reachable from a test root\n",
        report.items,
    );
}

test "declaration-analysis gate treats wrapped spellings as wrapping the module" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The wrapper and the bare import name the same file through different
    // spellings; normalization puts both on one form, so the documented
    // pairing is satisfied and a.zig is not reported. c.zig is imported
    // bare with no wrapper and must still be — otherwise an empty report
    // could not tell "the wrapped spelling counted" from a gate that
    // stopped reporting altogether.
    const sources = [_]Source{
        .{
            .path = "src\\root.zig",
            .text = "_ = @import(\"./a.zig\");\n" ++
                "test {\n" ++
                "    std.testing.refAllDecls(@import(\".//a.zig\"));\n" ++
                "}\n" ++
                "_ = @import(\"c.zig\");\n",
        },
        .{ .path = "src\\main.zig", .text = "" },
        .{ .path = "src\\a.zig", .text = "" },
        .{ .path = "src\\c.zig", .text = "" },
    };

    var report: std.ArrayListUnmanaged(u8) = .empty;
    try TestRegistrationStep.declarationAnalysisGaps(arena, &sources, '\\', &report);

    try std.testing.expectEqualStrings(
        "  src\\c.zig: imported by src\\root.zig without forced declaration analysis\n",
        report.items,
    );
}

test "importBetween resolves the import string from the importing file's directory" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A root-level importer reaches a submodule by its path from src/.
    try std.testing.expectEqualStrings(
        "sub/x.zig",
        try TestRegistrationStep.importBetween(
            arena,
            .{ .from = "src/root.zig", .to = "src/sub/x.zig" },
            '/',
        ),
    );

    // A top-level importer has no directory to strip: the target's
    // build-root-relative path goes out verbatim — the branch only the
    // build.zig-imports-src end-to-end test exercises otherwise.
    try std.testing.expectEqualStrings(
        "src/helper.zig",
        try TestRegistrationStep.importBetween(
            arena,
            .{ .from = "build.zig", .to = "src/helper.zig" },
            '/',
        ),
    );

    // Modules in one subdirectory are siblings: a bare filename.
    try std.testing.expectEqualStrings(
        "y.zig",
        try TestRegistrationStep.importBetween(
            arena,
            .{ .from = "src/sub/x.zig", .to = "src/sub/y.zig" },
            '/',
        ),
    );
    // Across branches the import climbs out with "..".
    try std.testing.expectEqualStrings(
        "../other/y.zig",
        try TestRegistrationStep.importBetween(
            arena,
            .{ .from = "src/sub/x.zig", .to = "src/other/y.zig" },
            '/',
        ),
    );
    // One ".." per directory left under the importer: c.zig sits in
    // src/a/b/, two levels below src/. Backslashes here double as another
    // pass through the separator normalization.
    try std.testing.expectEqualStrings(
        "../../top.zig",
        try TestRegistrationStep.importBetween(
            arena,
            .{ .from = "src\\a\\b\\c.zig", .to = "src\\top.zig" },
            '\\',
        ),
    );
    // The shared prefix must stop on a '/' boundary: src/aa/ and src/ab/
    // share "src/a" byte-wise but are different directories.
    try std.testing.expectEqualStrings(
        "../ab/g.zig",
        try TestRegistrationStep.importBetween(
            arena,
            .{ .from = "src/aa/f.zig", .to = "src/ab/g.zig" },
            '/',
        ),
    );

    // The Windows case, simulated on every host through the separator argument:
    // walked paths are normalized before resolution.
    const win = try normalizeSeparators(arena, "sub\\x\\y.zig", '\\');
    try std.testing.expectEqualStrings("sub/x/y.zig", win);
    try std.testing.expectEqualStrings(
        "y.zig",
        try TestRegistrationStep.importBetween(
            arena,
            .{ .from = "src\\sub\\x.zig", .to = "src\\sub\\y.zig" },
            '\\',
        ),
    );
}

test "test roots match whatever separator the walker produced" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The form appendZigFilesUnder hands make() on Windows, simulated through the separator
    // argument: joined with '\', so a byte-equal match against the '/'-written
    // test_roots would fail and both roots would be reported as unregistered modules.
    try std.testing.expect(try TestRegistrationStep.isTestRoot(arena, "src\\root.zig", '\\'));
    try std.testing.expect(try TestRegistrationStep.isTestRoot(arena, "src\\main.zig", '\\'));
    try std.testing.expect(!try TestRegistrationStep.isTestRoot(arena, "src\\sub\\x.zig", '\\'));

    // What make() sees on this host.
    const native = try normalizeSeparators(
        arena,
        "src/root.zig",
        std.fs.path.sep,
    );
    try std.testing.expect(try TestRegistrationStep.isTestRoot(arena, native, std.fs.path.sep));

    // build.zig is compiled as its own plain-module test binary, so it is a
    // test root whatever separator the walk produced — including the
    // separator-free form a top-level listing always has.
    try std.testing.expect(try TestRegistrationStep.isTestRoot(arena, "build.zig", '/'));
    try std.testing.expect(try TestRegistrationStep.isTestRoot(arena, "build.zig", '\\'));
}

test "test-registration gate reports exactly the modules no chain reaches from a test root" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The tree: main.zig imports sub/registered.zig, and only
    // registered.zig reaches ../other/second.zig — second's tests run
    // through that chain, so neither may be reported, whatever file imports
    // it. registered.zig also *mentions* sub/unregistered.zig inside a
    // comment: no real import call, so the orphan stays an orphan.
    const sources = [_]Source{
        .{
            .path = "src\\main.zig",
            .text = "comptime {\n    _ = @import(\"sub/registered.zig\");\n}\n",
        },
        .{ .path = "src\\root.zig", .text = "" },
        .{
            .path = "src\\sub\\registered.zig",
            .text = "_ = @import(\"../other/second.zig\");\n" ++
                "// _ = @import(\"sub/unregistered.zig\"); registers nothing\n",
        },
        .{ .path = "src\\other\\second.zig", .text = "" },
        .{ .path = "src\\sub\\unregistered.zig", .text = "" },
    };

    var report: std.ArrayListUnmanaged(u8) = .empty;
    try TestRegistrationStep.classifyModules(arena, &sources, '\\', &report);

    // The roots are never reported though nothing imports them; exactly the
    // orphan is, named by its walked path — the string make() prints on any
    // host.
    try std.testing.expectEqualStrings(
        "  src\\sub\\unregistered.zig: not reachable from a test root\n",
        report.items,
    );

    // The same tree in this host's separator form decides identically.
    const sep_str = std.fs.path.sep_str;
    const native_sources = [_]Source{
        .{
            .path = "src" ++ sep_str ++ "main.zig",
            .text = sources[0].text,
        },
        .{ .path = "src" ++ sep_str ++ "root.zig", .text = "" },
        .{
            .path = "src" ++ sep_str ++ "sub" ++ sep_str ++ "registered.zig",
            .text = sources[2].text,
        },
        .{ .path = "src" ++ sep_str ++ "other" ++ sep_str ++ "second.zig", .text = "" },
        .{ .path = "src" ++ sep_str ++ "sub" ++ sep_str ++ "unregistered.zig", .text = "" },
    };

    report = .empty;
    try TestRegistrationStep.classifyModules(arena, &native_sources, std.fs.path.sep, &report);

    try std.testing.expectEqualStrings(
        "  src" ++ sep_str ++ "sub" ++ sep_str ++
            "unregistered.zig: not reachable from a test root\n",
        report.items,
    );
}

test "test-registration gate counts an import wrapped in refAllDecls as registering" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The pairing src/root.zig documents makes the refAllDecls line itself
    // the registration: its import "both registers it and forces every
    // public declaration through the semantic analyzer". A matcher that
    // counted only unwrapped calls would report every module registered
    // solely by its analysis-test line — the shape this tree tells
    // contributors to write — so the walk must read wrapped imports off the
    // same token stream. helper.zig is reached only through the wrapper and
    // must stay silent; ghost.zig keeps the assertion from passing vacuously.
    const sources = [_]Source{
        .{
            .path = "src\\root.zig",
            .text = "test {\n" ++
                "    std.testing.refAllDecls(@import(\"helper.zig\"));\n" ++
                "}\n",
        },
        .{ .path = "src\\main.zig", .text = "" },
        .{ .path = "src\\helper.zig", .text = "" },
        .{ .path = "src\\ghost.zig", .text = "" },
    };

    var report: std.ArrayListUnmanaged(u8) = .empty;
    try TestRegistrationStep.classifyModules(arena, &sources, '\\', &report);

    try std.testing.expectEqualStrings(
        "  src\\ghost.zig: not reachable from a test root\n",
        report.items,
    );
}

test "classifyModules classifies through an import cycle and reports modules below an orphan" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Two reachable modules importing each other: real trees do this for
    // shared types, and the walk must visit the pair once — reporting both
    // as reached, terminating, and still naming the modules outside the
    // cycle. The exact report doubles as the termination proof: a walk
    // that re-enqueued visited modules never reached these assertions.
    //
    // The chain below the cycle matters too: down.zig is imported by
    // orphan.zig, which no root reaches, so down.zig has no chain from a
    // test root either and must be reported beside its importer — a walk
    // that seeded from unreachable modules instead of only the roots would
    // quietly classify the pair as covered.
    const sources = [_]Source{
        .{ .path = "src\\root.zig", .text = "_ = @import(\"a.zig\");\n" },
        .{ .path = "src\\main.zig", .text = "" },
        .{ .path = "src\\a.zig", .text = "_ = @import(\"b.zig\");\n" },
        .{ .path = "src\\b.zig", .text = "_ = @import(\"a.zig\");\n" },
        .{ .path = "src\\orphan.zig", .text = "_ = @import(\"down.zig\");\n" },
        .{ .path = "src\\down.zig", .text = "" },
    };

    var report: std.ArrayListUnmanaged(u8) = .empty;
    try TestRegistrationStep.classifyModules(arena, &sources, '\\', &report);

    try std.testing.expectEqualStrings(
        \\  src\orphan.zig: not reachable from a test root
        \\  src\down.zig: not reachable from a test root
        \\
    , report.items);
}

test "collectImports counts only a real @import call" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The reachability question classifyModules asks of a whole text,
    // answered the way production resolves it: collect then look up. The
    // forms that register: plain, spaced across lines, sharing a line with
    // a trailing comment.
    const counts = struct {
        fn counts(
            a: std.mem.Allocator,
            text: []const u8,
            wanted_import: []const u8,
        ) !bool {
            for (try TestRegistrationStep.collectImports(a, text)) |ref| {
                if (std.mem.eql(u8, ref.path, wanted_import)) return true;
            }
            return false;
        }
    }.counts;
    try std.testing.expect(try counts(arena, "_ = @import(\"sub/x.zig\");\n", "sub/x.zig"));
    try std.testing.expect(try counts(
        arena,
        "comptime {\n    _ = @import(\n        \"sub/x.zig\",\n    );\n}\n",
        "sub/x.zig",
    ));
    try std.testing.expect(try counts(
        arena,
        "_ = @import(\"sub/x.zig\"); // keep this one\n",
        "sub/x.zig",
    ));

    // The false-pass directions the removed textual matcher admitted:
    // mention inside an ordinary string literal, in a comment, in multiline
    // string data — none of them import anything.
    try std.testing.expect(!try counts(
        arena,
        "const msg = \"@import(\\\"sub/x.zig\\\") registers nothing\";\n",
        "sub/x.zig",
    ));
    try std.testing.expect(!try counts(arena, "// _ = @import(\"sub/x.zig\");\n", "sub/x.zig"));
    try std.testing.expect(!try counts(
        arena,
        "const prose =\n" ++
            "\\\\ @import(\"sub/x.zig\") reads well here.\n" ++
            ";\n",
        "sub/x.zig",
    ));
    try std.testing.expect(!try counts(
        arena,
        "// @import(\n// \"sub/x.zig\"); split across comment lines\n",
        "sub/x.zig",
    ));

    // A different builtin taking the same path is not registration either.
    try std.testing.expect(!try counts(
        arena,
        "const img = @embedFile(\"sub/x.zig\");\n",
        "sub/x.zig",
    ));

    // Neither is a computed path (@import(a ++ b)): only a literal string
    // argument matches, so such a module is reported by the gate — failing
    // loudly, never half-matched.
    try std.testing.expect(!try counts(
        arena,
        "const dir = \"sub\"; _ = @import(dir ++ \"/x.zig\");\n",
        "sub/x.zig",
    ));

    // A different path does not match.
    try std.testing.expect(!try counts(arena, "_ = @import(\"other/y.zig\");\n", "sub/x.zig"));
}

test "declaration-analysis gate reports a module its root never wraps in refAllDecls" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The half-done state every gate used to admit: the comptime block
    // registers a.zig, so its tests collect and the reachability walk is
    // satisfied, yet nothing references its declarations — Zig compiles an
    // unreferenced `pub` declaration into nothing, checked by nothing,
    // while `zig build test` stays green.
    const sources = [_]Source{
        .{
            .path = "src\\root.zig",
            .text = "comptime {\n    _ = @import(\"a.zig\");\n}\n",
        },
        .{ .path = "src\\main.zig", .text = "" },
        .{ .path = "src\\a.zig", .text = "" },
    };

    var report: std.ArrayListUnmanaged(u8) = .empty;
    try TestRegistrationStep.declarationAnalysisGaps(arena, &sources, '\\', &report);

    try std.testing.expectEqualStrings(
        \\  src\a.zig: imported by src\root.zig without forced declaration analysis
        \\
    , report.items);
}

test "declaration-analysis gate admits wrappers, duplicates and non-module imports" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // What must pass without a report: a bare registration doubled by a
    // refAllDecls line (the documented pairing), either wrapper spelling
    // across any whitespace, package and builtin imports ("build_options",
    // "std") resolving to no walked module, an import whose target does not
    // exist, and one distinct import string reported only once however often
    // it appears bare. What must still be caught: a look-alike wrapper —
    // `myRefAllDecls` analyzes nothing, so c.zig is the one reported module.
    const sources = [_]Source{
        .{
            .path = "src/root.zig",
            .text = "const o = @import(\"build_options\");\n" ++
                "_ = @import(\"std\");\n" ++
                "comptime {\n" ++
                "    _ = @import(\"a.zig\");\n" ++
                "    _ = @import(\"a.zig\");\n" ++
                "    _ = @import(\"c.zig\");\n" ++
                "    _ = @import(\"nowhere.zig\");\n" ++
                "}\n" ++
                "test {\n" ++
                "    std.testing.refAllDecls(@import(\"a.zig\"));\n" ++
                "    std.testing.refAllDeclsRecursive(\n" ++
                "        @import(\"b.zig\"),\n" ++
                "    );\n" ++
                "    myRefAllDecls(@import(\"c.zig\"));\n" ++
                "}\n",
        },
        .{ .path = "src/main.zig", .text = "" },
        .{ .path = "src/a.zig", .text = "" },
        .{ .path = "src/b.zig", .text = "" },
        .{ .path = "src/c.zig", .text = "" },
    };

    var report: std.ArrayListUnmanaged(u8) = .empty;
    try TestRegistrationStep.declarationAnalysisGaps(arena, &sources, '/', &report);

    try std.testing.expectEqualStrings(
        "  src/c.zig: imported by src/root.zig without forced declaration analysis\n",
        report.items,
    );
}

test "declaration-analysis gate reports a repeated bare import once per root" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The report shape the tally counts: one line per distinct import
    // string per root, whatever the number of bare occurrences — so two
    // bare mentions of a.zig yield one line. A regression that drops that
    // dedup doubles the newline count and inflates the gate's tally while
    // every module it names stays the same.
    //
    // Wrapping is scoped per root as well: main's refAllDecls of b.zig
    // excuses only main's own imports, so root's bare b.zig still reports —
    // each test root compiles into its own test binary (lib_tests vs
    // exe_tests), and a wrapper in one analyzes nothing for the other.
    // main comes first in the walk's order, the direction where a merged
    // wrapper set across roots would silently drop root's line.
    const sources = [_]Source{
        .{
            .path = "src\\main.zig",
            .text = "test {\n" ++
                "    std.testing.refAllDecls(@import(\"b.zig\"));\n" ++
                "}\n" ++
                "_ = @import(\"c.zig\");\n",
        },
        .{
            .path = "src\\root.zig",
            .text = "_ = @import(\"a.zig\");\n" ++
                "_ = @import(\"a.zig\");\n" ++
                "_ = @import(\"b.zig\");\n",
        },
        .{ .path = "src\\a.zig", .text = "" },
        .{ .path = "src\\b.zig", .text = "" },
        .{ .path = "src\\c.zig", .text = "" },
    };

    var report: std.ArrayListUnmanaged(u8) = .empty;
    try TestRegistrationStep.declarationAnalysisGaps(arena, &sources, '\\', &report);

    try std.testing.expectEqualStrings(
        \\  src\c.zig: imported by src\main.zig without forced declaration analysis
        \\  src\a.zig: imported by src\root.zig without forced declaration analysis
        \\  src\b.zig: imported by src\root.zig without forced declaration analysis
        \\
    , report.items);
}

test "declaration-analysis gate constrains only the test roots' own imports" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The documented convention puts both halves at the roots, so an
    // intermediate module's ordinary-use import (a.zig reaching b.zig) asks
    // for no wrapper, and neither does one root importing the other. root's
    // own bare d.zig still reports — proof the two exemptions above come
    // from the scoping rule and not from a gate gone quiet altogether.
    const sources = [_]Source{
        .{ .path = "src\\root.zig", .text = "_ = @import(\"d.zig\");\n" },
        .{ .path = "src\\main.zig", .text = "_ = @import(\"root.zig\");\n" },
        .{ .path = "src\\a.zig", .text = "_ = @import(\"b.zig\");\n" },
        .{ .path = "src\\b.zig", .text = "" },
        .{ .path = "src\\d.zig", .text = "" },
    };

    var report: std.ArrayListUnmanaged(u8) = .empty;
    try TestRegistrationStep.declarationAnalysisGaps(arena, &sources, '\\', &report);

    try std.testing.expectEqualStrings(
        "  src\\d.zig: imported by src\\root.zig without forced declaration analysis\n",
        report.items,
    );
}

test "case-mismatch gate names a wrong-case import hiding behind a correct chain" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The shape that used to pass every half silently: root.zig reaches
    // helper.zig through the exact-case wrapped import, so the module is
    // registered and analyzed — and the wrong-case spelling beside it matched
    // nothing byte-exact in either earlier half, exempting itself via the
    // orelse-continue path. Main.zig is the second finding's target: main.zig
    // is itself a test root, and the case half keeps roots among its fold
    // targets (exclude_test_roots=false) — a root importing another root
    // wrong-case breaks the case-sensitive build just the same. "std" is the
    // control that stays out: it matches no walked module exactly or folded,
    // like any package import. ghost.zig keeps the assertion from passing
    // vacuously on an empty walk. Helper.zig appears twice: the report stays
    // one line per distinct import string per importing file — the tally the
    // counted header derives — the same dedup pin the declaration-analysis
    // half carries for its repeated bare import.
    const sources = [_]Source{
        .{
            .path = "src\\root.zig",
            .text = "test {\n" ++
                "    std.testing.refAllDecls(@import(\"helper.zig\"));\n" ++
                "}\n" ++
                "_ = @import(\"Helper.zig\");\n" ++
                "_ = @import(\"Helper.zig\");\n" ++
                "_ = @import(\"Main.zig\");\n" ++
                "_ = @import(\"std\");\n",
        },
        .{ .path = "src\\main.zig", .text = "" },
        .{ .path = "src\\helper.zig", .text = "" },
        .{ .path = "src\\ghost.zig", .text = "" },
    };

    var report: std.ArrayListUnmanaged(u8) = .empty;
    try TestRegistrationStep.caseMismatchLines(arena, &sources, '\\', &report);

    try std.testing.expectEqualStrings(
        "  src\\helper.zig: imported by src\\root.zig as \"Helper.zig\"; " ++
            "only \"helper.zig\" resolves on every filesystem\n" ++
            "  src\\main.zig: imported by src\\root.zig as \"Main.zig\"; " ++
            "only \"main.zig\" resolves on every filesystem\n",
        report.items,
    );
}

test "case-mismatch gate scans non-root modules and stays silent on exact spellings" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // An ordinary module's wrong-case import breaks a case-sensitive build
    // exactly like a root's, so the scan is not scoped to the test roots:
    // inner.zig's "../Helper.zig" is reported with its canonical spelling.
    // The second tree holds what must pass without a line: exact-case
    // imports of walked modules, package imports, and an import whose target
    // does not exist at all (no walked module to fold against).
    const sources = [_]Source{
        .{ .path = "src\\main.zig", .text = "_ = @import(\"sub/inner.zig\");\n" },
        .{ .path = "src\\root.zig", .text = "" },
        .{ .path = "src\\sub\\inner.zig", .text = "_ = @import(\"../Helper.zig\");\n" },
        .{ .path = "src\\helper.zig", .text = "" },
    };

    var report: std.ArrayListUnmanaged(u8) = .empty;
    try TestRegistrationStep.caseMismatchLines(arena, &sources, '\\', &report);

    try std.testing.expectEqualStrings(
        "  src\\helper.zig: imported by src\\sub\\inner.zig as \"../Helper.zig\"; " ++
            "only \"../helper.zig\" resolves on every filesystem\n",
        report.items,
    );

    const clean = [_]Source{
        .{
            .path = "src/root.zig",
            .text = "_ = @import(\"helper.zig\");\n" ++
                "_ = @import(\"./sub/inner.zig\");\n" ++
                "const o = @import(\"build_options\");\n" ++
                "_ = @import(\"nowhere.zig\");\n",
        },
        .{ .path = "src/main.zig", .text = "" },
        .{ .path = "src/helper.zig", .text = "" },
        .{ .path = "src/sub/inner.zig", .text = "" },
    };

    report = .empty;
    try TestRegistrationStep.caseMismatchLines(arena, &clean, '/', &report);
    try std.testing.expectEqual(@as(usize, 0), report.items.len);
}

test "collectImports reads paths and wrapper position off the token stream" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Comments and string-literal mentions yield nothing; a computed path
    // yields nothing; the recorded paths are quote-stripped literals, and
    // `wrapped` tracks exactly which calls sit inside a wrapper's parens.
    const refs = try TestRegistrationStep.collectImports(
        arena,
        "// _ = @import(\"commented.zig\");\n" ++
            "const s = \"@import(\\\"string.zig\\\")\";\n" ++
            "const m =\n\\\\ @import(\"multiline.zig\")\n;\n" ++
            "const d = @import(dir ++ \"/x.zig\");\n" ++
            "comptime {\n" ++
            "    _ = @import(\"bare.zig\");\n" ++
            "    std.testing.refAllDecls(@import(\"wrapped.zig\"));\n" ++
            "}\n",
    );

    try std.testing.expectEqual(@as(usize, 2), refs.len);
    try std.testing.expectEqualStrings("bare.zig", refs[0].path);
    try std.testing.expect(!refs[0].wrapped);
    try std.testing.expectEqualStrings("wrapped.zig", refs[1].path);
    try std.testing.expect(refs[1].wrapped);
}

/// Orders path strings lexicographically, so tests can compare the walker's
/// filesystem-dependent order as a sorted set.
fn lessThanStrings(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

test "checkedFiles expands directory entries and takes plain entries whole" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A directory entry contributes its .zig descendants at any depth; a
    // plain entry is taken whole even without a .zig suffix, which is what
    // keeps build.zig.zon covered by both file-covering gates.
    (try tmp.dir.createDirPathOpen(io, "lib/deep", .{})).close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = "lib/top.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "lib/deep/inner.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig.zon", .data = "" });
    const gate_paths = [_][]const u8{ "lib", "build.zig.zon" };

    var failed_path: ?[]const u8 = null;
    const checked = try checkedFiles(tmp.dir, io, arena, &gate_paths, &failed_path);
    std.mem.sort([]const u8, checked, {}, lessThanStrings);

    try std.testing.expectEqual(@as(usize, 3), checked.len);
    const sep_str = std.fs.path.sep_str;
    try std.testing.expectEqualStrings("build.zig.zon", checked[0]);
    try std.testing.expectEqualStrings(
        "lib" ++ sep_str ++ "deep" ++ sep_str ++ "inner.zig",
        checked[1],
    );
    try std.testing.expectEqualStrings("lib" ++ sep_str ++ "top.zig", checked[2]);
}

test "checkedFiles resolves a listed path that symlinks a directory" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // statFile follows links, so a listed path that is itself a link to a
    // directory contributes its whole subtree to every gate expanding the
    // listed paths through checkedFiles — the top-level counterpart of
    // appendZigFilesUnder's mid-walk rules: following keeps the subtree
    // checked where descending through a mid-walk link is rejected. A
    // regression to a non-following stat here would drop a linked library
    // from every one of them while they stay green.
    (try tmp.dir.createDirPathOpen(io, "vendor/nested", .{})).close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = "vendor/nested/deep.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "vendor/notes.md", .data = "" });
    try symLinkOrSkip(
        tmp.dir,
        io,
        .{ .target = "vendor", .link = "linked-lib" },
        .{ .is_directory = true },
    );

    const gate_paths = [_][]const u8{"linked-lib"};
    var failed_path: ?[]const u8 = null;
    const checked = try checkedFiles(tmp.dir, io, arena, &gate_paths, &failed_path);

    // Paths stay as listed (through the link), the shape the gates report;
    // the non-.zig file is filtered like any walked entry.
    try std.testing.expectEqual(@as(usize, 1), checked.len);
    try std.testing.expectEqualStrings(
        "linked-lib" ++ std.fs.path.sep_str ++ "nested" ++ std.fs.path.sep_str ++ "deep.zig",
        checked[0],
    );
}

test "checkedFiles fails loudly when a checked path stops existing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // The documented alternative to silently checking nothing, with the
    // failing path captured for the step's report: the error alone names no
    // path, and one of three checked entries failed.
    const gate_paths = [_][]const u8{"gone"};
    var failed_path: ?[]const u8 = null;
    try std.testing.expectError(
        error.FileNotFound,
        checkedFiles(tmp.dir, io, arena, &gate_paths, &failed_path),
    );
    try std.testing.expectEqualStrings("gone", failed_path.?);
}

test "checkedFiles names the walked entry when a directory walk fails" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // The walk half of the failed-path contract: a link to a directory
    // inside a listed path rejects the walk, and the error surfaces with
    // failed_path naming the *entry* — "src/vendor", not just the gate
    // path — the value make()'s report prints, so the operator is not sent
    // back to all of "src" to find which link stopped it (the granularity
    // appendProjectZigFiles reports at for its own walk). The stat branch
    // above pins its half; this pins that the dispatcher's walk catch
    // prefers the entry when one owns the failure.
    (try tmp.dir.createDirPathOpen(io, "src/sub", .{})).close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = "src/sub/deep.zig", .data = "" });
    try symLinkOrSkip(
        tmp.dir,
        io,
        .{ .target = "sub", .link = "src/vendor" },
        .{ .is_directory = true },
    );

    const gate_paths = [_][]const u8{"src"};
    var failed_path: ?[]const u8 = null;
    try std.testing.expectError(
        error.LinkedDirectoryNotWalked,
        checkedFiles(tmp.dir, io, arena, &gate_paths, &failed_path),
    );
    try std.testing.expectEqualStrings(
        "src" ++ std.fs.path.sep_str ++ "vendor",
        failed_path.?,
    );
}

test "appendZigFilesUnder collects every .zig file below the directory, and only files" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // The layout: .zig files at the root and nested two levels deep, a
    // non-.zig file, and — the false-pass direction a suffix-only filter
    // would admit — a *directory* whose name ends in .zig.
    (try tmp.dir.createDirPathOpen(io, "src/a/b", .{})).close(io);
    (try tmp.dir.createDirPathOpen(io, "src/dir.zig", .{})).close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = "src/top.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/notes.md", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/a/inner.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/a/b/deep.zig", .data = "" });

    var found: std.ArrayListUnmanaged([]const u8) = .empty;
    var failed_path: ?[]const u8 = null;
    try appendZigFilesUnder(tmp.dir, io, arena, "src", &found, &failed_path, false);
    std.mem.sort([]const u8, found.items, {}, lessThanStrings);

    // Each result is dir_path joined with the walker-relative path, the
    // shape both gates report and read back through root_dir — joined with
    // the platform separator on every host.
    try std.testing.expectEqual(@as(usize, 3), found.items.len);
    try std.testing.expect(failed_path == null);
    const sep_str = std.fs.path.sep_str;
    try std.testing.expectEqualStrings(
        "src" ++ sep_str ++ "a" ++ sep_str ++ "b" ++ sep_str ++ "deep.zig",
        found.items[0],
    );
    try std.testing.expectEqualStrings(
        "src" ++ sep_str ++ "a" ++ sep_str ++ "inner.zig",
        found.items[1],
    );
    try std.testing.expectEqualStrings("src" ++ sep_str ++ "top.zig", found.items[2]);
}

test "appendZigFilesUnder analyzes a symlinked .zig file like a real one" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // The silent-drop the raw walker kinds would admit: iteration reports a
    // link as `.sym_link`, never the kind of its target, so filtering on
    // `entry.kind == .file` alone leaves a linked source file unchecked by
    // both gates while they stay green.
    // checked_paths covers src/ and examples/; both must exist in the
    // fixture for the gates' enumeration to reach what the test exercises.
    (try tmp.dir.createDirPathOpen(io, "src", .{})).close(io);
    (try tmp.dir.createDirPathOpen(io, "examples", .{})).close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = "src/real.zig", .data = "" });
    try symLinkOrSkip(tmp.dir, io, .{ .target = "real.zig", .link = "src/link.zig" }, .{});

    var found: std.ArrayListUnmanaged([]const u8) = .empty;
    var failed_path: ?[]const u8 = null;
    try appendZigFilesUnder(tmp.dir, io, arena, "src", &found, &failed_path, false);
    std.mem.sort([]const u8, found.items, {}, lessThanStrings);

    try std.testing.expectEqual(@as(usize, 2), found.items.len);
    try std.testing.expectEqualStrings(
        "src" ++ std.fs.path.sep_str ++ "link.zig",
        found.items[0],
    );
    try std.testing.expectEqualStrings(
        "src" ++ std.fs.path.sep_str ++ "real.zig",
        found.items[1],
    );
}

test "classifyWalkedEntry resolves an unclassifiable entry through its real kind" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // The raw kind no Linux getdents64 walk reports but real filesystems do
    // (XFS ftype=0, some NFS/FUSE): iteration hands back .unknown, which
    // filters on the raw kind drop wholesale. No walker-driven test can
    // synthesize one, so the classifier is driven directly with synthetic
    // entries whose targets really exist behind them.
    // checked_paths covers src/ and examples/; both must exist in the
    // fixture for the gates' enumeration to reach what the test exercises.
    (try tmp.dir.createDirPathOpen(io, "src", .{})).close(io);
    (try tmp.dir.createDirPathOpen(io, "examples", .{})).close(io);
    (try tmp.dir.createDirPathOpen(io, "src/sub", .{})).close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = "src/mystery.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/notes.md", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "toplevel.zig", .data = "" });

    // An unclassifiable .zig file classifies as a source under the walked
    // prefix — the probe follows to the real file, and the joined path is
    // the form both gates report and read back.
    const unknown_source = try classifyWalkedEntry(tmp.dir, io, arena, "src", .{
        .dir = tmp.dir,
        .basename = "mystery.zig",
        .path = "mystery.zig",
        .kind = .unknown,
    });
    try std.testing.expectEqualStrings(
        "src" ++ std.fs.path.sep_str ++ "mystery.zig",
        unknown_source.zig_source,
    );

    // The same probe with the empty prefix the coverage walk passes: the
    // join must yield the bare walked path, not "/toplevel.zig".
    const unknown_top = try classifyWalkedEntry(tmp.dir, io, arena, "", .{
        .dir = tmp.dir,
        .basename = "toplevel.zig",
        .path = "toplevel.zig",
        .kind = .unknown,
    });
    try std.testing.expectEqualStrings("toplevel.zig", unknown_top.zig_source);

    // An unclassifiable non-source stays out of every gate's file set.
    const unknown_other = try classifyWalkedEntry(tmp.dir, io, arena, "src", .{
        .dir = tmp.dir,
        .basename = "notes.md",
        .path = "notes.md",
        .kind = .unknown,
    });
    try std.testing.expect(unknown_other == .other);

    // An unclassifiable directory entry: the probe reveals a directory, so
    // the classifier hands up .directory — the callers enter it with the
    // kind forced, the only way a d_type-less mount's subtree stays
    // covered (and, rejected instead, every conforming tree on such a
    // mount failed).
    const unknown_dir = try classifyWalkedEntry(tmp.dir, io, arena, "src", .{
        .dir = tmp.dir,
        .basename = "sub",
        .path = "sub",
        .kind = .unknown,
    });
    try std.testing.expect(unknown_dir == .directory);

    // A *link* resolving to a directory stays the rejection case: its raw
    // kind is known and not a directory, so no walker may descend into it —
    // the loud outcome for a subtree following would need cycle protection
    // to visit. The link exists so the probe resolves; the skip rule is
    // symLinkOrSkip's.
    try symLinkOrSkip(
        tmp.dir,
        io,
        .{ .target = "sub", .link = "src/link" },
        .{ .is_directory = true },
    );
    const linked_dir = try classifyWalkedEntry(tmp.dir, io, arena, "src", .{
        .dir = tmp.dir,
        .basename = "link",
        .path = "link",
        .kind = .sym_link,
    });
    try std.testing.expect(linked_dir == .linked_directory);
}

test "appendZigFilesUnder rejects a linked directory whose walk cannot descend" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // The subtree behind the link never reaches either gate (the walker
    // enters only entries reported as directories, and links are not), and
    // following it here would need cycle protection the tree does not
    // warrant — failing loudly is the documented alternative to silently
    // checking nothing.
    (try tmp.dir.createDirPathOpen(io, "src/sub", .{})).close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = "src/sub/deep.zig", .data = "" });
    try symLinkOrSkip(
        tmp.dir,
        io,
        .{ .target = "sub", .link = "src/vendor" },
        .{ .is_directory = true },
    );

    var found: std.ArrayListUnmanaged([]const u8) = .empty;
    var failed_path: ?[]const u8 = null;
    try std.testing.expectError(
        error.LinkedDirectoryNotWalked,
        appendZigFilesUnder(tmp.dir, io, arena, "src", &found, &failed_path, false),
    );

    // The rejection names the walked entry — the link itself, joined under
    // the walked directory in the build-root-relative form both gates
    // report — the same granularity checkedFiles hands make()'s report and
    // appendProjectZigFiles applies to its own walk.
    try std.testing.expectEqualStrings(
        "src" ++ std.fs.path.sep_str ++ "vendor",
        failed_path.?,
    );
}

/// Fails the build when a project-owned `.zig` file lies outside every
/// analysis gate's coverage. The gates' paths are an allowlist
/// (`checked_paths`): through checkedFiles it fails loudly when a listed
/// path stops existing, but nothing watched the allowlist's complement — a
/// new source directory or a stray top-level module would reach no
/// formatter, no column cap and no test binary while `zig build test`
/// stayed green. This step walks the build root for what the allowlist
/// misses and fails naming each uncovered file, so coverage can only change
/// by editing `checked_paths`, never shrink silently.
const GateCoverageStep = struct {
    step: std.Build.Step,

    fn create(b: *std.Build) *GateCoverageStep {
        return newCustomStep(b, GateCoverageStep, "gate coverage completeness");
    }

    fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) anyerror!void {
        _ = options;
        const b = step.owner;
        const io = b.graph.io;
        var arena_state = std.heap.ArenaAllocator.init(b.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        // The covered side comes from the same shared dispatcher every
        // other enumerating gate uses, so this gate compares against
        // exactly what they check — never against its own re-derivation of
        // the checked set that could drift from theirs. Its enumeration
        // failure reports through the same one copy they use.
        var failed_path: ?[]const u8 = null;
        const covered = checkedFiles(
            b.build_root.handle,
            io,
            arena,
            &checked_paths,
            &failed_path,
        ) catch |err| return failEnumeration(step, err, failed_path);

        var candidates: std.ArrayListUnmanaged([]const u8) = .empty;
        // The walk can fail on one specific entry (an unlisted linked
        // directory it must reject, a link that no longer resolves):
        // failed_entry names it, the way checkedFiles now names the entry
        // its own walk stopped on — a bare error name would leave the
        // operator to find the entry by hand among everything the walk
        // visited.
        var failed_entry: ?[]const u8 = null;
        appendProjectZigFiles(
            b.build_root.handle,
            io,
            arena,
            &candidates,
            &failed_entry,
            // The same allowlist the covered side expands, so a listed
            // linked directory is followed on both sides of the comparison
            // and an unlisted one rejected: the walk can never disagree
            // with the covering gates about which links are walked.
            &checked_paths,
            std.fs.path.sep,
        ) catch |err| {
            if (failed_entry) |entry|
                return step.fail("cannot walk '{s}': {s}", .{ entry, @errorName(err) });
            return step.fail("cannot walk the project tree: {s}", .{@errorName(err)});
        };

        var report: std.ArrayListUnmanaged(u8) = .empty;
        try GateCoverageStep.violationLines(arena, covered, candidates.items, &report);

        // One report line per violation (pinned by the exact-string tests
        // below), so the tally is the newline count — no second output to
        // keep in lockstep with the appends.
        const violations = std.mem.count(u8, report.items, "\n");
        if (violations > 0)
            return step.fail("{d} Zig source(s) no analysis gate covers:\n{s}", .{
                violations, report.items,
            });
    }

    /// The gate's decision core, I/O-free so tests drive it directly, the
    /// way classifyModules serves the registration walk: appends one report
    /// line per candidate no gate covers, in the order handed in (the walk
    /// order, like the other gates' reports). A candidate is uncovered when
    /// `covered` — the checkedFiles expansion of `checked_paths` — holds no
    /// byte-equal entry for it, or when its basename names a Zig source in a
    /// spelling no gate's filter matches (zigNearMissName: ".zig" in any
    /// letter case, not as the exact lowercase suffix) while the covered set
    /// holds it anyway: checkedFiles takes a listed file whole, so a
    /// near-miss spelling listed in checked_paths joins the covered set and
    /// an equality match alone would silence itself there. The point is that
    /// listing such a path cannot buy silence: only renaming ends that.
    /// O(covered x candidates) comparisons — the tree holds a handful of
    /// files today and the point is to fail loudly while it is small.
    fn violationLines(
        arena: std.mem.Allocator,
        covered: []const []const u8,
        candidates: []const []const u8,
        report: *std.ArrayListUnmanaged(u8),
    ) !void {
        for (candidates) |path| {
            if (!listContainsPath(covered, path) or
                zigNearMissName(std.fs.path.basename(path)))
            {
                try report.print(arena, "  {s}: not covered by any analysis gate\n", .{path});
            }
        }
    }
};

/// True when a walked entry lies in tooling territory rather than among
/// project sources, so the coverage walk skips it: leading-dot entries at
/// any depth (.git holds objects, .zig-cache caches build artifacts,
/// .local/.agents hold machine-local state — tooling nests wherever it
/// wants) and the install prefix `zig-out` at the walk root. The depth
/// guard is load-bearing: a project directory that merely names itself
/// zig-out deeper down stays inside the gated tree, its sources still
/// reportable — the gate exists so nothing escapes silently.
fn excludedFromGates(basename: []const u8, depth: usize) bool {
    // The dot test indexes basename[0]; a walker entry always carries a
    // real name, and an empty one here would be a caller bug, not input.
    std.debug.assert(basename.len > 0);
    if (basename[0] == '.') return true;
    return depth == 1 and std.mem.eql(u8, basename, "zig-out");
}

/// True when a basename names a possible Zig source without spelling it
/// the one way every covering gate matches: ".zig" occurs in any letter
/// case somewhere in the name, but never as the exact lowercase suffix.
/// The wrong-case suffix ("x.ZIG", "y.ZiG") is the original member; the
/// same net must also catch a suffixed backup or reject file whose
/// ".zig" is no longer the end of the name ("root.zig~", "a.zig.bak",
/// "b.zig.rej", emacs's "c.zig.~1.2~") — each classifies as .other, so
/// every covering gate's filter skips it just the same. Two exemptions:
/// the exact lowercase suffix (the covering gates' own territory) and
/// any ".zon" suffix — the package-manifest spelling keeps ".zig"
/// mid-name by its own convention ("build.zig.zon", listed whole in
/// checked_paths) while carrying no source obligation. Callers narrow
/// further per role: appendProjectZigFiles' .other branch has already
/// claimed exact-lowercase names as .zig_source, and violationLines'
/// near-miss arm applies it only to names the covered set already holds.
fn zigNearMissName(basename: []const u8) bool {
    if (std.mem.endsWith(u8, basename, ".zig")) return false;
    if (std.mem.endsWith(u8, basename, ".zon")) return false;
    return std.ascii.indexOfIgnoreCase(basename, ".zig") != null;
}

test "zigNearMissName catches every spelling a gate's filters skip" {
    // The boundaries: every letter case of the suffix matches at any
    // position, the exact lowercase suffix is excluded (the callers see
    // it already as .zig_source or guard it themselves), and a basename
    // under four bytes carries no suffix at all — the guard a regression
    // to '>' would flip for exactly the four-byte ".ZIG".
    try std.testing.expect(zigNearMissName("Legacy.ZIG"));
    try std.testing.expect(zigNearMissName("y.ZiG"));
    try std.testing.expect(zigNearMissName("archive.x.zig.tar"));
    try std.testing.expect(zigNearMissName(".ZIG"));
    // The near-miss spellings a suffix-only check let through: editor
    // backups and patch rejects keep ".zig" mid-name.
    try std.testing.expect(zigNearMissName("root.zig~"));
    try std.testing.expect(zigNearMissName("main.zig.bak"));
    try std.testing.expect(zigNearMissName("patch.zig.rej"));
    try std.testing.expect(zigNearMissName("v.zig.~1.2~"));
    // Exact-lowercase sources are the covering gates' own territory, and
    // ".zon" is the manifest spelling whose ".zig" is conventional.
    try std.testing.expect(!zigNearMissName("plain.zig"));
    try std.testing.expect(!zigNearMissName("build.zig.zon"));
    try std.testing.expect(!zigNearMissName("coppiz.zon"));
    // Names merely resembling Zig stay out: no ".zig" substring.
    try std.testing.expect(!zigNearMissName("zig"));
    try std.testing.expect(!zigNearMissName("ziggurat"));
    try std.testing.expect(!zigNearMissName("notes.md"));
}

/// Appends every project-owned .zig file — everything under the build root
/// except what excludedFromGates prunes — as a path relative to the walked
/// root. That is the form `checked_paths` produces too, so the comparison
/// needs no separator or prefix normalization on any host. Pruning happens
/// during descent rather than after the walk: .zig-cache alone holds
/// thousands of entries that would otherwise be visited on every lint run.
/// Entry classification goes through classifyWalkedEntry, the same policy
/// appendZigFilesUnder applies for the covering gates — a linked .zig file
/// is collected like a real one, and a directory only the probe reveals is
/// entered with its kind forced, its subtree reportable like any other on a
/// d_type-less mount. One class of
/// entry lands here beyond the classifier's own:
/// a file whose name names a Zig source in a spelling every gate skips —
/// a wrong-case ".zig" suffix ("Legacy.ZIG") or a backup/reject file
/// keeping ".zig" mid-name ("root.zig~", "a.zig.bak"; zigNearMissName's
/// whole set) — classifies as .other everywhere, yet it is exactly the
/// source no gate sees, so the .other branch collects it as a candidate
/// the covering set cannot match — the report names it, and renaming to
/// the lowercase spelling (or deleting it) ends the failure.
///
/// A linked directory splits by whether its walked path names one of
/// `gate_paths` (the allowlist, '/'-separated; `separator` translates the
/// walked form so any platform can be simulated in a test). Listed, the
/// covering gates follow it — checkedFiles stats through the link and hands
/// the target's subtree to appendZigFilesUnder — so rejecting it here would
/// fail the very tree the allowlist blesses, with no checked_paths spelling
/// left that admits a linked library directory: unlisted, its subtree would
/// escape every gate and the rejection below fails loudly; listed, that
/// escape argument does not hold and this walk follows it one hop through
/// appendZigFilesUnder, collecting exactly the paths the covered side holds
/// (plus near-miss names, which no covering gate sees inside either real or
/// linked directories). Unlisted, it stays the loud rejection: following
/// every link met mid-walk needs cycle protection no tree justifies, and an
/// unlisted link's subtree reaches no gate — the silent-escape shape this
/// walk exists to name.
///
/// On failure `failed_path` names the walked entry that could not be handled —
/// the link or unclassifiable entry whose resolution failed or the directory
/// behind one — so the caller can report it instead of a bare error name (the same rule
/// appendZigFilesUnder follows for the covering gates' walk). A failure belonging to no
/// single entry — allocation alone, here, or the walker failing to descend
/// between entries — leaves it unset, and the caller falls back to a
/// generic subject.
fn appendProjectZigFiles(
    root_dir: std.Io.Dir,
    io: std.Io,
    arena: std.mem.Allocator,
    paths: *std.ArrayListUnmanaged([]const u8),
    failed_path: *?[]const u8,
    gate_paths: []const []const u8,
    separator: u8,
) !void {
    var dir = try root_dir.openDir(io, ".", .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walkSelectively(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (excludedFromGates(entry.basename, entry.depth())) continue;
        const classified = classifyWalkedEntry(root_dir, io, arena, "", entry) catch |err| {
            // next() invalidates its slices on the following call, so
            // the name is copied out before the walk (or its deinit)
            // continues.
            failed_path.* = try arena.dupe(u8, entry.path);
            return err;
        };
        switch (classified) {
            .directory => try enterForcedDirectory(&walker, io, entry),
            .linked_directory => {
                const normalized = try normalizeSeparators(arena, entry.path, separator);
                if (!listContainsPath(gate_paths, normalized)) {
                    failed_path.* = try arena.dupe(u8, entry.path);
                    return error.LinkedDirectoryNotWalked;
                }
                // The listed link: follow it one hop, exactly as checkedFiles
                // does for the covering gates — openDir resolves the link and
                // appendZigFilesUnder walks the target, joining under the
                // link's walked path, the form the covered set was built in.
                // A link inside the target still rejects loudly, here and in
                // the covering walk alike. next() invalidates its slices, so
                // the failure name is copied out before returning.
                var failed_entry: ?[]const u8 = null;
                appendZigFilesUnder(
                    root_dir,
                    io,
                    arena,
                    entry.path,
                    paths,
                    &failed_entry,
                    true,
                ) catch |err| {
                    failed_path.* = failed_entry orelse try arena.dupe(u8, entry.path);
                    return err;
                };
            },
            // The "" prefix joins to the entry's walked path itself: the
            // fresh copy outlives the walker slice it was derived from.
            .zig_source => |path| try paths.append(arena, path),
            .other => if (zigNearMissName(entry.basename)) {
                // A file whose name names a Zig source in a spelling no
                // gate's filter matches ("Legacy.ZIG", "root.zig~",
                // "a.zig.bak") classifies as other: the covering gates'
                // suffix filter and zig fmt's own directory walk are both
                // exact-match (verified on 0.16.0: `zig fmt --check` over a
                // directory leaves Bad.ZIG untouched), so the file would
                // reach no formatter, no column cap, no registration walk
                // and no test binary — and stay invisible here too,
                // candidates carrying only what classifyWalkedEntry calls
                // .zig_source. Collect it anyway: the covering set can never
                // hold it, so the gate names it until the file carries the
                // lowercase spelling every gate applies — or is deleted.
                // next() invalidates its slices, so the walked path is
                // copied out like a classified source's.
                try paths.append(arena, try arena.dupe(u8, entry.path));
            },
        }
    }
}

test "gate coverage reports exactly the candidates outside the checked paths" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The allowlist's silent complement, now reported: everything the gates
    // cover passes, and each uncovered candidate gets one line naming it,
    // in the order handed in (the walk order, like the other gates).
    const covered = [_][]const u8{ "src/root.zig", "build.zig" };
    const candidates = [_][]const u8{ "stray.zig", "build.zig", "tools/late.zig" };

    var report: std.ArrayListUnmanaged(u8) = .empty;
    try GateCoverageStep.violationLines(arena, &covered, &candidates, &report);

    try std.testing.expectEqualStrings(
        \\  stray.zig: not covered by any analysis gate
        \\  tools/late.zig: not covered by any analysis gate
        \\
    , report.items);
}

test "gate coverage stays silent when every candidate is covered" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The tree-today shape: the walk finds nothing the gates miss, so the
    // report is empty and make() fails nothing.
    const covered = [_][]const u8{ "src/main.zig", "src/root.zig" };
    const candidates = [_][]const u8{ "src/root.zig", "src/main.zig" };

    var report: std.ArrayListUnmanaged(u8) = .empty;
    try GateCoverageStep.violationLines(arena, &covered, &candidates, &report);

    try std.testing.expectEqual(@as(usize, 0), report.items.len);
}

test "gate coverage names a near-miss source even when checked_paths lists it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The listed shape the equality match alone cannot judge: "Legacy.ZIG" sat in
    // checked_paths, checkedFiles took it whole, and a covered-only match
    // accepted the very escape this gate closes — a silent report while the
    // file stayed outside every exact-case filter. violationLines returns
    // the line whatever the allowlist holds — for the suffixed backup
    // spelling ("main.zig.bak") exactly as for the wrong-case suffix, since
    // both are spellings no gate's filter matches; ok.zig shows an ordinary
    // covered candidate stays silent.
    const covered = [_][]const u8{ "src/ok.zig", "Legacy.ZIG", "src/main.zig.bak" };
    const candidates = [_][]const u8{ "src/ok.zig", "Legacy.ZIG", "src/main.zig.bak" };

    var report: std.ArrayListUnmanaged(u8) = .empty;
    try GateCoverageStep.violationLines(arena, &covered, &candidates, &report);

    try std.testing.expectEqualStrings(
        \\  Legacy.ZIG: not covered by any analysis gate
        \\  src/main.zig.bak: not covered by any analysis gate
        \\
    , report.items);

    // The unlisted shape keeps its single line per file: the OR of the two
    // conditions fires once per candidate, so a near-miss candidate outside
    // the covered list is not named twice — no doubled tally.
    const bare_covered = [_][]const u8{"src/ok.zig"};
    report = .empty;
    try GateCoverageStep.violationLines(arena, &bare_covered, &candidates, &report);
    try std.testing.expectEqualStrings(
        \\  Legacy.ZIG: not covered by any analysis gate
        \\  src/main.zig.bak: not covered by any analysis gate
        \\
    , report.items);
}

test "excludedFromGates prunes tooling entries only" {
    // Hidden entries are tooling territory at any depth (.git holds
    // objects, .zig-cache caches build artifacts, .local/.agents hold
    // machine-local state); zig-out is the install prefix, but only at the
    // walk root — deeper down it is just a project directory's name.
    try std.testing.expect(excludedFromGates(".git", 1));
    try std.testing.expect(excludedFromGates(".zig-cache", 4));
    try std.testing.expect(excludedFromGates("zig-out", 1));
    try std.testing.expect(!excludedFromGates("zig-out", 2));
    try std.testing.expect(!excludedFromGates("src", 1));
    try std.testing.expect(!excludedFromGates("tools", 3));
    try std.testing.expect(!excludedFromGates("build.zig", 1));

    // The dot must start a full component: a project entry whose name
    // merely contains one is walked like any other.
    try std.testing.expect(!excludedFromGates("src.tools", 1));
}

test "appendProjectZigFiles walks the tree minus tooling directories, links included" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // The layout: covered and uncoverable .zig files side by side, a
    // non-.zig file, a leading-dot directory and a root-level zig-out
    // holding .zig files the walk must never see — while a zig-out *nested*
    // in a project directory stays reportable (the depth guard) — and a
    // symlinked source file collected like a real one (the same policy the
    // two file-covering gates apply).
    // checked_paths covers src/ and examples/; both must exist in the
    // fixture for the gates' enumeration to reach what the test exercises.
    (try tmp.dir.createDirPathOpen(io, "src", .{})).close(io);
    (try tmp.dir.createDirPathOpen(io, "examples", .{})).close(io);
    (try tmp.dir.createDirPathOpen(io, "tools", .{})).close(io);
    (try tmp.dir.createDirPathOpen(io, ".hidden", .{})).close(io);
    (try tmp.dir.createDirPathOpen(io, "zig-out/bin", .{})).close(io);
    (try tmp.dir.createDirPathOpen(io, "tools/zig-out", .{})).close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = "src/top.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "tools/inner.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "tools/zig-out/made.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "stray.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "notes.md", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".hidden/cache.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "zig-out/bin/made.zig", .data = "" });
    try symLinkOrSkip(tmp.dir, io, .{ .target = "top.zig", .link = "src/link.zig" }, .{});

    var found: std.ArrayListUnmanaged([]const u8) = .empty;
    var failed_path: ?[]const u8 = null;
    try appendProjectZigFiles(tmp.dir, io, arena, &found, &failed_path, &.{}, std.fs.path.sep);
    std.mem.sort([]const u8, found.items, {}, lessThanStrings);

    // A clean walk names no failing entry: make()'s report stays generic
    // exactly when nothing specific failed.
    try std.testing.expectEqual(@as(usize, 5), found.items.len);
    try std.testing.expect(failed_path == null);
    const sep_str = std.fs.path.sep_str;
    try std.testing.expectEqualStrings("src" ++ sep_str ++ "link.zig", found.items[0]);
    try std.testing.expectEqualStrings("src" ++ sep_str ++ "top.zig", found.items[1]);
    try std.testing.expectEqualStrings("stray.zig", found.items[2]);
    try std.testing.expectEqualStrings("tools" ++ sep_str ++ "inner.zig", found.items[3]);
    try std.testing.expectEqualStrings(
        "tools" ++ sep_str ++ "zig-out" ++ sep_str ++ "made.zig",
        found.items[4],
    );
}

test "appendProjectZigFiles collects a near-miss .zig name as a candidate" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // The escape this closes: "Legacy.ZIG" is a Zig source by name whose
    // wrong-case suffix classifies it as .other, so no covering gate sees
    // it — the coverage walk must still hand it to the report. The suffixed
    // backup spelling ("root.zig~") is the same class with ".zig" no longer
    // at the end of the name: a suffix-only check let it through. Controls
    // on both sides: notes.md is a plain other and stays out, and a
    // *directory* named NotSources.ZIG is entered like any directory, never
    // appended, so only files can trigger the failure.
    // checked_paths covers src/ and examples/; both must exist in the
    // fixture for the gates' enumeration to reach what the test exercises.
    (try tmp.dir.createDirPathOpen(io, "src", .{})).close(io);
    (try tmp.dir.createDirPathOpen(io, "examples", .{})).close(io);
    (try tmp.dir.createDirPathOpen(io, "NotSources.ZIG", .{})).close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = "src/ok.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "Legacy.ZIG", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "root.zig~", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "notes.md", .data = "" });

    var found: std.ArrayListUnmanaged([]const u8) = .empty;
    var failed_path: ?[]const u8 = null;
    try appendProjectZigFiles(tmp.dir, io, arena, &found, &failed_path, &.{}, std.fs.path.sep);
    std.mem.sort([]const u8, found.items, {}, lessThanStrings);

    try std.testing.expectEqual(@as(usize, 3), found.items.len);
    try std.testing.expect(failed_path == null);
    try std.testing.expectEqualStrings("Legacy.ZIG", found.items[0]);
    try std.testing.expectEqualStrings("root.zig~", found.items[1]);
    try std.testing.expectEqualStrings(
        "src" ++ std.fs.path.sep_str ++ "ok.zig",
        found.items[2],
    );
}

test "appendProjectZigFiles rejects a linked directory like the gate-path walk" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // One policy everywhere for an *unlisted* link: SelectiveWalker enters
    // only entries reported as directories and links are not, so the subtree
    // behind it would silently escape every gate — fail loudly instead, the
    // direction appendZigFilesUnder already chose for the covering gates.
    // The empty gate_paths make this the unlisted case by construction; a
    // link the gate paths list is the followed counterpart in the test below.
    (try tmp.dir.createDirPathOpen(io, "tools/sub", .{})).close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = "tools/sub/deep.zig", .data = "" });
    // The link's target resolves relative to the link's own directory, the
    // same shape the gate-path walk's twin test uses.
    try symLinkOrSkip(
        tmp.dir,
        io,
        .{ .target = "sub", .link = "tools/vendor" },
        .{ .is_directory = true },
    );

    var found: std.ArrayListUnmanaged([]const u8) = .empty;
    var failed_path: ?[]const u8 = null;
    try std.testing.expectError(
        error.LinkedDirectoryNotWalked,
        appendProjectZigFiles(tmp.dir, io, arena, &found, &failed_path, &.{}, std.fs.path.sep),
    );
    try std.testing.expectEqualStrings(
        "tools" ++ std.fs.path.sep_str ++ "vendor",
        failed_path.?,
    );
}

test "appendProjectZigFiles follows a linked directory the gate paths list" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // The catch-22 this pins shut: checkedFiles follows a *listed* link and
    // hands its subtree to the covering gates ("a listed path that symlinks
    // a directory must contribute its subtree"), so rejecting that same link
    // here failed every spelling of the allowlist — unlisted, the rejection
    // above; listed, this same walk met the link again and rejected a tree
    // the allowlist blessed. Listed, the coverage walk now follows one hop
    // through the same appendZigFilesUnder call the covering gates use, so
    // both sides of the covered/candidate comparison derive from one policy.
    // The layout is the checkedFiles link test's plus two controls: a
    // near-miss name inside the followed subtree — no covering gate sees it,
    // exactly as behind a listed real directory, so the widened collection
    // keeps it reportable — and an ordinary source outside the link.
    (try tmp.dir.createDirPathOpen(io, "vendor/nested", .{})).close(io);
    // checked_paths covers src/ and examples/; both must exist in the
    // fixture for the gates' enumeration to reach what the test exercises.
    (try tmp.dir.createDirPathOpen(io, "src", .{})).close(io);
    (try tmp.dir.createDirPathOpen(io, "examples", .{})).close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = "vendor/nested/deep.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "vendor/Legacy.ZIG", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/ok.zig", .data = "" });
    try symLinkOrSkip(
        tmp.dir,
        io,
        .{ .target = "vendor", .link = "linked-lib" },
        .{ .is_directory = true },
    );

    const gate_paths = [_][]const u8{"linked-lib"};
    var found: std.ArrayListUnmanaged([]const u8) = .empty;
    var failed_path: ?[]const u8 = null;
    try appendProjectZigFiles(
        tmp.dir,
        io,
        arena,
        &found,
        &failed_path,
        &gate_paths,
        std.fs.path.sep,
    );
    std.mem.sort([]const u8, found.items, {}, lessThanStrings);

    // Five entries, each subtree spelling twice: the walk descends the real
    // vendor/ directory natively and follows the listed link beside it, so
    // every file arrives under both prefixes — the same dual reachability a
    // real listed link produces, and harmless to the gate (candidates the
    // covered set holds stay silent whatever their multiplicity). The
    // near-miss name appears under both prefixes too: no covering gate sees
    // either spelling, so both stay reportable, matching how the same file
    // behind a listed *real* directory behaves.
    try std.testing.expectEqual(@as(usize, 5), found.items.len);
    try std.testing.expect(failed_path == null);
    const sep_str = std.fs.path.sep_str;
    try std.testing.expectEqualStrings("linked-lib" ++ sep_str ++ "Legacy.ZIG", found.items[0]);
    try std.testing.expectEqualStrings(
        "linked-lib" ++ sep_str ++ "nested" ++ sep_str ++ "deep.zig",
        found.items[1],
    );
    try std.testing.expectEqualStrings("src" ++ sep_str ++ "ok.zig", found.items[2]);
    try std.testing.expectEqualStrings("vendor" ++ sep_str ++ "Legacy.ZIG", found.items[3]);
    try std.testing.expectEqualStrings(
        "vendor" ++ sep_str ++ "nested" ++ sep_str ++ "deep.zig",
        found.items[4],
    );
}

test "appendProjectZigFiles names a link that no longer resolves" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // The other entry-specific failure on this walk: a dangling link is
    // reported as .sym_link by iteration, and resolving it through statFile
    // (which follows links) fails — before failed_path existed, make()
    // printed only "cannot walk the project tree: FileNotFound", leaving
    // the operator to find which of every walked entry was dangling.
    // checked_paths covers src/ and examples/; both must exist in the
    // fixture for the gates' enumeration to reach what the test exercises.
    (try tmp.dir.createDirPathOpen(io, "src", .{})).close(io);
    (try tmp.dir.createDirPathOpen(io, "examples", .{})).close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = "src/real.zig", .data = "" });
    try symLinkOrSkip(tmp.dir, io, .{ .target = "nowhere.zig", .link = "src/dangling.zig" }, .{});

    var found: std.ArrayListUnmanaged([]const u8) = .empty;
    var failed_path: ?[]const u8 = null;
    try std.testing.expectError(
        error.FileNotFound,
        appendProjectZigFiles(tmp.dir, io, arena, &found, &failed_path, &.{}, std.fs.path.sep),
    );

    // The link, not its missing target: it is the tree entry that cannot be
    // handled (walked-path form, platform separators).
    try std.testing.expectEqualStrings(
        "src" ++ std.fs.path.sep_str ++ "dangling.zig",
        failed_path.?,
    );
}

/// A real std.Build whose build root is `root_dir`, so the gate steps'
/// make() functions and loadCheckedSources can run end-to-end over a
/// temporary tree instead of only their extracted cores. The graph lives in
/// the caller's frame because the Build borrows it; everything else is
/// arena-allocated. Construction mirrors what the build runner does, in the
/// shape std's own Build.Step.Options test uses: the test runner's io, a
/// resolved native host, and throwaway cache roots the gates never read.
fn makeTestBuilder(
    arena: std.mem.Allocator,
    io: std.Io,
    root_dir: std.Io.Dir,
    graph: *std.Build.Graph,
) anyerror!*std.Build {
    // anyerror because cwd resolution and native-target detection report
    // through host-OS error sets no gate ever names.
    const cwd_path = try std.process.currentPathAlloc(io, arena);
    graph.* = .{
        .io = io,
        .arena = arena,
        .cache = .{
            .io = io,
            .gpa = arena,
            .manifest_dir = root_dir,
            .cwd = cwd_path,
        },
        .zig_exe = "zig",
        .environ_map = std.process.Environ.Map.init(arena),
        .global_cache_root = .{ .path = null, .handle = root_dir },
        .host = .{
            .query = .{},
            .result = try std.zig.system.resolveTargetQuery(io, .{}),
        },
        .zig_lib_directory = .{ .path = null, .handle = root_dir },
        .time_report = false,
    };
    return std.Build.create(
        graph,
        .{ .path = null, .handle = root_dir },
        .{ .path = null, .handle = root_dir },
        &.{},
    );
}

/// The make function of the under-test step, never legitimately invoked:
/// the step exists only so direct-call tests can hand a live *std.Build.Step
/// to loadCheckedSources and failEnumeration for failure reporting. The
/// trapping body turns an accidental invocation into a loud crash instead
/// of undefined behavior through an `undefined` function pointer.
fn uninvokedMake(_: *std.Build.Step, _: std.Build.Step.MakeOptions) anyerror!void {
    unreachable;
}

/// The bare custom step loadCheckedSources' and failEnumeration's
/// direct-call tests report through, owned by a fresh test Build over
/// `root_dir`. One copy serves all three so their wiring cannot drift apart,
/// the same rule newCustomStep follows for the gate steps.
fn makeUnderTestStep(
    arena: std.mem.Allocator,
    io: std.Io,
    root_dir: std.Io.Dir,
    graph: *std.Build.Graph,
) !std.Build.Step {
    const b = try makeTestBuilder(arena, io, root_dir, graph);
    return std.Build.Step.init(.{
        .id = .custom,
        .name = "under test",
        .owner = b,
        .makeFn = uninvokedMake,
    });
}

/// The MakeOptions a direct make() call needs: no progress reporting, no
/// watch mode, no per-test timeout — the step bodies read none of it.
fn testMakeOptions(arena: std.mem.Allocator) std.Build.Step.MakeOptions {
    return .{
        .progress_node = .none,
        .watch = false,
        .web_server = null,
        .unit_test_timeout_ns = null,
        .gpa = arena,
    };
}

/// Runs `step`'s make function and pins both halves of a failing report:
/// the error is MakeFailed (the step already reported) and exactly one
/// message was recorded, matching `expected` character for character. The
/// exact-string form every gate's own tests use, applied one layer up.
fn expectStepFailure(
    step: *std.Build.Step,
    options: std.Build.Step.MakeOptions,
    expected: []const u8,
) !void {
    try std.testing.expectError(error.MakeFailed, step.makeFn(step, options));
    try std.testing.expectEqual(@as(usize, 1), step.result_error_msgs.items.len);
    try std.testing.expectEqualStrings(expected, step.result_error_msgs.items[0]);
}

test "loadCheckedSources reads each checked file whole, listed order preserved" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.zig", .data = "const a = 1;\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "notes.txt", .data = "hello" });

    var graph: std.Build.Graph = undefined;
    var step = try makeUnderTestStep(arena, io, tmp.dir, &graph);

    const paths = [_][]const u8{ "a.zig", "notes.txt" };
    const sources = try loadCheckedSources(&step, tmp.dir, io, arena, &paths);

    // Paths come back as listed (the form reports print) with each file's
    // full text, and a clean run records nothing on the step.
    try std.testing.expectEqual(@as(usize, 2), sources.len);
    try std.testing.expectEqualStrings("a.zig", sources[0].path);
    try std.testing.expectEqualStrings("const a = 1;\n", sources[0].text);
    try std.testing.expectEqualStrings("notes.txt", sources[1].path);
    try std.testing.expectEqualStrings("hello", sources[1].text);
    try std.testing.expectEqual(@as(usize, 0), step.result_error_msgs.items.len);
}

test "loadCheckedSources names the gate path when enumeration fails" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var graph: std.Build.Graph = undefined;
    var step = try makeUnderTestStep(arena, io, tmp.dir, &graph);

    // The shared front half of both analysis steps routes enumeration
    // failures through failEnumeration with the offending path attached —
    // not a bare error name the operator would have to locate by hand.
    const paths = [_][]const u8{"missing.zig"};
    try std.testing.expectError(
        error.MakeFailed,
        loadCheckedSources(&step, tmp.dir, io, arena, &paths),
    );
    try std.testing.expectEqualStrings(
        "cannot enumerate 'missing.zig': FileNotFound",
        step.result_error_msgs.items[0],
    );
}

test "loadCheckedSources names the covered file when its text cannot be read" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // The read half of the failure contract loadCheckedSources' docstring
    // spells beside enumeration's: a covered file that exists and stats
    // fine but whose bytes cannot be read is reported naming that file —
    // not a bare error name, and not silently skipped as an empty source.
    // Permission denial is capability-probed (setUnreadableOrSkip): where
    // no mode can deny a read — root, mode-ignoring filesystems — the test
    // skips rather than pass without exercising the branch.
    try tmp.dir.writeFile(io, .{ .sub_path = "a.zig", .data = "const a = 1;\n" });
    try setUnreadableOrSkip(tmp.dir, io, "a.zig");
    defer tmp.dir.setFilePermissions(io, "a.zig", .default_file, .{}) catch {};

    var graph: std.Build.Graph = undefined;
    var step = try makeUnderTestStep(arena, io, tmp.dir, &graph);

    const paths = [_][]const u8{"a.zig"};
    try std.testing.expectError(
        error.MakeFailed,
        loadCheckedSources(&step, tmp.dir, io, arena, &paths),
    );
    try std.testing.expectEqualStrings(
        "cannot read 'a.zig': AccessDenied",
        step.result_error_msgs.items[0],
    );
}

test "failEnumeration falls back to a generic subject when no path owns the error" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var graph: std.Build.Graph = undefined;
    var step = try makeUnderTestStep(arena, io, tmp.dir, &graph);

    // An error belonging to no single gate path (allocation alone) leaves
    // failed_path unset, and the report still says what was being enumerated.
    // failEnumeration returns a bare error set, so the value compares
    // directly.
    const err = failEnumeration(&step, error.OutOfMemory, null);
    try std.testing.expect(err == error.MakeFailed);
    try std.testing.expectEqualStrings(
        "cannot enumerate 'the checked paths': OutOfMemory",
        step.result_error_msgs.items[0],
    );
}

test "column-cap step fails over its build root naming the one offending line" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // The tree make() enumerates through checked_paths relative to the
    // build root: src/ plus stubs of the two top-level build files, so
    // enumeration succeeds and the step reaches the column check itself.
    // checked_paths covers src/ and examples/; both must exist in the
    // fixture for the gates' enumeration to reach what the test exercises.
    (try tmp.dir.createDirPathOpen(io, "src", .{})).close(io);
    (try tmp.dir.createDirPathOpen(io, "examples", .{})).close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = "src/ok.zig", .data = "" });
    try tmp.dir.writeFile(
        io,
        .{ .sub_path = "src/big.zig", .data = "a" ** (LineLengthStep.columns_max + 1) },
    );
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig.zon", .data = "" });

    // The end-to-end contract the core tests stop short of: the tally is
    // derived from the report lines, and the header carries the count and
    // cap beside them.
    const sep_str = std.fs.path.sep_str;
    var graph: std.Build.Graph = undefined;
    const b = try makeTestBuilder(arena, io, tmp.dir, &graph);
    const gate = LineLengthStep.create(b);
    try expectStepFailure(
        &gate.step,
        testMakeOptions(arena),
        "1 line(s) exceed 100 columns:\n" ++
            "  src" ++ sep_str ++ "big.zig:1\n",
    );
}

test "test-registration step reports unreachable modules then analysis gaps" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // One tree exercising both halves of make()'s assembled message in one
    // run: ghost.zig is imported by nobody (the reachability section) while
    // a.zig is imported bare by root.zig, reachable but never wrapped in
    // refAllDecls (the declaration-analysis section). Exactly one finding
    // per section keeps the report independent of the walker's order.
    // build.zig and build.zig.zon are stubbed because make() enumerates the
    // whole allowlist.
    // checked_paths covers src/ and examples/; both must exist in the
    // fixture for the gates' enumeration to reach what the test exercises.
    (try tmp.dir.createDirPathOpen(io, "src", .{})).close(io);
    (try tmp.dir.createDirPathOpen(io, "examples", .{})).close(io);
    try tmp.dir.writeFile(
        io,
        .{ .sub_path = "src/root.zig", .data = "_ = @import(\"a.zig\");\n" },
    );
    try tmp.dir.writeFile(io, .{ .sub_path = "src/main.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/a.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/ghost.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig.zon", .data = "" });

    // The two sections join as separate paragraphs under their counted
    // headers — the assembly no other test pins; a dropped separator or a
    // miscounted tally prints mangled gate output while every core stays
    // green.
    const sep_str = std.fs.path.sep_str;
    var graph: std.Build.Graph = undefined;
    const b = try makeTestBuilder(arena, io, tmp.dir, &graph);
    const gate = TestRegistrationStep.create(b);
    try expectStepFailure(
        &gate.step,
        testMakeOptions(arena),
        "1 module(s) whose tests never run:\n" ++
            "  src" ++ sep_str ++ "ghost.zig: not reachable from a test root\n" ++
            "\n" ++
            "1 module(s) whose public declarations are never analyzed:\n" ++
            "  src" ++ sep_str ++ "a.zig: imported by src" ++ sep_str ++
            "root.zig without forced declaration analysis\n",
    );
}

test "test-registration step reports unreachable modules alone, with no trailing section" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Only the reachability section fires: nothing is imported bare, so the
    // analysis half must contribute neither header nor separator. The
    // two-section pin above cannot see a join that appends its blank line
    // unconditionally — both single-section shapes are pinned separately.
    // build.zig and build.zig.zon are stubbed because make() enumerates the
    // whole allowlist.
    // checked_paths covers src/ and examples/; both must exist in the
    // fixture for the gates' enumeration to reach what the test exercises.
    (try tmp.dir.createDirPathOpen(io, "src", .{})).close(io);
    (try tmp.dir.createDirPathOpen(io, "examples", .{})).close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = "src/root.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/main.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/ghost.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig.zon", .data = "" });

    const sep_str = std.fs.path.sep_str;
    var graph: std.Build.Graph = undefined;
    const b = try makeTestBuilder(arena, io, tmp.dir, &graph);
    const gate = TestRegistrationStep.create(b);
    try expectStepFailure(
        &gate.step,
        testMakeOptions(arena),
        "1 module(s) whose tests never run:\n" ++
            "  src" ++ sep_str ++ "ghost.zig: not reachable from a test root\n",
    );
}

test "test-registration step owes build.zig's src imports the same refAllDecls pairing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // build.zig rides checked_paths into the registration walk: it is
    // compiled as its own test module, so it is a test root, and a root
    // that imports a src/ module bare owes it the refAllDecls line like
    // any other root. The import targets helper.zig, not one of the other
    // roots: one root importing another is no registration by design, so
    // that shape could not fail. While the walk enumerated src/ alone,
    // this bare import passed every gate while nothing analyzed helper's
    // decls.
    // checked_paths covers src/ and examples/; both must exist in the
    // fixture for the gates' enumeration to reach what the test exercises.
    (try tmp.dir.createDirPathOpen(io, "src", .{})).close(io);
    (try tmp.dir.createDirPathOpen(io, "examples", .{})).close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = "src/root.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/main.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/helper.zig", .data = "" });
    try tmp.dir.writeFile(
        io,
        .{ .sub_path = "build.zig", .data = "_ = @import(\"src/helper.zig\");\n" },
    );
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig.zon", .data = "" });

    const sep_str = std.fs.path.sep_str;
    var graph: std.Build.Graph = undefined;
    const b = try makeTestBuilder(arena, io, tmp.dir, &graph);
    const gate = TestRegistrationStep.create(b);
    try expectStepFailure(
        &gate.step,
        testMakeOptions(arena),
        "1 module(s) whose public declarations are never analyzed:\n" ++
            "  src" ++ sep_str ++ "helper.zig: imported by build.zig " ++
            "without forced declaration analysis\n",
    );
}

test "test-registration step does not mistake build.zig.zon for an unregistered module" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // The false-positive direction of the widened enumeration: the .zon
    // file rides checked_paths whole (the column cap caps it), so the walk
    // now hands it to the classifier beside the modules — dropping the .zig
    // filter reports it as unreachable and fails every conforming tree.
    // checked_paths covers src/ and examples/; both must exist in the
    // fixture for the gates' enumeration to reach what the test exercises.
    (try tmp.dir.createDirPathOpen(io, "src", .{})).close(io);
    (try tmp.dir.createDirPathOpen(io, "examples", .{})).close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = "src/root.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/main.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig.zon", .data = "" });

    var graph: std.Build.Graph = undefined;
    const b = try makeTestBuilder(arena, io, tmp.dir, &graph);
    const gate = TestRegistrationStep.create(b);
    try gate.step.makeFn(&gate.step, testMakeOptions(arena));

    // Success records nothing on the step: a stray message appended beside
    // a pass would read as a failure to whoever reads the run's output.
    try std.testing.expectEqual(@as(usize, 0), gate.step.result_error_msgs.items.len);
}

test "test-registration step reports a wrong-case import beside its clean chain" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // The end-to-end shape of the import-string escape this step's third
    // half closes: helper.zig is registered and analyzed through the
    // exact-case wrapper, so both earlier halves stay silent while the
    // wrong-case spelling beside it compiles on macOS or Windows and fails
    // on Linux. Only the case section fires — the single-section assembly
    // shape for the third report half.
    // build.zig and build.zig.zon are stubbed because make() enumerates the
    // whole allowlist.
    // checked_paths covers src/ and examples/; both must exist in the
    // fixture for the gates' enumeration to reach what the test exercises.
    (try tmp.dir.createDirPathOpen(io, "src", .{})).close(io);
    (try tmp.dir.createDirPathOpen(io, "examples", .{})).close(io);
    try tmp.dir.writeFile(
        io,
        .{
            .sub_path = "src/root.zig",
            .data = "test {\n" ++
                "    std.testing.refAllDecls(@import(\"helper.zig\"));\n" ++
                "}\n" ++
                "_ = @import(\"Helper.zig\");\n",
        },
    );
    try tmp.dir.writeFile(io, .{ .sub_path = "src/main.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/helper.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig.zon", .data = "" });

    const sep_str = std.fs.path.sep_str;
    var graph: std.Build.Graph = undefined;
    const b = try makeTestBuilder(arena, io, tmp.dir, &graph);
    const gate = TestRegistrationStep.create(b);
    try expectStepFailure(
        &gate.step,
        testMakeOptions(arena),
        "1 import(s) that resolve only on a case-insensitive filesystem:\n" ++
            "  src" ++ sep_str ++ "helper.zig: imported by src" ++ sep_str ++
            "root.zig as \"Helper.zig\"; only \"helper.zig\" resolves on every filesystem\n",
    );
}

test "test-registration step reports analysis gaps alone, with no leading section" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // The mirror direction: every module reachable, one bare import — so
    // only the analysis section fires and the report starts at its header.
    // a.zig stays reachable (the bare import itself is the chain) while
    // being reported (nothing wraps it in this root), which is exactly the
    // split between the two sections this shape isolates.
    // build.zig and build.zig.zon are stubbed because make() enumerates the
    // whole allowlist.
    // checked_paths covers src/ and examples/; both must exist in the
    // fixture for the gates' enumeration to reach what the test exercises.
    (try tmp.dir.createDirPathOpen(io, "src", .{})).close(io);
    (try tmp.dir.createDirPathOpen(io, "examples", .{})).close(io);
    try tmp.dir.writeFile(
        io,
        .{ .sub_path = "src/root.zig", .data = "_ = @import(\"a.zig\");\n" },
    );
    try tmp.dir.writeFile(io, .{ .sub_path = "src/main.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/a.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig.zon", .data = "" });

    const sep_str = std.fs.path.sep_str;
    var graph: std.Build.Graph = undefined;
    const b = try makeTestBuilder(arena, io, tmp.dir, &graph);
    const gate = TestRegistrationStep.create(b);
    try expectStepFailure(
        &gate.step,
        testMakeOptions(arena),
        "1 module(s) whose public declarations are never analyzed:\n" ++
            "  src" ++ sep_str ++ "a.zig: imported by src" ++ sep_str ++
            "root.zig without forced declaration analysis\n",
    );
}

test "test-registration step reports all three sections in one failure" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // The worst-case assembly every smaller pin stops short of: all three
    // halves fire at once — orphan.zig is imported by nobody (reachability),
    // a.zig is reachable but never wrapped (declaration analysis), and
    // helper.zig is registered through its exact-case wrapper while
    // "Helper.zig" beside it resolves only where the filesystem ignores
    // case. Exactly one finding per section keeps the shape independent of
    // the walker's order, and the whole-message pin fixes the section order
    // and the blank-line join between consecutive sections — the properties
    // no combination of the single- and two-section tests encodes. main's
    // wrapped ghost import keeps ghost out of every section, so the
    // fixture cannot pass with one half silenced.
    // build.zig and build.zig.zon are stubbed because make() enumerates the
    // whole allowlist.
    // checked_paths covers src/ and examples/; both must exist in the
    // fixture for the gates' enumeration to reach what the test exercises.
    (try tmp.dir.createDirPathOpen(io, "src", .{})).close(io);
    (try tmp.dir.createDirPathOpen(io, "examples", .{})).close(io);
    try tmp.dir.writeFile(
        io,
        .{
            .sub_path = "src/root.zig",
            .data = "_ = @import(\"a.zig\");\n" ++
                "test {\n" ++
                "    std.testing.refAllDecls(@import(\"helper.zig\"));\n" ++
                "}\n" ++
                "_ = @import(\"Helper.zig\");\n",
        },
    );
    try tmp.dir.writeFile(
        io,
        .{
            .sub_path = "src/main.zig",
            .data = "test {\n" ++
                "    std.testing.refAllDecls(@import(\"ghost.zig\"));\n" ++
                "}\n",
        },
    );
    try tmp.dir.writeFile(io, .{ .sub_path = "src/a.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/helper.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/ghost.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/orphan.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig.zon", .data = "" });

    const sep_str = std.fs.path.sep_str;
    var graph: std.Build.Graph = undefined;
    const b = try makeTestBuilder(arena, io, tmp.dir, &graph);
    const gate = TestRegistrationStep.create(b);
    try expectStepFailure(
        &gate.step,
        testMakeOptions(arena),
        "1 module(s) whose tests never run:\n" ++
            "  src" ++ sep_str ++ "orphan.zig: not reachable from a test root\n" ++
            "\n" ++
            "1 module(s) whose public declarations are never analyzed:\n" ++
            "  src" ++ sep_str ++ "a.zig: imported by src" ++ sep_str ++
            "root.zig without forced declaration analysis\n" ++
            "\n" ++
            "1 import(s) that resolve only on a case-insensitive filesystem:\n" ++
            "  src" ++ sep_str ++ "helper.zig: imported by src" ++ sep_str ++
            "root.zig as \"Helper.zig\"; only \"helper.zig\" resolves on every filesystem\n",
    );
}

test "test-registration step joins the outer sections around a silent middle half" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // The subset of section combinations no other pin runs: reachability and
    // case-mismatch fire while declaration-analysis stays silent, and the
    // blank-line join must still separate the outer two. appendSection keys
    // the separator on the message accumulated so far; a join keyed on
    // whether the *previous* section found something passed every existing
    // shape ({1}, {2}, {3}, {1,2} and all three above) while dropping this
    // report's separator — exactly one blank line lost, behind a green suite.
    // ghost.zig is imported by nobody (the reachability finding); helper.zig
    // is wrapped, so no bare import exists for the analysis half to report,
    // and "Helper.zig" beside the wrapper is the case finding.
    // build.zig and build.zig.zon are stubbed because make() enumerates the
    // whole allowlist.
    // checked_paths covers src/ and examples/; both must exist in the
    // fixture for the gates' enumeration to reach what the test exercises.
    (try tmp.dir.createDirPathOpen(io, "src", .{})).close(io);
    (try tmp.dir.createDirPathOpen(io, "examples", .{})).close(io);
    try tmp.dir.writeFile(
        io,
        .{
            .sub_path = "src/root.zig",
            .data = "test {\n" ++
                "    std.testing.refAllDecls(@import(\"helper.zig\"));\n" ++
                "}\n" ++
                "_ = @import(\"Helper.zig\");\n",
        },
    );
    try tmp.dir.writeFile(io, .{ .sub_path = "src/main.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/helper.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/ghost.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig.zon", .data = "" });

    const sep_str = std.fs.path.sep_str;
    var graph: std.Build.Graph = undefined;
    const b = try makeTestBuilder(arena, io, tmp.dir, &graph);
    const gate = TestRegistrationStep.create(b);
    try expectStepFailure(
        &gate.step,
        testMakeOptions(arena),
        "1 module(s) whose tests never run:\n" ++
            "  src" ++ sep_str ++ "ghost.zig: not reachable from a test root\n" ++
            "\n" ++
            "1 import(s) that resolve only on a case-insensitive filesystem:\n" ++
            "  src" ++ sep_str ++ "helper.zig: imported by src" ++ sep_str ++
            "root.zig as \"Helper.zig\"; only \"helper.zig\" resolves on every filesystem\n",
    );
}

test "test-registration step joins the last two sections around a silent first half" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // The subset of section combinations no other pin runs: declaration-
    // analysis and case-mismatch fire while the reachability half stays
    // silent — every module is reachable (helper through its wrapper, a.zig
    // through the bare import that is itself its chain), so no orphan line
    // exists. A join keyed on the *first* section having found something
    // passed every shape where reachability fired — the singles, {1,2},
    // {1,3} and all-three — while dropping this report's separator, the
    // mirror of the previous-section key the outer-join pin closed. Exactly
    // one finding per section keeps the shape independent of the walker's
    // order.
    // build.zig and build.zig.zon are stubbed because make() enumerates the
    // whole allowlist.
    // checked_paths covers src/ and examples/; both must exist in the
    // fixture for the gates' enumeration to reach what the test exercises.
    (try tmp.dir.createDirPathOpen(io, "src", .{})).close(io);
    (try tmp.dir.createDirPathOpen(io, "examples", .{})).close(io);
    try tmp.dir.writeFile(
        io,
        .{
            .sub_path = "src/root.zig",
            .data = "_ = @import(\"a.zig\");\n" ++
                "test {\n" ++
                "    std.testing.refAllDecls(@import(\"helper.zig\"));\n" ++
                "}\n" ++
                "_ = @import(\"Helper.zig\");\n",
        },
    );
    try tmp.dir.writeFile(io, .{ .sub_path = "src/main.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/helper.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/a.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig.zon", .data = "" });

    const sep_str = std.fs.path.sep_str;
    var graph: std.Build.Graph = undefined;
    const b = try makeTestBuilder(arena, io, tmp.dir, &graph);
    const gate = TestRegistrationStep.create(b);
    try expectStepFailure(
        &gate.step,
        testMakeOptions(arena),
        "1 module(s) whose public declarations are never analyzed:\n" ++
            "  src" ++ sep_str ++ "a.zig: imported by src" ++ sep_str ++
            "root.zig without forced declaration analysis\n" ++
            "\n" ++
            "1 import(s) that resolve only on a case-insensitive filesystem:\n" ++
            "  src" ++ sep_str ++ "helper.zig: imported by src" ++ sep_str ++
            "root.zig as \"Helper.zig\"; only \"helper.zig\" resolves on every filesystem\n",
    );
}

test "gate-coverage step fails naming a project file outside the checked paths" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // The tree-today shape plus one stray: everything checked_paths names
    // exists (so the covered side enumerates), and one top-level .zig file
    // lies outside the allowlist — the complement this step exists to fail
    // loudly about. Its end-to-end header and tally are pinned here because
    // violationLines' tests stop at the bare report lines.
    // checked_paths covers src/ and examples/; both must exist in the
    // fixture for the gates' enumeration to reach what the test exercises.
    (try tmp.dir.createDirPathOpen(io, "src", .{})).close(io);
    (try tmp.dir.createDirPathOpen(io, "examples", .{})).close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = "src/root.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig.zon", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "stray.zig", .data = "" });

    var graph: std.Build.Graph = undefined;
    const b = try makeTestBuilder(arena, io, tmp.dir, &graph);
    const gate = GateCoverageStep.create(b);
    try expectStepFailure(
        &gate.step,
        testMakeOptions(arena),
        "1 Zig source(s) no analysis gate covers:\n" ++
            "  stray.zig: not covered by any analysis gate\n",
    );
}

test "gate-coverage step fails naming a wrong-case .zig file no gate sees" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // The end-to-end shape of the wrong-case escape: every checked path
    // enumerates and "Legacy.ZIG" classifies as .other, so without the
    // .other collection rule the step would pass while the file sat outside
    // the formatter, column cap, registration walk and test binary. The
    // report is the generic uncovered line — renaming to the lowercase
    // spelling is what ends the failure, not a checked_paths entry, since
    // listing it would cover the name while zig fmt's directory walk still
    // skipped the file. One planted file per run: the report prints in walk
    // order, which no filesystem guarantees between siblings.
    // checked_paths covers src/ and examples/; both must exist in the
    // fixture for the gates' enumeration to reach what the test exercises.
    (try tmp.dir.createDirPathOpen(io, "src", .{})).close(io);
    (try tmp.dir.createDirPathOpen(io, "examples", .{})).close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = "src/root.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig.zon", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "Legacy.ZIG", .data = "" });

    var graph: std.Build.Graph = undefined;
    const b = try makeTestBuilder(arena, io, tmp.dir, &graph);
    const gate = GateCoverageStep.create(b);
    try expectStepFailure(
        &gate.step,
        testMakeOptions(arena),
        "1 Zig source(s) no analysis gate covers:\n" ++
            "  Legacy.ZIG: not covered by any analysis gate\n",
    );
}

test "gate-coverage step fails naming a backup-spelling .zig file no gate sees" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // The escape a suffix-only check admitted end to end: an editor backup
    // keeps ".zig" mid-name ("root.zig~"; same for "x.zig.bak",
    // "x.zig.rej"), classifies as .other like the wrong-case suffix, and no
    // covering gate sees it. Deleting the backup is what ends the failure.
    // checked_paths covers src/ and examples/; both must exist in the
    // fixture for the gates' enumeration to reach what the test exercises.
    (try tmp.dir.createDirPathOpen(io, "src", .{})).close(io);
    (try tmp.dir.createDirPathOpen(io, "examples", .{})).close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = "src/root.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig.zon", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "root.zig~", .data = "" });

    var graph: std.Build.Graph = undefined;
    const b = try makeTestBuilder(arena, io, tmp.dir, &graph);
    const gate = GateCoverageStep.create(b);
    try expectStepFailure(
        &gate.step,
        testMakeOptions(arena),
        "1 Zig source(s) no analysis gate covers:\n" ++
            "  root.zig~: not covered by any analysis gate\n",
    );
}

test "gate-coverage step names the walked entry when the project walk fails" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // The covered side enumerates (every checked path exists), then the
    // project walk hits a dangling link: make()'s catch must print the
    // entry failed_path names, not fall back to the generic subject. The
    // core tests pin that appendProjectZigFiles sets it; this pins the
    // report half of the same contract, the way loadCheckedSources' own
    // message tests pin failEnumeration's. The link sits outside the
    // checked paths on purpose: inside them the covering walk would fail
    // the step one branch earlier ("cannot enumerate"), which that gate's
    // own tests already pin.
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig.zon", .data = "" });
    // checked_paths covers src/ and examples/; both must exist in the
    // fixture for the gates' enumeration to reach what the test exercises.
    (try tmp.dir.createDirPathOpen(io, "src", .{})).close(io);
    (try tmp.dir.createDirPathOpen(io, "examples", .{})).close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = "src/root.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig", .data = "" });
    try symLinkOrSkip(tmp.dir, io, .{ .target = "nowhere.zig", .link = "dangling.zig" }, .{});

    var graph: std.Build.Graph = undefined;
    const b = try makeTestBuilder(arena, io, tmp.dir, &graph);
    const gate = GateCoverageStep.create(b);
    try expectStepFailure(
        &gate.step,
        testMakeOptions(arena),
        "cannot walk 'dangling.zig': FileNotFound",
    );
}

test "gate-coverage step names the checked path when its enumeration fails" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // The covered side's own failure contract, end to end: a checked path
    // missing from the tree stops checkedFiles before any comparison, and
    // make() routes that through failEnumeration naming the gate path — the
    // wording loadCheckedSources' tests pin for the other two gates, from
    // the one shared reporter. The message can only come from this branch:
    // a project-walk failure prints "cannot walk", and a coverage violation
    // prints under the tally header, so a pass here proves the routing ran.
    // checked_paths covers src/ and examples/; both must exist in the
    // fixture for the gates' enumeration to reach what the test exercises.
    (try tmp.dir.createDirPathOpen(io, "src", .{})).close(io);
    (try tmp.dir.createDirPathOpen(io, "examples", .{})).close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = "src/root.zig", .data = "" });
    // build.zig is deliberately absent: checked_paths lists it, so the
    // covered expansion fails with that path named.
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig.zon", .data = "" });

    var graph: std.Build.Graph = undefined;
    const b = try makeTestBuilder(arena, io, tmp.dir, &graph);
    const gate = GateCoverageStep.create(b);
    try expectStepFailure(
        &gate.step,
        testMakeOptions(arena),
        "cannot enumerate 'build.zig': FileNotFound",
    );
}

test "all three gate steps pass a conforming tree recording nothing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // The false-positive direction no other end-to-end test pins: every
    // other make() test feeds a violating tree, so a gate regression that
    // started rejecting legitimate trees — the worst failure mode for what
    // OQ 45 treats as the merge gate — would pass them all. This is the
    // tree-today layout, conforming: both roots present, the helper
    // registered through its refAllDecls line, every file inside
    // checked_paths, no long lines.
    // checked_paths covers src/ and examples/; both must exist in the
    // fixture for the gates' enumeration to reach what the test exercises.
    (try tmp.dir.createDirPathOpen(io, "src", .{})).close(io);
    (try tmp.dir.createDirPathOpen(io, "examples", .{})).close(io);
    try tmp.dir.writeFile(
        io,
        .{
            .sub_path = "src/root.zig",
            .data = "test {\n" ++
                "    std.testing.refAllDecls(@import(\"helper.zig\"));\n" ++
                "}\n",
        },
    );
    try tmp.dir.writeFile(io, .{ .sub_path = "src/main.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/helper.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig.zon", .data = "" });

    var graph: std.Build.Graph = undefined;
    const b = try makeTestBuilder(arena, io, tmp.dir, &graph);
    const options = testMakeOptions(arena);
    const column_gate = LineLengthStep.create(b);
    const registration_gate = TestRegistrationStep.create(b);
    const coverage_gate = GateCoverageStep.create(b);

    try column_gate.step.makeFn(&column_gate.step, options);
    try registration_gate.step.makeFn(&registration_gate.step, options);
    try coverage_gate.step.makeFn(&coverage_gate.step, options);

    // Success records nothing on any step: a stray message appended beside
    // a pass would read as a failure to whoever reads the run's output.
    try std.testing.expectEqual(@as(usize, 0), column_gate.step.result_error_msgs.items.len);
    try std.testing.expectEqual(
        @as(usize, 0),
        registration_gate.step.result_error_msgs.items.len,
    );
    try std.testing.expectEqual(@as(usize, 0), coverage_gate.step.result_error_msgs.items.len);
}

test "all public declarations analyze" {
    // build.zig is a test root (addChecks compiles it as its own test
    // binary), so it owes the src/ modules it imports the same refAllDecls
    // pairing any other root owes. docgen.zig is an executable root — no
    // test root under src/ imports it — so this import is what registers it
    // for test collection and forces its declarations through the analyzer.
    std.testing.refAllDecls(@import("src/settings/docgen.zig"));
}
