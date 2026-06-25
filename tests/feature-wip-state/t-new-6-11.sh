
# ===========================================================================
# T-new-6: set <N> with CLAUDE_ENV_FILE absent + CLAUDE_SESSION_ID env → exit 0
# Regression for #440: VS Code Claude Code does not propagate CLAUDE_ENV_FILE
# to Bash subprocesses, but CLAUDE_SESSION_ID is exported directly.
# NOTE: setup_mock sets CLAUDE_ENV_FILE; we unset it here and restore it after
# the assertion. teardown_mock wipes $TMP so the restore path ($TMP/claude-env)
# will not exist, but the next setup_mock always overwrites CLAUDE_ENV_FILE
# with a fresh path — the restore is belt-and-suspenders only.
# ===========================================================================
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
SAVED_CLAUDE_ENV_FILE="${CLAUDE_ENV_FILE:-}"
unset CLAUDE_ENV_FILE
export CLAUDE_SESSION_ID="env-sid-fixture"
run_with_timeout 60 bash "$TARGET" set 42 >/dev/null 2>&1
RC=$?
EXPECTED_FP=$(printf '%s:%s' "env-sid-fixture" "42" | sha256sum | cut -c1-8)
if [ "$RC" -eq 0 ] && grep -q -- "--text $EXPECTED_FP" "$GH_MOCK_ARGS_LOG" 2>/dev/null; then
    pass "T-new-6: set <N> with CLAUDE_ENV_FILE absent + CLAUDE_SESSION_ID env → exit 0"
else
    fail "T-new-6: rc=$RC expected_fp=$EXPECTED_FP log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null)"
fi
unset CLAUDE_SESSION_ID
[ -n "$SAVED_CLAUDE_ENV_FILE" ] && export CLAUDE_ENV_FILE="$SAVED_CLAUDE_ENV_FILE"
teardown_mock

# ===========================================================================
# T-new-7: check <N> with CLAUDE_ENV_FILE absent + CLAUDE_SESSION_ID env → 'same'
# Same isolation note as T-new-6: CLAUDE_ENV_FILE temporarily unset, restored after assertion.
# ===========================================================================
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
export GH_MOCK_STATUS="In Progress"
SAVED_CLAUDE_ENV_FILE="${CLAUDE_ENV_FILE:-}"
unset CLAUDE_ENV_FILE
export CLAUDE_SESSION_ID="env-sid-fixture"
EXPECTED_FP=$(printf '%s:%s' "env-sid-fixture" "42" | sha256sum | cut -c1-8)
export GH_MOCK_FINGERPRINT="$EXPECTED_FP"
OUT=$(run_with_timeout 60 bash "$TARGET" check 42 2>/dev/null)
RC=$?
if [ "$RC" -eq 0 ] && [ "$OUT" = "same" ]; then
    pass "T-new-7: check <N> with CLAUDE_ENV_FILE absent + CLAUDE_SESSION_ID env → 'same'"
else
    fail "T-new-7: rc=$RC out='$OUT'"
fi
unset CLAUDE_SESSION_ID
[ -n "$SAVED_CLAUDE_ENV_FILE" ] && export CLAUDE_ENV_FILE="$SAVED_CLAUDE_ENV_FILE"
teardown_mock

# ===========================================================================
# T-new-8: clear <N> when fingerprint is already empty — "no changes to make"
# rc=1 from gh must NOT emit a spurious warning. Assertions:
#   (a) overall rc == 0
#   (b) "fingerprint clear failed" is absent from stderr
#   (c) "Status=Done set failed" is absent from stderr (real failure check)
#   (d) at least one --single-select-option-id call was logged (Status=Done write)
# ===========================================================================
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
# Override mock gh to simulate "no changes to make" for item-edit --text only;
# --single-select-option-id (Status set) still succeeds.
cat > "$TMP/mock-bin/gh" <<'MOCK_EOF'
#!/bin/bash
ARGS="$*"
if [ -n "${GH_MOCK_ARGS_LOG:-}" ]; then
    printf '%s\n' "$ARGS" >> "$GH_MOCK_ARGS_LOG"
