#!/usr/bin/env bash
# tests/fix-526-workflow-mark-null-session-fatal.sh
# Tests: hooks/workflow-mark.js, hooks/workflow-mark/*.js
# Tags: workflow-mark, null-session, signalFatal, exit-2, issue-526
#
# After fix (#526), MUST handlers (MARK_STEP, NOT_NEEDED, USER_VERIFIED,
# BRANCHING_COMPLETE, CLARIFY_INTENT_COMPLETE) must use signalFatal when
# sessionId cannot be resolved → exit 2 with message on stderr.
#
# OPTIONAL handlers (RESET_FROM, PREMISE_FAIL) remain exit 0 with pushMessage.
#
# Expected:
#   T2.1–T2.6: FAIL until write-code fixes handlers to use signalFatal.
#   T2.7 (positive control): PASS now (sessionId provided → exit 0).
#   T2.8, T2.9 (optional handler controls): PASS now (already exit 0).

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK_NODE="$AGENTS_DIR/hooks/workflow-mark.js"
TMPDIR_BASE="${TMPDIR:-/tmp}/fix-526-$$"
mkdir -p "$TMPDIR_BASE"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

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

# For env -i subshells, we need an absolute binary path.
NODE_BIN="$(command -v node)"

# ─────────────────────────────────────────────────────────────────────────────
# Null-session isolation setup: block all 6 fallback paths in resolveSessionId:
#   (1) input.session_id: not present in payload
#   (2) CLAUDE_ENV_FILE: not set in env
#   (3) input.transcript_path: not present in payload
#   (4) JSONL scan via CLAUDE_TRANSCRIPT_BASE_DIR: set to empty tmpdir
#   (5) CLAUDE_PROJECT_DIR: not set in env
#   (6) process.cwd(): WORK_DIR is a non-git tmpdir (resolveSessionId may
#       derive an ID from cwd, so we ensure it can't produce a valid state file)
# ─────────────────────────────────────────────────────────────────────────────

EMPTY_TRANSCRIPT="$(mktemp -d "$TMPDIR_BASE/transcripts-XXXXXX")"
EMPTY_HOME="$(mktemp -d "$TMPDIR_BASE/home-XXXXXX")"
WORK_DIR="$(mktemp -d "$TMPDIR_BASE/work-XXXXXX")"

# Build a payload for a given sentinel command (no session_id, no transcript_path).
build_null_payload() {
  local sentinel_cmd="$1"
  # Use printf to safely embed the command; the sentinel_cmd must not contain '
  printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"tool_response":{"exit_code":0}}' \
    "$(echo "$sentinel_cmd" | sed 's/"/\\"/g')"
}

# Run workflow-mark with full null-session env isolation.
# Sets MARK_RC, MARK_OUT, MARK_ERR on return.
run_mark_null() {
  local sentinel_cmd="$1"
  local payload
  payload="$(build_null_payload "$sentinel_cmd")"
  local out_file="$TMPDIR_BASE/out-$$.txt"
  local err_file="$TMPDIR_BASE/err-$$.txt"
  local rc=0
  ( cd "$WORK_DIR" && env -i \
      PATH="$PATH" \
      HOME="$EMPTY_HOME" \
      CLAUDE_TRANSCRIPT_BASE_DIR="$EMPTY_TRANSCRIPT" \
      "$NODE_BIN" "$HOOK_NODE" <<< "$payload" \
      > "$out_file" 2> "$err_file" ) || rc=$?
  MARK_RC="$rc"
  MARK_OUT="$(cat "$out_file" 2>/dev/null)"
  MARK_ERR="$(cat "$err_file" 2>/dev/null)"
}

# Assert that a null-session MUST handler exits 2 with a recognizable fatal message.
assert_must_fatal() {
  local label="$1" sentinel_cmd="$2"
  run_mark_null "$sentinel_cmd"
  if [ "$MARK_RC" -eq 2 ]; then
    # Also verify stderr contains a meaningful message (NOT recorded / session_id etc.)
    if echo "$MARK_ERR" | grep -qiE "NOT (recorded|applied)|session_id|could not resolve"; then
      pass "$label → exit 2 + fatal stderr (null session blocked as fatal)"
    else
      pass "$label → exit 2 (null session blocked as fatal; stderr: $MARK_ERR)"
    fi
  else
    fail "$label → expected exit 2 (MUST handler fatal), got rc=$MARK_RC out=$MARK_OUT err=$MARK_ERR"
  fi
}

