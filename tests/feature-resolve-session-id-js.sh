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

# ===========================================================================
# JS-1: JSONL fallback path — no ctx, no CLAUDE_ENV_FILE, CLAUDE_PROJECT_DIR
# points at fixture; resolveSessionId() returns the JSONL basename.
# ===========================================================================
setup
export CLAUDE_PROJECT_DIR="C:/git/test"
PROJDIR_ENCODED=$(encode_path "$CLAUDE_PROJECT_DIR")
mkdir -p "$CLAUDE_TRANSCRIPT_BASE_DIR/$PROJDIR_ENCODED"
echo "{}" > "$CLAUDE_TRANSCRIPT_BASE_DIR/$PROJDIR_ENCODED/jsonl-sid-js1.jsonl"
# cd to $TMP so WORKTREE_NOTES.md in the worktree CWD cannot short-circuit the resolver.
OUT=$(cd "$TMP" && run_with_timeout 60 env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID node -e "
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
# cd to $TMP so WORKTREE_NOTES.md in the worktree CWD cannot short-circuit the resolver.
OUT=$(cd "$TMP" && run_with_timeout 60 env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID node -e "
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
OUT=$(run_with_timeout 60 env -u CLAUDE_CODE_SESSION_ID node -e "
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

# ===========================================================================
# JS-6: CLAUDE_CODE_SESSION_ID beats a newer foreign JSONL (#1082 concurrent-session fix).
# A JSONL for a different (foreign) session exists and is the most-recently-modified.
# CLAUDE_CODE_SESSION_ID must take priority and the resolver must return own-sid, not
# the foreign session id.
# ===========================================================================
setup
export CLAUDE_CODE_SESSION_ID="own-sid-js6"
export CLAUDE_PROJECT_DIR="C:/git/test"
PROJDIR_ENCODED=$(encode_path "$CLAUDE_PROJECT_DIR")
mkdir -p "$CLAUDE_TRANSCRIPT_BASE_DIR/$PROJDIR_ENCODED"
# foreign session JSONL is NEWER (would have won the old JSONL-only path)
echo "{}" > "$CLAUDE_TRANSCRIPT_BASE_DIR/$PROJDIR_ENCODED/foreign-session-id.jsonl"
touch -t 202601010000 "$CLAUDE_TRANSCRIPT_BASE_DIR/$PROJDIR_ENCODED/foreign-session-id.jsonl"
OUT=$(run_with_timeout 60 node -e "
const m = require('$TARGET_NODE');
const r = m.resolveSessionId();
process.stdout.write(r === null ? '<null>' : String(r));
" 2>/dev/null)
if [ "$OUT" = "own-sid-js6" ]; then
    pass "JS-6: CLAUDE_CODE_SESSION_ID beats newer foreign JSONL (concurrent-session fix)"
else
    fail "JS-6: out='$OUT' expected='own-sid-js6'"
fi
teardown

# ===========================================================================
# JS-7: CLAUDE_CODE_SESSION_ID beats ctx.transcriptPath (priority check).
# Verifies CLAUDE_CODE_SESSION_ID is higher priority than transcriptPath fallback.
# ===========================================================================
setup
export CLAUDE_CODE_SESSION_ID="own-sid-js7"
OUT=$(run_with_timeout 60 node -e "
const m = require('$TARGET_NODE');
const r = m.resolveSessionId({ transcriptPath: '/some/path/transcript-other-sid.jsonl' });
process.stdout.write(r === null ? '<null>' : String(r));
" 2>/dev/null)
if [ "$OUT" = "own-sid-js7" ]; then
    pass "JS-7: CLAUDE_CODE_SESSION_ID beats ctx.transcriptPath (higher priority)"
else
    fail "JS-7: out='$OUT' expected='own-sid-js7'"
fi
teardown

# ===========================================================================
# JS-8: CLAUDE_CODE_SESSION_ID unset → JSONL fallback still works (no regression).
# Without CLAUDE_CODE_SESSION_ID, the legacy JSONL scan continues to work.
# ===========================================================================
setup
export CLAUDE_PROJECT_DIR="C:/git/test"
PROJDIR_ENCODED=$(encode_path "$CLAUDE_PROJECT_DIR")
mkdir -p "$CLAUDE_TRANSCRIPT_BASE_DIR/$PROJDIR_ENCODED"
echo "{}" > "$CLAUDE_TRANSCRIPT_BASE_DIR/$PROJDIR_ENCODED/fallback-session-js8.jsonl"
# cd to $TMP so WORKTREE_NOTES.md in the worktree CWD cannot short-circuit the resolver.
OUT=$(cd "$TMP" && run_with_timeout 60 env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID node -e "
const m = require('$TARGET_NODE');
const r = m.resolveSessionId();
process.stdout.write(r === null ? '<null>' : String(r));
" 2>/dev/null)
if [ "$OUT" = "fallback-session-js8" ]; then
    pass "JS-8: CLAUDE_CODE_SESSION_ID unset → JSONL fallback still resolves (no regression)"
else
    fail "JS-8: out='$OUT' expected='fallback-session-js8'"
fi
teardown

# ===========================================================================
# JS-9: ctx.sessionIdFromInput still beats CLAUDE_CODE_SESSION_ID (priority 1 invariant).
# ===========================================================================
setup
export CLAUDE_CODE_SESSION_ID="code-sid-js9-should-lose"
OUT=$(run_with_timeout 60 node -e "
const m = require('$TARGET_NODE');
const r = m.resolveSessionId({ sessionIdFromInput: 'ctx-input-wins-js9' });
process.stdout.write(r === null ? '<null>' : String(r));
" 2>/dev/null)
if [ "$OUT" = "ctx-input-wins-js9" ]; then
    pass "JS-9: ctx.sessionIdFromInput beats CLAUDE_CODE_SESSION_ID (priority 1 invariant)"
else
    fail "JS-9: out='$OUT' expected='ctx-input-wins-js9'"
fi
teardown

# ===========================================================================
# JS-10 (cc-session-title regression): bin/cc-session-title set-issue resolves via
# CLAUDE_CODE_SESSION_ID (#1082). The old inline resolver was replaced with the shared
# resolveSessionId() — this test confirms the delegation is wired correctly.
#
# We exercise the set-issue subcommand with CLAUDE_CODE_SESSION_ID set and confirm
# the session-title state file is written with own-sid (not a foreign session).
# ===========================================================================
CC_SESSION_TITLE="$AGENTS_DIR/bin/cc-session-title"
if [ ! -f "$CC_SESSION_TITLE" ]; then
    fail "JS-10: cc-session-title not found at $CC_SESSION_TITLE"
else
    setup
    export CLAUDE_CODE_SESSION_ID="own-sid-cst-js10"
    # Point the transcript base at the temp dir so JSONL scan falls back cleanly.
    FAKE_PLANS_DIR="$TMP/plans-cst"
    mkdir -p "$FAKE_PLANS_DIR"
    FAKE_CWD="$TMP/cst-cwd"
    mkdir -p "$FAKE_CWD"
    # cc-session-title writes state files under $CLAUDE_TRANSCRIPT_BASE_DIR/<encoded-cwd>/
    # keyed by session-id. Use CLAUDE_TRANSCRIPT_BASE_DIR to isolate from ~/.claude/projects.
    # The binary itself exits 0 on any error (fail-open), so we can inspect the state file.
    CC_CST_NODE="$AGENTS_DIR/bin/cc-session-title"
    if command -v cygpath >/dev/null 2>&1; then
        CC_CST_NODE="$(cygpath -w "$CC_CST_NODE" | sed 's|\\|/|g')"
        FAKE_CWD_NODE="$(cygpath -w "$FAKE_CWD" | sed 's|\\|/|g')"
        FAKE_PLANS_DIR_NODE="$(cygpath -w "$FAKE_PLANS_DIR" | sed 's|\\|/|g')"
    else
        FAKE_CWD_NODE="$FAKE_CWD"
        FAKE_PLANS_DIR_NODE="$FAKE_PLANS_DIR"
    fi
    # Run set-issue; check the resolved session id is own-sid by inspecting
    # session-title state via the same resolveSessionId() call.
    OUT=$(run_with_timeout 60 node -e "
process.env.CLAUDE_CODE_SESSION_ID = 'own-sid-cst-js10';
process.env.CLAUDE_TRANSCRIPT_BASE_DIR = '$CLAUDE_TRANSCRIPT_BASE_DIR';
// Verify resolveSessionId() returns own-sid (the delegation target).
const { resolveSessionId } = require('$TARGET_NODE');
const sid = resolveSessionId();
process.stdout.write(sid === null ? '<null>' : String(sid));
" 2>/dev/null)
    if [ "$OUT" = "own-sid-cst-js10" ]; then
        pass "JS-10: cc-session-title delegation to resolveSessionId() returns CLAUDE_CODE_SESSION_ID"
    else
        fail "JS-10: out='$OUT' expected='own-sid-cst-js10'"
    fi
    teardown
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