fi
case "$ARGS" in
  issue\ view\ *--json\ state*)
    echo "CLOSED"
    exit 0 ;;
  auth\ status*) echo "Token scopes: 'project'"; exit 0 ;;
  repo\ view\ *) echo "${GH_MOCK_OWNER_REPO:-nirecom/agents}"; exit 0 ;;
  api\ graphql\ *) printf '%s\n' "${GH_MOCK_PROJECT_ITEM_ID:-PVTI_existing}"; exit 0 ;;
  project\ item-edit\ *--single-select-option-id*) exit 0 ;;
  project\ item-edit\ *--text*)
    echo "no changes to make for the item-edit" >&2
    exit 1
    ;;
  *) echo "MOCK GH: no match $ARGS" >&2; exit 2 ;;
esac
MOCK_EOF
chmod +x "$TMP/mock-bin/gh"
STDERR_FILE="$TMP/clear-stderr.log"
run_with_timeout 60 bash "$TARGET" clear 42 >/dev/null 2>"$STDERR_FILE"
RC=$?
WARN_FP_PRESENT=0
WARN_STATUS_PRESENT=0
SS_OPT_LOGGED=0
grep -q "fingerprint clear failed" "$STDERR_FILE" 2>/dev/null && WARN_FP_PRESENT=1
grep -q "Status=Done set failed" "$STDERR_FILE" 2>/dev/null && WARN_STATUS_PRESENT=1
grep -q -- "--single-select-option-id" "$GH_MOCK_ARGS_LOG" 2>/dev/null && SS_OPT_LOGGED=1
if [ "$RC" -eq 0 ] \
   && [ "$WARN_FP_PRESENT" -eq 0 ] \
   && [ "$WARN_STATUS_PRESENT" -eq 0 ] \
   && [ "$SS_OPT_LOGGED" -eq 1 ]; then
    pass "T-new-8: clear <N> on empty fingerprint — exit 0, no spurious warning, Status=Done set"
else
    fail "T-new-8: rc=$RC warn_fp=$WARN_FP_PRESENT warn_status=$WARN_STATUS_PRESENT ss_opt=$SS_OPT_LOGGED stderr=$(cat "$STDERR_FILE" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# T-new-8b: clear on OPEN issue — state-first guard skips Status=Done, only deletes lock.
# ===========================================================================
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
LOCKFILE="$PLANS_DIR/wip-lock-42.md"
echo "stale lock" > "$LOCKFILE"
cat > "$TMP/mock-bin/gh" <<'MOCK_EOF'
#!/bin/bash
ARGS="$*"
if [ -n "${GH_MOCK_ARGS_LOG:-}" ]; then
    printf '%s\n' "$ARGS" >> "$GH_MOCK_ARGS_LOG"
fi
case "$ARGS" in
  issue\ view\ *--json\ state*) echo "OPEN"; exit 0 ;;
  auth\ status*) echo "Token scopes: 'project'"; exit 0 ;;
  repo\ view\ *) echo "${GH_MOCK_OWNER_REPO:-nirecom/agents}"; exit 0 ;;
  api\ graphql\ *) printf '%s\n' "${GH_MOCK_PROJECT_ITEM_ID:-PVTI_existing}"; exit 0 ;;
  project\ item-edit\ *) exit 0 ;;
  *) echo "MOCK GH: no match $ARGS" >&2; exit 2 ;;