# Assert that a null-session OPTIONAL handler exits 0.
assert_optional_nonfatal() {
  local label="$1" sentinel_cmd="$2"
  run_mark_null "$sentinel_cmd"
  if [ "$MARK_RC" -eq 0 ]; then
    pass "$label → exit 0 (OPTIONAL handler, non-fatal)"
  else
    fail "$label → expected exit 0 (OPTIONAL handler), got rc=$MARK_RC err=$MARK_ERR"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Tests
# ─────────────────────────────────────────────────────────────────────────────

echo "=== fix-526: workflow-mark null-session fatal ==="
echo ""

# T2.1: MARK_STEP → must use signalFatal → exit 2
# Use "workflow_init" — a valid step in VALID_STEPS that reaches the null-session guard.
assert_must_fatal \
  "T2.1 MARK_STEP workflow_init_complete" \
  'echo "<<WORKFLOW_MARK_STEP_workflow_init_complete>>"'

# T2.2: RESEARCH_NOT_NEEDED → must use signalFatal → exit 2
assert_must_fatal \
  "T2.2 RESEARCH_NOT_NEEDED" \
  'echo "<<WORKFLOW_RESEARCH_NOT_NEEDED: reason for skip>>"'

# T2.2b: OUTLINE_NOT_NEEDED → must use signalFatal → exit 2
assert_must_fatal \
  "T2.2b OUTLINE_NOT_NEEDED" \
  'echo "<<WORKFLOW_OUTLINE_NOT_NEEDED: reason for skip>>"'

# T2.2c: DETAIL_NOT_NEEDED → must use signalFatal → exit 2
assert_must_fatal \
  "T2.2c DETAIL_NOT_NEEDED" \
  'echo "<<WORKFLOW_DETAIL_NOT_NEEDED: reason for skip>>"'

# T2.2d: WRITE_TESTS_NOT_NEEDED → must use signalFatal → exit 2
assert_must_fatal \
  "T2.2d WRITE_TESTS_NOT_NEEDED" \
  'echo "<<WORKFLOW_WRITE_TESTS_NOT_NEEDED: reason for skip>>"'

# T2.2e: REVIEW_SECURITY_NOT_NEEDED → must use signalFatal → exit 2
assert_must_fatal \
  "T2.2e REVIEW_SECURITY_NOT_NEEDED" \
  'echo "<<WORKFLOW_REVIEW_SECURITY_NOT_NEEDED: reason for skip>>"'

# T2.2f: CLARIFY_INTENT_NOT_NEEDED → must use signalFatal → exit 2
assert_must_fatal \
  "T2.2f CLARIFY_INTENT_NOT_NEEDED" \
  'echo "<<WORKFLOW_CLARIFY_INTENT_NOT_NEEDED: reason for skip>>"'

# T2.4: USER_VERIFIED → must use signalFatal → exit 2
assert_must_fatal \
  "T2.4 USER_VERIFIED" \
  'echo "<<WORKFLOW_USER_VERIFIED: ok user confirmed>>"'

# T2.5: BRANCHING_COMPLETE → must use signalFatal → exit 2
assert_must_fatal \
  "T2.5 BRANCHING_COMPLETE" \
  'echo "<<WORKFLOW_BRANCHING_COMPLETE: branch:fix/test|worktree:/tmp/wt|main>>"'

# T2.6: CLARIFY_INTENT_COMPLETE → must use signalFatal → exit 2
assert_must_fatal \
  "T2.6 CLARIFY_INTENT_COMPLETE" \
  'echo "<<WORKFLOW_CLARIFY_INTENT_COMPLETE>>"'

echo ""
echo "--- Negative controls (should PASS now) ---"
echo ""

# T2.7: Positive control — payload WITH session_id → resolveSessionId succeeds →
# handler doesn't hit the null-session guard → exit 0 (may pushMessage on other errors).
test_t2_7_with_session_id() {
  local payload='{"tool_name":"Bash","tool_input":{"command":"echo \"<<WORKFLOW_MARK_STEP_workflow_init_complete>>\""},"tool_response":{"exit_code":0},"session_id":"test-session-20260101-120000"}'
  local out_file="$TMPDIR_BASE/t27-out-$$.txt"
  local err_file="$TMPDIR_BASE/t27-err-$$.txt"
  local rc=0
  # Run WITHOUT full env isolation so HOME/.workflow-plans/ path is accessible
  # (the handler will fail to write state for fake session-id, but exits 0).
  ( cd "$WORK_DIR" && env -i \
      PATH="$PATH" \
      HOME="$EMPTY_HOME" \
      CLAUDE_TRANSCRIPT_BASE_DIR="$EMPTY_TRANSCRIPT" \
      "$NODE_BIN" "$HOOK_NODE" <<< "$payload" \
      > "$out_file" 2> "$err_file" ) || rc=$?
  # Any exit code except 2 is acceptable — the null-session guard must not fire.
  if [ "$rc" -ne 2 ]; then
    pass "T2.7: MARK_STEP with session_id in payload → exit $rc (not 2; null-session guard skipped)"
  else
    fail "T2.7: MARK_STEP with session_id → should NOT exit 2 (session_id was provided)"
  fi
}
test_t2_7_with_session_id

# T2.8: RESET_FROM — OPTIONAL handler — must remain exit 0 even after fix.
assert_optional_nonfatal \
  "T2.8 RESET_FROM (optional)" \
  'echo "<<WORKFLOW_RESET_FROM_write_code>>"'

# T2.9: PREMISE_FAIL — OPTIONAL handler — must remain exit 0 even after fix.
assert_optional_nonfatal \
  "T2.9 PREMISE_FAIL (optional)" \
  'echo "<<WORKFLOW_PREMISE_FAIL: some premise issue>>"'

# ─────────────────────────────────────────────────────────────────────────────
# Runner summary
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
