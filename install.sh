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
# Caches result for 5 minutes. On rate-limit/error, exponential backoff up to 60 min.
# Red highlight: percentages >= 90%, dollar cost >= $150.
# Dependencies: curl, bash, grep — no python3/jq/node required.

CACHE_FILE="${TMPDIR:-/tmp}/claude-usage-cache"
BACKOFF_FILE="${TMPDIR:-/tmp}/claude-usage-backoff"
BASE_TTL=300  # 5 minutes
MAX_TTL=3600  # 60 minutes

# Determine effective TTL (base or backoff)
NOW=$(date +%s)
EFFECTIVE_TTL=$BASE_TTL
if [ -f "$BACKOFF_FILE" ]; then
    EFFECTIVE_TTL=$(cat "$BACKOFF_FILE" 2>/dev/null)
    [ -z "$EFFECTIVE_TTL" ] || [ "$EFFECTIVE_TTL" -lt "$BASE_TTL" ] 2>/dev/null && EFFECTIVE_TTL=$BASE_TTL
    [ "$EFFECTIVE_TTL" -gt "$MAX_TTL" ] 2>/dev/null && EFFECTIVE_TTL=$MAX_TTL
fi

# Check cache freshness
if [ -f "$CACHE_FILE" ]; then
    if [ "$(uname)" = "Darwin" ]; then
        age=$(( NOW - $(stat -f%m "$CACHE_FILE") ))
    else
        age=$(( NOW - $(stat -c%Y "$CACHE_FILE") ))
    fi
    if [ "$age" -lt "$EFFECTIVE_TTL" ]; then
        cat "$CACHE_FILE"
        exit 0
    fi
fi

# Read OAuth token (macOS Keychain first, then credentials file)
TOKEN=""
if [ "$(uname)" = "Darwin" ]; then
    CREDS_JSON=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)
    [ -n "$CREDS_JSON" ] && TOKEN=$(printf '%s' "$CREDS_JSON" | grep -o '"accessToken":"[^"]*"' | head -1 | cut -d'"' -f4)
fi
if [ -z "$TOKEN" ]; then
    CREDS="$HOME/.claude/.credentials.json"
    [ -f "$CREDS" ] || { printf "?"; exit 0; }
    TOKEN=$(grep -o '"accessToken":"[^"]*"' "$CREDS" | head -1 | cut -d'"' -f4)
fi
[ -n "$TOKEN" ] || { printf "?"; exit 0; }

