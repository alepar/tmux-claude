#!/usr/bin/env bash
# Dependency-free regression tests for generated tmux helper scripts.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
REAL_CODEX=$(command -v codex || true)
WORK=$(mktemp -d)
HOME_DIR="$WORK/home"
STATE_DIR="$WORK/state"
BIN_DIR="$WORK/bin"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$HOME_DIR/.claude" "$HOME_DIR/.codex" "$STATE_DIR" "$BIN_DIR"
cat > "$HOME_DIR/.codex/hooks.json" <<'EOF'
{
  "unrelated": true,
  "hooks": {
    "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "keep-me"}]}],
    "SessionStart": [{"hooks": [{"type": "command", "command": "keep-start"}]}],
    "Stop": [{"hooks": [{"type": "command", "command": "keep-stop"}]}],
    "PostCompact": [{"hooks": [{"type": "command", "command": "keep-compact"}]}]
  }
}
EOF
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

cat > "$BIN_DIR/tmux" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "list-panes" ]; then
    printf '%s\n' "${TMUX_TEST_PANES:-}"
elif [ "$1" = "display-message" ]; then
    printf '%s\n' "${TMUX_TEST_PANE_PID:-100}"
fi
EOF
chmod +x "$BIN_DIR/tmux"

cat > "$BIN_DIR/ps" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "-axo" ] && [ "$2" = "pid=,ppid=" ]; then
    printf '200 100\n300 999\n'
elif [ "$1" = "-o" ] && [ "$2" = "comm=" ] && { [ "$4" = "200" ] || [ "$4" = "300" ]; }; then
    printf '%s\n' "${FAKE_COMM:-sh}"
else
    printf 'unexpected ps invocation: %s\n' "$*" >&2
    exit 64
fi
EOF
chmod +x "$BIN_DIR/ps"

cat > "$BIN_DIR/codex" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CODEX_LOG:?}"
[ "${CODEX_FAIL:-0}" = 1 ] && exit 1
EOF
chmod +x "$BIN_DIR/codex"

MARKETPLACE="$ROOT/.claude-plugin/marketplace.json"
PLUGIN="$ROOT/plugins/tmux-claude-context"
PLUGIN_MANIFEST="$PLUGIN/.codex-plugin/plugin.json"
PLUGIN_HOOKS="$PLUGIN/hooks/hooks.json"
assert_file "$MARKETPLACE"
assert_file "$PLUGIN_MANIFEST"
assert_file "$PLUGIN_HOOKS"
jq -e '
    .name == "tmux-claude"
    and .plugins == [{
        name: "tmux-claude-context",
        source: {source: "local", path: "./plugins/tmux-claude-context"},
        policy: {installation: "AVAILABLE", authentication: "ON_INSTALL"},
        category: "Productivity"
    }]
' "$MARKETPLACE" >/dev/null || fail 'marketplace does not expose the Codex context plugin'
jq -e '
    .name == "tmux-claude-context"
    and .version == "0.1.0"
    and .description != ""
    and .interface.displayName == "tmux-claude Context"
    and .interface.shortDescription != ""
    and has("hooks") | not
' "$PLUGIN_MANIFEST" >/dev/null || fail 'plugin manifest is missing required metadata or declares unsupported hooks'
jq -e '
    .hooks | keys == ["PostCompact", "SessionStart", "Stop"]
    and [.SessionStart[0].hooks[0].command, .Stop[0].hooks[0].command, .PostCompact[0].hooks[0].command] == [
        "bash ~/.tmux/codex-context-hook.sh start || true",
        "bash ~/.tmux/codex-context-hook.sh stop || true",
        "bash ~/.tmux/codex-context-hook.sh post-compact || true"
    ]
' "$PLUGIN_HOOKS" >/dev/null || fail 'plugin hooks do not declare the required Codex lifecycle commands'

