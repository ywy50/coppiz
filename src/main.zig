//! `spine` — the standalone node wrapping the spine library.
//!
//! A placeholder until RFC 0001 (library-first or service-first) is decided;
//! it prints the version and points at the docs so a checkout is never
//! silently inert.

const std = @import("std");
const spine = @import("spine");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var stdout_buffer: [256]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    try stdout_writer.interface.print(
        "spine {f} — not implemented yet; see docs/README.md\n",
        .{spine.version},
    );
    try stdout_writer.interface.flush();
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