# Call the usage API, capture both body and HTTP status
HTTP_RESPONSE=$(curl -s --max-time 5 -w "\n%{http_code}" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -H "User-Agent: claude-code/$(claude --version 2>/dev/null || echo 0)" \
    -H "anthropic-beta: oauth-2025-04-20" \
    "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)

HTTP_CODE=$(printf '%s' "$HTTP_RESPONSE" | tail -1)
HTTP_BODY=$(printf '%s' "$HTTP_RESPONSE" | sed '$d')

# Check for rate limiting or server errors
if [ "$HTTP_CODE" = "429" ] || [ "${HTTP_CODE:-0}" -ge 500 ] 2>/dev/null; then
    # Exponential backoff: double the current TTL (start from BASE_TTL)
    NEXT_TTL=$(( EFFECTIVE_TTL * 2 ))
    [ "$NEXT_TTL" -gt "$MAX_TTL" ] && NEXT_TTL=$MAX_TTL
    printf '%s' "$NEXT_TTL" > "$BACKOFF_FILE"
    # Touch cache so it won't retry until backoff expires
    [ -f "$CACHE_FILE" ] && touch "$CACHE_FILE" || printf '?' > "$CACHE_FILE"
    cat "$CACHE_FILE"
    exit 0
fi

# --- Pure-bash JSON helpers (no python3/jq needed) ---

# Extract utilization from a named JSON section: "key":{"utilization":N,...}
# Won't match "key_suffix" thanks to the closing quote before colon
json_util() {
    local section
    section=$(printf '%s' "$2" | grep -o "\"$1\":{[^}]*}" | head -1)
    [ -n "$section" ] && printf '%s' "$section" | grep -o '"utilization":[0-9.]*' | head -1 | cut -d: -f2
}

# Extract a top-level numeric value: "key":N
json_num() {
    printf '%s' "$2" | grep -o "\"$1\":[0-9.]*" | head -1 | cut -d: -f2
}

# Format percentage with red highlight for >= 90%
fmt_pct() {
    local v="$1"
    if [ -z "$v" ]; then printf '?'; return; fi
    local n=${v%%.*}
    if [ "$n" -ge 90 ] 2>/dev/null; then
        printf '#[fg=colour196]%s%%#[fg=colour183]' "$n"
    else
        printf '%s%%' "$n"
    fi
}

# Format dollar cost with red highlight for >= $150
fmt_cost() {
    local v="$1"
    if [ -z "$v" ]; then printf -- '-'; return; fi
    local cents=${v%%.*}
    local dollars=$(( cents / 100 ))
    if [ "$dollars" -ge 150 ] 2>/dev/null; then
        printf '#[fg=colour196]$%s#[fg=colour183]' "$dollars"
    else
        printf '$%s' "$dollars"
    fi
}

# Parse response fields
S=$(json_util "five_hour" "$HTTP_BODY")
W=$(json_util "seven_day" "$HTTP_BODY")
WS=$(json_util "seven_day_sonnet" "$HTTP_BODY")
EU=$(json_num "used_credits" "$HTTP_BODY")

USAGE="$(fmt_pct "$S")/$(fmt_pct "$W")/$(fmt_pct "$WS")/$(fmt_cost "$EU")"

if [ "$USAGE" = "?/?/?/-" ]; then
    # Total parse failure — treat as error, apply backoff
    NEXT_TTL=$(( EFFECTIVE_TTL * 2 ))
    [ "$NEXT_TTL" -gt "$MAX_TTL" ] && NEXT_TTL=$MAX_TTL
    printf '%s' "$NEXT_TTL" > "$BACKOFF_FILE"
    USAGE="?"
else
    # Success (even partial) — clear backoff
    rm -f "$BACKOFF_FILE"
fi

printf '%s' "$USAGE" > "$CACHE_FILE"
printf '%s' "$USAGE"
EOF
chmod +x "$TMUX_DIR/claude-usage.sh"
echo "    Wrote $TMUX_DIR/claude-usage.sh"

# --------------------------------------------------------------------------
# ~/.tmux/claude-statusline.sh
# --------------------------------------------------------------------------
cat > "$TMUX_DIR/claude-statusline.sh" << 'EOF'
#!/bin/bash
# Claude Code status line: 20-segment context bar + remaining tokens.
# Reads the JSON payload Claude sends on stdin, locates the latest assistant
# usage record in the session transcript, and prints e.g.
#   ████░░░░░░░░░░░░░░░░ | remaining: 920k/1m
# Bar color: green < 60% used, yellow < 85%, red above.
# Dependencies: jq, awk.

input=$(cat)
transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty')
model_id=$(printf '%s' "$input" | jq -r '.model.id // empty')
exceeds_200k=$(printf '%s' "$input" | jq -r '.exceeds_200k_tokens // false')

tokens=0
if [ -n "$transcript" ] && [ -f "$transcript" ]; then
    last=$(grep -F '"usage"' "$transcript" 2>/dev/null | tail -n 1)
    if [ -n "$last" ]; then
        tokens=$(printf '%s' "$last" | jq -r '
          (.message.usage.input_tokens // 0) +
          (.message.usage.cache_read_input_tokens // 0) +
          (.message.usage.cache_creation_input_tokens // 0)
        ' 2>/dev/null)
        [ -z "$tokens" ] && tokens=0
    fi
fi

# Derive window. Claude Code marks the 1M tier in model.id ("[1m]"); the model
# family is only a fallback for when no marker is present. Haiku is 200k-only.
window=200000
case "$model_id" in
    *"[1m]"*|*-1m|*-1m-*)        window=1000000 ;;
    *haiku*)                     window=200000 ;;
    *fable*|*sonnet-5*|*mythos*) window=1000000 ;;
esac
if [ "$window" -lt 1000000 ] && { [ "$exceeds_200k" = "true" ] || [ "$tokens" -gt 200000 ]; }; then
    window=1000000
fi

[ "$tokens" -gt "$window" ] && tokens=$window
remaining=$((window - tokens))

# Bar: 20 segments, filled proportional to usage (at least 1 once any tokens used).
SEGMENTS=20
filled=$(awk -v t="$tokens" -v w="$window" -v n="$SEGMENTS" 'BEGIN {
    f = int((t / w) * n + 0.5)
    if (t > 0 && f < 1) f = 1
    if (f > n) f = n
    print f
}')

pct=$(awk -v t="$tokens" -v w="$window" 'BEGIN { printf "%d", (t/w)*100 }')
if   [ "$pct" -ge 85 ]; then color=$'\033[31m'   # red
elif [ "$pct" -ge 60 ]; then color=$'\033[33m'   # yellow
else                         color=$'\033[32m'   # green
fi
dim=$'\033[90m'
reset=$'\033[0m'

# Built segment-by-segment: substring slicing on multibyte blocks is locale-dependent.
filled_part=""
empty_part=""
i=0
while [ "$i" -lt "$SEGMENTS" ]; do
    if [ "$i" -lt "$filled" ]; then
        filled_part="${filled_part}█"
    else
        empty_part="${empty_part}░"
    fi
    i=$((i + 1))
done

human() {
    awk -v n="$1" 'BEGIN {
        if (n >= 1000000) {
            s = sprintf("%.1f", n / 1000000)
            sub(/\.0$/, "", s)
            printf "%sm", s
        } else if (n >= 1000) {
            printf "%dk", int(n / 1000 + 0.5)
        } else {
            printf "%d", n
        }
    }'
}

printf "%s%s%s%s%s | remaining: %s/%s" \
    "$color" "$filled_part" "$dim" "$empty_part" "$reset" \
    "$(human "$remaining")" "$(human "$window")"
EOF
chmod +x "$TMUX_DIR/claude-statusline.sh"
echo "    Wrote $TMUX_DIR/claude-statusline.sh"

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

    STATUSLINE_JSON='{"type": "command", "command": "bash ~/.tmux/claude-statusline.sh"}'

    if [ -f "$CLAUDE_SETTINGS" ]; then
        # Merge hooks into existing settings (replace hooks section entirely)
        existing=$(cat "$CLAUDE_SETTINGS")
        updated=$(printf '%s' "$existing" | jq \
            --argjson hooks "$HOOKS_JSON" \
            --argjson statusline "$STATUSLINE_JSON" \
            '.hooks = ($hooks + (.hooks // {} | to_entries | map(select(.key as $k | ($hooks | keys | index($k)) == null)) | from_entries))
             | .statusLine = $statusline')
        printf '%s\n' "$updated" > "$CLAUDE_SETTINGS"
        echo "    Updated $CLAUDE_SETTINGS with tmux hooks + status line"
    else
        # Create new settings file
        printf '%s\n' "$HOOKS_JSON" | jq \
            --argjson statusline "$STATUSLINE_JSON" \
            '{hooks: ., statusLine: $statusline}' > "$CLAUDE_SETTINGS"
        echo "    Created $CLAUDE_SETTINGS with tmux hooks + status line"
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