if [ -n "$REAL_CODEX" ]; then
    REAL_CODEX_HOME="$WORK/real-codex-home"
    mkdir -p "$REAL_CODEX_HOME"
    HOME="$REAL_CODEX_HOME" "$REAL_CODEX" plugin marketplace add "$ROOT" >/dev/null || \
        fail 'real Codex marketplace registration failed'
    HOME="$REAL_CODEX_HOME" "$REAL_CODEX" plugin add tmux-claude-context@tmux-claude >/dev/null || \
        fail 'real Codex plugin installation failed'
fi

original_codex_hooks=$(cat "$HOME_DIR/.codex/hooks.json")

env HOME="$HOME_DIR" TMPDIR="$STATE_DIR" PATH="$BIN_DIR:$PATH" CODEX_LOG="$CODEX_LOG" \
    bash "$ROOT/install.sh" >/dev/null

HOOK="$HOME_DIR/.tmux/codex-context-hook.sh"
STATUS="$HOME_DIR/.tmux/agent-status.sh"
CLEANUP="$HOME_DIR/.tmux/cleanup-markers.sh"
PANE_LABEL="$HOME_DIR/.tmux/pane-label.sh"
assert_file "$HOOK"
assert_file "$STATUS"
assert_file "$CLEANUP"
assert_file "$PANE_LABEL"
bash -n "$HOOK" "$STATUS" "$CLEANUP" "$PANE_LABEL"
if grep -q -- '--ppid' "$STATUS" "$PANE_LABEL"; then
    fail 'generated process walkers must not use GNU ps --ppid'
fi
assert_eq "$(cat "$HOME_DIR/.codex/hooks.json")" "$original_codex_hooks"
assert_eq "$(cat "$CODEX_LOG")" "$(printf 'plugin marketplace add %s\nplugin add tmux-claude-context@tmux-claude' "$ROOT")"

NO_JQ_BIN="$WORK/no-jq-bin"
NO_JQ_LOG="$WORK/no-jq-codex.log"
mkdir -p "$NO_JQ_BIN"
for tool in bash basename cat chmod cp date dirname env grep head mkdir mktemp mv rm sed tr awk; do
    ln -s "$(command -v "$tool")" "$NO_JQ_BIN/$tool"
done
ln -s "$BIN_DIR/codex" "$NO_JQ_BIN/codex"
ln -s "$BIN_DIR/tmux" "$NO_JQ_BIN/tmux"
NO_JQ_HOME="$WORK/no-jq-home"
mkdir -p "$NO_JQ_HOME"
no_jq_output=$(env HOME="$NO_JQ_HOME" TMPDIR="$STATE_DIR" PATH="$NO_JQ_BIN" CODEX_LOG="$NO_JQ_LOG" \
    bash "$ROOT/install.sh")
[ ! -s "$NO_JQ_LOG" ] || fail 'Codex plugin commands ran without jq'
printf '%s\n' "$no_jq_output" | grep -qF 'Skipping Codex context plugin (Codex CLI or jq not found).' || \
    fail 'missing clear Codex jq prerequisite skip message'

EMPTY_CODEX_HOME="$WORK/empty-codex-home"
mkdir -p "$EMPTY_CODEX_HOME/.claude"
env HOME="$EMPTY_CODEX_HOME" TMPDIR="$STATE_DIR" PATH="$BIN_DIR:$PATH" CODEX_LOG="$CODEX_LOG" \
    bash "$ROOT/install.sh" >/dev/null
assert_no_file "$EMPTY_CODEX_HOME/.codex/hooks.json"

FAILED_CODEX_HOME="$WORK/failed-codex-home"
mkdir -p "$FAILED_CODEX_HOME/.claude"
env HOME="$FAILED_CODEX_HOME" TMPDIR="$STATE_DIR" PATH="$BIN_DIR:$PATH" CODEX_LOG="$CODEX_LOG" CODEX_FAIL=1 \
    bash "$ROOT/install.sh" >/dev/null || fail 'failed Codex plugin commands aborted installation'
assert_no_file "$FAILED_CODEX_HOME/.codex/hooks.json"

