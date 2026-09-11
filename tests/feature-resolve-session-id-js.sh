#!/bin/bash
# Tests: hooks/workflow-state/session-id.js, hooks/lib/git-common-dir.js
# Tags: workflow, hook, scope:common
# Tests for resolveSessionId() — #2270 pruned it to a 4-tier SUPPLY-only chain
# (no filesystem inference); see docs/architecture/claude-code/session-id-resolution.md.
# Tests use `node -e` inline scripts; CLAUDE_TRANSCRIPT_BASE_DIR isolates from
# the real ~/.claude/projects.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="$AGENTS_DIR/hooks/workflow-state.js"
# Normalize to Windows-style path for Node when running under MSYS/Cygwin.
if command -v cygpath >/dev/null 2>&1; then
    TARGET_NODE="$(cygpath -w "$TARGET" | sed 's|\\|/|g')"
    # Un-slashed: encode_path() below must see the same path form node's
    # process.cwd() reports, so the removed JSONL tier's directory name can be
    # reproduced exactly (section-supply-tier.sh JS-26).
    AGENTS_DIR_NODE="$(cygpath -w "$AGENTS_DIR")"
else
    TARGET_NODE="$TARGET"
    AGENTS_DIR_NODE="$AGENTS_DIR"
fi

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

if [ ! -f "$TARGET" ]; then
    echo "FAIL: $TARGET not found"
    echo ""
    echo "Results: 0 passed, 5 failed"
    exit 1
fi

# Confirm resolveSessionId is exported.
if ! node -e "const m=require('$TARGET_NODE'); if(typeof m.resolveSessionId!=='function'){process.exit(2)}" 2>/dev/null; then
    echo "FAIL: resolveSessionId is not exported from workflow-state.js"
    echo ""
    echo "Results: 0 passed, 5 failed"
    exit 1
fi

TMP=""
setup() {
    TMP="$(mktemp -d)"
    export CLAUDE_TRANSCRIPT_BASE_DIR="$TMP/transcripts"
    mkdir -p "$CLAUDE_TRANSCRIPT_BASE_DIR"
    unset CLAUDE_PROJECT_DIR CLAUDE_ENV_FILE CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID 2>/dev/null || true
}
teardown() {
    if [ -n "${TMP:-}" ] && [ -d "$TMP" ]; then
        rm -rf "$TMP" 2>/dev/null || true
    fi
    TMP=""
    unset CLAUDE_TRANSCRIPT_BASE_DIR CLAUDE_PROJECT_DIR CLAUDE_ENV_FILE CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID 2>/dev/null || true
}

# Encoding helper for JS-1: CC-native encoding via shell to match the helper.
encode_path() {
    printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C sed 's/[^a-z0-9]/-/g'
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUB_DIR="$SCRIPT_DIR/feature-resolve-session-id-js"

# shellcheck source=/dev/null
. "$SUB_DIR/section-cc-session-title.sh"
# shellcheck source=/dev/null
. "$SUB_DIR/section-supply-tier.sh"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
