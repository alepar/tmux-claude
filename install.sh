#!/usr/bin/env bash
# install-tmux-setup.sh — Self-contained tmux setup installer
# Works on macOS and Linux. Requires: tmux, git, jq (optional, for Claude Code hooks)
#
# Usage: bash install.sh
#
# Installs:
#   ~/.tmux.conf               — tmux configuration
#   ~/.tmux/cpu.sh             — CPU usage for status bar
#   ~/.tmux/mem.sh             — Memory usage for status bar
#   ~/.tmux/claude-usage.sh    — Claude subscription usage for status bar
#   ~/.tmux/project-color.sh   — Session-hashed color badge
#   ~/.tmux/pane-label.sh      — Pane header: git branch/worktree + idle indicator
#   ~/.tmux/claude-cwd-hook.sh — Claude Code cwd tracking hook
#   ~/.tmux/cleanup-markers.sh — Cleans up stale marker files
#
# Claude Code hooks (added to ~/.claude/settings.json if jq + ~/.claude exist):
#   PostToolUse[Bash]  — tracks cwd changes when Claude cd's
#   Notification[idle] — marks pane as idle (orange header + tab)
#   UserPromptSubmit   — clears idle state
#   SessionStart       — initializes cwd marker + idle state
#   SessionEnd         — cleans up markers
#
# Backs up existing ~/.tmux.conf if present.

set -euo pipefail

TMUX_DIR="$HOME/.tmux"
TMUX_CONF="$HOME/.tmux.conf"

echo "==> Installing tmux setup..."

# Back up existing config
if [ -f "$TMUX_CONF" ]; then
    backup="$TMUX_CONF.bak.$(date +%Y%m%d%H%M%S)"
    cp "$TMUX_CONF" "$backup"
    echo "    Backed up existing $TMUX_CONF -> $backup"
fi

mkdir -p "$TMUX_DIR"

# --------------------------------------------------------------------------
# ~/.tmux.conf
# --------------------------------------------------------------------------
cat > "$TMUX_CONF" << 'TMUX_CONF_EOF'
# ============================================================================
# tmux.conf — Claude Code workflow edition
# ============================================================================

# --- Basics ---
set -g default-terminal "tmux-256color"
set -ag terminal-overrides ",xterm-256color:RGB"
set -g mouse on
set -g history-limit 50000
set -g base-index 1
setw -g pane-base-index 1
set -g renumber-windows on
set -g focus-events on
set -s escape-time 0

# --- Status bar ---
set -g status-interval 3
set -g status-position bottom
set -g status-style "bg=colour235,fg=colour248"

# Left: project-colored session badge
set -g status-left-length 50
set -g status-left "#(~/.tmux/project-color.sh '#{session_name}')"

# Right: hostname, CPU, memory, Claude usage, time (local TZ)
set -g status-right-length 100
set -g status-right "\
#[fg=colour243]#h \
#[fg=colour240]│ \
#[fg=colour222]CPU:#(~/.tmux/cpu.sh)%% \
#[fg=colour114]MEM:#(~/.tmux/mem.sh)%% \
#[fg=colour183]CL:#(bash ~/.tmux/claude-usage.sh) \
#[fg=colour240]│ \
#[fg=colour248]%H:%M %Z "

# --- Window tabs (orange highlight when Claude is idle) ---
setw -g window-status-format "#{?@claude_idle, #[fg=colour235]#[bg=colour208]#[bold]#I:#W #[default], #[fg=colour243]#I#[fg=colour245]:#W }"
setw -g window-status-current-format "#[fg=colour255]#[bg=colour238]#[bold]#I:#W #[bg=colour235]"
setw -g window-status-separator ""

# --- Pane borders with git branch / worktree labels + idle indicator ---
set -g pane-border-status top
set -g pane-border-format "#(bash ~/.tmux/pane-label.sh '#{pane_pid}' '#{pane_id}' '#{pane_index}' '#{pane_active}')"
set -g pane-border-style "fg=colour238"
set -g pane-active-border-style "fg=colour075"

# --- Clear idle highlight when pane becomes active (dismiss notification) ---
set-hook -g after-select-pane 'run-shell -b "T=$TMPDIR; [ -z \"$T\" ] && T=/tmp; rm -f \"$T/claude-idle#{pane_id}\"; tmux set -wu @claude_idle 2>/dev/null; true"'
set-hook -g after-select-window 'run-shell -b "T=$TMPDIR; [ -z \"$T\" ] && T=/tmp; rm -f \"$T/claude-idle#{pane_id}\"; tmux set -wu @claude_idle 2>/dev/null; true"'

