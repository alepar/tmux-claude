# tmux-claude

A tmux setup for Claude Code and Codex workflows. tmux shows project and system state; each agent owns its own context and usage status.

## Features

**tmux status bar** — project-colored session badge, CPU/GPU usage, optional coolant temp, hostname, and clock. It does not inspect agent processes or render agent usage.

**Codex native status** — the installer safely merges these settings into `~/.codex/config.toml`:

```toml
[tui]
status_line = ["context-remaining", "five-hour-limit", "weekly-limit"]
status_line_use_colors = true
```

**Claude native status line** — a 20-segment context bar, remaining-token count, optional model name, and cached subscription usage:

```
████░░░░░░░░░░░░░░░░ | remaining: 920k/1m | Fable | CL:42%/68%/$13
```

**Idle notifications and pane headers** — background Claude panes turn orange when idle; headers show the current git branch or worktree and follow Claude CWD changes.

## Prerequisites

- `tmux` 3.5+
- `git`
- `bash`
- `curl` for Claude subscription usage
- `jq` for Claude Code hooks and status-line parsing
- Codex CLI is optional; its native TUI settings do not require a plugin

## Install

```bash
git clone https://github.com/alepar/tmux-claude.git
cd tmux-claude
bash install.sh
```

If already inside tmux, run `tmux source ~/.tmux.conf`. The installer backs up an existing `~/.tmux.conf`.

### Installed files

| File | Purpose |
|---|---|
| `~/.tmux.conf` | Project/system status, tabs, and pane styling |
| `~/.tmux/pane-label.sh` | Pane git/worktree label and Claude idle indicator |
| `~/.tmux/claude-usage.sh` | Cached Claude API usage |
| `~/.tmux/claude-statusline.sh` | Claude context/model line with `CL:` usage |
| `~/.tmux/claude-cwd-hook.sh` | Tracks Claude CWD changes |
| `~/.tmux/project-color.sh` | Session color badge |
| `~/.tmux/cpu.sh`, `~/.tmux/gpu.sh` | System usage |
| `~/.tmux/water.sh` | Coolant temp (Aquacomputer Octo, if present) |
| `~/.claude/settings.json` | Merged Claude hooks and native `statusLine` command |
| `~/.codex/config.toml` | Narrowly merged native Codex `[tui]` settings |

## How it works

Claude Code hooks retain only the state tmux needs for idle highlighting and CWD-aware pane labels. `claude-idle%XX` and `claude-cwd%XX` markers live in `$TMPDIR`, keyed by pane ID; the hooks clear them on prompt/session end or when the pane is focused.

Codex context and usage are displayed by Codex itself. Reinstalling removes the former local integration, generated helper scripts, and stale Codex state files.

## License

MIT
