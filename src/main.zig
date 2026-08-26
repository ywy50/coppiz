//! `spine` — the standalone node wrapping the spine library.
//!
//! A placeholder until the library API and node CLI land (PRD 0005; RFC 0001
//! decides which surface leads); it prints the version and points at the
//! docs so a checkout is never silently inert.

const std = @import("std");
const spine = @import("spine");

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [256]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    try writeStartupBanner(&stdout_writer.interface, spine.version);
    try stdout_writer.interface.flush();
}

/// Writes the startup banner: the library's version followed by the pointer
/// to the docs. These exact bytes are the node's whole placeholder behavior,
/// and documented output is part of the public contract (RELEASES.md), so
/// the test below pins them character for character. The writer is the only
/// effect — no process state — so the test drives it through a fixed buffer,
/// the way build.zig's gate cores stay testable.
fn writeStartupBanner(writer: *std.Io.Writer, version: std.SemanticVersion) !void {
    try writer.print("spine {f} — not implemented yet; see docs/README.md\n", .{version});
}

test "startup banner reports the version it was handed and points at the docs" {
    // The version comes from the argument, not from the package value: the
    // wiring spine.version -> main -> stdout is what RELEASES.md documents,
    // and a banner that printed anything but the handed version would break
    // it invisibly if the test baked today's version number in. 1.2.3 also
    // proves the fields survive formatting order-sensitively.
    var buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeStartupBanner(&writer, .{ .major = 1, .minor = 2, .patch = 3 });
    try std.testing.expectEqualStrings(
        "spine 1.2.3 — not implemented yet; see docs/README.md\n",
        writer.buffered(),
    );
}

test "all public declarations analyze" {
    // Zig's analyzer is lazy: an unreferenced `pub` declaration is compiled
    // into nothing and checked by nothing, so this test references them all.
    // CLI-only submodules go here as they are added: an import registers a
    // submodule for test collection, and the refAllDecls line is what also
    // forces its public declarations through the analyzer (src/root.zig
    // spells out both halves; the lint gate fails a root import that never
    // gets its refAllDecls line):
    //     std.testing.refAllDecls(@import("cli/x.zig"));
    std.testing.refAllDecls(@This());
}
