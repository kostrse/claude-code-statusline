const std = @import("std");
const render = @import("render.zig");

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.skip(); // skip program name

    const render_mode = if (args.next()) |arg|
        std.mem.eql(u8, arg, "render")
    else
        false;

    if (render_mode) {
        const home = init.environ_map.get("HOME");
        // Honor the NO_COLOR convention: any presence disables styling.
        const color = init.environ_map.get("NO_COLOR") == null;
        // render owns its own stdin/stdout
        try render.run(init.io, init.gpa, home, color);
    } else {
        try usage(init.io);
    }
}

fn usage(io: std.Io) !void {
    var buf: [256]u8 = undefined;
    var stderr: std.Io.File.Writer = .init(.stderr(), io, &buf);
    const w = &stderr.interface;
    try w.writeAll("usage: claude_code_statusline render  (reads session JSON on stdin)\n");
    try w.flush();
}

test {
    // Pull submodule tests into the `zig build test` binary (rooted at main.zig).
    _ = @import("render.zig");
    _ = @import("StatusInput.zig");
    _ = @import("element.zig");
    _ = @import("style.zig");
}
