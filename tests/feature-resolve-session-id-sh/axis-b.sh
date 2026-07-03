# axis-b.sh — Axis B: Security cases (B-22)
# Sourced by feature-resolve-session-id-sh.sh; inherits all globals and helpers.

# ===========================================================================
# B-22: isSameGitRepo blocks P7 scan for a real foreign git repo (security).
# git init a foreign repo in temp, run bridge from it — must rc=2, no stdout.
# Guard: if git init fails, fail the case with a clear message.
# ===========================================================================
setup
FOREIGN_REPO="$TMP/b22-foreign-repo"
mkdir -p "$FOREIGN_REPO"
GIT_INIT_RC=0
git init "$FOREIGN_REPO" >/dev/null 2>&1 || GIT_INIT_RC=$?
if [ "$GIT_INIT_RC" -ne 0 ]; then
    fail "B-22: git init failed (rc=$GIT_INIT_RC) — cannot test isSameGitRepo security gate"
else
    # Encode the foreign repo path and put a JSONL there to tempt the scanner.
    ENCODED=$(enc "$FOREIGN_REPO")
    mk_jsonl "$CLAUDE_TRANSCRIPT_BASE_DIR/$ENCODED" "foreign-repo-sid-b22"
    OUT=$(bash -c "
        unset CLAUDE_SESSION_ID CLAUDE_ENV_FILE CLAUDE_CODE_SESSION_ID
        export CLAUDE_TRANSCRIPT_BASE_DIR='$CLAUDE_TRANSCRIPT_BASE_DIR'
        export AGENTS_CONFIG_DIR='$AGENTS_DIR'
        cd '$FOREIGN_REPO'
        bash '$BRIDGE' 2>/dev/null
    " 2>/dev/null)
    RC=$?
    if [ "$RC" -eq 2 ] && [ -z "$OUT" ]; then
        pass "B-22: isSameGitRepo blocks P7 JSONL scan from foreign git repo (rc=2, empty stdout)"
    else
        fail "B-22: rc=$RC out='$OUT' — expected rc=2 + empty stdout from foreign repo"
    fi
fi
teardown
