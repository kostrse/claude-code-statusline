//! ANSI/SGR styling primitives for status-line segments. Pure text: a `Style`
//! knows how to write its "select graphics" escape and the matching reset into
//! a `*std.Io.Writer`. `render.zig` decides which segment gets which style; this
//! module only turns a style into bytes.

const std = @import("std");

/// The standard 16 ANSI colors (0–7 normal, 8–15 bright). Rendered through the
/// terminal's palette, so they track the user's theme.
pub const Named = enum(u8) {
    black = 0,
    red,
    green,
    yellow,
    blue,
    magenta,
    cyan,
    white,
    bright_black,
    bright_red,
    bright_green,
    bright_yellow,
    bright_blue,
    bright_magenta,
    bright_cyan,
    bright_white,
};

/// A 24-bit truecolor value. Exact, but ignores the terminal theme.
pub const Rgb = struct { r: u8, g: u8, b: u8 };

/// A foreground/background color: a theme-aware named color or an exact RGB.
pub const Color = union(enum) {
    named: Named,
    rgb: Rgb,
};

/// How a single status-line segment is painted. Every field defaults off, so the
/// zero value (`.{}`) means "no styling" and writes no bytes.
pub const Style = struct {
    fg: ?Color = null,
    bg: ?Color = null,
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,

    /// True when nothing is set — `open`/`close` then write nothing, keeping
    /// unstyled output byte-identical to plain text.
    pub fn isEmpty(s: Style) bool {
        return s.fg == null and s.bg == null and
            !s.bold and !s.dim and !s.italic and !s.underline;
    }

    /// Write the SGR "select graphics rendition" sequence for this style
    /// (`\x1b[…m`), joining parameters with `;`. No-op when empty.
    pub fn open(s: Style, w: *std.Io.Writer) !void {
        if (s.isEmpty()) return;
        try w.writeAll("\x1b[");
        var first = true;
        if (s.bold) try writeAttr(w, &first, "1");
        if (s.dim) try writeAttr(w, &first, "2");
        if (s.italic) try writeAttr(w, &first, "3");
        if (s.underline) try writeAttr(w, &first, "4");
        if (s.fg) |c| try writeColor(w, &first, c, false);
        if (s.bg) |c| try writeColor(w, &first, c, true);
        try w.writeByte('m');
    }

    /// Write the SGR reset (`\x1b[0m`). No-op when empty. Each segment fully
    /// re-specifies its style, so a blanket reset can't bleed across segments.
    pub fn close(s: Style, w: *std.Io.Writer) !void {
        if (!s.isEmpty()) try w.writeAll("\x1b[0m");
    }
};

/// Write `;` before every parameter except the first.
fn writeSep(w: *std.Io.Writer, first: *bool) !void {
    if (!first.*) try w.writeByte(';');
    first.* = false;
}

fn writeAttr(w: *std.Io.Writer, first: *bool, code: []const u8) !void {
    try writeSep(w, first);
    try w.writeAll(code);
}

/// Append a color parameter. `bg` selects the background variant (40/100/48)
/// over the foreground one (30/90/38).
fn writeColor(w: *std.Io.Writer, first: *bool, color: Color, bg: bool) !void {
    try writeSep(w, first);
    switch (color) {
        .named => |n| {
            const v: u8 = @intFromEnum(n);
            // 0–7 → 30/40 base; 8–15 → 90/100 bright base.
            const code: u8 = if (v < 8)
                (if (bg) @as(u8, 40) else 30) + v
            else
                (if (bg) @as(u8, 100) else 90) + (v - 8);
            try w.print("{d}", .{code});
        },
        .rgb => |c| {
            const lead: []const u8 = if (bg) "48;2;" else "38;2;";
            try w.print("{s}{d};{d};{d}", .{ lead, c.r, c.g, c.b });
        },
    }
}

const testing = std.testing;

test "empty style writes nothing" {
    var buf: [32]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const s: Style = .{};
    try s.open(&w);
    try s.close(&w);
    try testing.expectEqualStrings("", w.buffered());
}

test "named foreground" {
    var buf: [32]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try (Style{ .fg = .{ .named = .cyan } }).open(&w);
    try testing.expectEqualStrings("\x1b[36m", w.buffered());
}

test "bright foreground uses the 90 base" {
    var buf: [32]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try (Style{ .fg = .{ .named = .bright_red } }).open(&w);
    try testing.expectEqualStrings("\x1b[91m", w.buffered());
}

test "named background uses the 40 base" {
    var buf: [32]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try (Style{ .bg = .{ .named = .green } }).open(&w);
    try testing.expectEqualStrings("\x1b[42m", w.buffered());
}

test "rgb foreground" {
    var buf: [32]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try (Style{ .fg = .{ .rgb = .{ .r = 0, .g = 215, .b = 255 } } }).open(&w);
    try testing.expectEqualStrings("\x1b[38;2;0;215;255m", w.buffered());
}

test "attributes precede the foreground and join with ;" {
    var buf: [32]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try (Style{ .bold = true, .fg = .{ .named = .red } }).open(&w);
    try testing.expectEqualStrings("\x1b[1;31m", w.buffered());
}

test "reset" {
    var buf: [32]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try (Style{ .fg = .{ .named = .cyan } }).close(&w);
    try testing.expectEqualStrings("\x1b[0m", w.buffered());
}
