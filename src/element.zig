//! The status-line element taxonomy: the set of segments a layout can be built
//! from. These types are pure data — `render.zig` owns how each one is turned
//! into text. A layout is an ordered `[]const Item`, each pairing an `Element`
//! with the `Style` it is painted with, so adding a new segment kind means
//! adding a variant here and a case in the renderer.

const style = @import("style.zig");

/// Which rate-limit window a `.usage` element renders.
pub const WindowKind = enum { five_hour, seven_day };

/// Whether a percentage gauge shows quota *consumed* or quota *remaining*.
pub const Portion = enum { used, left };

/// Which form of the model name to render. Claude Code only supplies these two
/// strings — there is no short `opus-4.8`-style form in the payload.
pub const ModelName = enum {
    /// Human label, e.g. "Opus 4.8" (`model.display_name`).
    display,
    /// Machine slug, e.g. "claude-opus-4-8" (`model.id`).
    id,
};

/// One renderable segment of the status line. Bare variants render a fixed
/// segment; parametrized variants carry their own configuration. `render.format`
/// iterates a slice of these and renders each in order, so the layout is data
/// rather than control flow.
pub const Element = union(enum) {
    model: Model,
    project_dir, // workspace.project_dir, $HOME collapsed to ~
    branch, // worktree branch
    context: Context,
    usage: Usage,

    /// Model name plus an optional effort modifier: "Opus 4.8 high".
    pub const Model = struct {
        /// Which name string to render.
        name: ModelName = .display,
        /// Append the effort level (e.g. " high") when the payload has one.
        effort: bool = true,
    };

    /// Context-window gauge: "Context N% used" / "Context N% left".
    pub const Context = struct {
        portion: Portion = .used,
    };

    /// Rate-limit window gauge: "5h N% left" / "weekly N% used", with optional
    /// reset info appended (e.g. " (resets in 2h 15m at 14:30 UTC)").
    pub const Usage = struct {
        /// Which window this segment reports on.
        window: WindowKind,
        /// Show consumed or remaining quota.
        portion: Portion = .left,
        /// Append the absolute reset time (UTC).
        reset_at: bool = false,
        /// Append the relative time until the window resets.
        time_left: bool = false,
    };
};

/// One entry in a layout: an `Element` plus the `Style` it is painted with.
/// Layouts are `[]const Item`, so color travels with the element as data — the
/// same kind can appear twice with different styles. The default style (`.{}`)
/// is "no styling", so an entry written without one renders as plain text.
pub const Item = struct {
    element: Element,
    style: style.Style = .{},
};
