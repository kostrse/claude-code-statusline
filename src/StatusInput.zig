//! Strongly-typed model of the JSON snapshot Claude Code pipes to a status line
//! command on stdin.
//!
//! Schema source:
//! https://code.claude.com/docs/en/statusline.md
//!
//! Defensive by design: every field is optional with a `= null` default. Claude
//! Code omits fields depending on session state, and `std.json` errors on a
//! missing field unless it has a default — so optionality + defaults let any
//! subset of the payload (including `{}`) parse without failing. Renderers must
//! treat every field as possibly absent.

const std = @import("std");

const StatusInput = @This();

cwd: ?[]const u8 = null,
session_id: ?[]const u8 = null,
session_name: ?[]const u8 = null,
transcript_path: ?[]const u8 = null,
version: ?[]const u8 = null,
exceeds_200k_tokens: ?bool = null,

model: ?Model = null,
workspace: ?Workspace = null,
output_style: ?OutputStyle = null,
cost: ?Cost = null,
context_window: ?ContextWindow = null,

effort: ?Effort = null,
thinking: ?Thinking = null,
vim: ?Vim = null,
agent: ?Agent = null,
pr: ?Pr = null,
rate_limits: ?RateLimits = null,
worktree: ?Worktree = null,

pub const Model = struct {
    id: ?[]const u8 = null,
    display_name: ?[]const u8 = null,
};

pub const Workspace = struct {
    current_dir: ?[]const u8 = null,
    project_dir: ?[]const u8 = null,
    added_dirs: ?[]const []const u8 = null,
    git_worktree: ?[]const u8 = null,
    repo: ?Repo = null,

    pub const Repo = struct {
        host: ?[]const u8 = null,
        owner: ?[]const u8 = null,
        name: ?[]const u8 = null,
    };
};

pub const OutputStyle = struct {
    name: ?[]const u8 = null,
};

pub const Cost = struct {
    total_cost_usd: ?f64 = null,
    total_duration_ms: ?i64 = null,
    total_api_duration_ms: ?i64 = null,
    total_lines_added: ?i64 = null,
    total_lines_removed: ?i64 = null,
};

pub const ContextWindow = struct {
    total_input_tokens: ?i64 = null,
    total_output_tokens: ?i64 = null,
    context_window_size: ?i64 = null,
    // Pre-calculated; may be null early in a session.
    used_percentage: ?f64 = null,
    remaining_percentage: ?f64 = null,
    // Null before the first API call and after /compact until the next call.
    current_usage: ?CurrentUsage = null,

    pub const CurrentUsage = struct {
        input_tokens: ?i64 = null,
        output_tokens: ?i64 = null,
        cache_creation_input_tokens: ?i64 = null,
        cache_read_input_tokens: ?i64 = null,
    };
};

pub const Effort = struct {
    // "low" | "medium" | "high" | "xhigh" | "max"
    level: ?[]const u8 = null,
};

pub const Thinking = struct {
    enabled: ?bool = null,
};

pub const Vim = struct {
    // "NORMAL" | "INSERT" | "VISUAL" | "VISUAL LINE"
    mode: ?[]const u8 = null,
};

pub const Agent = struct {
    name: ?[]const u8 = null,
};

pub const Pr = struct {
    number: ?i64 = null,
    url: ?[]const u8 = null,
    // "approved" | "pending" | "changes_requested" | "draft"
    review_state: ?[]const u8 = null,
};

pub const RateLimits = struct {
    five_hour: ?Window = null,
    seven_day: ?Window = null,

    pub const Window = struct {
        used_percentage: ?f64 = null,
        resets_at: ?i64 = null, // Unix epoch seconds.
    };
};

pub const Worktree = struct {
    name: ?[]const u8 = null,
    path: ?[]const u8 = null,
    branch: ?[]const u8 = null,
    original_cwd: ?[]const u8 = null,
    original_branch: ?[]const u8 = null,
};

/// Parse a status-line JSON payload into a `StatusInput`.
///
/// Unknown JSON keys are ignored so the program keeps working as Claude Code
/// adds fields. The caller owns the returned `Parsed` and must `deinit()` it;
/// string fields in `.value` reference the parse arena and are only valid until
/// then.
pub fn parse(gpa: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(StatusInput) {
    return std.json.parseFromSlice(StatusInput, gpa, bytes, .{ .ignore_unknown_fields = true });
}

test "parses a minimal payload" {
    const parsed = try parse(std.testing.allocator, "{\"model\":{\"display_name\":\"Opus\"}}");
    defer parsed.deinit();

    try std.testing.expectEqualStrings("Opus", parsed.value.model.?.display_name.?);
    // Absent optionals stay null.
    try std.testing.expect(parsed.value.cwd == null);
    try std.testing.expect(parsed.value.cost == null);
}

test "parses an empty object" {
    const parsed = try parse(std.testing.allocator, "{}");
    defer parsed.deinit();

    try std.testing.expect(parsed.value.model == null);
    try std.testing.expect(parsed.value.workspace == null);
}

test "parses nested numbers and ignores unknown fields" {
    const json =
        \\{
        \\  "cwd": "/Users/you/project",
        \\  "version": "2.1.90",
        \\  "model": { "id": "claude-opus-4-8", "display_name": "Opus" },
        \\  "workspace": { "current_dir": "/Users/you/project", "git_worktree": "feature-xyz" },
        \\  "cost": { "total_cost_usd": 0.01234, "total_lines_added": 156 },
        \\  "context_window": { "context_window_size": 200000, "used_percentage": 8, "current_usage": null },
        \\  "exceeds_200k_tokens": false,
        \\  "some_future_field": { "nested": [1, 2, 3] }
        \\}
    ;
    const parsed = try parse(std.testing.allocator, json);
    defer parsed.deinit();

    const v = parsed.value;
    try std.testing.expectEqualStrings("claude-opus-4-8", v.model.?.id.?);
    try std.testing.expectEqualStrings("feature-xyz", v.workspace.?.git_worktree.?);
    try std.testing.expectEqual(@as(f64, 0.01234), v.cost.?.total_cost_usd.?);
    try std.testing.expectEqual(@as(i64, 156), v.cost.?.total_lines_added.?);
    try std.testing.expectEqual(@as(i64, 200000), v.context_window.?.context_window_size.?);
    try std.testing.expectEqual(@as(f64, 8), v.context_window.?.used_percentage.?);
    try std.testing.expect(v.context_window.?.current_usage == null);
    try std.testing.expectEqual(false, v.exceeds_200k_tokens.?);
}
