# CLAUDE.md

tmux setup optimized for Claude Code and Codex workflows. Single install script deploys everything.

## Quick Start

```bash
bash install.sh          # installs to ~/.tmux/ and ~/.tmux.conf
tmux source ~/.tmux.conf # reload if already in tmux
```

## What It Does

- **Status bar**: project-colored badge, CPU/MEM, active-pane `CL`/`CTX` usage, hostname, clock
- **Claude status line**: 20-segment context bar (green → yellow → red as context fills) + remaining tokens + model name, e.g. `████░░░░░░░░░░░░░░░░ | remaining: 920k/1m | Fable`
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
| `codex-session%XX` | Codex `SessionStart` hook | `cleanup-markers.sh` | Binds one Codex session ID and transcript to one pane |
| `codex-context%XX` | Codex `Stop` / `PostCompact` hooks | `cleanup-markers.sh` | Validated integer context percentage for that pane |

The `@claude_idle` tmux window option is set/cleared alongside the marker file to drive the `#{?@claude_idle,...}` conditional in `window-status-format` (tab highlighting).

### Why marker files?

tmux `pane-border-format` runs a shell script per pane, but format conditionals (`#{?...}`) resolve at **window scope** — so `@option`-based approaches leak to all panes. Marker files checked by `pane-label.sh` with the specific pane ID are truly per-pane.

## Files Installed

| Destination | Source function |
|---|---|
| `~/.tmux.conf` | Main tmux config |
| `~/.tmux/pane-label.sh` | Pane border labels: git info + idle detection |
| `~/.tmux/claude-cwd-hook.sh` | PostToolUse hook: tracks `cd` commands |
| `~/.tmux/codex-context-hook.sh` | Codex lifecycle hook: owns session mappings and context markers |
| `~/.tmux/agent-status.sh` | Active-pane renderer: `CL`, `CTX`, or empty |
| `~/.tmux/claude-usage.sh` | Fetches Claude API usage (5h window), 60s cache |
| `~/.tmux/claude-statusline.sh` | Claude Code status line: context bar + remaining tokens |
| `~/.tmux/cleanup-markers.sh` | Removes markers for dead panes |
| `~/.tmux/project-color.sh` | Session name → deterministic color badge |
| `~/.tmux/cpu.sh` | CPU usage % (macOS + Linux) |
| `~/.tmux/mem.sh` | Memory usage % (macOS + Linux) |
| `~/.claude/settings.json` | Claude Code hooks + `statusLine` (merged, not overwritten) |
| Repository `.claude-plugin/marketplace.json` + `plugins/tmux-claude-context/` | Local Codex marketplace and lifecycle-hook plugin |

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

## Codex Hooks and Status Rendering

When the Codex CLI and `jq` are present, installation registers the repository root containing `.claude-plugin/marketplace.json` as the `tmux-claude` marketplace and adds its `tmux-claude-context` plugin. Codex discovers the plugin's conventional `hooks/hooks.json` file, which declares the `SessionStart`, `Stop`, and `PostCompact` commands. Every command ends in `|| true`, so a marker failure cannot obstruct Codex. The installer never writes `~/.codex/hooks.json`; start a new Codex thread after installation to load the hooks.

`SessionStart` writes the exact pane's session/transcript mapping. `Stop` and `PostCompact` require a matching session ID, read the final `event_msg` with a `token_count` payload from that mapped transcript, calculate `round(input_tokens / model_context_window * 100)`, and atomically update `codex-context%XX`. Invalid, missing, stale, or mismatched state is silent.

`agent-status.sh <pane_id> <pane_pid>` follows the existing first-child process-tree convention and emits one field only: `CL:<existing claude-usage.sh output>` for `claude`/`node`; otherwise `CTX:<integer>%` when the exact pane has valid Codex session and context markers, regardless of foreground command; or nothing. CTX colors are `colour114` below 60%, `colour222` through 84%, and `colour196` at 85%+.