esac
MOCK_EOF
chmod +x "$TMP/mock-bin/gh"
run_with_timeout 60 bash "$TARGET" clear 42 >/dev/null 2>&1
RC=$?
LOCK_DELETED=0
[ ! -f "$LOCKFILE" ] && LOCK_DELETED=1
HAS_SS_OPT=0; grep -q -- "--single-select-option-id" "$GH_MOCK_ARGS_LOG" 2>/dev/null && HAS_SS_OPT=1
HAS_TEXT=0; grep -qE -- '--text ' "$GH_MOCK_ARGS_LOG" 2>/dev/null && HAS_TEXT=1
if [ "$RC" -eq 0 ] && [ "$LOCK_DELETED" -eq 1 ] && [ "$HAS_SS_OPT" -eq 0 ] && [ "$HAS_TEXT" -eq 0 ]; then
    pass "T-new-8b: clear on OPEN issue — lock deleted, Status=Done NOT called"
else
    fail "T-new-8b: rc=$RC lock_deleted=$LOCK_DELETED ss_opt=$HAS_SS_OPT text=$HAS_TEXT log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# T-new-8c: clear when gh fails in issue-state-check — treated as OPEN (guard skips).
# ===========================================================================
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
LOCKFILE="$PLANS_DIR/wip-lock-42.md"
echo "stale lock" > "$LOCKFILE"
cat > "$TMP/mock-bin/gh" <<'MOCK_EOF'
#!/bin/bash
ARGS="$*"
if [ -n "${GH_MOCK_ARGS_LOG:-}" ]; then
    printf '%s\n' "$ARGS" >> "$GH_MOCK_ARGS_LOG"
fi
case "$ARGS" in
  issue\ view\ *--json\ state*) exit 1 ;;
  auth\ status*) echo "Token scopes: 'project'"; exit 0 ;;
  repo\ view\ *) echo "${GH_MOCK_OWNER_REPO:-nirecom/agents}"; exit 0 ;;
  api\ graphql\ *) printf '%s\n' "${GH_MOCK_PROJECT_ITEM_ID:-PVTI_existing}"; exit 0 ;;
  project\ item-edit\ *) exit 0 ;;
  *) echo "MOCK GH: no match $ARGS" >&2; exit 2 ;;
esac
MOCK_EOF
chmod +x "$TMP/mock-bin/gh"
run_with_timeout 60 bash "$TARGET" clear 42 >/dev/null 2>&1
RC=$?
LOCK_DELETED=0
[ ! -f "$LOCKFILE" ] && LOCK_DELETED=1
HAS_SS_OPT=0; grep -q -- "--single-select-option-id" "$GH_MOCK_ARGS_LOG" 2>/dev/null && HAS_SS_OPT=1
if [ "$RC" -eq 0 ] && [ "$LOCK_DELETED" -eq 1 ] && [ "$HAS_SS_OPT" -eq 0 ]; then
    pass "T-new-8c: clear on gh-failure from state-check — lock deleted, Status=Done NOT called"
else
    fail "T-new-8c: rc=$RC lock_deleted=$LOCK_DELETED ss_opt=$HAS_SS_OPT log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# T-new-8d: clear on CLOSED issue — full path (Status=Done + fingerprint + lock).
# ===========================================================================
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
LOCKFILE="$PLANS_DIR/wip-lock-42.md"
echo "stale lock" > "$LOCKFILE"
cat > "$TMP/mock-bin/gh" <<'MOCK_EOF'
#!/bin/bash
ARGS="$*"
if [ -n "${GH_MOCK_ARGS_LOG:-}" ]; then
    printf '%s\n' "$ARGS" >> "$GH_MOCK_ARGS_LOG"
fi
case "$ARGS" in
  issue\ view\ *--json\ state*) echo "CLOSED"; exit 0 ;;
  auth\ status*) echo "Token scopes: 'project'"; exit 0 ;;
  repo\ view\ *) echo "${GH_MOCK_OWNER_REPO:-nirecom/agents}"; exit 0 ;;
  api\ graphql\ *) printf '%s\n' "${GH_MOCK_PROJECT_ITEM_ID:-PVTI_existing}"; exit 0 ;;
  project\ item-edit\ *) exit 0 ;;
  *) echo "MOCK GH: no match $ARGS" >&2; exit 2 ;;
