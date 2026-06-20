//! Status line rendering: reads the session JSON on stdin and writes a status
//! line to stdout.
//!
//! Layered so the formatting core stays testable without touching real file
//! descriptors:
//!   - `run`    — the I/O shell. main injects the `Io` instance, allocator, and
//!                `$HOME`; this builds its own stdin reader and stdout writer,
//!                reads the wall clock, and gathers everything the renderers
//!                need into a `Context`.
//!   - `format` — the pure core. Takes an in-memory `*std.Io.Writer`, a parsed
//!                value, and a `Context`. Its only I/O is writing to `w`, so
//!                tests drive it with a fixed buffer and a fixed `Context`.

const std = @import("std");
const StatusInput = @import("StatusInput.zig");
const element = @import("element.zig");
const style = @import("style.zig");

/// Upper bound on the stdin payload we will read (the real snapshot is tiny).
const max_input_bytes = 1 << 20; // 1 MiB

/// Ambient inputs the renderers need from the environment, gathered once by
/// `run` so `format` and the segment renderers stay pure — their only I/O is
/// writing to `w`. Every field has a default, so tests supply just what they
/// exercise (`.{ .home_dir = "/home/me" }`).
pub const Context = struct {
    /// `$HOME`; abbreviates a matching directory prefix to `~`. Null disables.
    home_dir: ?[]const u8 = null,
    /// Current wall-clock epoch in seconds. Drives relative reset times; null
    /// suppresses any "time left" output.
    now: ?i64 = null,
    /// Seconds east of UTC, applied when formatting absolute times. Zero (the
    /// default) renders UTC.
    utc_offset_seconds: i64 = 0,
    /// Whether segment styles are emitted. Off by default so unstyled output is
    /// byte-identical to plain text; `run` turns it on (respecting `NO_COLOR`).
    color: bool = false,
};

/// Pairs a segment's `Style` with the global on/off gate, so each renderer can
/// wrap its text without re-checking `ctx.color`. When `on` is false (or the
/// style is empty) nothing is written, leaving the segment as plain text.
const Paint = struct {
    style: style.Style,
    on: bool,

    fn open(p: Paint, w: *std.Io.Writer) !void {
        if (p.on) try p.style.open(w);
    }
    fn close(p: Paint, w: *std.Io.Writer) !void {
        if (p.on) try p.style.close(w);
    }
};

/// The built-in layout, reproducing the historical hard-coded order. `run`
/// passes this to `format`; it is a pure description of layout and holds no
/// runtime state.
pub const default_format = [_]element.Item{
    .{ .element = .{ .model = .{} }, .style = .{ .fg = .{ .named = .cyan } } },
    .{ .element = .project_dir, .style = .{ .fg = .{ .named = .blue } } },
    .{ .element = .branch, .style = .{ .fg = .{ .named = .magenta } } },
    .{ .element = .{ .context = .{} }, .style = .{ .fg = .{ .named = .yellow } } },
    .{ .element = .{ .usage = .{ .window = .five_hour, .time_left = true } }, .style = .{ .fg = .{ .named = .green } } },
    .{ .element = .{ .usage = .{ .window = .seven_day, .time_left = true } }, .style = .{ .fg = .{ .named = .green } } },
};

/// Read the JSON snapshot from stdin and print the status line to stdout.
///
/// Capability injection: `io` and `gpa` come from `main`, and this function owns
/// the concrete stdin reader and stdout writer (and their buffers). The status
/// line is never left blank — malformed input still produces a line and a
/// successful exit, since Claude Code blanks the line on empty stdout or a
/// non-zero exit.
pub fn run(io: std.Io, gpa: std.mem.Allocator, homeDir: ?[]const u8, color: bool) !void {
    var in_buf: [4096]u8 = undefined;
    var stdin: std.Io.File.Reader = .init(.stdin(), io, &in_buf);
    const bytes = try stdin.interface.allocRemaining(gpa, .limited(max_input_bytes));
    defer gpa.free(bytes);

    var out_buf: [1024]u8 = undefined;
    var stdout: std.Io.File.Writer = .init(.stdout(), io, &out_buf);
    const w = &stdout.interface;

    const ctx: Context = .{
        .home_dir = homeDir,
        // Wall-clock epoch (seconds), read through `io`.
        .now = @intCast(@divFloor(std.Io.Clock.now(.real, io).nanoseconds, 1_000_000_000)),
        // Absolute times render in UTC; sourcing a local offset would set this.
        .utc_offset_seconds = 0,
        .color = color,
    };

    if (StatusInput.parse(gpa, bytes)) |parsed| {
        defer parsed.deinit();
        try format(w, parsed.value, ctx, &default_format);
    } else |_| {
        // Don't blank the line just because the payload was unparseable.
        try w.writeAll("STATUS FAILURE\n");
    }

    try w.flush();
}

