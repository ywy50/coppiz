const std = @import("std");

// spine builds two things from one tree, on purpose: the library module
// (`spine`, src/root.zig) a host such as clanker fetches as a dependency,
// and the `spine` executable (src/main.zig) that wraps that same library
// as a standalone node. Which of the two leads the design is RFC 0001.
pub fn build(b: *std.Build) void {
    enforceToolchainFloor();
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const options = b.addOptions();
    // The raw zon declaration only: the library parses it where `spine.version`
    // is defined (src/root.zig), so the single-source-of-truth value is never
    // carried twice in lockstep (RELEASES.md).
    options.addOption([]const u8, "version_text", @import("build.zig.zon").version);

    const lib_mod = b.addModule("spine", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_mod.addOptions("build_options", options);

    const exe = b.addExecutable(.{
        .name = "spine",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "spine", .module = lib_mod },
            },
        }),
    });
    b.installArtifact(exe);

    // addRunArtifact already ties the run to the freshly built binary; no
    // step here needs the install performed first.
    const run_step = b.step("run", "Build and run the spine node");
    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    addChecks(b, lib_mod, exe);
}

/// Fails the build when the toolchain executing it is older than the floor
/// declared in build.zig.zon. Zig itself never checks that field for a tree
/// built directly (verified on 0.16.0: a floor of 99.0.0 builds silently);
/// only a consumer fetching spine as a dependency gets it checked. Yet every
/// gate in addChecks assumes the declared toolchain's semantics — zig fmt's
/// output and --ast-check, std.zig.Tokenizer's lexing behind the test
/// registration check, test-block collection from module roots — so an
/// undeclared toolchain would analyze with the wrong rules. Fail loudly
/// instead, before any gate can half-run.
fn enforceToolchainFloor() void {
    const floor_text = @import("build.zig.zon").minimum_zig_version;
    if (!meetsZigFloor(@import("builtin").zig_version, floor_text))
        std.debug.panic(
            "spine requires Zig {s} or newer; running {f}",
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
fn addChecks(b: *std.Build, lib_mod: *std.Build.Module, exe: *std.Build.Step.Compile) void {
    // Zig 0.16 collects `test` blocks from a test module's root file and
    // from every src/ module its analyzed imports reach, so every src/ file
    // must be reachable from a test-module root — src/root.zig's comptime
    // reference block or src/main.zig, directly or through another module —
    // or its tests silently never run.
    const lib_tests = b.addTest(.{ .root_module = lib_mod });
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    // The build file carries lint-gate logic with its own tests; compiling
    // it as a plain module (not as the build script) runs them.
    const build_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("build.zig"),
        .target = b.resolveTargetQuery(.{}),
    }) });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(lib_tests).step);
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);
    test_step.dependOn(&b.addRunArtifact(build_tests).step);

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

    // The checked paths come from `checked_paths`, shared with the column
    // cap and coverage gates, so the file-covering gates can never drift
    // apart about what is analyzed.
    const fmt_args = [_][]const u8{ b.graph.zig_exe, "fmt", "--check", "--ast-check" } ++
        checked_paths;
    const fmt_check = b.addSystemCommand(&fmt_args);
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
/// Zig sources under `src/` plus the two build files at the top level.
/// One list serves both file-covering gates — `zig fmt --check --ast-check`
/// and the 100-column cap below — so they can never disagree about what is
/// analyzed: a new source directory or file is added once and both gates
/// pick it up. A path here that stops existing fails both gates loudly
/// rather than silently checking nothing.
const checked_paths = [_][]const u8{ "src", "build.zig", "build.zig.zon" };

