# Conditional Claude/Codex status usage

## Problem description

The tmux status bar always displays the Claude subscription-usage field (`CL:`), even when the active pane runs Codex. The status field should instead describe the active coding agent: keep the existing Claude usage for Claude Code, show a compact colored Codex context percentage for Codex, and display nothing for any other active pane.

## Main challenges

Codex does not provide a Claude-style status-line command or a direct hook payload containing token usage. Its hook payload includes the session ID and inherits the tmux pane environment, while its locally persisted session transcript contains token-count events. The implementation must bind that session to the pane at session start, avoid selecting a different Codex instance in a multi-pane repository, and degrade silently when no trustworthy state exists.

## Key decisions made

Use Codex hooks and per-pane marker files, matching the repository's existing Claude integration rather than wrapping the `codex` command. A `SessionStart` hook records the mapping from `TMUX_PANE` to Codex session ID. `Stop` and `PostCompact` hooks read the session's latest `token_count` record and write an integer usage percentage to a pane-keyed marker. The tmux status command determines whether the active pane currently runs Claude or Codex, then renders `CL:` or `CTX:` respectively; it renders neither for a non-agent or untracked pane.

## Decision points, by section

### Status source

The selected source is a pane-keyed Codex marker file refreshed from Codex hooks. A status-time scan for the newest session in the working directory was discarded because multiple Codex panes may share a repository and therefore produce incorrect attribution. A launcher wrapper was discarded because it changes the normal way users start Codex and is unnecessary when hooks provide the session identity.

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
