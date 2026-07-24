# SPEC.md — tmux-claude

## Overview

tmux-claude provides tmux project/system presentation plus native Claude Code and Codex status lines. Agent context and account usage are not inferred from the active tmux pane.

## tmux status bar

The status bar contains a deterministic project-color badge, hostname, CPU percentage, GPU utilization percentage, an optional coolant temperature, and clock. It refreshes every three seconds. CPU and GPU turn red at 90% or higher. GPU utilization is averaged across all cards, read from `nvidia-smi` when present and otherwise from the AMD `gpu_busy_percent` sysfs entries; it renders `?` when neither source is available.

When an Aquacomputer Octo (hwmon `name` of `octo`) is present, an `H2O:` coolant temperature is shown from the device's first populated `temp*_input`, located by hwmon name rather than index since numbering is not stable across reboots. It is cyan normally, orange above 55C, and red above 60C. The segment renders nothing — no dangling label — when no Octo is attached.

tmux retains pane labels and Claude idle highlighting. `pane-label.sh` walks the pane process tree to resolve its working directory, using the retained Claude CWD marker for Claude/node processes. It never detects an agent in order to render agent status.

## Native agent status

### Codex

The installer atomically merges only these keys into `~/.codex/config.toml`:

```toml
[tui]
status_line = ["context-remaining", "five-hour-limit", "weekly-limit"]
status_line_use_colors = true
```

The merge preserves all other TOML lines. Within an existing `[tui]` table it replaces only `status_line` and `status_line_use_colors`. When `[tui]` is absent but a `[tui.*]` table exists, it inserts the parent table immediately before the first nested table; otherwise it appends it. The generated temporary file replaces the config only after a successful transform.

### Claude Code

`~/.tmux/claude-statusline.sh` reads Claude's status payload and transcript, renders its ANSI context bar, remaining-token count, and optional model name, then appends ` | CL:` followed by `~/.tmux/claude-usage.sh`. The usage helper retains its cache and exponential-backoff behavior in `$TMPDIR`.

## Claude hooks and retained markers

The installer merges Claude's `PostToolUse`, `Notification[idle_prompt]`, `UserPromptSubmit`, `SessionStart`, and `SessionEnd` hooks into `~/.claude/settings.json`, alongside the `statusLine` command. These hooks maintain only `claude-cwd%XX` and `claude-idle%XX` markers for pane labels and idle highlighting.

`Notification[idle_prompt]` is used rather than `Stop`, because `Stop` can fire between tool calls. Focus hooks clear an idle marker and the tmux window option for the selected pane/window.

## Legacy migration

Installation removes the retired generated helpers and stale Codex marker files. If the Codex CLI is installed, it best-effort removes the former local integration. Missing commands, plugins, and marker files do not fail installation.

## Dependencies and platform support

- `tmux`, `git`, and `bash` are required.
- `curl` fetches Claude subscription usage.
- `jq` is required for Claude hook setup and status-line parsing.
- Linux uses `/proc`; macOS uses `top`, `vm_stat`, and `lsof` where appropriate.
