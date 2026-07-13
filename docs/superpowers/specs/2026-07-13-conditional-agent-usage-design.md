# Conditional Claude/Codex status usage

## Problem description

The tmux status bar always displays the Claude subscription-usage field (`CL:`), even when the active pane runs Codex. The status field should instead describe the active coding agent: keep the existing Claude usage for Claude Code, show a compact colored Codex context percentage for Codex, and display nothing for any other active pane.

## Main challenges

Codex does not provide a Claude-style status-line command or a direct hook payload containing token usage. Its hook payload includes the session ID and inherits the tmux pane environment, while its locally persisted session transcript contains token-count events. Codex discovers lifecycle hooks from installed plugins, not from a standalone `~/.codex/hooks.json`; the implementation must therefore install a small local plugin as well as bind the session to the pane at session start, avoid selecting a different Codex instance in a multi-pane repository, and degrade silently when no trustworthy state exists.

## Key decisions made

Use Codex hooks supplied by a bundled local Codex plugin and per-pane marker files, matching the repository's existing Claude integration rather than wrapping the `codex` command. The installer registers the repository marketplace and installs the plugin through `codex plugin`; it never writes unsupported standalone Codex hook configuration. A `SessionStart` hook records the mapping from `TMUX_PANE` to Codex session ID. `Stop` and `PostCompact` hooks read the session's latest `token_count` record and write an integer usage percentage to a pane-keyed marker. The tmux status command determines whether the active pane currently runs Claude or Codex, then renders `CL:` or `CTX:` respectively; it renders neither for a non-agent or untracked pane.

## Decision points, by section

### Status source

The selected source is a pane-keyed Codex marker file refreshed from hooks in a bundled `tmux-claude-context` Codex plugin. The plugin uses Codex's supported hook discovery mechanism and calls the already-installed `~/.tmux/codex-context-hook.sh`. A status-time scan for the newest session in the working directory was discarded because multiple Codex panes may share a repository and therefore produce incorrect attribution. A launcher wrapper was discarded because it changes the normal way users start Codex and is unnecessary when hooks provide the session identity. A standalone `~/.codex/hooks.json` was discarded because Codex does not load it.

### Plugin installation

The repository provides a local marketplace and a single plugin. When Codex and `jq` are installed, `install.sh` registers that marketplace and installs or enables the bundled plugin using the Codex CLI. This is intentionally a user-level configuration change, equivalent in scope to the existing Claude settings integration, and is skipped with a clear message if either prerequisite is unavailable. The plugin contains only lifecycle-hook declarations; all marker parsing and rendering remains in `~/.tmux` scripts so the plugin has one responsibility. Plugin-version changes are release metadata and are not mutated by the installer.

### Codex percentage

The selected calculation is `last_token_usage.input_tokens / model_context_window`, rounded to an integer. It is a best-effort context-use indicator, not an exact remaining-token promise: Codex reserves runtime capacity and the semantics of the exposed window are not sufficiently documented. Token totals and graphical bars are discarded to keep the global status field compact and avoid overstating precision.

### Rendering

The active-pane output is `CL:<existing Claude usage>` when the pane runs Claude Code, `CTX:<percent>%` when it runs Codex and has a valid marker, and empty otherwise. Codex percentage colors match the current context thresholds: green below 60%, yellow from 60% through 84%, and red at 85% or above. Showing `CTX:?` was discarded because absence of a marker is not meaningful information and wastes status-bar space.

### Lifecycle and failures

Codex hook commands write only under `$TMPDIR` and never block Codex's work on a state-read error. Missing, malformed, stale, or not-yet-written state is treated as absent. The existing stale-marker cleanup will be extended to remove Codex state for closed panes.

### Verification

Tests will exercise token-record parsing, rounding and color boundaries, active-pane process detection, Claude/Codex/non-agent selection, and absence behavior. Manual verification will run one Claude pane, one Codex pane, and a normal shell pane concurrently to confirm the global status field switches only with the active pane.

## Acceptance criteria

- An active Claude Code pane displays the existing `CL:` subscription usage field.
- An active tracked Codex pane displays only a colored `CTX:<integer>%` field.
- Active shell and unknown panes display neither agent-usage field.
- Two Codex panes in the same repository never read each other's state.
- Codex marker failures never obstruct or visibly degrade Codex itself.
- Closed panes do not leave reusable Codex marker files behind.

## Post-Implementation Notes

*As this design is implemented and iterated on — bug fixes, adjustments, anything that diverged from the assumptions above — append a dated note here, whether or not a formal debugging skill was used.*

**Changes vs. original design (2026-07-13):** Codex requires the local marketplace manifest at `.claude-plugin/marketplace.json`, requires `jq` for the installed hook helper, and caches local plugins by manifest version. The installer therefore installs/enables the bundled version rather than rewriting repository metadata to force a refresh; a future hook-definition release must intentionally bump the plugin version/cachebuster before reinstalling.
