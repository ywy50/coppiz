const std = @import("std");

// spine builds two things from one tree, on purpose: the library module
// (`spine`, src/root.zig) a host such as clanker fetches as a dependency,
// and the `spine` executable (src/main.zig) that wraps that same library
// as a standalone node. Which of the two leads the design is RFC 0001.
pub fn build(b: *std.Build) void {
    enforceToolchainFloor();
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const version_text = @import("build.zig.zon").version;
    const version = std.SemanticVersion.parse(version_text) catch
        std.debug.panic("build.zig.zon version is not semver: '{s}'", .{version_text});
    const options = b.addOptions();
    options.addOption(std.SemanticVersion, "version", version);
    // The raw declaration too, so the library's tests can pin `spine.version`
    // to the literal build.zig.zon value rather than trusting the build's
    // parse step (RELEASES.md: the zon file is the single source of truth).
    options.addOption([]const u8, "version_text", version_text);

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

    const run_step = b.step("run", "Build and run the spine node");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
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
    // 100-column cap matching zig fmt's own wrap target, and test
    // registration (a module no chain of imports reaches from a test root
    // loses its tests silently).
    const lint_step = b.step("lint", "Check formatting, line length and test registration");

    // The checked paths come from `checked_paths`, shared with the column
    // cap below, so the two file-covering gates can never drift apart.
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

/// Every file the column-cap gate checks, derived from `checked_paths`: a
/// listed directory contributes its .zig descendants; any other entry is
/// taken whole (build.zig.zon has no .zig suffix but must still be capped).
///
/// All paths go through `root_dir` — the build root — not the process cwd:
/// the runner walks up to find build.zig without changing directory, so a
/// `zig build` invoked from anywhere under the project must still read this
/// project's files. Symlinks are followed (statFile's default), so a
/// linked-in source tree is analyzed like a real one.
/// `gate_paths` is a parameter rather than a read of `checked_paths` so a
/// test can drive the dispatch against a temporary tree, the same way `sep`
/// is a parameter below; production hands in `&checked_paths`.
fn checkedFiles(
    root_dir: std.Io.Dir,
    io: std.Io,
    arena: std.mem.Allocator,
    gate_paths: []const []const u8,
) ![][]const u8 {
    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    for (gate_paths) |path| {
        if ((try root_dir.statFile(io, path, .{})).kind == .directory) {
            try appendZigFilesUnder(root_dir, io, path, arena, &paths);
        } else {
            try paths.append(arena, path);
        }
    }
    return paths.toOwnedSlice(arena);
}

/// Appends every .zig file under the directory `dir_path`, as a path from
/// the build root ("src/foo.zig"), in walker order.
fn appendZigFilesUnder(
    root_dir: std.Io.Dir,
    io: std.Io,
    dir_path: []const u8,
    arena: std.mem.Allocator,
    paths: *std.ArrayListUnmanaged([]const u8),
) !void {
    var dir = try root_dir.openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        try paths.append(arena, try std.fs.path.join(arena, &.{ dir_path, entry.path }));
    }
}

/// Fails the build when any checked source line exceeds `max_columns`.
/// Columns are Unicode code points; invalid UTF-8 falls back to byte count.
const LineLengthStep = struct {
    step: std.Build.Step,

    const max_columns = 100;

    fn create(b: *std.Build) *LineLengthStep {
        const self = b.allocator.create(LineLengthStep) catch @panic("OOM");
        self.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                // Computed from max_columns so the displayed name cannot
                // drift from the cap it describes.
                .name = std.fmt.comptimePrint("{d}-column cap", .{max_columns}),
                .owner = b,
                .makeFn = make,
            }),
        };
        return self;
    }

    fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) anyerror!void {
        _ = options;
        const b = step.owner;
        const io = b.graph.io;
        var arena_state = std.heap.ArenaAllocator.init(b.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var report: std.ArrayListUnmanaged(u8) = .empty;
        var count: usize = 0;
        const root_dir = b.build_root.handle;
        const files = checkedFiles(root_dir, io, arena, &checked_paths) catch |err|
            return step.fail("cannot enumerate the checked paths: {s}", .{@errorName(err)});
        for (files) |path| {
            const bytes = root_dir.readFileAlloc(io, path, arena, .unlimited) catch |err|
                return step.fail("cannot read '{s}': {s}", .{ path, @errorName(err) });
            try checkBytes(arena, bytes, path, &report, &count);
        }
        if (count > 0)
            return step.fail("{d} line(s) exceed {d} columns:\n{s}", .{
                count, max_columns, report.items,
            });
    }

    /// The cap itself, I/O-free so tests can drive it directly.
    fn checkBytes(
        arena: std.mem.Allocator,
        bytes: []const u8,
        path: []const u8,
        report: *std.ArrayListUnmanaged(u8),
        count: *usize,
    ) !void {
        var line_no: usize = 0;
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            line_no += 1;
            if ((std.unicode.utf8CountCodepoints(line) catch line.len) <= max_columns) continue;
            count.* += 1;
            try report.print(arena, "  {s}:{d}\n", .{ path, line_no });
        }
    }
};

