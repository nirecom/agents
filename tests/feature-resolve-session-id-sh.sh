#!/bin/bash
# Tests for bin/lib/resolve-session-id.sh — Issue #519 JSONL transcript scan fallback.
#
# Helper provides three functions:
#   - encode_path_for_claude_projects(path) — emits CC-native encoded basename
#   - _scan_one_transcript_dir(dir) — emits mtime-newest *.jsonl basename (sans .jsonl)
#       Rejects unsafe basenames (containing chars outside [A-Za-z0-9_-]).
#   - resolve_session_id_from_jsonl() — tries CLAUDE_PROJECT_DIR first, then pwd
#
# All tests isolate via $CLAUDE_TRANSCRIPT_BASE_DIR — never touch ~/.claude/projects.
# RED: this suite fails clean while bin/lib/resolve-session-id.sh is missing.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$AGENTS_DIR/bin/lib/resolve-session-id.sh"
CODEX_CORE="$AGENTS_DIR/bin/lib/codex-core.sh"
GEMINI_CORE="$AGENTS_DIR/bin/lib/gemini-core.sh"

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

# Early-exit: if the helper is missing, report cleanly with all-RED counts.
if [ ! -f "$HELPER" ]; then
    echo "FAIL: bin/lib/resolve-session-id.sh not found (implementation missing — tests are RED)"
    echo ""
    echo "Results: 0 passed, 7 failed"
    exit 1
fi

TMP=""

setup() {
    TMP="$(mktemp -d)"
    export CLAUDE_TRANSCRIPT_BASE_DIR="$TMP/transcripts"
    mkdir -p "$CLAUDE_TRANSCRIPT_BASE_DIR"
    unset CLAUDE_PROJECT_DIR CLAUDE_SESSION_ID CLAUDE_ENV_FILE 2>/dev/null || true
}

teardown() {
    if [ -n "${TMP:-}" ] && [ -d "$TMP" ]; then
        rm -rf "$TMP" 2>/dev/null || true
    fi
    TMP=""
    unset CLAUDE_TRANSCRIPT_BASE_DIR CLAUDE_PROJECT_DIR CLAUDE_SESSION_ID CLAUDE_ENV_FILE 2>/dev/null || true
}

# ===========================================================================
# B-1: _scan_one_transcript_dir returns mtime-newest *.jsonl basename.
# ===========================================================================
setup
DIR="$CLAUDE_TRANSCRIPT_BASE_DIR/some-encoded-cwd"
mkdir -p "$DIR"
echo "{}" > "$DIR/older-sid.jsonl"
touch -t 202001010000 "$DIR/older-sid.jsonl"
echo "{}" > "$DIR/newer-sid.jsonl"
touch -t 202601010000 "$DIR/newer-sid.jsonl"
OUT=$(bash -c "source '$HELPER' && _scan_one_transcript_dir '$DIR'" 2>/dev/null)
RC=$?
if [ "$RC" -eq 0 ] && [ "$OUT" = "newer-sid" ]; then
    pass "B-1: _scan_one_transcript_dir returns mtime-newest basename"
else
    fail "B-1: rc=$RC out='$OUT' expected='newer-sid'"
fi
teardown

# ===========================================================================
# B-2: resolve_session_id_from_jsonl with CLAUDE_PROJECT_DIR set → uses that.
# ===========================================================================
setup
export CLAUDE_PROJECT_DIR="C:/git/test"
PROJDIR_ENCODED=$(printf '%s' "$CLAUDE_PROJECT_DIR" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C sed 's/[^a-z0-9]/-/g')
mkdir -p "$CLAUDE_TRANSCRIPT_BASE_DIR/$PROJDIR_ENCODED"
echo "{}" > "$CLAUDE_TRANSCRIPT_BASE_DIR/$PROJDIR_ENCODED/proj-session-id.jsonl"
touch -t 202601010000 "$CLAUDE_TRANSCRIPT_BASE_DIR/$PROJDIR_ENCODED/proj-session-id.jsonl"
OUT=$(bash -c "export CLAUDE_TRANSCRIPT_BASE_DIR='$CLAUDE_TRANSCRIPT_BASE_DIR'; export CLAUDE_PROJECT_DIR='$CLAUDE_PROJECT_DIR'; source '$HELPER' && resolve_session_id_from_jsonl" 2>/dev/null)
RC=$?
if [ "$RC" -eq 0 ] && [ "$OUT" = "proj-session-id" ]; then
    pass "B-2: resolve_session_id_from_jsonl uses CLAUDE_PROJECT_DIR encoding"
else
    fail "B-2: rc=$RC out='$OUT' expected='proj-session-id'"
fi
teardown

# ===========================================================================
# B-3: resolve_session_id_from_jsonl with no CLAUDE_PROJECT_DIR → uses pwd.
# ===========================================================================
setup
FAKE_CWD="$TMP/fake-cwd-b3"
mkdir -p "$FAKE_CWD"
ENCODED=$(printf '%s' "$FAKE_CWD" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C sed 's/[^a-z0-9]/-/g')
mkdir -p "$CLAUDE_TRANSCRIPT_BASE_DIR/$ENCODED"
echo "{}" > "$CLAUDE_TRANSCRIPT_BASE_DIR/$ENCODED/pwd-session-id.jsonl"
touch -t 202601010000 "$CLAUDE_TRANSCRIPT_BASE_DIR/$ENCODED/pwd-session-id.jsonl"
OUT=$(bash -c "export CLAUDE_TRANSCRIPT_BASE_DIR='$CLAUDE_TRANSCRIPT_BASE_DIR'; cd '$FAKE_CWD' && source '$HELPER' && resolve_session_id_from_jsonl" 2>/dev/null)
RC=$?
if [ "$RC" -eq 0 ] && [ "$OUT" = "pwd-session-id" ]; then
    pass "B-3: resolve_session_id_from_jsonl falls back to pwd encoding"