/// Render `in` as a single status line (terminated by a newline) into `w`,
/// emitting `elements` in the order given.
///
/// `ctx` carries the ambient inputs (home dir, clock, timezone). Every payload
/// field is treated as optional and skipped when absent; an element whose data
/// is missing produces nothing (not even a leading separator). If no element
/// produces output, a static label is emitted so stdout is never empty.
pub fn format(w: *std.Io.Writer, in: StatusInput, ctx: Context, items: []const element.Item) !void {
    var wrote = false;
    for (items) |item| {
        const paint: Paint = .{ .style = item.style, .on = ctx.color };
        switch (item.element) {
            .model => |cfg| try renderModel(w, in, cfg, paint, &wrote),
            .project_dir => try renderProjectDir(w, in, ctx, paint, &wrote),
            .branch => try renderBranch(w, in, paint, &wrote),
            .context => |cfg| try renderContext(w, in, cfg, paint, &wrote),
            .usage => |cfg| try renderUsage(w, in, cfg, ctx, paint, &wrote),
        }
    }

    if (!wrote) try w.writeAll("¯\\(°_o)/¯");
    try w.writeByte('\n');
}

/// Model name (display label or machine id), with the effort level as an
/// optional trailing modifier: "Opus 4.8 high".
fn renderModel(w: *std.Io.Writer, in: StatusInput, cfg: element.Element.Model, paint: Paint, wrote: *bool) !void {
    const model = in.model orelse return;
    const name = switch (cfg.name) {
        .display => model.display_name,
        .id => model.id,
    } orelse return;
    try separator(w, wrote);
    try paint.open(w);
    try w.writeAll(name);
    if (cfg.effort) {
        if (in.effort) |effort| {
            if (effort.level) |level| try w.print(" {s}", .{level});
        }
    }
    try paint.close(w);
}

/// Project root as a full path, with `$HOME` collapsed to `~`. Prefers the
/// workspace's project dir, falling back to top-level cwd when it is absent.
fn renderProjectDir(w: *std.Io.Writer, in: StatusInput, ctx: Context, paint: Paint, wrote: *bool) !void {
    const dir = if (in.workspace) |ws| ws.project_dir orelse in.cwd else in.cwd;
    const d = dir orelse return;
    try separator(w, wrote);
    try paint.open(w);
    try writeDir(w, d, ctx.home_dir);
    try paint.close(w);
}

/// Git branch (only present in the payload for worktree sessions).
fn renderBranch(w: *std.Io.Writer, in: StatusInput, paint: Paint, wrote: *bool) !void {
    const wt = in.worktree orelse return;
    const branch = wt.branch orelse return;
    try separator(w, wrote);
    try paint.open(w);
    try w.writeAll(branch);
    try paint.close(w);
}

/// Context-window usage: "Context N% used" / "Context N% left".
fn renderContext(w: *std.Io.Writer, in: StatusInput, cfg: element.Element.Context, paint: Paint, wrote: *bool) !void {
    const ctx = in.context_window orelse return;
    const pct: f64 = switch (cfg.portion) {
        .used => ctx.used_percentage orelse return,
        // Prefer the supplied remaining figure; fall back to the complement.
        .left => ctx.remaining_percentage orelse (100 - (ctx.used_percentage orelse return)),
    };
    try separator(w, wrote);
    try paint.open(w);
    try w.print("Context {d:.0}% {s}", .{ pct, portionWord(cfg.portion) });
    try paint.close(w);
}