# --- Clean up stale marker files when new panes/windows are created ---
set-hook -g after-split-window 'run-shell -b "bash ~/.tmux/cleanup-markers.sh"'
set-hook -g after-new-window 'run-shell -b "bash ~/.tmux/cleanup-markers.sh"'
set-hook -g after-new-session 'run-shell -b "bash ~/.tmux/cleanup-markers.sh"'
TMUX_CONF_EOF
echo "    Wrote $TMUX_CONF"

# --------------------------------------------------------------------------
# ~/.tmux/cpu.sh
# --------------------------------------------------------------------------
cat > "$TMUX_DIR/cpu.sh" << 'EOF'
#!/usr/bin/env bash
# CPU usage percentage (macOS + Linux) — red when >= 90%
case "$(uname)" in
    Darwin)
        val=$(top -l 1 -n 0 2>/dev/null | awk '/CPU usage/ {printf "%.0f", 100 - $7}')
        ;;
    Linux)
        s1=$(head -1 /proc/stat)
        sleep 0.5
        s2=$(head -1 /proc/stat)
        val=$(echo "$s1
$s2" | awk '
            NR==1 { for(i=2;i<=NF;i++) a[i]=$i }
            NR==2 {
                total=0; idle=0
                for(i=2;i<=NF;i++) { d=$i - a[i]; total+=d }
                idle = ($5-a[5]) + ($6-a[6])
                if (total>0) printf "%.0f", (total-idle)*100/total
                else print "0"
            }
        ')
        ;;
    *) val="?" ;;
esac
if [ "$val" != "?" ] && [ "$val" -ge 90 ] 2>/dev/null; then
    printf '#[fg=colour196]%s' "$val"
else
    printf '%s' "$val"
fi
EOF
chmod +x "$TMUX_DIR/cpu.sh"
echo "    Wrote $TMUX_DIR/cpu.sh"

# --------------------------------------------------------------------------
# ~/.tmux/mem.sh
# --------------------------------------------------------------------------
cat > "$TMUX_DIR/mem.sh" << 'EOF'
#!/usr/bin/env bash
# Memory usage percentage (macOS + Linux) — red when >= 90%
case "$(uname)" in
    Darwin)
        total_mem=$(sysctl -n hw.memsize 2>/dev/null)
        val=$(vm_stat 2>/dev/null | awk -v total_mem="$total_mem" '
            /page size of/      { page_size = $8 + 0 }
            /Pages active:/     { gsub(/[^0-9]/,"",$NF); active = $NF + 0 }
            /Pages wired/       { gsub(/[^0-9]/,"",$NF); wired = $NF + 0 }
            /Pages speculative/ { gsub(/[^0-9]/,"",$NF); spec = $NF + 0 }
            END {
                if (page_size > 0) {
                    total_pages = total_mem / page_size
                    used = active + wired + spec
                    if (total_pages > 0) printf "%.0f", used * 100 / total_pages
                    else print "?"
                } else print "?"
            }
        ')
        ;;
    Linux)
        val=$(awk '/MemTotal/ {t=$2} /MemAvailable/ {a=$2} END {printf "%.0f", (1-a/t)*100}' /proc/meminfo)
        ;;
    *) val="?" ;;
esac
if [ "$val" != "?" ] && [ "$val" -ge 90 ] 2>/dev/null; then
    printf '#[fg=colour196]%s' "$val"
else
    printf '%s' "$val"
fi
EOF
chmod +x "$TMUX_DIR/mem.sh"
echo "    Wrote $TMUX_DIR/mem.sh"

# --------------------------------------------------------------------------
# ~/.tmux/claude-usage.sh
# --------------------------------------------------------------------------
cat > "$TMUX_DIR/claude-usage.sh" << 'EOF'
#!/usr/bin/env bash
# Fetch Claude subscription usage percentage for tmux status bar.
# Caches result for 60 seconds to avoid excessive API calls.
# Red highlight: percentages >= 90%, dollar cost >= $150.

CACHE_FILE="${TMPDIR:-/tmp}/claude-usage-cache"
CACHE_TTL=60  # seconds

# Check cache freshness
if [ -f "$CACHE_FILE" ]; then
    if [ "$(uname)" = "Darwin" ]; then
        age=$(( $(date +%s) - $(stat -f%m "$CACHE_FILE") ))
    else
        age=$(( $(date +%s) - $(stat -c%Y "$CACHE_FILE") ))
    fi
    if [ "$age" -lt "$CACHE_TTL" ]; then
        cat "$CACHE_FILE"
        exit 0
    fi
