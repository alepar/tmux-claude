#!/usr/bin/env bash
# Dependency-free regression tests for the native agent status-line migration.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d)
HOME_DIR="$WORK/home"
STATE_DIR="$WORK/state"
BIN_DIR="$WORK/bin"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$HOME_DIR/.claude" "$HOME_DIR/.codex" "$STATE_DIR" "$BIN_DIR"
CODEX_LOG="$WORK/codex.log"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_eq() {
    [ "$1" = "$2" ] || fail "expected [$2], got [$1]"
}

assert_file() {
    [ -f "$1" ] || fail "missing file: $1"
}

assert_no_file() {
    [ ! -e "$1" ] || fail "unexpected file: $1"
}

assert_contains() {
    grep -qF "$2" "$1" || fail "missing [$2] in $1"
}

assert_not_contains() {
    ! grep -qF "$2" "$1" || fail "unexpected [$2] in $1"
}

assert_count() {
    local file="$1" text="$2" expected="$3" actual
    actual=$(grep -cF "$text" "$file" || true)
    assert_eq "$actual" "$expected"
}

cat > "$BIN_DIR/codex" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CODEX_LOG:?}"
[ "${CODEX_FAIL:-0}" = 1 ] && exit 1
EOF
chmod +x "$BIN_DIR/codex"

cat > "$BIN_DIR/claude" <<'EOF'
#!/usr/bin/env bash
printf 'test\n'
EOF
chmod +x "$BIN_DIR/claude"

cat > "$BIN_DIR/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"five_hour":{"utilization":95},"seven_day":{"utilization":91},"used_credits":15000}' '200'
EOF
chmod +x "$BIN_DIR/curl"

run_install() {
    env HOME="$1" TMPDIR="$STATE_DIR" PATH="$BIN_DIR:$PATH" CODEX_LOG="$CODEX_LOG" \
        bash "$ROOT/install.sh" >/dev/null
}

canonical_status='status_line = ["context-remaining", "five-hour-limit", "weekly-limit"]'
canonical_colors='status_line_use_colors = true'
obsolete_status='status_line = ["context-left", "usage-limit", "secondary-usage-limit"]'

# No existing config: create the managed [tui] table and only the two keys.
run_install "$HOME_DIR"
assert_file "$HOME_DIR/.codex/config.toml"
assert_count "$HOME_DIR/.codex/config.toml" "$canonical_status" 1
assert_count "$HOME_DIR/.codex/config.toml" "$canonical_colors" 1
assert_not_contains "$HOME_DIR/.codex/config.toml" "$obsolete_status"

# Existing [tui]: replace only stale managed keys and retain unrelated settings.
EXISTING_HOME="$WORK/existing-home"
mkdir -p "$EXISTING_HOME/.claude" "$EXISTING_HOME/.codex"
cat > "$EXISTING_HOME/.codex/config.toml" <<'EOF'
model = "gpt-5"

[tui]
animation = false
status_line = ["old"]
status_line_use_colors = false
other_key = "preserve"

[other]
value = 1
EOF
run_install "$EXISTING_HOME"
assert_contains "$EXISTING_HOME/.codex/config.toml" 'model = "gpt-5"'
assert_contains "$EXISTING_HOME/.codex/config.toml" 'animation = false'
assert_contains "$EXISTING_HOME/.codex/config.toml" 'other_key = "preserve"'
assert_contains "$EXISTING_HOME/.codex/config.toml" '[other]'
assert_count "$EXISTING_HOME/.codex/config.toml" "$canonical_status" 1
assert_count "$EXISTING_HOME/.codex/config.toml" "$canonical_colors" 1

# A nested [tui.*] table without [tui] needs a parent table immediately before it.
NESTED_HOME="$WORK/nested-home"
mkdir -p "$NESTED_HOME/.claude" "$NESTED_HOME/.codex"
cat > "$NESTED_HOME/.codex/config.toml" <<'EOF'
approval_policy = "on-request"

[tui.theme]
name = "night"
EOF
run_install "$NESTED_HOME"
assert_eq "$(sed -n '3,5p' "$NESTED_HOME/.codex/config.toml")" "$(printf '[tui]\n%s\n%s' "$canonical_status" "$canonical_colors")"
assert_eq "$(sed -n '6,7p' "$NESTED_HOME/.codex/config.toml")" "$(printf '[tui.theme]\nname = "night"')"

# An array-of-tables header ends [tui] just like a standard table header.
ARRAY_HOME="$WORK/array-home"
mkdir -p "$ARRAY_HOME/.claude" "$ARRAY_HOME/.codex"
cat > "$ARRAY_HOME/.codex/config.toml" <<'EOF'
[tui]
animation = false
[[profiles]]
name = "default"
EOF
run_install "$ARRAY_HOME"
assert_eq "$(sed -n '1,5p' "$ARRAY_HOME/.codex/config.toml")" "$(printf '[tui]\nanimation = false\n%s\n%s\n[[profiles]]' "$canonical_status" "$canonical_colors")"
assert_eq "$(sed -n '6p' "$ARRAY_HOME/.codex/config.toml")" 'name = "default"'