/// Quota for a rate-limit window: "5h N% left" / "weekly N% used", optionally
/// followed by reset info ("(resets in 2h 15m at 14:30 UTC)").
fn renderUsage(w: *std.Io.Writer, in: StatusInput, cfg: element.Element.Usage, ctx: Context, paint: Paint, wrote: *bool) !void {
    const limits = in.rate_limits orelse return;
    const data = switch (cfg.window) {
        .five_hour => limits.five_hour,
        .seven_day => limits.seven_day,
    } orelse return;
    const used = data.used_percentage orelse return;
    try separator(w, wrote);
    try paint.open(w);
    const label = switch (cfg.window) {
        .five_hour => "5h",
        .seven_day => "weekly",
    };
    const pct = switch (cfg.portion) {
        .used => used,
        .left => 100 - used,
    };
    try w.print("{s} {d:.0}% {s}", .{ label, pct, portionWord(cfg.portion) });
    if (cfg.reset_at or cfg.time_left) try writeReset(w, data.resets_at, ctx, cfg);
    try paint.close(w);
}

/// Append reset details for a usage window. `time_left` needs `ctx.now`;
/// `reset_at` formats the absolute reset moment in `ctx`'s timezone. Renders
/// nothing if there is no reset timestamp (or no clock, when only the relative
/// form was requested).
fn writeReset(w: *std.Io.Writer, resets_at: ?i64, ctx: Context, cfg: element.Element.Usage) !void {
    const resets = resets_at orelse return;
    const show_left = cfg.time_left and ctx.now != null;
    if (!show_left and !cfg.reset_at) return;

    try w.writeAll(" (resets");
    if (show_left) {
        try w.writeAll(" in ");
        try writeDuration(w, resets - ctx.now.?);
    }
    if (cfg.reset_at) {
        try w.writeAll(" at ");
        try writeClock(w, resets, ctx.utc_offset_seconds);
        try writeTzLabel(w, ctx.utc_offset_seconds);
    }
    try w.writeByte(')');
}

/// Write a coarse human duration for `secs` ("2h 15m", "3d 4h", "45m"). Clamps
/// non-positive values to "now".
fn writeDuration(w: *std.Io.Writer, secs: i64) !void {
    if (secs <= 0) return w.writeAll("now");
    const days = @divFloor(secs, 86400);
    const hours = @divFloor(@mod(secs, 86400), 3600);
    const mins = @divFloor(@mod(secs, 3600), 60);
    if (days > 0) {
        try w.print("{d}d {d}h", .{ days, hours });
    } else if (hours > 0) {
        try w.print("{d}h {d}m", .{ hours, mins });
    } else {
        try w.print("{d}m", .{mins});
    }
}

/// Write the wall-clock time ("14:30") for a Unix epoch in seconds, shifted by
/// `offset` seconds east of UTC.
fn writeClock(w: *std.Io.Writer, epoch: i64, offset: i64) !void {
    const local = epoch + offset;
    if (local < 0) return;
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(local) };
    const day = es.getDaySeconds();
    try w.print("{d:0>2}:{d:0>2}", .{ day.getHoursIntoDay(), day.getMinutesIntoHour() });
}

/// Write the timezone label for an offset: " UTC" at zero, otherwise " +02:00".
fn writeTzLabel(w: *std.Io.Writer, offset: i64) !void {
    if (offset == 0) return w.writeAll(" UTC");
    const sign: u8 = if (offset < 0) '-' else '+';
    const mag: u64 = @intCast(if (offset < 0) -offset else offset);
    try w.print(" {c}{d:0>2}:{d:0>2}", .{ sign, mag / 3600, (mag % 3600) / 60 });
}

/// The trailing word for a percentage gauge.
fn portionWord(portion: element.Portion) []const u8 {
    return switch (portion) {
        .used => "used",
        .left => "left",
    };
}

/// Write `dir`, collapsing a leading `home` to `~` (so `/home/me/p` with
/// `home = /home/me` prints `~/p`). The prefix only counts on a path boundary,
/// so `/home/meadow` is never mistaken for a child of `/home/me`.
fn writeDir(w: *std.Io.Writer, dir: []const u8, home: ?[]const u8) !void {
    if (home) |h| {
        if (h.len > 0 and std.mem.startsWith(u8, dir, h)) {
            const rest = dir[h.len..];
            if (rest.len == 0) {
                try w.writeByte('~');
                return;
            }
            if (rest[0] == '/') {
                try w.writeByte('~');
                try w.writeAll(rest);
                return;
            }
        }
    }
    try w.writeAll(dir);
}

/// Write the segment separator before every segment except the first.
fn separator(w: *std.Io.Writer, wrote: *bool) !void {
    if (wrote.*) try w.writeAll(" · ");
    wrote.* = true;
}