test "column cap admits a line at exactly the limit" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var report: std.ArrayListUnmanaged(u8) = .empty;
    var count: usize = 0;

    const exact = "a" ** LineLengthStep.max_columns;
    try LineLengthStep.checkBytes(arena, exact ++ "\nsecond\n", "f.zig", &report, &count);

    try std.testing.expectEqual(@as(usize, 0), count);
    try std.testing.expectEqual(@as(usize, 0), report.items.len);
}

test "column cap flags the first line past the limit, with path and line number" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var report: std.ArrayListUnmanaged(u8) = .empty;
    var count: usize = 0;

    const over = "a" ** (LineLengthStep.max_columns + 1);
    // Two violations: the first must still be the one named above, and the
    // aggregate — count and every report entry — must survive past it, so a
    // checker that stops at the first offense cannot pass.
    try LineLengthStep.checkBytes(
        arena,
        "ok\n" ++ over ++ "\nalso ok\n" ++ over ++ "\nlast ok\n",
        "f.zig",
        &report,
        &count,
    );

    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqualStrings("  f.zig:2\n  f.zig:4\n", report.items);
}

test "column cap measures code points, not bytes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var report: std.ArrayListUnmanaged(u8) = .empty;
    var count: usize = 0;

    // 60 two-byte code points: 120 bytes, but only 60 columns.
    try LineLengthStep.checkBytes(arena, "\u{00e9}" ** 60, "f.zig", &report, &count);

    try std.testing.expectEqual(@as(usize, 0), count);

    // The invalid side of the same boundary: 101 code points is over the cap
    // whatever the encoding, so wide characters are not skipped wholesale.
    const wide_over = "\u{00e9}" ** (LineLengthStep.max_columns + 1);
    try LineLengthStep.checkBytes(arena, wide_over, "f.zig", &report, &count);

    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqualStrings("  f.zig:1\n", report.items);
}

test "column cap falls back to byte count on invalid UTF-8" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var report: std.ArrayListUnmanaged(u8) = .empty;
    var count: usize = 0;

    const bad = "\xff" ** (LineLengthStep.max_columns + 1);
    try LineLengthStep.checkBytes(arena, bad, "f.zig", &report, &count);

    try std.testing.expectEqual(@as(usize, 1), count);
    // Same path:line report as the valid-UTF-8 over-limit case.
    try std.testing.expectEqualStrings("  f.zig:1\n", report.items);
}

/// The src/ files whose `test` blocks Zig collects (the test-module roots).
/// One list serves both uses in the gate below: the seeds of the
/// reachability walk, and the files exempt from requiring reachability.
const test_roots = [_][]const u8{ "src/root.zig", "src/main.zig" };

/// One walked src/ file: its path as appendZigFilesUnder hands it out
/// (build-root-relative, platform separators) and its source text.
const Source = struct {
    path: []const u8,
    text: []const u8,
};

