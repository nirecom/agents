#!/bin/bash
# Tests: hooks/lib/workflow-state/session-id.js, hooks/lib/git-common-dir.js
# Tags: workflow, hook, scope:common
# Tests for resolveSessionId() in hooks/lib/workflow-state/session-id.js — Issue #519.
#
# After the fix, the priority chain becomes:
#   1. ctx.sessionIdFromInput
#   2. CLAUDE_ENV_FILE → CLAUDE_SESSION_ID
#   3. ctx.transcriptPath basename
#   4. JSONL scan under CLAUDE_TRANSCRIPT_BASE_DIR/<encoded-cwd-or-projdir>
#
# Tests use `node -e` inline scripts; CLAUDE_TRANSCRIPT_BASE_DIR isolates from
# the real ~/.claude/projects.
# RED: JS-1/JS-2 fail until the JSONL fallback is wired in. JS-3/4/5 are
# regression guards and may pass trivially today, becoming load-bearing once
# the JSONL fallback exists.
# RED: JS-11/JS-12/JS-17 fail until the Priority 7 cross-repo guard lands in
# write-code (#1099). They assert the post-guard behavior (returns <null>);
# until then the resolver returns the foreign JSONL sid instead of null.
# RED: JS-17 exercises the `|| path.resolve(__dirname,"..","..","..")` fallback
# anchor branch (AGENTS_CONFIG_DIR unset — the common production path).
# GREEN: JS-13 is the same-repo positive path — guard must ALLOW same-repo P7.
# Load-bearing regression guard: catches guard over-blocking after #1099 lands.
# GREEN: JS-14 is the linked-worktree positive path — guard must ALLOW P7 when
# the candidate is a linked worktree of the same repo (git-common-dir match).
#
# L3 gap: JS-11/JS-12 use node + `git init` temp repos (L2 narrow-integration).
# A real cross-repo hook subprocess fired from an actual concurrent session
# (real CC firing PreToolUse from a foreign repo's CWD) is not exercised.
# Mitigation: L2 directly calls resolveSessionId() from inside the foreign git
# dir with identical env isolation, reproducing the exact code path the guard
# must block.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="$AGENTS_DIR/hooks/lib/workflow-state.js"
# Normalize to Windows-style path for Node when running under MSYS/Cygwin.
if command -v cygpath >/dev/null 2>&1; then
    TARGET_NODE="$(cygpath -w "$TARGET" | sed 's|\\|/|g')"
else
    TARGET_NODE="$TARGET"
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
    unset CLAUDE_PROJECT_DIR CLAUDE_ENV_FILE CLAUDE_CODE_SESSION_ID 2>/dev/null || true
}
teardown() {
    if [ -n "${TMP:-}" ] && [ -d "$TMP" ]; then
        rm -rf "$TMP" 2>/dev/null || true
    fi
    TMP=""
    unset CLAUDE_TRANSCRIPT_BASE_DIR CLAUDE_PROJECT_DIR CLAUDE_ENV_FILE CLAUDE_CODE_SESSION_ID 2>/dev/null || true
}

# Encoding helper for JS-1: CC-native encoding via shell to match the helper.
encode_path() {
    printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C sed 's/[^a-z0-9]/-/g'
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUB_DIR="$SCRIPT_DIR/feature-resolve-session-id-js"

# shellcheck source=/dev/null
. "$SUB_DIR/section-regression-priority-chain.sh"
# shellcheck source=/dev/null
. "$SUB_DIR/section-cc-session-title.sh"
# shellcheck source=/dev/null
. "$SUB_DIR/section-p7-cross-repo-guard.sh"
# shellcheck source=/dev/null
. "$SUB_DIR/section-p7-positive.sh"
# shellcheck source=/dev/null
. "$SUB_DIR/section-p7-fallback.sh"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