BAD_HOME="$WORK/bad-home"
mkdir -p "$BAD_HOME/.claude" "$BAD_HOME/.codex"
printf '%s\n' '{not-json' > "$BAD_HOME/.codex/hooks.json"
env HOME="$BAD_HOME" TMPDIR="$STATE_DIR" PATH="$BIN_DIR:$PATH" CODEX_LOG="$CODEX_LOG" \
    bash "$ROOT/install.sh" >/dev/null || fail 'Codex CLI failure handling aborted installation'
assert_eq "$(cat "$BAD_HOME/.codex/hooks.json")" '{not-json'

no_tmux=$(printf '%s' '{"session_id":"no-pane","transcript_path":"/missing"}' | \
    env -u TMUX_PANE TMPDIR="$STATE_DIR" bash "$HOOK" start)
assert_eq "$no_tmux" ""
assert_no_file "$STATE_DIR/codex-session%1"

make_transcript() {
    local path="$1" tokens="$2" window="$3"
    printf '%s\n' \
        '{"type":"event_msg","payload":{"type":"other"}}' \
        "{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"input_tokens\":$tokens},\"model_context_window\":$window}}}" \
        > "$path"
}

start_session() {
    local pane="$1" session="$2" transcript="$3" pane_pid="${4:-100}"
    printf '{"session_id":"%s","transcript_path":"%s"}\n' "$session" "$transcript" | \
        TMUX_PANE="$pane" TMUX_TEST_PANE_PID="$pane_pid" TMPDIR="$STATE_DIR" PATH="$BIN_DIR:$PATH" bash "$HOOK" start
}

refresh_session() {
    local pane="$1" session="$2" event="${3:-stop}"
    printf '{"session_id":"%s"}\n' "$session" | \
        TMUX_PANE="$pane" TMPDIR="$STATE_DIR" bash "$HOOK" "$event"
}

for boundary in '59 59000' '60 59500' '84 84500' '85 84501'; do
    read -r expected tokens <<< "$boundary"
    pane="%$expected"
    transcript="$WORK/$expected.jsonl"
    make_transcript "$transcript" "$tokens" 100000
    start_session "$pane" "session-$expected" "$transcript"
    refresh_session "$pane" "session-$expected"
    assert_eq "$(cat "$STATE_DIR/codex-context$pane")" "$expected"
done

left="$WORK/left.jsonl"
right="$WORK/right.jsonl"
make_transcript "$left" 10000 100000
make_transcript "$right" 90000 100000
printf '%s\n' '77' > "$STATE_DIR/codex-context%11"
start_session '%11' 'left-session' "$left"
assert_no_file "$STATE_DIR/codex-context%11"
start_session '%12' 'right-session' "$right"
refresh_session '%11' 'left-session' post-compact
assert_eq "$(cat "$STATE_DIR/codex-context%11")" '10'
assert_no_file "$STATE_DIR/codex-context%12"
refresh_session '%12' 'right-session'
assert_eq "$(cat "$STATE_DIR/codex-context%12")" '90'
assert_eq "$(FAKE_COMM=codex TMPDIR="$STATE_DIR" PATH="$BIN_DIR:$PATH" bash "$STATUS" '%12' 999)" ''
assert_no_file "$STATE_DIR/codex-context%12"
assert_no_file "$STATE_DIR/codex-session%12"

legacy="$WORK/legacy.jsonl"
make_transcript "$legacy" 50000 100000
printf '{"session_id":"legacy-session","agent_transcript_path":"%s"}\n' "$legacy" | \
    TMUX_PANE='%13' TMUX_TEST_PANE_PID=100 TMPDIR="$STATE_DIR" PATH="$BIN_DIR:$PATH" bash "$HOOK" start
refresh_session '%13' 'legacy-session'
assert_eq "$(cat "$STATE_DIR/codex-context%13")" '50'

pending_transcript="$WORK/pending.jsonl"
make_transcript "$pending_transcript" 1 100000
start_session '%24' 'pending-session' "$pending_transcript"
assert_no_file "$STATE_DIR/codex-context%24"
assert_eq "$(FAKE_COMM=codex TMPDIR="$STATE_DIR" PATH="$BIN_DIR:$PATH" bash "$STATUS" '%24' 100)" ''
assert_file "$STATE_DIR/codex-session%24"