/// Fails the build when no chain of real @imports reaches a src/ module
/// from a test-module root (src/root.zig or src/main.zig): only such a
/// chain makes Zig 0.16 collect the module's `test` blocks, so an
/// unreachable module's tests silently never run while `zig build test`
/// stays green. Collection follows analyzed imports transitively — verified
/// on 0.16.0: with root.zig importing a.zig importing b.zig, b's tests run;
/// an import in a declaration that is never analyzed (an unused
/// container-level const) collects nothing — so the gate walks real
/// @import calls across every walked module (hasRealImport), resolving each
/// candidate's import string relative to the importing file's directory
/// (importBetween), not just against the two roots. Only a literal
/// `@import("path")` call counts: a mention inside a comment or any string
/// literal registers nothing.
const TestRegistrationStep = struct {
    step: std.Build.Step,

    fn create(b: *std.Build) *TestRegistrationStep {
        const self = b.allocator.create(TestRegistrationStep) catch @panic("OOM");
        self.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = "test registration",
                .owner = b,
                .makeFn = make,
            }),
        };
        return self;
    }

    fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) anyerror!void {
        _ = options;
        const b = step.owner;
        const io = b.graph.io;
        var arena_state = std.heap.ArenaAllocator.init(b.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var report: std.ArrayListUnmanaged(u8) = .empty;
        var count: usize = 0;
        // Every walked module's text: the reachability walk reads imports
        // out of intermediate modules too, not just out of the two roots.
        // The roots sit in src/ themselves, so one walk finds them and no
        // file is read twice.
        var module_paths: std.ArrayListUnmanaged([]const u8) = .empty;
        appendZigFilesUnder(b.build_root.handle, io, "src", arena, &module_paths) catch |err|
            return step.fail("cannot enumerate the src/ modules: {s}", .{@errorName(err)});
        var sources: std.ArrayListUnmanaged(Source) = .empty;
        for (module_paths.items) |path| {
            const bytes = b.build_root.handle.readFileAlloc(
                io,
                path,
                arena,
                .unlimited,
            ) catch |err| return step.fail(
                "cannot read module '{s}': {s}",
                .{ path, @errorName(err) },
            );
            try sources.append(arena, .{ .path = path, .text = bytes });
        }
        try classifyModules(arena, sources.items, std.fs.path.sep, &report, &count);
        if (count > 0)
            return step.fail("{d} module(s) whose tests never run:\n{s}", .{
                count, report.items,
            });
    }

    /// The gate's decision core, I/O-free so tests drive it directly, the
    /// way checkBytes serves the column cap: from the test roots, follow
    /// real imports across `sources` and append one report line per module
    /// no chain reaches, counting them. O(modules²) tokenizer runs — src/
    /// holds a handful of files today and the point is to fail loudly while
    /// the tree is small. `sep` is a parameter so any platform can be
    /// simulated in a test.
    fn classifyModules(
        arena: std.mem.Allocator,
        sources: []const Source,
        sep: u8,
        report: *std.ArrayListUnmanaged(u8),
        count: *usize,
    ) !void {
        var reachable: std.StringArrayHashMapUnmanaged(void) = .empty;
        defer reachable.deinit(arena);
        var queue: std.ArrayListUnmanaged([]const u8) = .empty;
        defer queue.deinit(arena);
        for (sources) |source| {
            if (try isTestRoot(arena, source.path, sep)) try queue.append(arena, source.path);
        }
        var cursor: usize = 0;
        while (cursor < queue.items.len) : (cursor += 1) {
            const path = queue.items[cursor];
            if (reachable.contains(path)) continue;
            try reachable.put(arena, path, {});
            const text = for (sources) |source| {
                if (std.mem.eql(u8, source.path, path)) break source.text;
            } else unreachable;
            for (sources) |candidate| {
                if (std.mem.eql(u8, candidate.path, path)) continue;
                if (reachable.contains(candidate.path)) continue;
                const wanted = try importBetween(arena, path, candidate.path, sep);
                if (try hasRealImport(arena, text, wanted))
                    try queue.append(arena, candidate.path);
            }
        }
        for (sources) |source| {
            if (try isTestRoot(arena, source.path, sep)) continue;
            if (reachable.contains(source.path)) continue;
            count.* += 1;
            try report.print(arena, "  {s}: not reachable from a test root\n", .{source.path});
        }
    }

    /// appendZigFilesUnder joins with the platform separator ('\') on Windows, while
    /// test_roots is written with '/', so a byte-equal comparison never matches there:
    /// the roots would be checked as ordinary modules and fail the gate (nothing
    /// @imports them as files). Normalize the walked path to '/' separators first —
    /// the same translation importBetween applies after resolving. `sep` is a
    /// parameter so any platform can be simulated in a test.
    fn isTestRoot(
        arena: std.mem.Allocator,
        path: []const u8,
        sep: u8,
    ) !bool {
        const normalized = try importSeparators(arena, path, sep);
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
    /// neither carries a drive or leading separator; `sep` is a parameter
    /// so any platform can be simulated in a test.
    fn importBetween(
        arena: std.mem.Allocator,
        from_path: []const u8,
        to_path: []const u8,
        sep: u8,
    ) ![]const u8 {
        const from = try importSeparators(arena, from_path, sep);
        const to = try importSeparators(arena, to_path, sep);
        // Longest common prefix ending on a '/' boundary: stopping at the
        // first differing byte instead would treat "src/aa/" and "src/ab/"
        // as one directory because they share "src/a".
        var scanned: usize = 0;
        var boundary: usize = 0;
        const limit = @min(from.len, to.len);
        while (scanned < limit and from[scanned] == to[scanned]) : (scanned += 1) {
            if (from[scanned] == '/') boundary = scanned + 1;
        }
        var out: std.ArrayListUnmanaged(u8) = .empty;
        // Each directory left under the importer climbs one "..".
        for (from[boundary..]) |c| {
            if (c != '/') continue;
            try out.appendSlice(arena, "../");
        }
        try out.appendSlice(arena, to[boundary..]);
        return out.toOwnedSlice(arena);
    }

    /// True when `source` actually calls `@import("target")`, decided on the
    /// token stream rather than the text: comments are dropped entirely, and
    /// string literals lex as inert data (a multiline string one token per
    /// line, under its own tag), so a mention in either registers nothing,
    /// while an import sharing a line with a trailing comment — or with an
    /// earlier "//" inside a string — still counts. The builtin's spelling is
    /// matched too, so
    /// @embedFile("sub/x.zig") is not registration. Only the
    /// two preceding tokens are remembered; that spans any whitespace but not
    /// a computed path (@import(a ++ b)), which fails loudly instead — the
    /// direction the gate accepts.
    fn hasRealImport(arena: std.mem.Allocator, source: []const u8, target: []const u8) !bool {
        const terminated = try arena.dupeZ(u8, source);
        var lexer = std.zig.Tokenizer.init(terminated);
        var prev_tags: [2]std.zig.Token.Tag = .{ .eof, .eof };
        var prev_slices: [2][]const u8 = .{ "", "" };
        const wanted = try std.fmt.allocPrint(arena, "\"{s}\"", .{target});
        while (true) {
            const token = lexer.next();
            if (token.tag == .eof) return false;
            if (token.tag == .string_literal and
                prev_tags[0] == .builtin and std.mem.eql(u8, prev_slices[0], "@import") and
                prev_tags[1] == .l_paren)
            {
                if (std.mem.eql(u8, terminated[token.loc.start..token.loc.end], wanted))
                    return true;
            }
            prev_tags[0] = prev_tags[1];
            prev_tags[1] = token.tag;
            prev_slices[0] = prev_slices[1];
            prev_slices[1] = terminated[token.loc.start..token.loc.end];
        }
    }
};

/// Rewrites filesystem separators to import separators ('/'), the only form
/// that can appear inside an @import string. A no-op where the separator is
/// already '/'; `sep` is a parameter so any platform can be simulated in a
/// test.
fn importSeparators(arena: std.mem.Allocator, path: []const u8, sep: u8) ![]const u8 {
    if (sep == '/') return path;
    return std.mem.replaceOwned(u8, arena, path, &.{sep}, "/");
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
    // The shared prefix must stop on a '/' boundary: src/aa/ and src/ab/
    // share "src/a" byte-wise but are different directories.
    try std.testing.expectEqualStrings(
        "../ab/g.zig",
        try TestRegistrationStep.importBetween(arena, "src/aa/f.zig", "src/ab/g.zig", '/'),
    );

    // The Windows case, simulated on every host through the sep argument:
    // walked paths are normalized before resolution.
    const win = try importSeparators(arena, "sub\\x\\y.zig", '\\');
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

    // The form appendZigFilesUnder hands make() on Windows, simulated through the sep
    // argument: joined with '\', so a byte-equal match against the '/'-written
    // test_roots would fail and both roots would be reported as unregistered modules.
    try std.testing.expect(try TestRegistrationStep.isTestRoot(arena, "src\\root.zig", '\\'));
    try std.testing.expect(try TestRegistrationStep.isTestRoot(arena, "src\\main.zig", '\\'));
    try std.testing.expect(!try TestRegistrationStep.isTestRoot(arena, "src\\sub\\x.zig", '\\'));

    // What make() sees on this host.
    const native = try importSeparators(arena, "src/root.zig", std.fs.path.sep);
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
    var count: usize = 0;
    try TestRegistrationStep.classifyModules(arena, &sources, '\\', &report, &count);

    // The roots are never reported though nothing imports them; exactly the
    // orphan is, named by its walked path — the string make() prints on any
    // host.
    try std.testing.expectEqual(@as(usize, 1), count);
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
    count = 0;
    try TestRegistrationStep.classifyModules(
        arena,
        &native_sources,
        std.fs.path.sep,
        &report,
        &count,
    );

    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqualStrings(
        "  src" ++ s ++ "sub" ++ s ++ "unregistered.zig: not reachable from a test root\n",
        report.items,
    );
}

test "hasRealImport counts only a real @import call" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The forms that register: plain, spaced across lines, sharing a line
    // with a trailing comment.
    try std.testing.expect(try TestRegistrationStep.hasRealImport(
        arena,
        "_ = @import(\"sub/x.zig\");\n",
        "sub/x.zig",
    ));
    try std.testing.expect(try TestRegistrationStep.hasRealImport(
        arena,
        "comptime {\n    _ = @import(\n        \"sub/x.zig\",\n    );\n}\n",
        "sub/x.zig",
    ));
    try std.testing.expect(try TestRegistrationStep.hasRealImport(
        arena,
        "_ = @import(\"sub/x.zig\"); // keep this one\n",
        "sub/x.zig",
    ));

    // The false-pass directions the removed textual matcher admitted:
    // mention inside an ordinary string literal, in a comment, in multiline
    // string data — none of them import anything.
    try std.testing.expect(!try TestRegistrationStep.hasRealImport(
        arena,
        "const msg = \"@import(\\\"sub/x.zig\\\") registers nothing\";\n",
        "sub/x.zig",
    ));
    try std.testing.expect(!try TestRegistrationStep.hasRealImport(
        arena,
        "// _ = @import(\"sub/x.zig\");\n",
        "sub/x.zig",
    ));
    try std.testing.expect(!try TestRegistrationStep.hasRealImport(
        arena,
        "const prose =\n" ++
            "\\\\ @import(\"sub/x.zig\") reads well here.\n" ++
            ";\n",
        "sub/x.zig",
    ));
    try std.testing.expect(!try TestRegistrationStep.hasRealImport(
        arena,
        "// @import(\n// \"sub/x.zig\"); split across comment lines\n",
        "sub/x.zig",
    ));

    // A different builtin taking the same path is not registration either.
    try std.testing.expect(!try TestRegistrationStep.hasRealImport(
        arena,
        "const img = @embedFile(\"sub/x.zig\");\n",
        "sub/x.zig",
    ));

    // Neither is a computed path (@import(a ++ b)): only a literal string
    // argument matches, so such a module is reported by the gate — failing
    // loudly, never half-matched.
    try std.testing.expect(!try TestRegistrationStep.hasRealImport(
        arena,
        "const dir = \"sub\"; _ = @import(dir ++ \"/x.zig\");\n",
        "sub/x.zig",
    ));

    // A different path does not match.
    try std.testing.expect(!try TestRegistrationStep.hasRealImport(
        arena,
        "_ = @import(\"other/y.zig\");\n",
        "sub/x.zig",
    ));
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

    const checked = try checkedFiles(tmp.dir, io, arena, &gate_paths);
    std.mem.sort([]const u8, checked, {}, lessThanStrings);

    try std.testing.expectEqual(@as(usize, 3), checked.len);
    try std.testing.expectEqualStrings("build.zig.zon", checked[0]);
    try std.testing.expectEqualStrings("lib/deep/inner.zig", checked[1]);
    try std.testing.expectEqualStrings("lib/top.zig", checked[2]);
}

test "checkedFiles fails loudly when a checked path stops existing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // The documented alternative to silently checking nothing.
    const gate_paths = [_][]const u8{"gone"};
    try std.testing.expectError(
        error.FileNotFound,
        checkedFiles(tmp.dir, io, arena, &gate_paths),
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
    try appendZigFilesUnder(tmp.dir, io, "src", arena, &found);
    std.mem.sort([]const u8, found.items, {}, lessThanStrings);

    // Each result is dir_path joined with the walker-relative path, the
    // shape both gates report and read back through root_dir.
    try std.testing.expectEqual(@as(usize, 3), found.items.len);
    try std.testing.expectEqualStrings("src/a/b/deep.zig", found.items[0]);
    try std.testing.expectEqualStrings("src/a/inner.zig", found.items[1]);
    try std.testing.expectEqualStrings("src/top.zig", found.items[2]);
}
