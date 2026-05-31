#!/bin/bash
# Tests: hooks/lib/workflow-state.js
# Tags: workflow, hook, bin, windows, tests
# Tests for resolveSessionId() in hooks/lib/workflow-state.js — Issue #519.
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
    unset CLAUDE_PROJECT_DIR CLAUDE_ENV_FILE 2>/dev/null || true
}
teardown() {
    if [ -n "${TMP:-}" ] && [ -d "$TMP" ]; then
        rm -rf "$TMP" 2>/dev/null || true
    fi
    TMP=""
    unset CLAUDE_TRANSCRIPT_BASE_DIR CLAUDE_PROJECT_DIR CLAUDE_ENV_FILE 2>/dev/null || true
}

# Encoding helper for JS-1: CC-native encoding via shell to match the helper.
encode_path() {
    printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C sed 's/[^a-z0-9]/-/g'
}

# ===========================================================================
# JS-1: JSONL fallback path — no ctx, no CLAUDE_ENV_FILE, CLAUDE_PROJECT_DIR
# points at fixture; resolveSessionId() returns the JSONL basename.
# ===========================================================================
setup
export CLAUDE_PROJECT_DIR="C:/git/test"
PROJDIR_ENCODED=$(encode_path "$CLAUDE_PROJECT_DIR")
mkdir -p "$CLAUDE_TRANSCRIPT_BASE_DIR/$PROJDIR_ENCODED"
echo "{}" > "$CLAUDE_TRANSCRIPT_BASE_DIR/$PROJDIR_ENCODED/jsonl-sid-js1.jsonl"
OUT=$(run_with_timeout 60 node -e "
const m = require('$TARGET_NODE');
const r = m.resolveSessionId();
process.stdout.write(r === null ? '<null>' : String(r));
" 2>/dev/null)
if [ "$OUT" = "jsonl-sid-js1" ]; then
    pass "JS-1: resolveSessionId falls through to JSONL scan when prior paths fail"
else
    fail "JS-1: out='$OUT' expected='jsonl-sid-js1'"
fi
teardown

# ===========================================================================
# JS-2: No JSONL dir → returns null.
# ===========================================================================
setup
export CLAUDE_PROJECT_DIR="C:/git/no-such-dir"
# Do not create the encoded subdir.
OUT=$(run_with_timeout 60 node -e "
const m = require('$TARGET_NODE');
const r = m.resolveSessionId();
process.stdout.write(r === null ? '<null>' : String(r));
" 2>/dev/null)
if [ "$OUT" = "<null>" ]; then
    pass "JS-2: resolveSessionId returns null when no JSONL fixture exists"
else
    fail "JS-2: out='$OUT' expected='<null>'"
fi
teardown

# ===========================================================================
# JS-3: ctx.sessionIdFromInput wins (priority 1 — regression guard).
# ===========================================================================
setup
export CLAUDE_PROJECT_DIR="C:/git/test"
PROJDIR_ENCODED=$(encode_path "$CLAUDE_PROJECT_DIR")
mkdir -p "$CLAUDE_TRANSCRIPT_BASE_DIR/$PROJDIR_ENCODED"
echo "{}" > "$CLAUDE_TRANSCRIPT_BASE_DIR/$PROJDIR_ENCODED/jsonl-loser.jsonl"
OUT=$(run_with_timeout 60 node -e "
const m = require('$TARGET_NODE');
const r = m.resolveSessionId({ sessionIdFromInput: 'ctx-sid-wins' });
process.stdout.write(r === null ? '<null>' : String(r));
" 2>/dev/null)
if [ "$OUT" = "ctx-sid-wins" ]; then
    pass "JS-3: ctx.sessionIdFromInput beats JSONL scan (priority 1 invariant)"
else
    fail "JS-3: out='$OUT' expected='ctx-sid-wins'"
fi
teardown

# ===========================================================================
# JS-4: ctx.transcriptPath wins over JSONL (priority 3 invariant).
# ===========================================================================
setup
export CLAUDE_PROJECT_DIR="C:/git/test"
PROJDIR_ENCODED=$(encode_path "$CLAUDE_PROJECT_DIR")
mkdir -p "$CLAUDE_TRANSCRIPT_BASE_DIR/$PROJDIR_ENCODED"
echo "{}" > "$CLAUDE_TRANSCRIPT_BASE_DIR/$PROJDIR_ENCODED/jsonl-loser.jsonl"
OUT=$(run_with_timeout 60 node -e "
const m = require('$TARGET_NODE');
const r = m.resolveSessionId({ transcriptPath: '/some/path/transcript-sid-wins.jsonl' });
process.stdout.write(r === null ? '<null>' : String(r));
" 2>/dev/null)
if [ "$OUT" = "transcript-sid-wins" ]; then
    pass "JS-4: ctx.transcriptPath beats JSONL scan (priority 3 invariant)"
else
    fail "JS-4: out='$OUT' expected='transcript-sid-wins'"
fi
teardown

# ===========================================================================
# JS-5: CLAUDE_ENV_FILE wins over JSONL (priority 2 invariant).
# ===========================================================================
setup
ENV_FILE="$TMP/claude-env-js5"
echo "CLAUDE_SESSION_ID=env-file-sid-wins" > "$ENV_FILE"
export CLAUDE_ENV_FILE="$ENV_FILE"
export CLAUDE_PROJECT_DIR="C:/git/test"
PROJDIR_ENCODED=$(encode_path "$CLAUDE_PROJECT_DIR")
mkdir -p "$CLAUDE_TRANSCRIPT_BASE_DIR/$PROJDIR_ENCODED"
echo "{}" > "$CLAUDE_TRANSCRIPT_BASE_DIR/$PROJDIR_ENCODED/jsonl-loser.jsonl"
OUT=$(run_with_timeout 60 node -e "
const m = require('$TARGET_NODE');
const r = m.resolveSessionId();
process.stdout.write(r === null ? '<null>' : String(r));
" 2>/dev/null)
if [ "$OUT" = "env-file-sid-wins" ]; then
    pass "JS-5: CLAUDE_ENV_FILE beats JSONL scan (priority 2 invariant)"
else
    fail "JS-5: out='$OUT' expected='env-file-sid-wins'"
fi
teardown

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
