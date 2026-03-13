# CLAUDE.md

tmux setup optimized for Claude Code workflows. Single install script deploys everything.

## Quick Start

```bash
bash install.sh          # installs to ~/.tmux/ and ~/.tmux.conf
tmux source ~/.tmux.conf # reload if already in tmux
```

## What It Does

- **Status bar**: project-colored badge, CPU/MEM/Claude usage (session%/weekly%/sonnet%/$extra), hostname, clock
- **Window tabs**: orange highlight when Claude is idle in a background window
- **Pane headers**: git branch (blue) or worktree name (orange), auto-updates when Claude switches worktrees
- **Pane headers**: orange bg strip when Claude is idle in an inactive pane
- **Idle dismiss**: focusing a pane/window clears its idle highlight (notification-style UX)

## Architecture

All state is communicated via **marker files** in `$TMPDIR` (or `/tmp`), keyed by tmux's globally unique pane ID (`$TMUX_PANE`, e.g. `%22`):

| File | Created by | Cleared by | Purpose |
|------|-----------|------------|---------|
| `claude-idle%XX` | `Notification[idle_prompt]` hook | `UserPromptSubmit` hook, `after-select-pane` tmux hook | Marks pane as having idle Claude |
| `claude-cwd%XX` | `PostToolUse[Bash]` hook, `SessionStart` hook | `SessionEnd` hook, `cleanup-markers.sh` | Tracks Claude's working directory |

The `@claude_idle` tmux window option is set/cleared alongside the marker file to drive the `#{?@claude_idle,...}` conditional in `window-status-format` (tab highlighting).

### Why marker files?

tmux `pane-border-format` runs a shell script per pane, but format conditionals (`#{?...}`) resolve at **window scope** — so `@option`-based approaches leak to all panes. Marker files checked by `pane-label.sh` with the specific pane ID are truly per-pane.

## Files Installed

| Destination | Source function |
|---|---|
| `~/.tmux.conf` | Main tmux config |
| `~/.tmux/pane-label.sh` | Pane border labels: git info + idle detection |
| `~/.tmux/claude-cwd-hook.sh` | PostToolUse hook: tracks `cd` commands |
| `~/.tmux/claude-usage.sh` | Fetches Claude API usage (5h window), 60s cache |
| `~/.tmux/cleanup-markers.sh` | Removes markers for dead panes |
| `~/.tmux/project-color.sh` | Session name → deterministic color badge |
| `~/.tmux/cpu.sh` | CPU usage % (macOS + Linux) |
| `~/.tmux/mem.sh` | Memory usage % (macOS + Linux) |
| `~/.claude/settings.json` | Claude Code hooks (merged, not overwritten) |

## Claude Code Hooks

The installer adds these hooks to `~/.claude/settings.json` (merges with existing):

| Hook | Matcher | Action |
|------|---------|--------|
| `Notification` | `idle_prompt` | Touch idle marker + set `@claude_idle` |
| `UserPromptSubmit` | (any) | Remove idle marker + unset `@claude_idle` |
| `SessionStart` | (any) | Write cwd marker + touch idle marker |
| `SessionEnd` | (any) | Remove both markers |
| `PostToolUse` | `Bash` | Parse `cd` commands, update cwd marker |

**Important**: Uses `Notification[idle_prompt]`, NOT `Stop`. The `Stop` hook fires after every assistant response (including between tool calls), which causes false idle highlights during long-running operations.

## Key Design Decisions

- **`Notification[idle_prompt]` over `Stop`**: `Stop` fires between tool calls, not just when truly idle
- **Active pane/window never shows orange**: If you're looking at it, no need for the notification
- **`after-select-pane` / `after-select-window` hooks**: Clear idle state when user focuses a pane (dismiss notification)
- **`${TMPDIR:-/tmp}` everywhere**: macOS sets `$TMPDIR` to `/var/folders/...`
- **Avoid `${VAR:-default}` in tmux hooks**: tmux interprets `${...}` as environment variable syntax and doesn't support `:-`. Use `T=$VAR; [ -z "$T" ] && T=default` pattern instead
- **5min cache on usage API**: Avoids hammering `api.anthropic.com/api/oauth/usage` every 3s status refresh; exponential backoff (up to 60min) on rate-limit or server errors
- **jq required for hooks**: Claude Code hook commands read JSON from stdin; cwd hook parses `tool_input.command`

## Platform Support

- **Linux**: Full support. Uses `/proc/pid/cwd`, `/proc/stat`, `/proc/meminfo`
- **macOS**: Full support. Uses `lsof` for cwd, `top -l` for CPU, `vm_stat` for memory

## Dependencies

- `tmux` (tested with 3.5+)
- `git` (for branch/worktree detection)
- `bash` (all scripts use bash)
- `curl` + `python3` (for Claude usage API)
- `jq` (optional, for Claude Code hooks installation and cwd tracking)

## Colors

| Element | Color | Code |
|---------|-------|------|
| Active pane border | Blue | `colour075` |
| Inactive pane border | Dark grey | `colour238` |
| Git branch label | Blue | `colour075` |
| Worktree name label | Orange | `colour208` |
| Idle highlight | Orange bg | `colour208` |
| CPU stat | Yellow | `colour222` |
| MEM stat | Green | `colour114` |
| Claude usage stat | Light purple | `colour183` |
| Current tab | Light grey bg | `colour238` |
| Status bar bg | Dark grey | `colour235` |