/// Every file a checking step covers, derived from its gate paths: a listed
/// directory contributes its .zig descendants; any other entry is taken
/// whole (build.zig.zon has no .zig suffix but must still be capped). One
/// dispatcher serves every step that enumerates files — the 100-column cap,
/// the test-registration walk and the coverage-completeness walk (`zig fmt`
/// takes the same list but reads the files itself) — so their coverage rules
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
/// is a parameter below; production hands in `&checked_paths` for the
/// column-cap and coverage walks and `&.{"src"}` for the registration walk.
///
/// On failure `failed_path` names the gate path that could not be stat'd or
/// walked, so the caller can report it — a bare error name would leave the
/// operator to re-derive the checked-path list by hand (the same rule the
/// read failures in loadCheckedSources follow). An error belonging to no
/// single gate path — allocation alone, here — leaves it unset, and the
/// caller falls back to a generic subject.
fn checkedFiles(
    root_dir: std.Io.Dir,
    io: std.Io,
    arena: std.mem.Allocator,
    gate_paths: []const []const u8,
    failed_path: *?[]const u8,
) ![][]const u8 {
    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    for (gate_paths) |path| {
        const stat = root_dir.statFile(io, path, .{}) catch |err| {
            failed_path.* = path;
            return err;
        };
        if (stat.kind == .directory) {
            appendZigFilesUnder(root_dir, io, arena, path, &paths) catch |err| {
                failed_path.* = path;
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
    /// A directory walked into as a real directory (the walker descended or
    /// may be told to).
    directory,
    /// A link or unclassifiable entry resolving to a directory: neither
    /// walker descends into it, so its subtree would escape every gate
    /// silently — reject loudly instead.
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
        kind = (try root_dir.statFile(io, probe_path, .{})).kind;
    }
    if (kind == .directory) {
        return if (entry.kind == .directory) .directory else .linked_directory;
    }
    if (kind != .file) return .other;
    if (!std.mem.endsWith(u8, entry.basename, ".zig")) return .other;
    return .{ .zig_source = try std.fs.path.join(arena, &.{ prefix, entry.path }) };
}

/// Appends every .zig file under the directory `dir_path`, as a path from
/// the build root ("src/foo.zig"), in walker order. A linked directory is
/// never descended into (Walker only enters entries reported as
/// directories), so classifyWalkedEntry rejects one loudly instead of
/// silently dropping its subtree from every gate.
fn appendZigFilesUnder(
    root_dir: std.Io.Dir,
    io: std.Io,
    arena: std.mem.Allocator,
    dir_path: []const u8,
    paths: *std.ArrayListUnmanaged([]const u8),
) !void {
    var dir = try root_dir.openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        // entry.path is relative to the walked directory, while root_dir
        // stands at the build root: classification probes and collects
        // through dir_path joined onto it, the form both gates report.
        switch (try classifyWalkedEntry(root_dir, io, arena, dir_path, entry)) {
            .zig_source => |path| try paths.append(arena, path),
            .linked_directory => return error.LinkedDirectoryNotWalked,
            // The plain walker descends real directories itself.
            .directory, .other => {},
        }
    }
}

/// One file a gate covers: its path as checkedFiles hands it out
/// (build-root-relative, platform separators) and its full text.
const Source = struct {
    path: []const u8,
    text: []const u8,
};

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
/// all three steps' constructors share, differing only in type, display
/// name and make function. One copy serves all three so their wiring cannot
/// drift apart, the same rule failEnumeration and loadCheckedSources follow
/// for their shared plumbing.
fn newCustomStep(
    b: *std.Build,
    comptime T: type,
    name: []const u8,
    comptime make_fn: std.Build.Step.MakeFn,
) *T {
    const self = b.allocator.create(T) catch @panic("OOM");
    self.* = .{
        .step = std.Build.Step.init(.{
            .id = .custom,
            .name = name,
            .owner = b,
            .makeFn = make_fn,
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
            make,
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
        for (sources) |source| try checkLineLengths(arena, source.text, source.path, &report);
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
    /// report line per offending line.
    fn checkLineLengths(
        arena: std.mem.Allocator,
        bytes: []const u8,
        path: []const u8,
        report: *std.ArrayListUnmanaged(u8),
    ) !void {
        var line_no: usize = 0;
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            line_no += 1;
            // Code points can only outnumber bytes, so a line at or under
            // the cap in bytes cannot exceed it in columns and needs no
            // UTF-8 decode — the common case in a conforming tree.
            if (line.len <= columns_max) continue;
            if ((std.unicode.utf8CountCodepoints(line) catch line.len) <= columns_max) continue;
            try report.print(arena, "  {s}:{d}\n", .{ path, line_no });
        }
    }
};

test "column cap admits a line at exactly the limit" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var report: std.ArrayListUnmanaged(u8) = .empty;

    const exact = "a" ** LineLengthStep.columns_max;
    try LineLengthStep.checkLineLengths(arena, exact ++ "\nsecond\n", "f.zig", &report);

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
        "ok\n" ++ over ++ "\nalso ok\n" ++ over,
        "f.zig",
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
    try LineLengthStep.checkLineLengths(arena, "\u{00e9}" ** 60, "f.zig", &report);
    try std.testing.expectEqual(@as(usize, 0), report.items.len);

    // The invalid side of the same boundary: 101 code points is over the cap
    // whatever the encoding, so wide characters are not skipped wholesale.
    const wide_over = "\u{00e9}" ** (LineLengthStep.columns_max + 1);
    try LineLengthStep.checkLineLengths(arena, wide_over, "f.zig", &report);
    try std.testing.expectEqualStrings("  f.zig:1\n", report.items);
}

test "column cap falls back to byte count on invalid UTF-8" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var report: std.ArrayListUnmanaged(u8) = .empty;

    const bad = "\xff" ** (LineLengthStep.columns_max + 1);
    try LineLengthStep.checkLineLengths(arena, bad, "f.zig", &report);

    // Same path:line report as the valid-UTF-8 over-limit case.
    try std.testing.expectEqualStrings("  f.zig:1\n", report.items);
}

/// The src/ files whose `test` blocks Zig collects (the test-module roots).
/// One list serves both uses in the gate below: the seeds of the
/// reachability walk, and the files exempt from requiring reachability.
const test_roots = [_][]const u8{ "src/root.zig", "src/main.zig" };

/// Fails the build when no chain of real @imports reaches a src/ module
/// from a test-module root (src/root.zig or src/main.zig): only such a
/// chain makes Zig 0.16 collect the module's `test` blocks, so an
/// unreachable module's tests silently never run while `zig build test`
/// stays green. The step also fails when a test root imports a src/ module
/// but never wraps that import in refAllDecls: registration alone collects
/// tests and analyzes nothing, an unreferenced `pub` declaration is
/// compiled into nothing, so the module's public surface would reach no
/// semantic check. Collection follows analyzed imports transitively — verified
/// on 0.16.0: with root.zig importing a.zig importing b.zig, b's tests run;
/// an import in a declaration that is never analyzed (an unused
/// container-level const) collects nothing — so the gate walks real
/// @import calls across every walked module (collectImports), resolving each
/// candidate's import string relative to the importing file's directory
/// (importBetween), not just against the two roots. Only a literal
/// `@import("path")` call counts: a mention inside a comment or any string
/// literal registers nothing.
const TestRegistrationStep = struct {
    step: std.Build.Step,

    fn create(b: *std.Build) *TestRegistrationStep {
        return newCustomStep(
            b,
            TestRegistrationStep,
            "test registration and declaration analysis",
            make,
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
        // Every walked module's text: the reachability walk reads imports
        // out of intermediate modules too, not just out of the two roots.
        // The roots sit in src/ themselves, so one walk finds them and no
        // file is read twice. Enumeration goes through loadCheckedSources,
        // so both steps share the dispatcher and its failure reporting.
        const sources = try loadCheckedSources(step, b.build_root.handle, io, arena, &.{"src"});
        try classifyModules(arena, sources, std.fs.path.sep, &report);
        var analysis_report: std.ArrayListUnmanaged(u8) = .empty;
        try declarationAnalysisGaps(arena, sources, std.fs.path.sep, &analysis_report);
        // Both cores append one report line per finding (pinned by the
        // exact-string tests below), so each tally is a newline count — no
        // second output to keep in lockstep with the appends.
        const count = std.mem.count(u8, report.items, "\n");
        const analysis_count = std.mem.count(u8, analysis_report.items, "\n");
        var message: std.ArrayListUnmanaged(u8) = .empty;
        if (count > 0)
            try message.print(arena, "{d} module(s) whose tests never run:\n{s}", .{
                count, report.items,
            });
        if (analysis_count > 0) {
            if (message.items.len > 0) try message.append(arena, '\n');
            try message.print(
                arena,
                "{d} module(s) whose public declarations are never analyzed:\n{s}",
                .{ analysis_count, analysis_report.items },
            );
        }
        if (message.items.len > 0)
            return step.fail("{s}", .{message.items});
    }

    /// The gate's decision core, I/O-free so tests drive it directly, the
    /// way checkLineLengths serves the column cap: from the test roots, follow
    /// real imports across `sources` and append one report line per module
    /// no chain reaches. Each module's text is tokenized once when it is
    /// dequeued and its imports matched against every candidate after that —
    /// re-collecting per candidate would make the tokenizer runs quadratic
    /// where only the cheap string comparisons are. `separator` is a
    /// parameter so any platform can be simulated in a test.
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
        var reached = try arena.alloc(bool, sources.len);
        @memset(reached, false);
        var queue: std.ArrayListUnmanaged(usize) = .empty;
        for (sources, 0..) |source, i| {
            if (!try isTestRoot(arena, source.path, separator)) continue;
            reached[i] = true;
            try queue.append(arena, i);
        }
        var cursor: usize = 0;
        while (cursor < queue.items.len) : (cursor += 1) {
            const from = sources[queue.items[cursor]];
            const from_imports = try collectImports(arena, from.text);
            for (sources, 0..) |candidate, i| {
                if (reached[i]) continue;
                const wanted = try importBetween(arena, from.path, candidate.path, separator);
                if (importsPath(from_imports, wanted)) {
                    reached[i] = true;
                    try queue.append(arena, i);
                }
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
        const normalized = try importSeparators(arena, path, separator);
        for (test_roots) |root_path| {
            if (std.mem.eql(u8, normalized, root_path)) return true;
        }
        return false;
    }

    /// The @import string that reaches the file `to_path` from the file
    /// `from_path`: relative to the importing file's directory and
    /// '/'-separated, the only form an import string may hold — "sub/x.zig"
    /// from a root-level importer, "y.zig" beside the importer,
    /// "../other/y.zig" across branches (a submodule importing a sibling
    /// tree climbs out). Both paths come from one walk of "src/", so
    /// neither carries a drive or leading separator; `separator` is a parameter
    /// so any platform can be simulated in a test.
    fn importBetween(
        arena: std.mem.Allocator,
        from_path: []const u8,
        to_path: []const u8,
        separator: u8,
    ) ![]const u8 {
        const from = try importSeparators(arena, from_path, separator);
        const to = try importSeparators(arena, to_path, separator);
        // Longest common prefix ending on a '/' boundary: stopping at the
        // first differing byte instead would treat "src/aa/" and "src/ab/"
        // as one directory because they share "src/a".
        var scanned: usize = 0;
        var boundary: usize = 0;
        const limit = @min(from.len, to.len);
        while (scanned < limit and from[scanned] == to[scanned]) : (scanned += 1) {
            if (from[scanned] == '/') boundary = scanned + 1;
        }
        var import_string: std.ArrayListUnmanaged(u8) = .empty;
        // Each directory left under the importer climbs one "..".
        for (from[boundary..]) |c| {
            if (c != '/') continue;
            try import_string.appendSlice(arena, "../");
        }
        try import_string.appendSlice(arena, to[boundary..]);
        return normalizeImportPath(arena, try import_string.toOwnedSlice(arena));
    }

    /// Collapses an @import string to the one form Zig resolves it to: empty
    /// components ("a//b"), "." components ("./a.zig", "a/./b.zig") and
    /// "name/.." pairs ("sub/../x.zig") disappear — each spelling reaches
    /// the same file and collects its tests, so the gates must not tell them
    /// apart (an exact-byte match failed a tree whose tests ran). Leading
    /// ".." runs survive: they climb out of the importer's directory, which
    /// has no further parent to pop into. Applied where import strings enter
    /// the gates — collectImports' recorded paths and importBetween's
    /// computed ones — so every comparison below sees canonical text.
    fn normalizeImportPath(arena: std.mem.Allocator, raw: []const u8) ![]const u8 {
        var parts: std.ArrayListUnmanaged([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, raw, '/');
        while (it.next()) |part| {
            if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
            if (std.mem.eql(u8, part, "..")) {
                const poppable = parts.items.len > 0 and
                    !std.mem.eql(u8, parts.items[parts.items.len - 1], "..");
                if (poppable) {
                    _ = parts.pop();
                } else {
                    try parts.append(arena, part);
                }
                continue;
            }
            try parts.append(arena, part);
        }
        return std.mem.join(arena, "/", parts.items);
    }

    /// Rewrites filesystem separators to import separators ('/'), the only
    /// form that can appear inside an @import string. A no-op where the
    /// separator is already '/'; `separator` is a parameter so any platform can be
    /// simulated in a test.
    fn importSeparators(arena: std.mem.Allocator, path: []const u8, separator: u8) ![]const u8 {
        if (separator == '/') return path;
        return std.mem.replaceOwned(u8, arena, path, &.{separator}, "/");
    }

    /// True when `imports` — one module's collectImports result — names
    /// `wanted_import`: the comparison classifyModules applies per candidate
    /// against the importer's once-collected imports.
    fn importsPath(imports: []const ImportRef, wanted_import: []const u8) bool {
        for (imports) |imp| {
            if (std.mem.eql(u8, imp.path, wanted_import)) return true;
        }
        return false;
    }

    /// One real `@import("path")` call found in a token stream: `path` is the
    /// literal between the quotes, normalized (normalizeImportPath), and
    /// `wrapped` whether the call sits directly inside a
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
                    .path = try normalizeImportPath(
                        arena,
                        terminated[token.loc.start + 1 .. token.loc.end - 1],
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
    /// two test roots are constrained: that is where the documented
    /// convention puts both halves, while an intermediate module's imports
    /// are ordinary use. An import resolving to no walked module (`std`,
    /// `build_options`, the `spine` package) needs no wrapper. One report
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
            // deriving it per import would redo identical work. First
            // candidate wins, and a candidate that is itself a test root is
            // absent — one root importing the other is not a registration
            // and asks for no wrapper.
            var named: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
            for (sources) |candidate| {
                if (std.mem.eql(u8, candidate.path, root_source.path)) continue;
                if (try isTestRoot(arena, candidate.path, separator)) continue;
                const wanted = try importBetween(
                    arena,
                    root_source.path,
                    candidate.path,
                    separator,
                );
                if (!named.contains(wanted)) try named.put(arena, wanted, candidate.path);
            }

            const imports = try collectImports(arena, root_source.text);
            var wrapped_paths: std.StringArrayHashMapUnmanaged(void) = .empty;
            for (imports) |imp| {
                if (imp.wrapped) try wrapped_paths.put(arena, imp.path, {});
            }
            var reported: std.StringArrayHashMapUnmanaged(void) = .empty;
            for (imports) |imp| {
                if (wrapped_paths.contains(imp.path)) continue;
                if (reported.contains(imp.path)) continue;
                const candidate_path = named.get(imp.path) orelse continue;
                try reported.put(arena, imp.path, {});
                try report.print(
                    arena,
                    "  {s}: imported by {s} without forced declaration analysis\n",
                    .{ candidate_path, root_source.path },
                );
            }
        }
    }
};

test "normalizeImportPath collapses the legal spellings Zig resolves to one target" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Every right-hand spelling reaches the same file as the left-hand one
    // (verified on 0.16.0: @import("./sub/x.zig") collects the target's
    // tests), so an exact-byte comparison reported a reachable module as
    // unreachable — and hid bare imports behind wrappers spelled with "./".
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
        .{ "", "" },
    };
    for (cases) |case| {
        try std.testing.expectEqualStrings(
            case[1],
            try TestRegistrationStep.normalizeImportPath(arena, case[0]),
        );
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
        try TestRegistrationStep.importBetween(arena, "src/root.zig", "src/sub/x.zig", '/'),
    );

    // Modules in one subdirectory are siblings: a bare filename.
    try std.testing.expectEqualStrings(
        "y.zig",
        try TestRegistrationStep.importBetween(arena, "src/sub/x.zig", "src/sub/y.zig", '/'),
    );
    // Across branches the import climbs out with "..".
    try std.testing.expectEqualStrings(
        "../other/y.zig",
        try TestRegistrationStep.importBetween(arena, "src/sub/x.zig", "src/other/y.zig", '/'),
    );
    // One ".." per directory left under the importer: c.zig sits in
    // src/a/b/, two levels below src/. Backslashes here double as another
    // pass through the separator normalization.
    try std.testing.expectEqualStrings(
        "../../top.zig",
        try TestRegistrationStep.importBetween(
            arena,
            "src\\a\\b\\c.zig",
            "src\\top.zig",
            '\\',
        ),
    );
    // The shared prefix must stop on a '/' boundary: src/aa/ and src/ab/
    // share "src/a" byte-wise but are different directories.
    try std.testing.expectEqualStrings(
        "../ab/g.zig",
        try TestRegistrationStep.importBetween(arena, "src/aa/f.zig", "src/ab/g.zig", '/'),
    );

    // The Windows case, simulated on every host through the separator argument:
    // walked paths are normalized before resolution.
    const win = try TestRegistrationStep.importSeparators(arena, "sub\\x\\y.zig", '\\');
    try std.testing.expectEqualStrings("sub/x/y.zig", win);
    try std.testing.expectEqualStrings(
        "y.zig",
        try TestRegistrationStep.importBetween(
            arena,
            "src\\sub\\x.zig",
            "src\\sub\\y.zig",
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
    const native = try TestRegistrationStep.importSeparators(
        arena,
        "src/root.zig",
        std.fs.path.sep,
    );
    try std.testing.expect(try TestRegistrationStep.isTestRoot(arena, native, std.fs.path.sep));
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
    const s = std.fs.path.sep_str;
    const native_sources = [_]Source{
        .{
            .path = "src" ++ s ++ "main.zig",
            .text = sources[0].text,
        },
        .{ .path = "src" ++ s ++ "root.zig", .text = "" },
        .{
            .path = "src" ++ s ++ "sub" ++ s ++ "registered.zig",
            .text = sources[2].text,
        },
        .{ .path = "src" ++ s ++ "other" ++ s ++ "second.zig", .text = "" },
        .{ .path = "src" ++ s ++ "sub" ++ s ++ "unregistered.zig", .text = "" },
    };

    report = .empty;
    try TestRegistrationStep.classifyModules(arena, &native_sources, std.fs.path.sep, &report);

    try std.testing.expectEqualStrings(
        "  src" ++ s ++ "sub" ++ s ++ "unregistered.zig: not reachable from a test root\n",
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

test "importsPath counts only a real @import call" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The question classifyModules asks per candidate, asked of a whole
    // text: collect then match. The forms that register: plain, spaced
    // across lines, sharing a line with a trailing comment.
    const counts = struct {
        fn counts(
            a: std.mem.Allocator,
            text: []const u8,
            wanted_import: []const u8,
        ) !bool {
            return TestRegistrationStep.importsPath(
                try TestRegistrationStep.collectImports(a, text),
                wanted_import,
            );
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
    try std.testing.expectEqualStrings("build.zig.zon", checked[0]);
    try std.testing.expectEqualStrings("lib/deep/inner.zig", checked[1]);
    try std.testing.expectEqualStrings("lib/top.zig", checked[2]);
}

test "checkedFiles resolves a listed path that symlinks a directory" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // statFile follows links, so a listed path that is itself a link to a
    // directory contributes its whole subtree to both file-covering gates —
    // the top-level counterpart of appendZigFilesUnder's mid-walk rules:
    // following keeps the subtree checked where descending through a
    // mid-walk link is rejected. A regression to a non-following stat here
    // would drop a linked library from both gates while they stay green.
    (try tmp.dir.createDirPathOpen(io, "vendor/nested", .{})).close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = "vendor/nested/deep.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "vendor/notes.md", .data = "" });
    try tmp.dir.symLink(io, "vendor", "linked-lib", .{});

    const gate_paths = [_][]const u8{"linked-lib"};
    var failed_path: ?[]const u8 = null;
    const checked = try checkedFiles(tmp.dir, io, arena, &gate_paths, &failed_path);

    // Paths stay as listed (through the link), the shape both gates report;
    // the non-.zig file is filtered like any walked entry.
    try std.testing.expectEqual(@as(usize, 1), checked.len);
    try std.testing.expectEqualStrings("linked-lib/nested/deep.zig", checked[0]);
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

test "checkedFiles names the gate path when a directory walk fails" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // The walk half of the failed-path contract: a link to a directory
    // inside a listed path rejects the walk, and the error surfaces with
    // failed_path naming the *gate path* — "src", not the link — the value
    // make()'s report prints. The stat branch above pins its own half; this
    // pins that the dispatcher's walk catch sets it too.
    (try tmp.dir.createDirPathOpen(io, "src/sub", .{})).close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = "src/sub/deep.zig", .data = "" });
    try tmp.dir.symLink(io, "sub", "src/vendor", .{});

    const gate_paths = [_][]const u8{"src"};
    var failed_path: ?[]const u8 = null;
    try std.testing.expectError(
        error.LinkedDirectoryNotWalked,
        checkedFiles(tmp.dir, io, arena, &gate_paths, &failed_path),
    );
    try std.testing.expectEqualStrings("src", failed_path.?);
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
    try appendZigFilesUnder(tmp.dir, io, arena, "src", &found);
    std.mem.sort([]const u8, found.items, {}, lessThanStrings);

    // Each result is dir_path joined with the walker-relative path, the
    // shape both gates report and read back through root_dir.
    try std.testing.expectEqual(@as(usize, 3), found.items.len);
    try std.testing.expectEqualStrings("src/a/b/deep.zig", found.items[0]);
    try std.testing.expectEqualStrings("src/a/inner.zig", found.items[1]);
    try std.testing.expectEqualStrings("src/top.zig", found.items[2]);
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
    (try tmp.dir.createDirPathOpen(io, "src", .{})).close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = "src/real.zig", .data = "" });
    try tmp.dir.symLink(io, "real.zig", "src/link.zig", .{});

    var found: std.ArrayListUnmanaged([]const u8) = .empty;
    try appendZigFilesUnder(tmp.dir, io, arena, "src", &found);
    std.mem.sort([]const u8, found.items, {}, lessThanStrings);

    try std.testing.expectEqual(@as(usize, 2), found.items.len);
    try std.testing.expectEqualStrings("src/link.zig", found.items[0]);
    try std.testing.expectEqualStrings("src/real.zig", found.items[1]);
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
    try tmp.dir.symLink(io, "sub", "src/vendor", .{});

    var found: std.ArrayListUnmanaged([]const u8) = .empty;
    try std.testing.expectError(
        error.LinkedDirectoryNotWalked,
        appendZigFilesUnder(tmp.dir, io, arena, "src", &found),
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
        return newCustomStep(b, GateCoverageStep, "gate coverage completeness", make);
    }

    fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) anyerror!void {
        _ = options;
        const b = step.owner;
        const io = b.graph.io;
        var arena_state = std.heap.ArenaAllocator.init(b.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        // The covered side comes from the same dispatcher the two
        // file-covering gates use, so this gate compares against exactly
        // what they check — never against its own re-derivation of the
        // checked set that could drift from theirs. Its enumeration failure
        // reports through the same one copy they use.
        var failed_path: ?[]const u8 = null;
        const covered = checkedFiles(
            b.build_root.handle,
            io,
            arena,
            &checked_paths,
            &failed_path,
        ) catch |err| return failEnumeration(step, err, failed_path);

        var candidates: std.ArrayListUnmanaged([]const u8) = .empty;
        // The walk can fail on one specific entry (a linked directory it
        // must reject, a link that no longer resolves): failed_path names
        // it, the way checkedFiles names the gate path it stopped on — a
        // bare error name would leave the operator to find the entry by
        // hand among everything the walk visited. The variable is reused
        // from the covered side above: its enumeration outcome was already
        // handled by then.
        failed_path = null;
        appendProjectZigFiles(
            b.build_root.handle,
            io,
            arena,
            &candidates,
            &failed_path,
        ) catch |err| {
            if (failed_path) |path|
                return step.fail("cannot walk '{s}': {s}", .{ path, @errorName(err) });
            return step.fail("cannot walk the project tree: {s}", .{@errorName(err)});
        };

        var report: std.ArrayListUnmanaged(u8) = .empty;
        try GateCoverageStep.uncoveredPaths(arena, covered, candidates.items, &report);

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
    /// line per candidate equal to no entry of `covered`, in the order
    /// handed in (the walk order, like the other gates' reports).
    /// O(covered x candidates) comparisons — the tree holds a handful of
    /// files today and the point is to fail loudly while it is small.
    fn uncoveredPaths(
        arena: std.mem.Allocator,
        covered: []const []const u8,
        candidates: []const []const u8,
        report: *std.ArrayListUnmanaged(u8),
    ) !void {
        outer: for (candidates) |path| {
            for (covered) |checked| {
                if (std.mem.eql(u8, checked, path)) continue :outer;
            }
            try report.print(arena, "  {s}: not covered by any analysis gate\n", .{path});
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
    if (basename.len == 0) return false;
    if (basename[0] == '.') return true;
    return depth == 1 and std.mem.eql(u8, basename, "zig-out");
}

/// Appends every project-owned .zig file — everything under the build root
/// except what excludedFromGates prunes — as a path relative to the walked
/// root. That is the form `checked_paths` produces too, so the comparison
/// needs no separator or prefix normalization on any host. Pruning happens
/// during descent rather than after the walk: .zig-cache alone holds
/// thousands of entries that would otherwise be visited on every lint run.
/// Entry classification goes through classifyWalkedEntry, the same policy
/// appendZigFilesUnder applies for the covering gates — a linked .zig file
/// is collected like a real one (SelectiveWalker enters only entries
/// reported as directories, so classifyWalkedEntry rejects a linked
/// directory loudly and its subtree would otherwise escape this gate
/// silently).
///
/// On failure `failed_path` names the walked entry that could not be handled —
/// the link or unclassifiable entry whose resolution failed or the directory
/// behind one — so the caller can report it instead of a bare error name (the same rule
/// checkedFiles follows for its gate paths). A failure belonging to no
/// single entry — allocation alone, here, or the walker failing to descend
/// between entries — leaves it unset, and the caller falls back to a
/// generic subject.
fn appendProjectZigFiles(
    root_dir: std.Io.Dir,
    io: std.Io,
    arena: std.mem.Allocator,
    paths: *std.ArrayListUnmanaged([]const u8),
    failed_path: *?[]const u8,
) !void {
    var dir = try root_dir.openDir(io, ".", .{ .iterate = true });
    defer dir.close(io);
    var walker = try std.Io.Dir.walkSelectively(dir, arena);
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
            // Entering is opt-in with a selective walker; skipping a
            // pruned or non-directory entry just keeps reading siblings.
            .directory => try walker.enter(io, entry),
            .linked_directory => {
                failed_path.* = try arena.dupe(u8, entry.path);
                return error.LinkedDirectoryNotWalked;
            },
            // The "" prefix joins to the entry's walked path itself: the
            // fresh copy outlives the walker slice it was derived from.
            .zig_source => |path| try paths.append(arena, path),
            .other => {},
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
    try GateCoverageStep.uncoveredPaths(arena, &covered, &candidates, &report);

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
    try GateCoverageStep.uncoveredPaths(arena, &covered, &candidates, &report);

    try std.testing.expectEqual(@as(usize, 0), report.items.len);
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
    (try tmp.dir.createDirPathOpen(io, "src", .{})).close(io);
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
    try tmp.dir.symLink(io, "top.zig", "src/link.zig", .{});

    var found: std.ArrayListUnmanaged([]const u8) = .empty;
    var failed_path: ?[]const u8 = null;
    try appendProjectZigFiles(tmp.dir, io, arena, &found, &failed_path);
    std.mem.sort([]const u8, found.items, {}, lessThanStrings);

    // A clean walk names no failing entry: make()'s report stays generic
    // exactly when nothing specific failed.
    try std.testing.expectEqual(@as(usize, 5), found.items.len);
    try std.testing.expect(failed_path == null);
    try std.testing.expectEqualStrings("src/link.zig", found.items[0]);
    try std.testing.expectEqualStrings("src/top.zig", found.items[1]);
    try std.testing.expectEqualStrings("stray.zig", found.items[2]);
    try std.testing.expectEqualStrings("tools/inner.zig", found.items[3]);
    try std.testing.expectEqualStrings("tools/zig-out/made.zig", found.items[4]);
}

test "appendProjectZigFiles rejects a linked directory like the gate-path walk" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // One policy everywhere: SelectiveWalker enters only entries reported
    // as directories and links are not, so the subtree behind the link
    // would silently escape this gate too — fail loudly instead, the
    // direction appendZigFilesUnder already chose for the covering gates.
    (try tmp.dir.createDirPathOpen(io, "tools/sub", .{})).close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = "tools/sub/deep.zig", .data = "" });
    // The link's target resolves relative to the link's own directory, the
    // same shape the gate-path walk's twin test uses.
    try tmp.dir.symLink(io, "sub", "tools/vendor", .{});

    var found: std.ArrayListUnmanaged([]const u8) = .empty;
    var failed_path: ?[]const u8 = null;
    try std.testing.expectError(
        error.LinkedDirectoryNotWalked,
        appendProjectZigFiles(tmp.dir, io, arena, &found, &failed_path),
    );

    // The rejection names the walked entry — the link itself, in walked-path
    // form — so make()'s report says which entry stopped the walk instead of
    // a bare error name the operator would have to locate by hand.
    try std.testing.expectEqualStrings("tools/vendor", failed_path.?);
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
    (try tmp.dir.createDirPathOpen(io, "src", .{})).close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = "src/real.zig", .data = "" });
    try tmp.dir.symLink(io, "nowhere.zig", "src/dangling.zig", .{});

    var found: std.ArrayListUnmanaged([]const u8) = .empty;
    var failed_path: ?[]const u8 = null;
    try std.testing.expectError(
        error.FileNotFound,
        appendProjectZigFiles(tmp.dir, io, arena, &found, &failed_path),
    );

    // The link, not its missing target: it is the tree entry that cannot be
    // handled.
    try std.testing.expectEqualStrings("src/dangling.zig", failed_path.?);
}
