//! `coppiz docs` — regenerates `docs/configuration.md` from the settings
//! schema (PRD 0004 phase 5). Invoked by `zig build docs`, which passes the
//! target path; the rendered reference is byte-compared against the
//! checked-in file by the pinned test in render.zig (G5).
//!
//! A dedicated executable (not the `coppiz` CLI) so the build step can run
//! it without shell redirection; `coppiz settings schema` prints the same
//! table to stdout for operators.

const std = @import("std");
const render = @import("render.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    const argv0 = args.next() orelse return error.BadArgs;
    _ = argv0;
    const output = args.next() orelse {
        std.debug.print("usage: docgen <output.md>\n", .{});
        return error.BadArgs;
    };

    var alloc_writer = std.Io.Writer.Allocating.init(gpa);
    defer alloc_writer.deinit();
    try render.render(&alloc_writer.writer);
    const text = try alloc_writer.toOwnedSlice();
    defer gpa.free(text);

    const dir = std.Io.Dir.cwd();
    const file = try dir.createFile(init.io, output, .{ .truncate = true });
    defer file.close(init.io);
    try file.writePositionalAll(init.io, text, 0);
    try file.sync(init.io);
}