test "format renders the default line" {
    const in: StatusInput = .{
        .cwd = "/home/me/Dev/divigo-backend",
        .model = .{ .id = "claude-opus-4-8", .display_name = "Opus 4.8" },
        .effort = .{ .level = "high" },
        .workspace = .{ .project_dir = "/home/me/Dev/divigo-backend" },
        .worktree = .{ .branch = "main" },
        .context_window = .{ .used_percentage = 11 },
        .rate_limits = .{
            .five_hour = .{ .used_percentage = 6 },
            .seven_day = .{ .used_percentage = 1 },
        },
    };

    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try format(&w, in, .{ .home_dir = "/home/me" }, &default_format);

    try std.testing.expectEqualStrings(
        "Opus 4.8 high · ~/Dev/divigo-backend · main · Context 11% used · 5h 94% left · weekly 99% left\n",
        w.buffered(),
    );
}

test "format falls back to a label when nothing is present" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try format(&w, .{}, .{}, &default_format);

    try std.testing.expectEqualStrings("¯\\(°_o)/¯\n", w.buffered());
}

test "model element honors the name switch and effort toggle" {
    const in: StatusInput = .{
        .model = .{ .id = "claude-opus-4-8", .display_name = "Opus 4.8" },
        .effort = .{ .level = "high" },
    };

    // id name, effort suppressed.
    const layout = [_]element.Item{.{ .element = .{ .model = .{ .name = .id, .effort = false } } }};
    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try format(&w, in, .{}, &layout);
    try std.testing.expectEqualStrings("claude-opus-4-8\n", w.buffered());
}

test "project_dir renders the project root, not cwd" {
    const in: StatusInput = .{
        .cwd = "/home/me/elsewhere",
        .workspace = .{ .project_dir = "/home/me/Dev/proj" },
    };

    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try format(&w, in, .{ .home_dir = "/home/me" }, &[_]element.Item{.{ .element = .project_dir }});
    try std.testing.expectEqualStrings("~/Dev/proj\n", w.buffered());
}

test "project_dir falls back to cwd when project_dir is absent" {
    const in: StatusInput = .{ .cwd = "/srv/app", .workspace = .{} };

    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try format(&w, in, .{}, &[_]element.Item{.{ .element = .project_dir }});
    try std.testing.expectEqualStrings("/srv/app\n", w.buffered());
}

test "context portion switch renders used or left" {
    const in: StatusInput = .{ .context_window = .{ .used_percentage = 30, .remaining_percentage = 70 } };

    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try format(&w, in, .{}, &[_]element.Item{.{ .element = .{ .context = .{ .portion = .left } } }});
    try std.testing.expectEqualStrings("Context 70% left\n", w.buffered());
}

test "format renders elements in the given order" {
    const in: StatusInput = .{
        .model = .{ .display_name = "Sonnet" },
        .context_window = .{ .used_percentage = 42 },
    };

    // Reordered + subset: context before model, no other segments.
    const layout = [_]element.Item{ .{ .element = .{ .context = .{} } }, .{ .element = .{ .model = .{} } } };

    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try format(&w, in, .{}, &layout);

    try std.testing.expectEqualStrings("Context 42% used · Sonnet\n", w.buffered());
}

test "usage renders a single window with used portion" {
    const in: StatusInput = .{
        .rate_limits = .{
            .five_hour = .{ .used_percentage = 6 },
            .seven_day = .{ .used_percentage = 1 },
        },
    };

    const layout = [_]element.Item{.{ .element = .{ .usage = .{ .window = .seven_day, .portion = .used } } }};

    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try format(&w, in, .{}, &layout);

    try std.testing.expectEqualStrings("weekly 1% used\n", w.buffered());
}

test "usage appends relative and absolute reset info" {
    // resets_at = 1h 5m after now; 23:18 UTC.
    const now: i64 = 1_700_000_000;
    const in: StatusInput = .{
        .rate_limits = .{
            .five_hour = .{ .used_percentage = 6, .resets_at = now + 3900 },
        },
    };

    const layout = [_]element.Item{.{ .element = .{ .usage = .{
        .window = .five_hour,
        .reset_at = true,
        .time_left = true,
    } } }};

    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try format(&w, in, .{ .now = now }, &layout);

    try std.testing.expectEqualStrings("5h 94% left (resets in 1h 5m at 23:18 UTC)\n", w.buffered());
}

