# AGENTS.md

Guidance for AI coding agents working in this repository.

## What this is

`claude-code-statusline` is a small native command-line program, written in Zig,
that renders a custom **status line for Claude Code**. Claude Code invokes the
built binary, pipes a JSON snapshot of the current session to the program's
**stdin**, and prints whatever the program writes to **stdout** as the status
line beneath the prompt.

The program is invoked through a `render` subcommand:

```
claude_code_statusline render   # reads session JSON on stdin, writes status line to stdout
```

## Project structure

```
.
├── build.zig          # Build graph: executable, `run` step, `test` step
├── build.zig.zon      # Package manifest (name, version, min Zig, deps)
├── src/
│   └── main.zig       # Entry point + render logic (everything lives here for now)
├── .zed/tasks.json    # Zed editor tasks (build/run/test/fmt)
├── .editorconfig      # Formatting rules (see Conventions)
├── README.md          # Human-facing build & configuration docs
└── AGENTS.md          # This file
```

There is no `src/root.zig` library module — this is a single-executable project.
New source files go under `src/` and are imported from `main.zig` (or a module
you add explicitly in `build.zig`).

## Toolchain

- **Zig `0.16.0`** is required (`minimum_zig_version` in `build.zig.zon`). There
  is no vendored toolchain; use the system `zig`.
- No third-party dependencies (`.dependencies = .{}`). Prefer the Zig standard
  library; if you must add a dependency, wire it through `build.zig.zon` and
  `build.zig` and explain why in the PR.

### Zig 0.16 idioms in use (important)

This code uses the **new Zig 0.16 `Io` / `process.Init` model**. These APIs
differ sharply from pre-0.15 Zig, so do not "correct" them back to older
patterns:

- `main` takes an init parameter: `pub fn main(init: std.process.Init) !void`.
- Allocator comes from `init.gpa`; the `Io` instance from `init.io`.
- Arguments are iterated with `init.minimal.args.iterateAllocator(init.gpa)`
  (remember `defer args.deinit()` and skip the program name).
- Output uses a buffered writer:
  `std.Io.File.Writer.init(.stdout(), init.io, &buffer)`, then write through
  `writer.interface` (a `*std.Io.Writer`), and you **must** call `.flush()`
  before returning or output is lost.

When reading stdin (the next step), use the same `init.io` model rather than the
legacy `std.io.getStdIn()` API.

## Commands

Run from the repository root:

| Task                | Command                                  |
| ------------------- | ---------------------------------------- |
| Build (debug)       | `zig build`                              |
| Build (release)     | `zig build -Doptimize=ReleaseSafe`       |
| Run                 | `zig build run`                          |
| Run the subcommand  | `zig build run -- render`                |
| Run tests           | `zig build test`                         |
| Format all sources  | `zig fmt .`                              |

The built binary is installed to `zig-out/bin/claude_code_statusline`.

To exercise the real stdin contract end to end:

```
echo '{"model":{"display_name":"Opus"}}' | zig-out/bin/claude_code_statusline render
```

Cross-compile for another host (e.g. to ship a binary) with
`zig build -Dtarget=<arch>-<os> -Doptimize=ReleaseSafe`.

## Conventions

- **Formatting is authoritative via `zig fmt`.** Always run `zig fmt .` before
  finishing; do not hand-format. `.editorconfig` mirrors the result: UTF-8, LF
  line endings, final newline, trimmed trailing whitespace, 4-space indent for
  `.zig`, 2-space for `.json`.
- Keep the binary's stdout limited to the status line itself. Diagnostics, if
  any, belong on stderr (Claude Code ignores stderr).
- **Status line output rules** (these shape correctness):
  - Only the text written to stdout is shown; ANSI color/style escapes, OSC 8
    hyperlinks, and emoji are supported.
  - A non-zero exit or empty stdout blanks the status line — handle missing/null
    JSON fields gracefully and still produce sensible output.
  - The command is run frequently and may be cancelled mid-run; keep `render`
    fast and free of slow I/O (no network calls, avoid heavy `git` invocations).

## Testing

Tests run through `zig build test`, which builds a test binary from
`src/main.zig`'s root module. Add `test "..." { ... }` blocks alongside the code
they cover. There is no separate test directory.

## Adding tests / changes — checklist for agents

1. Make the change in `src/` and keep stdout = status line only.
2. `zig build` (must compile under Zig 0.16) and `zig build test`.
3. `zig fmt .`.
4. Sanity-check the subcommand by piping representative JSON to
   `zig-out/bin/claude_code_statusline render` (see example above).

## Reference: stdin JSON contract

Claude Code passes a JSON object on stdin. Fields the renderer will care about
(not exhaustive; some are absent depending on session state):

- `cwd`, `session_id`, `transcript_path`, `version`
- `model.id`, `model.display_name`
- `workspace.current_dir`, `workspace.project_dir` (optional:
  `workspace.git_worktree`, `workspace.repo.{host,owner,name}`)
- `output_style.name`
- `cost.{total_cost_usd,total_duration_ms,total_api_duration_ms,total_lines_added,total_lines_removed}`
- `context_window.{used_percentage,remaining_percentage,context_window_size,...}`
  (`current_usage` may be `null` early in a session)
- `exceeds_200k_tokens`
- Optional/contextual: `effort.level`, `thinking.enabled`, `vim.mode`,
  `agent.name`, `pr.{number,url,review_state}`, `rate_limits`, `worktree`,
  `session_name`

Always code defensively: optional fields may be missing and some values may be
`null`. The README has the full configuration contract and an example payload.