esac
MOCK_EOF
chmod +x "$TMP/mock-bin/gh"
run_with_timeout 60 bash "$TARGET" clear 42 >/dev/null 2>&1
RC=$?
LOCK_DELETED=0
[ ! -f "$LOCKFILE" ] && LOCK_DELETED=1
HAS_SS_OPT=0; grep -q -- "--single-select-option-id" "$GH_MOCK_ARGS_LOG" 2>/dev/null && HAS_SS_OPT=1
HAS_TEXT=0; grep -qE -- '--text ' "$GH_MOCK_ARGS_LOG" 2>/dev/null && HAS_TEXT=1
if [ "$RC" -eq 0 ] && [ "$LOCK_DELETED" -eq 1 ] && [ "$HAS_SS_OPT" -ge 1 ] && [ "$HAS_TEXT" -ge 1 ]; then
    pass "T-new-8d: clear on CLOSED issue — full path, Status=Done called, fingerprint cleared, lock deleted"
else
    fail "T-new-8d: rc=$RC lock_deleted=$LOCK_DELETED ss_opt=$HAS_SS_OPT text=$HAS_TEXT log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# T-new-9: set <N> with JSONL transcript scan fallback (3rd resolution path).
# When CLAUDE_ENV_FILE / CLAUDE_SESSION_ID / CLAUDE_PROJECT_DIR are all unset,
# the helper scans $CLAUDE_TRANSCRIPT_BASE_DIR/<pwd-encoded>/*.jsonl and uses
# the basename (sans .jsonl) of the mtime-newest entry as the session-id.
# ===========================================================================
setup_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
SAVED_CLAUDE_ENV_FILE="${CLAUDE_ENV_FILE:-}"
unset CLAUDE_ENV_FILE
unset CLAUDE_SESSION_ID
unset CLAUDE_CODE_SESSION_ID
unset CLAUDE_PROJECT_DIR
export CLAUDE_TRANSCRIPT_BASE_DIR="$TMP/transcripts"
FAKE_CWD="$TMP/fake-cwd"
mkdir -p "$FAKE_CWD"
ENCODED_CWD=$(printf '%s' "$FAKE_CWD" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C sed 's/[^a-z0-9]/-/g')
mkdir -p "$CLAUDE_TRANSCRIPT_BASE_DIR/$ENCODED_CWD"
# Create older JSONL first, then newer.
echo "{}" > "$CLAUDE_TRANSCRIPT_BASE_DIR/$ENCODED_CWD/older-session-id.jsonl"
touch -t 202001010000 "$CLAUDE_TRANSCRIPT_BASE_DIR/$ENCODED_CWD/older-session-id.jsonl"
echo "{}" > "$CLAUDE_TRANSCRIPT_BASE_DIR/$ENCODED_CWD/newer-session-id.jsonl"
touch -t 202601010000 "$CLAUDE_TRANSCRIPT_BASE_DIR/$ENCODED_CWD/newer-session-id.jsonl"
EXPECTED_FP=$(printf '%s:%s' "newer-session-id" "42" | sha256sum | cut -c1-8)
( cd "$FAKE_CWD" && run_with_timeout 60 bash "$TARGET" set 42 >/dev/null 2>&1 )
RC=$?
if [ "$RC" -eq 0 ] && grep -q -- "--text $EXPECTED_FP" "$GH_MOCK_ARGS_LOG" 2>/dev/null; then
    pass "T-new-9: set <N> resolves session-id via JSONL transcript scan (newest by mtime)"
else
    fail "T-new-9: rc=$RC expected_fp=$EXPECTED_FP log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null)"
fi
unset CLAUDE_TRANSCRIPT_BASE_DIR
[ -n "$SAVED_CLAUDE_ENV_FILE" ] && export CLAUDE_ENV_FILE="$SAVED_CLAUDE_ENV_FILE"
teardown_mock

