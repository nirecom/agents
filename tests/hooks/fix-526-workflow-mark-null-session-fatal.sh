#!/usr/bin/env bash
# tests/hooks/fix-526-workflow-mark-null-session-fatal.sh
# Tests: hooks/workflow-mark.js, hooks/workflow-mark
# Tags: workflow-mark, null-session, strong-channel, not-applied, issue-526, issue-2824, scope:issue-specific
#
# #526: a MUST handler whose sessionId is unresolved is refused, not silently dropped.
# #2824: the refusal is UNAPPLIED, told on the strong channel hooks/workflow-mark/emit.js
# STRONG_CHANNEL names (exit2: stderr + exit 2; block-decision: {decision:"block"}), with the
# "[NOT APPLIED]" prefix; tests/lib/workflow-mark-output.js judges the form. OPTIONAL handlers
# (RESET_FROM) stay INFO on the normal channel, exit 0.

set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK_NODE="$SCRIPT_CHECKOUT_ROOT/hooks/workflow-mark.js"
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
# Null-session isolation setup: block all 3 tiers of resolveSessionId:
#   (1) input.session_id: not present in payload
#   (2) CLAUDE_CODE_SESSION_ID: not set in env
#   (3) input.transcript_path: not present in payload
# Defense in depth: CLAUDE_TRANSCRIPT_BASE_DIR is an empty tmpdir,
# CLAUDE_PROJECT_DIR is unset and WORK_DIR is a non-git tmpdir.
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

OUT_LIB="$SCRIPT_CHECKOUT_ROOT/tests/lib/workflow-mark-output.js"
# check_output <kind unapplied|info> <ERE>: judge the last run's output with the shared helper.
check_output() {
  printf '%s' "$MARK_OUT" > "$TMPDIR_BASE/chk-out.txt"; printf '%s' "$MARK_ERR" > "$TMPDIR_BASE/chk-err.txt"
  CHECK_WHY="$("$NODE_BIN" "$OUT_LIB" check "$1" "$2" "$MARK_RC" "$TMPDIR_BASE/chk-out.txt" "$TMPDIR_BASE/chk-err.txt")"
}

# Assert that a null-session MUST handler is refused on the strong channel, naming why.
assert_must_fatal() {
  run_mark_null "$2"
  if check_output unapplied "session|could not resolve"; then pass "$1 → refused on the strong channel (null session)"
  else fail "$1 → expected an UNAPPLIED refusal on the strong channel: $CHECK_WHY"; fi
}

# Assert that a null-session OPTIONAL handler stays INFO on the normal channel (exit 0).
assert_optional_nonfatal() {
  run_mark_null "$2"
  if check_output info "session|RESET"; then pass "$1 → INFO on the normal channel (OPTIONAL handler, non-fatal)"
  else fail "$1 → expected INFO on the normal channel: $CHECK_WHY"; fi
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

# T2.8: RESET_FROM — OPTIONAL handler — stays INFO (exit 0), never the strong channel.
assert_optional_nonfatal \
  "T2.8 RESET_FROM (optional)" \
  'echo "<<WORKFLOW_RESET_FROM_write_code: test reason>>"'

# ─────────────────────────────────────────────────────────────────────────────
# Runner summary
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