# TOML permits whitespace inside table headers; preserve that header without a duplicate [tui].
SPACED_HOME="$WORK/spaced-home"
mkdir -p "$SPACED_HOME/.claude" "$SPACED_HOME/.codex"
cat > "$SPACED_HOME/.codex/config.toml" <<'EOF'
[ tui ]
animation = false
EOF
run_install "$SPACED_HOME"
assert_contains "$SPACED_HOME/.codex/config.toml" '[ tui ]'
assert_eq "$(grep -Ec '^\[[[:space:]]*tui[[:space:]]*\][[:space:]]*(#.*)?$' "$SPACED_HOME/.codex/config.toml")" 1
assert_count "$SPACED_HOME/.codex/config.toml" "$canonical_status" 1
assert_count "$SPACED_HOME/.codex/config.toml" "$canonical_colors" 1

# Retired plugin removals and marker cleanup are best-effort.
printf 'old\n' > "$STATE_DIR/codex-session%1"
printf 'old\n' > "$STATE_DIR/codex-context%1"
run_install "$HOME_DIR"
assert_no_file "$STATE_DIR/codex-session%1"
assert_no_file "$STATE_DIR/codex-context%1"
assert_eq "$(grep -cFx 'plugin remove tmux-claude-context@tmux-claude' "$CODEX_LOG")" 6
assert_eq "$(grep -cFx 'plugin marketplace remove tmux-claude' "$CODEX_LOG")" 6

FAILED_CODEX_HOME="$WORK/failed-codex-home"
mkdir -p "$FAILED_CODEX_HOME/.claude"
env HOME="$FAILED_CODEX_HOME" TMPDIR="$STATE_DIR" PATH="$BIN_DIR:$PATH" CODEX_LOG="$CODEX_LOG" CODEX_FAIL=1 \
    bash "$ROOT/install.sh" >/dev/null || fail 'failed Codex removals aborted installation'

NO_CODEX_HOME="$WORK/no-codex-home"
mkdir -p "$NO_CODEX_HOME/.claude"
env HOME="$NO_CODEX_HOME" TMPDIR="$STATE_DIR" PATH="/usr/bin:/bin" \
    bash "$ROOT/install.sh" >/dev/null || fail 'missing Codex command aborted installation'

TMUX_DIR="$HOME_DIR/.tmux"
assert_file "$TMUX_DIR/claude-statusline.sh"
assert_file "$TMUX_DIR/pane-label.sh"
assert_no_file "$TMUX_DIR/agent-status.sh"
assert_no_file "$TMUX_DIR/cleanup-markers.sh"
assert_no_file "$TMUX_DIR/codex-context-hook.sh"
for retired in agent-status.sh cleanup-markers.sh codex-context CL: CTX:; do
    assert_not_contains "$HOME_DIR/.tmux.conf" "$retired"
done
for hook in after-split-window after-new-window after-new-session; do
    assert_contains "$HOME_DIR/.tmux.conf" "set-hook -gu $hook"
done

# Claude retains context/model output and appends a plain cached subscription value.
TRANSCRIPT="$WORK/claude-transcript.jsonl"
printf '%s\n' '{"message":{"usage":{"input_tokens":100000,"cache_read_input_tokens":20000,"cache_creation_input_tokens":0}}}' > "$TRANSCRIPT"
printf '12%%' > "$STATE_DIR/claude-usage-cache"
status=$(printf '%s' "{\"transcript_path\":\"$TRANSCRIPT\",\"model\":{\"id\":\"fable-1m\",\"display_name\":\"Fable\"}}" | \
    HOME="$HOME_DIR" TMPDIR="$STATE_DIR" bash "$TMUX_DIR/claude-statusline.sh")
expected=$'\033[32m██\033[90m░░░░░░░░░░░░░░░░░░\033[0m | remaining: 880k/1m | Fable | CL:12%'
assert_eq "$status" "$expected"

# The native Claude line must remove old tmux color directives from a fresh cache.
printf '%s' '#[fg=colour196]95%#[fg=colour183]/#[fg=colour196]91%#[fg=colour183]/#[fg=colour196]$150#[fg=colour183]' > "$STATE_DIR/claude-usage-cache"
high_status=$(printf '%s' "{\"transcript_path\":\"$TRANSCRIPT\",\"model\":{\"id\":\"fable-1m\",\"display_name\":\"Fable\"}}" | \
    HOME="$HOME_DIR" TMPDIR="$STATE_DIR" bash "$TMUX_DIR/claude-statusline.sh")
high_expected=$'\033[32m██\033[90m░░░░░░░░░░░░░░░░░░\033[0m | remaining: 880k/1m | Fable | CL:95%/91%/$150'
assert_eq "$high_status" "$high_expected"

# Fresh fetched high-threshold values must also be plain text before caching.
rm -f "$STATE_DIR/claude-usage-cache"
printf '%s\n' '{"claudeAiOauth":{"accessToken":"test-token"}}' > "$HOME_DIR/.claude/.credentials.json"
fetched_usage=$(HOME="$HOME_DIR" TMPDIR="$STATE_DIR" PATH="$BIN_DIR:$PATH" bash "$TMUX_DIR/claude-usage.sh")
assert_eq "$fetched_usage" '95%/91%/$150'
assert_not_contains "$STATE_DIR/claude-usage-cache" '#['

printf 'PASS\n'
