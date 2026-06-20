# claude-code-statusline

A fast, native custom **status line for [Claude Code](https://docs.claude.com/en/docs/claude-code)**, written in Zig.

Claude Code can render a custom status line beneath the prompt by running an
external command and feeding it a JSON snapshot of the current session. This
project is that command: it reads the session JSON on stdin and prints a status
line to stdout.

## Requirements

- [Zig](https://ziglang.org/) **0.16.0** (matches `minimum_zig_version` in
  `build.zig.zon`).
- macOS, Linux, or Windows (via Git Bash / PowerShell — see
  [Claude Code's status line docs](https://docs.claude.com/en/docs/claude-code/statusline)).

## Build

```sh
# Debug build
zig build

# Optimized build (recommended for daily use)
zig build -Doptimize=ReleaseSafe
```

The binary is written to:

```
zig-out/bin/claude_code_statusline
```

Cross-compile for another machine with `-Dtarget`, e.g.:

```sh
zig build -Doptimize=ReleaseSafe -Dtarget=aarch64-macos
```

## Run it directly

The program takes a `render` subcommand and reads session JSON on stdin:

```sh
echo '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp"}}' \
  | zig-out/bin/claude_code_statusline render
```

You can also run through the build system during development:

```sh
zig build run -- render
```

## Configure in Claude Code

Claude Code reads the status line from `settings.json` — either user-wide
(`~/.claude/settings.json`) or per-project (`.claude/settings.json`). Point the
`statusLine.command` at the built binary and pass the `render` subcommand:

```json
{
  "statusLine": {
    "type": "command",
    "command": "/absolute/path/to/zig-out/bin/claude_code_statusline render",
    "padding": 0
  }
}
```

Use an **absolute path** (or a `~/`-prefixed path) to the binary. A convenient
pattern is to install the release build somewhere stable on your `PATH` or under
`~/.claude/` and reference it there:

```sh
zig build -Doptimize=ReleaseSafe
cp zig-out/bin/claude_code_statusline ~/.claude/claude_code_statusline
```

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/claude_code_statusline render"
  }
}
```

Optional `statusLine` settings supported by Claude Code:

| Field             | Type    | Description                                                            |
| ----------------- | ------- | --------------------------------------------------------------------- |
| `padding`         | integer | Extra horizontal padding in characters (default `0`).                 |
| `refreshInterval` | integer | Re-run the command every N seconds while idle (omit for event-only).  |

After editing `settings.json`, the new status line appears on the next update.
You can also let Claude Code scaffold a config for you with the `/statusline`
slash command.

## How it works

When the status line is active, Claude Code pipes a JSON object describing the
session to the command on **stdin**, and displays the command's **stdout** as the
status line. Key points:

- **Output:** everything written to stdout is shown. ANSI color/style escapes,
  OSC 8 hyperlinks, and emoji are supported. stderr is ignored.
- **Colors:** each segment carries its own style. Styling lives per layout entry
  (`element.Item` pairs an element with a `style.Style`), so the same kind can be
  colored differently per position. A `Style` takes a foreground/background that
  is either a named 16-color (`.{ .named = .cyan }`, theme-aware) or 24-bit RGB
  (`.{ .rgb = .{ .r = …, .g = …, .b = … } }`), plus bold/dim/italic/underline.
  Setting the [`NO_COLOR`](https://no-color.org) environment variable disables
  all styling and emits plain text.
- **Failure handling:** a non-zero exit code or empty stdout blanks the status
  line, so the renderer always aims to produce something useful.
- **Refresh:** updates are event-driven (e.g. after each assistant message) with
  ~300 ms debouncing; long-running invocations may be cancelled, so rendering is
  kept fast and side-effect free.
- **Trust:** the command only runs once you've accepted workspace trust, the same
  as Claude Code hooks.

### Example stdin payload

A representative (trimmed) payload looks like this:

```json
{
  "cwd": "/Users/you/project",
  "session_id": "abc123",
  "transcript_path": "/path/to/transcript.jsonl",
  "version": "2.1.90",
  "model": { "id": "claude-opus-4-8", "display_name": "Opus" },
  "workspace": {
    "current_dir": "/Users/you/project",
    "project_dir": "/Users/you/project"
  },
  "output_style": { "name": "default" },
  "cost": {
    "total_cost_usd": 0.01234,
    "total_duration_ms": 45000,
    "total_lines_added": 156,
    "total_lines_removed": 23
  },
  "context_window": {
    "context_window_size": 200000,
    "used_percentage": 8,
    "remaining_percentage": 92
  },
  "exceeds_200k_tokens": false
}
```

Some fields are present only in certain sessions (git worktree, vim mode,
reasoning effort, open PR, rate limits, etc.). For the authoritative and
complete schema, see Claude Code's
[status line documentation](https://docs.claude.com/en/docs/claude-code/statusline).

## Development

```sh
zig build          # compile (debug)
zig build run      # build and run
zig build test     # run tests
zig fmt .          # format sources
```

The whole program lives in `src/main.zig` for now. If you use the
[Zed](https://zed.dev) editor, `.zed/tasks.json` provides ready-made build, run,
test, and format tasks. Contributor and agent-oriented notes (Zig 0.16 idioms,
project layout, conventions) live in [AGENTS.md](AGENTS.md).

## License

[MIT](LICENSE) © 2026 Sergey Kostrukov