test "usage renders the absolute reset time in the context timezone" {
    const now: i64 = 1_700_000_000;
    const in: StatusInput = .{
        .rate_limits = .{ .five_hour = .{ .used_percentage = 6, .resets_at = now + 3900 } },
    };

    const layout = [_]element.Item{.{ .element = .{ .usage = .{ .window = .five_hour, .reset_at = true } } }};

    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    // +02:00 shifts 23:18 UTC to 01:18 the next day.
    try format(&w, in, .{ .now = now, .utc_offset_seconds = 2 * 3600 }, &layout);

    try std.testing.expectEqualStrings("5h 94% left (resets at 01:18 +02:00)\n", w.buffered());
}

test "usage time_left is suppressed without a clock" {
    const in: StatusInput = .{
        .rate_limits = .{ .five_hour = .{ .used_percentage = 6, .resets_at = 1_700_000_000 } },
    };

    const layout = [_]element.Item{.{ .element = .{ .usage = .{ .window = .five_hour, .time_left = true } } }};

    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try format(&w, in, .{}, &layout);

    try std.testing.expectEqualStrings("5h 94% left\n", w.buffered());
}

test "format skips absent segments and keeps separators clean" {
    const in: StatusInput = .{
        .model = .{ .display_name = "Sonnet" },
        // no effort / workspace / cwd / branch / rate limits
        .context_window = .{ .used_percentage = 42 },
    };

    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try format(&w, in, .{}, &default_format);

    try std.testing.expectEqualStrings("Sonnet · Context 42% used\n", w.buffered());
}

test "format prints the absolute dir when home does not match" {
    const in: StatusInput = .{ .cwd = "/srv/app", .workspace = .{ .project_dir = "/srv/app" } };

    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try format(&w, in, .{ .home_dir = "/home/me" }, &default_format);

    try std.testing.expectEqualStrings("/srv/app\n", w.buffered());
}

test "writeDir collapses home only on a path boundary" {
    var buf: [128]u8 = undefined;

    // Exact home → "~".
    var w1 = std.Io.Writer.fixed(&buf);
    try writeDir(&w1, "/home/me", "/home/me");
    try std.testing.expectEqualStrings("~", w1.buffered());

    // Child of home → "~/...".
    var w2 = std.Io.Writer.fixed(&buf);
    try writeDir(&w2, "/home/me/Dev/x", "/home/me");
    try std.testing.expectEqualStrings("~/Dev/x", w2.buffered());

    // Sibling that merely shares a prefix → left absolute.
    var w3 = std.Io.Writer.fixed(&buf);
    try writeDir(&w3, "/home/meadow", "/home/me");
    try std.testing.expectEqualStrings("/home/meadow", w3.buffered());
}

test "color wraps a styled segment with named SGR codes" {
    const in: StatusInput = .{ .model = .{ .display_name = "Sonnet" } };
    const layout = [_]element.Item{
        .{ .element = .{ .model = .{} }, .style = .{ .fg = .{ .named = .cyan } } },
    };

    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try format(&w, in, .{ .color = true }, &layout);
    try std.testing.expectEqualStrings("\x1b[36mSonnet\x1b[0m\n", w.buffered());
}

test "color supports truecolor (RGB) foreground" {
    const in: StatusInput = .{ .model = .{ .display_name = "Sonnet" } };
    const layout = [_]element.Item{
        .{ .element = .{ .model = .{} }, .style = .{ .fg = .{ .rgb = .{ .r = 0, .g = 215, .b = 255 } } } },
    };

    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try format(&w, in, .{ .color = true }, &layout);
    try std.testing.expectEqualStrings("\x1b[38;2;0;215;255mSonnet\x1b[0m\n", w.buffered());
}

test "color: styled layout emits no codes when the gate is off" {
    const in: StatusInput = .{ .model = .{ .display_name = "Sonnet" } };
    const layout = [_]element.Item{
        .{ .element = .{ .model = .{} }, .style = .{ .fg = .{ .named = .cyan } } },
    };

    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    // color defaults to false → byte-identical to plain text.
    try format(&w, in, .{}, &layout);
    try std.testing.expectEqualStrings("Sonnet\n", w.buffered());
}

test "color: an empty style emits no codes even when the gate is on" {
    const in: StatusInput = .{ .model = .{ .display_name = "Sonnet" } };
    const layout = [_]element.Item{.{ .element = .{ .model = .{} } }};

    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try format(&w, in, .{ .color = true }, &layout);
    try std.testing.expectEqualStrings("Sonnet\n", w.buffered());
}