## Key Design Decisions

- **`Notification[idle_prompt]` over `Stop`**: `Stop` fires between tool calls, not just when truly idle
- **Active pane/window never shows orange**: If you're looking at it, no need for the notification
- **`after-select-pane` / `after-select-window` hooks**: Clear idle state when user focuses a pane (dismiss notification)
- **`${TMPDIR:-/tmp}` everywhere**: macOS sets `$TMPDIR` to `/var/folders/...`
- **Avoid `${VAR:-default}` in tmux hooks**: tmux interprets `${...}` as environment variable syntax and doesn't support `:-`. Use `T=$VAR; [ -z "$T" ] && T=default` pattern instead
- **5min cache on usage API**: Avoids hammering `api.anthropic.com/api/oauth/usage` every 3s status refresh; exponential backoff (up to 60min) on rate-limit or server errors
- **jq required for hooks**: Claude Code hook commands read JSON from stdin; cwd hook parses `tool_input.command`
- **Codex state is pane-keyed**: the status renderer never scans a repository for a "latest" session; it trusts only the active pane's matching session marker
- **Codex failures stay invisible**: invalid hook input produces no marker update and no status placeholder
- **Context window is marker-driven, not name-driven**: `claude-statusline.sh` reads the 1M tier from the `[1m]` suffix in `model.id` (plus the `exceeds_200k_tokens` flag), so new models work without a code change. Model-family matching (haiku → 200k, fable/sonnet-5 → 1M) is only a fallback when no marker is present — don't replace this with a model-name lookup table

## Platform Support

- **Linux**: Full support. Uses `/proc/pid/cwd`, `/proc/stat`, `/proc/meminfo`
- **macOS**: Full support. Uses `lsof` for cwd, `top -l` for CPU, `vm_stat` for memory

## Dependencies

- `tmux` (tested with 3.5+)
- `git` (for branch/worktree detection)
- `bash` (all scripts use bash)
- `curl` (for Claude usage API)
- `jq` (optional, for Claude Code hooks installation, cwd tracking, and Codex context hooks)
- Codex CLI (optional; requires `jq` for Codex context hooks)

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
| Codex context (<60%) | Green | `colour114` |
| Codex context (60–84%) | Yellow | `colour222` |
| Codex context (85%+) | Red | `colour196` |
| Current tab | Light grey bg | `colour238` |
| Status bar bg | Dark grey | `colour235` |


<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:6cd5cc61 -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.

## Agent Context Profiles

The managed Beads block is task-tracking guidance, not permission to override repository, user, or orchestrator instructions.

- **Conservative (default)**: Use `bd` for task tracking. Do not run git commits, git pushes, or Dolt remote sync unless explicitly asked. At handoff, report changed files, validation, and suggested next commands.
- **Minimal**: Keep tool instruction files as pointers to `bd prime`; use the same conservative git policy unless active instructions say otherwise.
- **Team-maintainer**: Only when the repository explicitly opts in, agents may close beads, run quality gates, commit, and push as part of session close. A current "do not commit" or "do not push" instruction still wins.

## Session Completion

This protocol applies when ending a Beads implementation workflow. It is subordinate to explicit user, repository, and orchestrator instructions.

1. **File issues for remaining work** - Create beads for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **Handle git/sync by active profile**:
   ```bash
   # Conservative/minimal/default: report status and proposed commands; wait for approval.
   git status

   # Team-maintainer opt-in only, unless current instructions forbid it:
   git pull --rebase
   git push
   git status
   ```
5. **Hand off** - Summarize changes, validation, issue status, and any blocked sync/commit/push step

**Critical rules:**
- Explicit user or orchestrator instructions override this Beads block.
- Do not commit or push without clear authority from the active profile or the current user request.
- If a required sync or push is blocked, stop and report the exact command and error.
<!-- END BEADS INTEGRATION -->