fi

# Read OAuth token
CREDS="$HOME/.claude/.credentials.json"
[ -f "$CREDS" ] || { printf "?"; exit 0; }

TOKEN=$(python3 -c "import json; print(json.load(open('$CREDS'))['claudeAiOauth']['accessToken'])" 2>/dev/null)
[ -n "$TOKEN" ] || { printf "?"; exit 0; }

# Call the usage API and parse in one pipeline
USAGE=$(curl -s --max-time 5 \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -H "User-Agent: claude-code/$(claude --version 2>/dev/null || echo 0)" \
    -H "anthropic-beta: oauth-2025-04-20" \
    "https://api.anthropic.com/api/oauth/usage" 2>/dev/null \
  | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    s = d.get('five_hour', {}).get('utilization')
    w = d.get('seven_day', {}).get('utilization')
    ws = d.get('seven_day_sonnet', {})
    ws = ws.get('utilization') if ws else None
    ex = d.get('extra_usage') or {}
    eu = ex.get('used_credits')
    R = '#[fg=colour196]'
    N = '#[fg=colour183]'
    def pct(v):
        if v is None: return '?'
        n = int(v)
        t = f'{n}%'
        return f'{R}{t}{N}' if n >= 90 else t
    def cost(v):
        if v is None: return '-'
        n = int(v / 100)
        t = f'\${n}'
        return f'{R}{t}{N}' if n >= 150 else t
    print(f'{pct(s)}/{pct(w)}/{pct(ws)}/{cost(eu)}')
except Exception:
    print('?')
" 2>/dev/null)

[ -n "$USAGE" ] || USAGE="?"
printf '%s' "$USAGE" > "$CACHE_FILE"
printf '%s' "$USAGE"
EOF
chmod +x "$TMUX_DIR/claude-usage.sh"
echo "    Wrote $TMUX_DIR/claude-usage.sh"

# --------------------------------------------------------------------------
# ~/.tmux/project-color.sh
# --------------------------------------------------------------------------
cat > "$TMUX_DIR/project-color.sh" << 'EOF'
#!/usr/bin/env bash
# Hashes session name to a consistent accent color for the status bar badge
SESSION="$1"
COLORS=(204 114 039 220 183 209 156 081 141 215 117 168 149 075 229)

hash=0
for (( i=0; i<${#SESSION}; i++ )); do
    ord=$(printf '%d' "'${SESSION:$i:1}")
    hash=$(( (hash * 31 + ord) % 65536 ))
done
color="${COLORS[$((hash % ${#COLORS[@]}))]}"

printf "#[bg=colour%s]   #[fg=colour255,bg=colour238,bold] %s #[fg=colour238,bg=colour235] " \
    "$color" "$SESSION"
EOF
chmod +x "$TMUX_DIR/project-color.sh"
echo "    Wrote $TMUX_DIR/project-color.sh"

# --------------------------------------------------------------------------
# ~/.tmux/pane-label.sh
# --------------------------------------------------------------------------
cat > "$TMUX_DIR/pane-label.sh" << 'PANE_EOF'
#!/usr/bin/env bash
# Pane border label: git branch (blue) / worktree name (orange) / idle highlight
# Args: <pane_pid> <pane_id> <pane_index> <pane_active>
# Uses marker files for per-pane Claude idle detection (no tmux option leaking).

PANE_PID="$1"
PANE_ID="${2:-}"
PANE_INDEX="${3:-?}"
PANE_ACTIVE="${4:-0}"
_TMPDIR="${TMPDIR:-/tmp}"

# --- Check idle state via per-pane marker file ---
# Active pane never shows idle highlight (user is looking at it)
idle=false
if [ "$PANE_ACTIVE" != "1" ]; then
    [ -n "$PANE_ID" ] && [ -f "${_TMPDIR}/claude-idle${PANE_ID}" ] && idle=true
fi

# --- Resolve cwd ---
DIR=""
if [[ "$PANE_PID" =~ ^[0-9]+$ ]]; then
    pid="$PANE_PID"
    while true; do
        child=$(ps -o pid= --ppid "$pid" 2>/dev/null | head -1 | tr -d ' ')
        [ -z "$child" ] && break
        pid="$child"
    done
    deepest_comm=$(ps -o comm= -p "$pid" 2>/dev/null)
    marker="${_TMPDIR}/claude-cwd${PANE_ID}"
    if [[ ("$deepest_comm" == "claude" || "$deepest_comm" == "node") && -n "$PANE_ID" && -f "$marker" ]]; then
        DIR=$(cat "$marker")
    else
        if [ -d "/proc/$pid/cwd" ]; then
            DIR=$(readlink -f "/proc/$pid/cwd" 2>/dev/null)
        else
            DIR=$(lsof -p "$pid" -Fn 2>/dev/null | awk '/^n\// && /cwd/ {print substr($0,2); exit}')
            [ -z "$DIR" ] && DIR=$(lsof -d cwd -p "$pid" -Fn 2>/dev/null | awk '/^n\// {print substr($0,2); exit}')
        fi
    fi
fi

# --- Get git info ---
git_label=""
git_color="colour075"
if [ -n "$DIR" ] && cd "$DIR" 2>/dev/null; then
    branch=$(git symbolic-ref --short HEAD 2>/dev/null || git rev-parse --short HEAD 2>/dev/null)
    if [ -n "$branch" ]; then
        toplevel=$(git rev-parse --show-toplevel 2>/dev/null)
        common_dir=$(git rev-parse --git-common-dir 2>/dev/null)
        git_dir=$(git rev-parse --git-dir 2>/dev/null)
        is_worktree=false
        if [ -n "$common_dir" ] && [ -n "$git_dir" ]; then
            common_real=$(cd "$common_dir" 2>/dev/null && pwd -P)
            git_real=$(cd "$git_dir" 2>/dev/null && pwd -P)
            [ "$common_real" != "$git_real" ] && is_worktree=true
        fi
        if $is_worktree; then
            git_label=$(basename "$toplevel")
            git_color="colour208"
        else
            git_label="$branch"
            git_color="colour075"
        fi
    fi
fi

# --- Output ---
if $idle; then
    # Idle Claude: orange bg strip with dark text
    printf "#[fg=colour235,bg=colour208,bold] %s: %s #[default]" "$PANE_INDEX" "$git_label"
else
    # Normal: blue/grey pane number, colored git info
    if [ "$PANE_ACTIVE" = "1" ]; then
        num_color="colour075"
    else
        num_color="colour248"
    fi
    if [ -n "$git_label" ]; then
        printf " #[fg=%s]%s:#[fg=%s] %s " "$num_color" "$PANE_INDEX" "$git_color" "$git_label"
    else
        printf " #[fg=%s]%s " "$num_color" "$PANE_INDEX"
    fi
fi
PANE_EOF
chmod +x "$TMUX_DIR/pane-label.sh"
echo "    Wrote $TMUX_DIR/pane-label.sh"

# --------------------------------------------------------------------------
# ~/.tmux/cleanup-markers.sh
# --------------------------------------------------------------------------
cat > "$TMUX_DIR/cleanup-markers.sh" << 'CLEANUP_EOF'
#!/usr/bin/env bash
# Remove claude-idle and claude-cwd marker files for panes that no longer exist.
d="${TMPDIR:-/tmp}"
live=$(tmux list-panes -a -F '#{pane_id}' 2>/dev/null) || exit 0
for f in "$d"/claude-idle%* "$d"/claude-cwd%*; do
    [ -f "$f" ] || continue
    pane_id="%$(basename "$f" | grep -o '[0-9]*$')"
    echo "$live" | grep -qF "$pane_id" || rm -f "$f"
done
CLEANUP_EOF
chmod +x "$TMUX_DIR/cleanup-markers.sh"
echo "    Wrote $TMUX_DIR/cleanup-markers.sh"

# --------------------------------------------------------------------------
# ~/.tmux/claude-cwd-hook.sh  (Claude Code PostToolUse hook)
# --------------------------------------------------------------------------
cat > "$TMUX_DIR/claude-cwd-hook.sh" << 'HOOK_EOF'
#!/usr/bin/env bash
# PostToolUse hook: track Claude Code's Bash cwd changes for tmux pane headers.
# Writes detected cwd to $TMPDIR/claude-cwd<TMUX_PANE>.
# Requires jq. The pane-label.sh script reads this marker file.

[ -z "$TMUX_PANE" ] && exit 0

input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null)
[ -z "$cmd" ] && exit 0

# Detect: cd /path, cd "/path with spaces", cd /path && ...
if [[ "$cmd" =~ ^[[:space:]]*cd[[:space:]]+(\"([^\"]+)\"|\'([^\']+)\'|([^\"\'[:space:]\&\;\|]+)) ]]; then
    new_dir="${BASH_REMATCH[2]:-${BASH_REMATCH[3]:-${BASH_REMATCH[4]}}}"
    if [[ -n "$new_dir" && "$new_dir" == /* && -d "$new_dir" ]]; then
        printf '%s' "$new_dir" > "${TMPDIR:-/tmp}/claude-cwd${TMUX_PANE}"
    fi
fi
HOOK_EOF
chmod +x "$TMUX_DIR/claude-cwd-hook.sh"
echo "    Wrote $TMUX_DIR/claude-cwd-hook.sh"

# --------------------------------------------------------------------------
# Claude Code hooks (optional — requires Claude Code + jq)
# --------------------------------------------------------------------------
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
if command -v jq &>/dev/null && [ -d "$HOME/.claude" ]; then
    echo ""
    echo "==> Claude Code detected. Setting up hooks..."

    # Define the hooks we want to add
    HOOKS_JSON=$(cat << 'HOOKS_EOF'
{
  "PostToolUse": [
    {
      "matcher": "Bash",
      "hooks": [{"type": "command", "command": "bash ~/.tmux/claude-cwd-hook.sh"}]
    }
  ],
  "Notification": [
    {
      "matcher": "idle_prompt",
      "hooks": [{"type": "command", "command": "[ -n \"$TMUX_PANE\" ] && touch \"${TMPDIR:-/tmp}/claude-idle${TMUX_PANE}\" && tmux set -w -t \"$TMUX_PANE\" @claude_idle 1"}]
    }
  ],
  "UserPromptSubmit": [
    {
      "matcher": "",
      "hooks": [{"type": "command", "command": "[ -n \"$TMUX_PANE\" ] && rm -f \"${TMPDIR:-/tmp}/claude-idle${TMUX_PANE}\"; tmux set -wu -t \"$TMUX_PANE\" @claude_idle 2>/dev/null; true"}]
    }
  ],
  "SessionStart": [
    {
      "matcher": "",
      "hooks": [{"type": "command", "command": "[ -n \"$TMUX_PANE\" ] && pwd > \"${TMPDIR:-/tmp}/claude-cwd${TMUX_PANE}\" && touch \"${TMPDIR:-/tmp}/claude-idle${TMUX_PANE}\" && tmux set -w -t \"$TMUX_PANE\" @claude_idle 1"}]
    }
  ],
  "SessionEnd": [
    {
      "matcher": "",
      "hooks": [{"type": "command", "command": "[ -n \"$TMUX_PANE\" ] && rm -f \"${TMPDIR:-/tmp}/claude-idle${TMUX_PANE}\"; tmux set -wu -t \"$TMUX_PANE\" @claude_idle 2>/dev/null; true"}]
    }
  ]
}
HOOKS_EOF
)

    if [ -f "$CLAUDE_SETTINGS" ]; then
        # Merge hooks into existing settings (replace hooks section entirely)
        existing=$(cat "$CLAUDE_SETTINGS")
        updated=$(printf '%s' "$existing" | jq --argjson hooks "$HOOKS_JSON" '.hooks = ($hooks + (.hooks // {} | to_entries | map(select(.key as $k | ($hooks | keys | index($k)) == null)) | from_entries))')
        printf '%s\n' "$updated" > "$CLAUDE_SETTINGS"
        echo "    Updated $CLAUDE_SETTINGS with tmux hooks"
    else
        # Create new settings file
        printf '%s\n' "$HOOKS_JSON" | jq '{hooks: .}' > "$CLAUDE_SETTINGS"
        echo "    Created $CLAUDE_SETTINGS with tmux hooks"
    fi
else
    echo ""
    echo "    Skipping Claude Code hooks (jq or ~/.claude not found)."
    echo "    Install jq and Claude Code, then re-run to enable idle detection."
fi

# --------------------------------------------------------------------------
# Reload tmux if running
# --------------------------------------------------------------------------
echo ""
if [ -n "${TMUX:-}" ]; then
    tmux source-file "$TMUX_CONF" 2>/dev/null && echo "==> Reloaded tmux config." || echo "    tmux reload failed (try: tmux source-file ~/.tmux.conf)"
else
    echo "==> Not inside tmux. Run 'tmux source-file ~/.tmux.conf' to load after starting tmux."
fi

echo ""
echo "Done! Features:"
echo "  - Status bar: project-colored badge, CPU/MEM/Claude %, hostname, clock"
echo "  - Window tabs: orange highlight when Claude is idle"
echo "  - Pane headers: git branch (blue) / worktree name (orange)"
echo "  - Pane headers: orange bg strip when Claude is idle (per-pane)"
echo "  - Claude Code: auto-tracks cwd when switching worktrees"
