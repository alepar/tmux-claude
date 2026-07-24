# Native agent status lines

## Problem description

The tmux status bar currently infers whether the active pane runs Claude Code or Codex, persists Codex context state in pane-keyed files, and selects either `CL:` or `CTX:` globally. That cross-process state is fragile and duplicates status-line features that both agents already provide. Codex can natively show remaining context and its primary and secondary usage limits; Claude Code has its own status-line command.

## Main challenges

The installer must add the Codex `[tui]` settings without damaging an existing `~/.codex/config.toml`, including configurations that contain nested `[tui.*]` tables but no explicit `[tui]` table. Claude's existing status command must retain its context bar, remaining-token count, and model while adding the compact `CL:` subscription value. The migration must remove the retired plugin, hooks, marker files, and tmux renderer so no agent-specific state remains shared through tmux.

## Key decisions made

Codex owns Codex status through its native TUI configuration:

```toml
[tui]
status_line = ["context-remaining", "five-hour-limit", "weekly-limit"]
status_line_use_colors = true
```

This displays remaining context together with Codex's two available account-usage-limit slots (normally the short-period and weekly limits for plans that expose both). `install.sh` updates only these two keys, preserves unrelated TOML, creates `[tui]` immediately before a first `[tui.*]` table when necessary, and uses an atomic replacement.

Claude Code owns Claude status through its configured `statusLine` command. `claude-statusline.sh` appends the existing subscription-usage summary as `CL:<value>`. The short-lived Claude usage cache remains because it prevents the native status line from repeatedly fetching the account endpoint; it is not used by tmux.

The tmux status bar no longer renders `CL:` or `CTX:`, detects agent processes, reads marker files, installs a Codex plugin, or provides Codex lifecycle hooks. The installer removes the legacy local Codex plugin registration when present and removes retired generated scripts and stale Codex marker files. Claude's status-line hook remains configured as before.

## Decision points, by section

### Status ownership

Each agent's status is displayed only inside that agent's own session. This avoids global active-pane inference, correctly follows multiple agent panes, and lets each upstream CLI define the semantics of its quota and context readings. A compact tmux substitute was discarded because it would continue to require unsupported or duplicated state extraction.

### Codex configuration merge

The installer performs a narrow text merge instead of replacing the config file or adding a TOML dependency. It rewrites `status_line` and `status_line_use_colors` only inside `[tui]`; if that table is absent, it creates it before nested `tui` tables so TOML table rules remain valid. The resulting file is written through a temporary file and moved into place only after generation succeeds.

### Claude subscription display

The `CL:` prefix moves to the Claude native status line. Usage values remain plain text there, while the existing ANSI context bar continues to carry the visual context signal. Account usage is deliberately not shown in tmux because it belongs to a Claude session rather than to whichever pane happens to be active.

### Legacy removal

The bundled `tmux-claude-context` marketplace/plugin, Codex lifecycle-hook script, `agent-status.sh`, process detection, marker cleanup, and status-right command substitution are deleted. A best-effort legacy-plugin removal is included in the installer so existing users stop running the hook immediately after reinstalling. Absence of Codex, `jq`, an existing plugin, or stale markers is non-fatal.

### Verification

Automated tests cover TOML merges for absent and existing `[tui]` tables, verify preservation of unrelated settings, assert that generated tmux configuration has no agent-status command, and verify the Claude status script emits `CL:`. Manual verification reinstalls the configuration, starts a new Codex session to inspect its native status line, and starts Claude Code to inspect its native `CL:` field.

## Acceptance criteria

- `install.sh` enables Codex's colored native remaining-context, primary-usage-limit, and secondary-usage-limit status items.
- The Codex config merge preserves unrelated configuration, including nested `[tui.*]` tables.
- Claude Code's native status line includes `CL:` in addition to its existing context/model information.
- The tmux global status line contains no `CL:` or `CTX:` field and does not inspect agent processes or state files.
- No repository or generated installer machinery remains for Codex marker hooks or the local Codex plugin.
- Reinstallation tolerates users who never installed the retired Codex integration.

## Post-Implementation Notes

*As this design is implemented and iterated on — bug fixes, adjustments, anything that diverged from the assumptions above — append a dated note here, whether or not a formal debugging skill was used.*

**Changes vs. original design (2026-07-14):** The narrow TOML merge also recognizes valid whitespace in table headers and array-of-tables boundaries. The Claude usage helper strips legacy tmux color directives from cached data so upgrades cannot render those directives literally in Claude's native status line.

- 2026-07-14: Codex CLI 0.144.4 rejected the initially selected item identifiers. The installer now uses the CLI's accepted `context-remaining`, `five-hour-limit`, and `weekly-limit` identifiers.
