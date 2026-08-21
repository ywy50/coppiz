const std = @import("std");

// spine builds two things from one tree, on purpose: the library module
// (`spine`, src/root.zig) a host such as clanker fetches as a dependency,
// and the `spine` executable (src/main.zig) that wraps that same library
// as a standalone node. Which of the two leads the design is RFC 0001.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const version = std.SemanticVersion.parse(
        @import("build.zig.zon").version,
    ) catch @panic("build.zig.zon version is not semver");
    const options = b.addOptions();
    options.addOption(std.SemanticVersion, "version", version);

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

    // Zig 0.16 runs `test` blocks only from the root file of each test
    // module, so every src/ file must be reachable from src/root.zig's
    // comptime reference block or its tests silently never run.
    const lib_tests = b.addTest(.{ .root_module = lib_mod });
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(lib_tests).step);
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);
}
