# helpers.sh — Shared setup and helper functions for fix-conv-lang-inject tests.
# Sourced by the dispatch entrypoint; not executable directly.
# Sets: AGENTS_DIR, CONV_LANG_LIB, SESSION_START, POST_COMPACT,
#       TMPDIR_BASE, EMPTY_CFG, ENV_FILE, NODE_LIB_PATH,
#       NODE_SESSION_START, NODE_POST_COMPACT, EXPECTED_JA,
#       PASS, FAIL, SKIP counters, pass/fail/skip functions,
#       run_with_timeout, to_node_path, call_helper,
#       call_session_start, call_post_compact.

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONV_LANG_LIB="$AGENTS_DIR/hooks/lib/conv-lang.js"
SESSION_START="$AGENTS_DIR/hooks/session-start.js"
POST_COMPACT="$AGENTS_DIR/hooks/post-compact.js"

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
    TMPDIR_BASE=$(mktemp -d "${_BASH_WIN_TMPDIR}/cctests-conv-lang.XXXXXXXX")
else
    TMPDIR_BASE=$(mktemp -d)
fi
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Convert a posix-ish path back to a Node.js-friendly Windows path if needed.
to_node_path() { echo "$1" | sed 's|^/\([a-zA-Z]\)/|\1:/|'; }

NODE_LIB_PATH=$(to_node_path "$CONV_LANG_LIB")
NODE_SESSION_START=$(to_node_path "$SESSION_START")
NODE_POST_COMPACT=$(to_node_path "$POST_COMPACT")

# Isolate from any user .env that might define CONV_LANG. Point
# AGENTS_CONFIG_DIR at an empty dir so load-env's default lookup misses.
EMPTY_CFG="$TMPDIR_BASE/empty-cfg"
mkdir -p "$EMPTY_CFG"
export AGENTS_CONFIG_DIR="$EMPTY_CFG"

# A throwaway env file location for session-start (it appends CLAUDE_SESSION_ID).
ENV_FILE="$TMPDIR_BASE/session.env"

# Helper: invoke the conv-lang helper with a given CONV_LANG value (or unset).
# Prints the JSON-encoded return value (string or null) to stdout.
# Args: <mode: set|unset> [value]
call_helper() {
    local mode="$1"
    local value="${2-}"
    if [ "$mode" = "set" ]; then
        CONV_LANG="$value" node -e "
const { getConvLangInjection } = require(process.argv[1]);
const r = getConvLangInjection();
process.stdout.write(JSON.stringify(r === undefined ? null : r));
" "$NODE_LIB_PATH" 2>/dev/null
    else
        # Scrub CONV_LANG from the child environment via subshell unset.
        (unset CONV_LANG; node -e "
const { getConvLangInjection } = require(process.argv[1]);
const r = getConvLangInjection();
process.stdout.write(JSON.stringify(r === undefined ? null : r));
" "$NODE_LIB_PATH" 2>/dev/null)
    fi
}

# Helper: spawn session-start.js with a given CONV_LANG setting (or unset)
# and print the additionalContext string to stdout. Empty on failure.
# Args: <sid> <mode: set|unset> [value]
call_session_start() {
    local sid="$1" mode="$2" value="${3-}"
    local payload="{\"session_id\":\"$sid\"}"
    local raw
    if [ "$mode" = "set" ]; then
        raw=$(printf '%s' "$payload" | \
            CONV_LANG="$value" \
            CLAUDE_PROJECT_DIR="$TMPDIR_BASE" \
            CLAUDE_ENV_FILE="$ENV_FILE" \
            CLAUDE_WORKFLOW_DIR="$TMPDIR_BASE/workflow" \
            HOME="$TMPDIR_BASE/home" \
            run_with_timeout 30 node "$SESSION_START" 2>/dev/null)
    else
        raw=$(printf '%s' "$payload" | (
            unset CONV_LANG
            CLAUDE_PROJECT_DIR="$TMPDIR_BASE" \
            CLAUDE_ENV_FILE="$ENV_FILE" \
            CLAUDE_WORKFLOW_DIR="$TMPDIR_BASE/workflow" \
            HOME="$TMPDIR_BASE/home" \
            run_with_timeout 30 node "$SESSION_START" 2>/dev/null
        ))
    fi
    [ -z "$raw" ] && return 0
    node -e "
try {
  const o = JSON.parse(process.argv[1]);
  process.stdout.write(o.additionalContext || '');
} catch (e) {}
" "$raw" 2>/dev/null
}

# Helper: spawn post-compact.js with a given CONV_LANG setting (or unset)
# and print the additionalContext string to stdout. Empty on failure.
# Args: <sid> <mode: set|unset> [value]
call_post_compact() {
    local sid="$1" mode="$2" value="${3-}"
    local payload="{\"session_id\":\"$sid\"}"
    local raw
    if [ "$mode" = "set" ]; then
        raw=$(printf '%s' "$payload" | \
            CONV_LANG="$value" \
            CLAUDE_WORKFLOW_DIR="$TMPDIR_BASE/workflow" \
            HOME="$TMPDIR_BASE/home" \
            run_with_timeout 30 node "$POST_COMPACT" 2>/dev/null)
    else
        raw=$(printf '%s' "$payload" | (
            unset CONV_LANG
            CLAUDE_WORKFLOW_DIR="$TMPDIR_BASE/workflow" \
            HOME="$TMPDIR_BASE/home" \
            run_with_timeout 30 node "$POST_COMPACT" 2>/dev/null
        ))
    fi
    [ -z "$raw" ] && return 0
    node -e "
try {
  const o = JSON.parse(process.argv[1]);
  process.stdout.write(o.additionalContext || '');
} catch (e) {}
" "$raw" 2>/dev/null
}

EXPECTED_JA='Respond to the user in japanese.'