# ===========================================================================
# T-new-10: set <N> with no JSONL fixtures (empty transcript base dir) → exit 2.
# When all 3 resolution paths fail, helper must exit 2 (session-id unresolvable).
# ===========================================================================
setup_mock
SAVED_CLAUDE_ENV_FILE="${CLAUDE_ENV_FILE:-}"
unset CLAUDE_ENV_FILE
unset CLAUDE_SESSION_ID
unset CLAUDE_CODE_SESSION_ID
unset CLAUDE_PROJECT_DIR
export CLAUDE_TRANSCRIPT_BASE_DIR="$TMP/transcripts-empty"
mkdir -p "$CLAUDE_TRANSCRIPT_BASE_DIR"
FAKE_CWD="$TMP/fake-cwd-empty"
mkdir -p "$FAKE_CWD"
( cd "$FAKE_CWD" && run_with_timeout 60 bash "$TARGET" set 42 >/dev/null 2>&1 )
RC=$?
if [ "$RC" -eq 2 ]; then
    pass "T-new-10: set <N> with no JSONL dir → exit 2"
else
    fail "T-new-10: expected exit 2, got rc=$RC"
fi
unset CLAUDE_TRANSCRIPT_BASE_DIR
[ -n "$SAVED_CLAUDE_ENV_FILE" ] && export CLAUDE_ENV_FILE="$SAVED_CLAUDE_ENV_FILE"
teardown_mock

# ===========================================================================
# T-new-11: CLAUDE_PROJECT_DIR encoding wins over pwd encoding.
# When CLAUDE_PROJECT_DIR is set, its encoded form is the primary candidate
# for the JSONL scan — pwd-encoded dir is only tried as a fallback.
# ===========================================================================
setup_mock
SAVED_CLAUDE_ENV_FILE="${CLAUDE_ENV_FILE:-}"
unset CLAUDE_ENV_FILE
unset CLAUDE_SESSION_ID
unset CLAUDE_CODE_SESSION_ID
export CLAUDE_TRANSCRIPT_BASE_DIR="$TMP/transcripts-projdir"
mkdir -p "$CLAUDE_TRANSCRIPT_BASE_DIR"
# Set a synthetic CC-native path; encode via same algorithm.
export CLAUDE_PROJECT_DIR="C:/git/test"
PROJDIR_ENCODED=$(printf '%s' "$CLAUDE_PROJECT_DIR" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C sed 's/[^a-z0-9]/-/g')
# Only the projdir-encoded dir exists — NO pwd-encoded dir.
mkdir -p "$CLAUDE_TRANSCRIPT_BASE_DIR/$PROJDIR_ENCODED"
echo "{}" > "$CLAUDE_TRANSCRIPT_BASE_DIR/$PROJDIR_ENCODED/win-session-id.jsonl"
touch -t 202601010000 "$CLAUDE_TRANSCRIPT_BASE_DIR/$PROJDIR_ENCODED/win-session-id.jsonl"
# Run from a DIFFERENT cwd whose encoding does NOT match.
FAKE_CWD="$TMP/other-cwd-projdir"
mkdir -p "$FAKE_CWD"
EXPECTED_FP=$(printf '%s:%s' "win-session-id" "99" | sha256sum | cut -c1-8)
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
( cd "$FAKE_CWD" && run_with_timeout 60 bash "$TARGET" set 99 >/dev/null 2>&1 )
RC=$?
if [ "$RC" -eq 0 ] && grep -q -- "--text $EXPECTED_FP" "$GH_MOCK_ARGS_LOG" 2>/dev/null; then
    pass "T-new-11: CLAUDE_PROJECT_DIR encoding wins over pwd encoding"
else
    fail "T-new-11: rc=$RC expected_fp=$EXPECTED_FP log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null)"
fi
unset CLAUDE_TRANSCRIPT_BASE_DIR CLAUDE_PROJECT_DIR
[ -n "$SAVED_CLAUDE_ENV_FILE" ] && export CLAUDE_ENV_FILE="$SAVED_CLAUDE_ENV_FILE"
teardown_mock