else
    fail "B-3: rc=$RC out='$OUT' expected='pwd-session-id'"
fi
teardown

# ===========================================================================
# B-4: resolve_session_id_from_jsonl with no candidates → exit 1.
# ===========================================================================
setup
FAKE_CWD="$TMP/empty-cwd"
mkdir -p "$FAKE_CWD"
# CLAUDE_TRANSCRIPT_BASE_DIR exists but has no encoded subdirs.
OUT=$(bash -c "export CLAUDE_TRANSCRIPT_BASE_DIR='$CLAUDE_TRANSCRIPT_BASE_DIR'; cd '$FAKE_CWD' && source '$HELPER' && resolve_session_id_from_jsonl" 2>/dev/null)
RC=$?
if [ "$RC" -ne 0 ] && [ -z "$OUT" ]; then
    pass "B-4: resolve_session_id_from_jsonl with no candidates → non-zero exit, empty stdout"
else
    fail "B-4: rc=$RC out='$OUT' (expected non-zero rc, empty out)"
fi
teardown

# ===========================================================================
# B-5: _scan_one_transcript_dir rejects unsafe basename (contains '.' / '/').
# A file like 'bad.name.jsonl' would yield basename 'bad.name' which contains
# a '.' and must be rejected by the [A-Za-z0-9_-]+ filter.
# ===========================================================================
setup
DIR="$CLAUDE_TRANSCRIPT_BASE_DIR/unsafe-dir"
mkdir -p "$DIR"
echo "{}" > "$DIR/bad.name.jsonl"
touch -t 202601010000 "$DIR/bad.name.jsonl"
OUT=$(bash -c "source '$HELPER' && _scan_one_transcript_dir '$DIR'" 2>/dev/null)
RC=$?
# Either non-zero rc or empty out is acceptable rejection.
if [ -z "$OUT" ] || [ "$RC" -ne 0 ]; then
    pass "B-5: _scan_one_transcript_dir rejects unsafe basename ('bad.name')"
else
    fail "B-5: unsafe basename should be rejected; got rc=$RC out='$OUT'"
fi
teardown

# ===========================================================================
# B-6: codex-core.sh SESSION_ID falls through to JSONL when CLAUDE_SESSION_ID
# and CLAUDE_ENV_FILE are unset.
# ===========================================================================
setup
if [ ! -f "$CODEX_CORE" ]; then
    fail "B-6: $CODEX_CORE not found"
else
    FAKE_CWD="$TMP/b6-cwd"
    mkdir -p "$FAKE_CWD"
    ENCODED=$(printf '%s' "$FAKE_CWD" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C sed 's/[^a-z0-9]/-/g')
    mkdir -p "$CLAUDE_TRANSCRIPT_BASE_DIR/$ENCODED"
    echo "{}" > "$CLAUDE_TRANSCRIPT_BASE_DIR/$ENCODED/codex-jsonl-sid.jsonl"
    touch -t 202601010000 "$CLAUDE_TRANSCRIPT_BASE_DIR/$ENCODED/codex-jsonl-sid.jsonl"
    OUT=$(bash -c "
        unset CLAUDE_SESSION_ID CLAUDE_ENV_FILE
        export CLAUDE_TRANSCRIPT_BASE_DIR='$CLAUDE_TRANSCRIPT_BASE_DIR'
        cd '$FAKE_CWD'
        source '$CODEX_CORE'
        codex_core_init 'test-label' >/dev/null 2>&1
        printf '%s' \"\$SESSION_ID\"
    " 2>/dev/null)
    if [ "$OUT" = "codex-jsonl-sid" ]; then
        pass "B-6: codex_core_init SESSION_ID resolves via JSONL scan when CLAUDE_SESSION_ID/CLAUDE_ENV_FILE absent"
    else
        fail "B-6: out='$OUT' expected='codex-jsonl-sid'"
    fi
fi
teardown

# ===========================================================================
# B-7: gemini-core.sh symmetric to B-6.
# ===========================================================================
setup
if [ ! -f "$GEMINI_CORE" ]; then
    fail "B-7: $GEMINI_CORE not found"
else
    FAKE_CWD="$TMP/b7-cwd"
    mkdir -p "$FAKE_CWD"
    ENCODED=$(printf '%s' "$FAKE_CWD" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C sed 's/[^a-z0-9]/-/g')
    mkdir -p "$CLAUDE_TRANSCRIPT_BASE_DIR/$ENCODED"
    echo "{}" > "$CLAUDE_TRANSCRIPT_BASE_DIR/$ENCODED/gemini-jsonl-sid.jsonl"
    touch -t 202601010000 "$CLAUDE_TRANSCRIPT_BASE_DIR/$ENCODED/gemini-jsonl-sid.jsonl"
    OUT=$(bash -c "
        unset CLAUDE_SESSION_ID CLAUDE_ENV_FILE
        export CLAUDE_TRANSCRIPT_BASE_DIR='$CLAUDE_TRANSCRIPT_BASE_DIR'
        cd '$FAKE_CWD'
        source '$GEMINI_CORE'
        gemini_core_init 'test-label' >/dev/null 2>&1
        printf '%s' \"\$SESSION_ID\"
    " 2>/dev/null)
    if [ "$OUT" = "gemini-jsonl-sid" ]; then
        pass "B-7: gemini_core_init SESSION_ID resolves via JSONL scan when CLAUDE_SESSION_ID/CLAUDE_ENV_FILE absent"
    else
        fail "B-7: out='$OUT' expected='gemini-jsonl-sid'"
    fi
fi
teardown

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