late_transcript="$WORK/later.jsonl"
printf '%s\n' '77' > "$STATE_DIR/codex-context%14"
start_session '%14' 'later-session' "$late_transcript"
assert_file "$STATE_DIR/codex-session%14"
assert_no_file "$STATE_DIR/codex-context%14"
assert_eq "$(FAKE_COMM=codex TMPDIR="$STATE_DIR" PATH="$BIN_DIR:$PATH" bash "$STATUS" '%14' 100)" ''
assert_file "$STATE_DIR/codex-session%14"

bad_transcript="$WORK/bad.jsonl"
printf '%s\n' '{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":"oops"},"model_context_window":0}}}' > "$bad_transcript"
start_session '%20' 'bad-session' "$bad_transcript"
refresh_session '%20' 'bad-session'
assert_no_file "$STATE_DIR/codex-context%20"
printf '%s' 'not-json' | TMUX_PANE='%21' TMPDIR="$STATE_DIR" bash "$HOOK" start
assert_no_file "$STATE_DIR/codex-session%21"
start_session '%22' 'mismatch-session' "$left"
refresh_session '%22' 'other-session'
assert_no_file "$STATE_DIR/codex-context%22"
start_session '%23' 'stale-session' "$right"
rm -f "$right"
refresh_session '%23' 'stale-session'
assert_no_file "$STATE_DIR/codex-context%23"

printf '%s\n' '59' > "$STATE_DIR/codex-context%1"
printf '%s\n' '60' > "$STATE_DIR/codex-context%2"
printf '%s\n' 'session' > "$STATE_DIR/codex-session%2"
TMUX_TEST_PANES='%1' TMPDIR="$STATE_DIR" PATH="$BIN_DIR:$PATH" bash "$CLEANUP"
assert_file "$STATE_DIR/codex-context%1"
assert_no_file "$STATE_DIR/codex-context%2"
assert_no_file "$STATE_DIR/codex-session%2"

printf '%s\n' '59' > "$STATE_DIR/codex-context%30"
status_transcript="$WORK/status.jsonl"
make_transcript "$status_transcript" 1 100000
for value in 59 60 84 85; do
    start_session "%$value" "status-$value" "$status_transcript"
    printf '%s\n' "$value" > "$STATE_DIR/codex-context%$value"
done
assert_eq "$(FAKE_COMM=codex TMPDIR="$STATE_DIR" PATH="$BIN_DIR:$PATH" bash "$STATUS" '%59' 100)" '#[fg=colour114]CTX:59%#[fg=colour248]'
assert_eq "$(FAKE_COMM=codex TMPDIR="$STATE_DIR" PATH="$BIN_DIR:$PATH" bash "$STATUS" '%60' 100)" '#[fg=colour222]CTX:60%#[fg=colour248]'
assert_eq "$(FAKE_COMM=codex TMPDIR="$STATE_DIR" PATH="$BIN_DIR:$PATH" bash "$STATUS" '%84' 100)" '#[fg=colour222]CTX:84%#[fg=colour248]'
assert_eq "$(FAKE_COMM=codex TMPDIR="$STATE_DIR" PATH="$BIN_DIR:$PATH" bash "$STATUS" '%85' 100)" '#[fg=colour196]CTX:85%#[fg=colour248]'
assert_eq "$(FAKE_COMM=sh TMPDIR="$STATE_DIR" PATH="$BIN_DIR:$PATH" bash "$STATUS" '%59' 100)" ''
printf '%s\n' '#!/usr/bin/env bash' 'printf mocked' > "$HOME_DIR/.tmux/claude-usage.sh"
chmod +x "$HOME_DIR/.tmux/claude-usage.sh"
assert_eq "$(FAKE_COMM=claude TMPDIR="$STATE_DIR" HOME="$HOME_DIR" PATH="$BIN_DIR:$PATH" bash "$STATUS" '%59' 100)" '#[fg=colour183]CL:mocked#[fg=colour248]'

printf 'PASS\n'
