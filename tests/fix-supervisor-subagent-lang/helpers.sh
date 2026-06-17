# helpers.sh — Shared setup and helper functions for fix-supervisor-subagent-lang tests.
# Sourced by the dispatch entrypoint; not executable directly.
# Sets: AGENTS_DIR, SETTINGS_JSON, SUBAGENT_START, AGENT_FILES, EXPECTED_JA,
#       TMPDIR_BASE, PASS, FAIL, SKIP counters, pass/fail/skip functions,
#       run_with_timeout, to_node_path.

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SETTINGS_JSON="$AGENTS_DIR/settings.json"
SUBAGENT_START="$AGENTS_DIR/hooks/subagent-start.js"
ASSEMBLE_SETTINGS="$AGENTS_DIR/install/assemble-settings.js"

# 8 agent files (per #897 plan; workers and other non-MUST agents are out of scope).
AGENT_FILES=(
    "$AGENTS_DIR/agents/supervisor.md"
    "$AGENTS_DIR/agents/survey-history.md"
    "$AGENTS_DIR/agents/survey-code.md"
    "$AGENTS_DIR/agents/detail-planner.md"
    "$AGENTS_DIR/agents/outline-planner.md"
    "$AGENTS_DIR/agents/security-scanner.md"
    "$AGENTS_DIR/agents/detail-reviewer.md"
    "$AGENTS_DIR/agents/outline-reviewer.md"
)

EXPECTED_JA='Respond to the user in japanese.'

PASS=0
FAIL=0
SKIP=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

# ---------------------------------------------------------------------------
# Windows-compatible tmpdir
# ---------------------------------------------------------------------------
_NODE_TMPDIR=$(node -e "process.stdout.write(require('os').tmpdir())" 2>/dev/null || echo "")
if [[ "$_NODE_TMPDIR" =~ ^[A-Za-z]: ]]; then
    _DRIVE=$(echo "$_NODE_TMPDIR" | cut -c1 | tr 'A-Z' 'a-z')
    _REST=$(echo "$_NODE_TMPDIR" | cut -c3- | tr '\\' '/')
    _BASH_WIN_TMPDIR="/${_DRIVE}${_REST}"
    TMPDIR_BASE=$(mktemp -d "${_BASH_WIN_TMPDIR}/cctests-subagent-lang.XXXXXXXX")
else
    TMPDIR_BASE=$(mktemp -d)
fi
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Convert a posix-ish path back to a Node.js-friendly Windows path if needed.
to_node_path() { echo "$1" | sed 's|^/\([a-zA-Z]\)/|\1:/|'; }

NODE_SETTINGS_JSON=$(to_node_path "$SETTINGS_JSON")
NODE_SUBAGENT_START=$(to_node_path "$SUBAGENT_START")
NODE_ASSEMBLE_SETTINGS=$(to_node_path "$ASSEMBLE_SETTINGS")

# Isolate from any user .env that might define CONV_LANG.
EMPTY_CFG="$TMPDIR_BASE/empty-cfg"
mkdir -p "$EMPTY_CFG"
export AGENTS_CONFIG_DIR="$EMPTY_CFG"

assert_eq() {
    # assert_eq <label> <expected> <actual>
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        pass "$label"
    else
        fail "$label (expected='$expected' actual='$actual')"
    fi
}

assert_contains() {
    # assert_contains <label> <needle> <haystack>
    local label="$1" needle="$2" haystack="$3"
    if echo "$haystack" | grep -qF "$needle"; then
        pass "$label"
    else
        fail "$label (missing '$needle' in: $haystack)"
    fi
}
