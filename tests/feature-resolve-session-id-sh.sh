#!/bin/bash
# Tests: bin/lib/codex-core.sh, bin/lib/gemini-core.sh, bin/lib/resolve-session-id.sh
# Tags: bin, codex, tests
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
    echo "Results: 0 passed, 14 failed"
    exit 1
fi

TMP=""

setup() {
    TMP="$(mktemp -d)"
    export CLAUDE_TRANSCRIPT_BASE_DIR="$TMP/transcripts"
    mkdir -p "$CLAUDE_TRANSCRIPT_BASE_DIR"
    unset CLAUDE_PROJECT_DIR CLAUDE_SESSION_ID CLAUDE_ENV_FILE CLAUDE_CODE_SESSION_ID 2>/dev/null || true
}

teardown() {
    if [ -n "${TMP:-}" ] && [ -d "$TMP" ]; then
        rm -rf "$TMP" 2>/dev/null || true
    fi
    TMP=""
    unset CLAUDE_TRANSCRIPT_BASE_DIR CLAUDE_PROJECT_DIR CLAUDE_SESSION_ID CLAUDE_ENV_FILE CLAUDE_CODE_SESSION_ID 2>/dev/null || true
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
        unset CLAUDE_SESSION_ID CLAUDE_ENV_FILE CLAUDE_CODE_SESSION_ID
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
        unset CLAUDE_SESSION_ID CLAUDE_ENV_FILE CLAUDE_CODE_SESSION_ID
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

# ===========================================================================
# B-8: encode_path_for_claude_projects backslash form (regression guard, GREEN pre-fix).
# 'C:\git\agents' → C(alnum), :(dash), \(dash), git, \(dash), agents → 'c--git-agents'.
# ===========================================================================
setup
OUT=$(bash -c "source '$HELPER' && encode_path_for_claude_projects 'C:\\git\\agents'" 2>/dev/null)
RC=$?
if [ "$RC" -eq 0 ] && [ "$OUT" = "c--git-agents" ]; then
    pass "B-8: encode_path_for_claude_projects backslash form -> c--git-agents"
else
    fail "B-8: rc=$RC out='$OUT' expected='c--git-agents'"
fi
teardown

# ===========================================================================
# B-9: encode_path_for_claude_projects canonical Windows form (regression guard, GREEN pre-fix).
# 'C:/git/agents' → C, :, /, git, /, agents → 'c--git-agents'.
# ===========================================================================
setup
OUT=$(bash -c "source '$HELPER' && encode_path_for_claude_projects 'C:/git/agents'" 2>/dev/null)
RC=$?
if [ "$RC" -eq 0 ] && [ "$OUT" = "c--git-agents" ]; then
    pass "B-9: encode_path_for_claude_projects C:/git/agents -> c--git-agents"
else
    fail "B-9: rc=$RC out='$OUT' expected='c--git-agents'"
fi
teardown

# ===========================================================================
# B-10: encode_path_for_claude_projects Git Bash POSIX form (actual regression, RED pre-fix).
# '/c/git/agents' must normalize to 'c--git-agents' to match Windows-form encoding.
# ===========================================================================
setup
OUT=$(bash -c "source '$HELPER' && encode_path_for_claude_projects '/c/git/agents'" 2>/dev/null)
RC=$?
if [ "$RC" -eq 0 ] && [ "$OUT" = "c--git-agents" ]; then
    pass "B-10: encode_path_for_claude_projects /c/git/agents -> c--git-agents"
else
    fail "B-10: rc=$RC out='$OUT' expected='c--git-agents' (RED pre-fix: /c/git/agents encodes to -c-git-agents without normalization)"
fi
teardown

# ===========================================================================
# B-11: encode_path_for_claude_projects trailing slash (RED pre-fix).
# 'c:/git/agents/' trailing slash must be stripped before encoding.
# ===========================================================================
setup
OUT=$(bash -c "source '$HELPER' && encode_path_for_claude_projects 'c:/git/agents/'" 2>/dev/null)
RC=$?
if [ "$RC" -eq 0 ] && [ "$OUT" = "c--git-agents" ]; then
    pass "B-11: encode_path_for_claude_projects c:/git/agents/ -> c--git-agents (trailing slash stripped)"
else
    fail "B-11: rc=$RC out='$OUT' expected='c--git-agents' (RED pre-fix: trailing slash produces c--git-agents-)"
fi
teardown

# ===========================================================================
# B-12: encode_path_for_claude_projects POSIX non-Windows path (regression guard, GREEN pre-fix).
# '/home/user/repo' → '-home-user-repo'. Leading dash expected; the Windows
# single-letter drive normalization must NOT fire on a multi-letter first segment.
# ===========================================================================
setup
OUT=$(bash -c "source '$HELPER' && encode_path_for_claude_projects '/home/user/repo'" 2>/dev/null)
RC=$?
if [ "$RC" -eq 0 ] && [ "$OUT" = "-home-user-repo" ]; then
    pass "B-12: encode_path_for_claude_projects /home/user/repo -> -home-user-repo (Windows normalization must NOT fire)"
else
    fail "B-12: rc=$RC out='$OUT' expected='-home-user-repo'"
fi
teardown

# ===========================================================================
# B-13: resolver-level integration test — RED pre-fix.
# CLAUDE_PROJECT_DIR is set to Git Bash POSIX form '/c/git/agents'; the encoder
# must normalize it to 'c--git-agents' to find the transcript directory.
# Also verifies newest-file-wins selection.
# ===========================================================================
setup
PROJDIR_ENCODED="c--git-agents"
mkdir -p "$CLAUDE_TRANSCRIPT_BASE_DIR/$PROJDIR_ENCODED"
echo '{}' > "$CLAUDE_TRANSCRIPT_BASE_DIR/$PROJDIR_ENCODED/sess-b13-old.jsonl"
touch -t 202401010000 "$CLAUDE_TRANSCRIPT_BASE_DIR/$PROJDIR_ENCODED/sess-b13-old.jsonl"
echo '{}' > "$CLAUDE_TRANSCRIPT_BASE_DIR/$PROJDIR_ENCODED/sess-519-test.jsonl"
touch -t 202601010000 "$CLAUDE_TRANSCRIPT_BASE_DIR/$PROJDIR_ENCODED/sess-519-test.jsonl"
OUT=$(bash -c "
    export CLAUDE_TRANSCRIPT_BASE_DIR='$CLAUDE_TRANSCRIPT_BASE_DIR'
    export CLAUDE_PROJECT_DIR='/c/git/agents'
    source '$HELPER'
    resolve_session_id_from_jsonl
" 2>/dev/null)
RC=$?
if [ "$RC" -eq 0 ] && [ "$OUT" = "sess-519-test" ]; then
    pass "B-13: resolve_session_id_from_jsonl with CLAUDE_PROJECT_DIR=/c/git/agents (POSIX) resolves to newest transcript"
else
    fail "B-13: rc=$RC out='$OUT' expected='sess-519-test' (RED pre-fix: /c/git/agents encodes to wrong dir name)"
fi
teardown

# ===========================================================================
# B-14: root-path no-crash guard.
# Root paths (/, C:/) are not valid project roots; their encoding is intentionally
# undefined. This test guards against crashes/hangs and empty stdout only.
# ===========================================================================
setup
RC14a=0
OUT14a=$(bash -c "source '$HELPER' && encode_path_for_claude_projects '/'" 2>/dev/null) || RC14a=$?
RC14b=0
OUT14b=$(bash -c "source '$HELPER' && encode_path_for_claude_projects 'C:/'" 2>/dev/null) || RC14b=$?
if [ "$RC14a" -eq 0 ] && [ -z "$OUT14a" ]; then
    fail "B-14: encode_path_for_claude_projects '/' produced empty output (must not produce empty)"
elif [ "$RC14b" -eq 0 ] && [ -z "$OUT14b" ]; then
    fail "B-14: encode_path_for_claude_projects 'C:/' produced empty output (must not produce empty)"
else
    pass "B-14: root-path inputs (/, C:/) do not crash or produce empty output (encoding undefined — crash/hang guard only)"
fi
teardown

WIP_SID_HELPER="$AGENTS_DIR/bin/github-issues/wip-state/session-id.sh"

# ===========================================================================
# B-15: resolve_session_id (wip-state/session-id.sh) — CLAUDE_CODE_SESSION_ID
# beats a newer foreign JSONL (concurrent-session fix, #1082).
# When CLAUDE_CODE_SESSION_ID=own-sid and a newer JSONL for a foreign session
# exists, the resolver must return own-sid.
# ===========================================================================
setup
if [ ! -f "$HELPER" ] || [ ! -f "$WIP_SID_HELPER" ]; then
    fail "B-15: $WIP_SID_HELPER not found"
else
    FAKE_CWD="$TMP/b15-cwd"
    mkdir -p "$FAKE_CWD"
    ENCODED=$(printf '%s' "$FAKE_CWD" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C sed 's/[^a-z0-9]/-/g')
    mkdir -p "$CLAUDE_TRANSCRIPT_BASE_DIR/$ENCODED"
    # A newer foreign session JSONL that the old code would return.
    echo "{}" > "$CLAUDE_TRANSCRIPT_BASE_DIR/$ENCODED/foreign-sid-b15.jsonl"
    touch -t 202601010000 "$CLAUDE_TRANSCRIPT_BASE_DIR/$ENCODED/foreign-sid-b15.jsonl"
    # Source resolve-session-id.sh first (provides resolve_session_id_from_jsonl),
    # then wip-state/session-id.sh (provides resolve_session_id).
    OUT=$(bash -c "
        unset CLAUDE_SESSION_ID CLAUDE_ENV_FILE
        export CLAUDE_CODE_SESSION_ID='own-sid-b15'
        export CLAUDE_TRANSCRIPT_BASE_DIR='$CLAUDE_TRANSCRIPT_BASE_DIR'
        cd '$FAKE_CWD'
        source '$HELPER'
        source '$WIP_SID_HELPER'
        resolve_session_id
    " 2>/dev/null)
    RC=$?
    if [ "$RC" -eq 0 ] && [ "$OUT" = "own-sid-b15" ]; then
        pass "B-15: resolve_session_id: CLAUDE_CODE_SESSION_ID beats newer foreign JSONL (concurrent-session fix)"
    else
        fail "B-15: rc=$RC out='$OUT' expected='own-sid-b15'"
    fi
fi
teardown

# ===========================================================================
# B-16: resolve_session_id (wip-state/session-id.sh) — CLAUDE_CODE_SESSION_ID
# unset → JSONL fallback still works (no regression for headless/CI).
# ===========================================================================
setup
if [ ! -f "$HELPER" ] || [ ! -f "$WIP_SID_HELPER" ]; then
    fail "B-16: $WIP_SID_HELPER not found"
else
    FAKE_CWD="$TMP/b16-cwd"
    mkdir -p "$FAKE_CWD"
    ENCODED=$(printf '%s' "$FAKE_CWD" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C sed 's/[^a-z0-9]/-/g')
    mkdir -p "$CLAUDE_TRANSCRIPT_BASE_DIR/$ENCODED"
    echo "{}" > "$CLAUDE_TRANSCRIPT_BASE_DIR/$ENCODED/headless-sid-b16.jsonl"
    touch -t 202601010000 "$CLAUDE_TRANSCRIPT_BASE_DIR/$ENCODED/headless-sid-b16.jsonl"
    OUT=$(bash -c "
        unset CLAUDE_SESSION_ID CLAUDE_ENV_FILE CLAUDE_CODE_SESSION_ID
        export CLAUDE_TRANSCRIPT_BASE_DIR='$CLAUDE_TRANSCRIPT_BASE_DIR'
        cd '$FAKE_CWD'
        source '$HELPER'
        source '$WIP_SID_HELPER'
        resolve_session_id
    " 2>/dev/null)
    RC=$?
    if [ "$RC" -eq 0 ] && [ "$OUT" = "headless-sid-b16" ]; then
        pass "B-16: resolve_session_id: CLAUDE_CODE_SESSION_ID unset → JSONL fallback no regression"
    else
        fail "B-16: rc=$RC out='$OUT' expected='headless-sid-b16'"
    fi
fi
teardown

# ===========================================================================
# B-17: codex_core_init SESSION_ID — CLAUDE_CODE_SESSION_ID beats newer foreign JSONL.
# codex-core.sh concurrent-session fix (#1082).
# ===========================================================================
setup
if [ ! -f "$CODEX_CORE" ]; then
    fail "B-17: $CODEX_CORE not found"
else
    FAKE_CWD="$TMP/b17-cwd"
    mkdir -p "$FAKE_CWD"
    ENCODED=$(printf '%s' "$FAKE_CWD" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C sed 's/[^a-z0-9]/-/g')
    mkdir -p "$CLAUDE_TRANSCRIPT_BASE_DIR/$ENCODED"
    echo "{}" > "$CLAUDE_TRANSCRIPT_BASE_DIR/$ENCODED/foreign-codex-b17.jsonl"
    touch -t 202601010000 "$CLAUDE_TRANSCRIPT_BASE_DIR/$ENCODED/foreign-codex-b17.jsonl"
    OUT=$(bash -c "
        unset CLAUDE_SESSION_ID CLAUDE_ENV_FILE
        export CLAUDE_CODE_SESSION_ID='own-codex-b17'
        export CLAUDE_TRANSCRIPT_BASE_DIR='$CLAUDE_TRANSCRIPT_BASE_DIR'
        export NO_LOG=true
        cd '$FAKE_CWD'
        source '$CODEX_CORE'
        codex_core_init 'test-label' >/dev/null 2>&1
        printf '%s' \"\$SESSION_ID\"
    " 2>/dev/null)
    if [ "$OUT" = "own-codex-b17" ]; then
        pass "B-17: codex_core_init: CLAUDE_CODE_SESSION_ID beats newer foreign JSONL"
    else
        fail "B-17: out='$OUT' expected='own-codex-b17'"
    fi
fi
teardown

# ===========================================================================
# B-18: gemini_core_init SESSION_ID — CLAUDE_CODE_SESSION_ID beats newer foreign JSONL.
# gemini-core.sh concurrent-session fix (#1082, byte-identical to codex).
# ===========================================================================
setup
if [ ! -f "$GEMINI_CORE" ]; then
    fail "B-18: $GEMINI_CORE not found"
else
    FAKE_CWD="$TMP/b18-cwd"
    mkdir -p "$FAKE_CWD"
    ENCODED=$(printf '%s' "$FAKE_CWD" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C sed 's/[^a-z0-9]/-/g')
    mkdir -p "$CLAUDE_TRANSCRIPT_BASE_DIR/$ENCODED"
    echo "{}" > "$CLAUDE_TRANSCRIPT_BASE_DIR/$ENCODED/foreign-gemini-b18.jsonl"
    touch -t 202601010000 "$CLAUDE_TRANSCRIPT_BASE_DIR/$ENCODED/foreign-gemini-b18.jsonl"
    OUT=$(bash -c "
        unset CLAUDE_SESSION_ID CLAUDE_ENV_FILE
        export CLAUDE_CODE_SESSION_ID='own-gemini-b18'
        export CLAUDE_TRANSCRIPT_BASE_DIR='$CLAUDE_TRANSCRIPT_BASE_DIR'
        export NO_LOG=true
        cd '$FAKE_CWD'
        source '$GEMINI_CORE'
        gemini_core_init 'test-label' >/dev/null 2>&1
        printf '%s' \"\$SESSION_ID\"
    " 2>/dev/null)
    if [ "$OUT" = "own-gemini-b18" ]; then
        pass "B-18: gemini_core_init: CLAUDE_CODE_SESSION_ID beats newer foreign JSONL"
    else
        fail "B-18: out='$OUT' expected='own-gemini-b18'"
    fi
fi
teardown

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
