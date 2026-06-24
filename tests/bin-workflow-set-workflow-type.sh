#!/usr/bin/env bash
# Tests: bin/workflow/set-workflow-type, hooks/lib/workflow-state/state-io.js
# Tags: L2, workflow, wf-plan, scope:common
#
# L3 gap (what this test does NOT catch):
# - Real Claude Code session where set-workflow-type runs before mark-step-handler fires
# - The actual PP1→PP2 ordering constraint observable only in a live workflow-init session
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration

set -euo pipefail

: "${AGENTS_CONFIG_DIR:?AGENTS_CONFIG_DIR not set}"

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not available"
  exit 77
fi

TMPDIR_WT="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_WT"' EXIT
export CLAUDE_WORKFLOW_DIR="$TMPDIR_WT"

SCRIPT_AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SET_WORKFLOW_TYPE="$SCRIPT_AGENTS_DIR/bin/workflow/set-workflow-type"

if [ ! -f "$SET_WORKFLOW_TYPE" ]; then
  echo "SKIP (RED): $SET_WORKFLOW_TYPE not yet implemented — TDD RED phase"
  exit 77
fi

PASS=0
FAIL=0

run_with_timeout() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 30 "$@"
  else
    perl -e 'alarm 30; exec @ARGV' -- "$@"
  fi
}

check() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then
    echo "PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc -- expected [$expected] got [$actual]"
    FAIL=$((FAIL + 1))
  fi
}

check_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -qF "$needle"; then
    echo "PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc -- expected [$needle] in: $haystack"
    FAIL=$((FAIL + 1))
  fi
}

json_val() {
  local file="$1" expr="$2"
  STATE_FILE_PATH="$file" node -e "
    const s=JSON.parse(require('fs').readFileSync(process.env.STATE_FILE_PATH,'utf8'));
    const v=(${expr});
    console.log(v!=null?String(v):'__NULL__');
  " 2>/dev/null || echo "__ERROR__"
}

write_state_json() {
  local sid="$1" json="$2"
  printf '%s' "$json" > "$TMPDIR_WT/${sid}.json"
}

run_script() {
  run_with_timeout node "$SET_WORKFLOW_TYPE" "$@"
}

run_tests() {
  # ---- 1: argument validation ------------------------------------------------

  local rc

  # 1a: no args → exit 1
  rc=0
  run_script 2>/dev/null || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "PASS: 1a: no-args exits non-zero"
    PASS=$((PASS + 1))
  else
    echo "FAIL: 1a: no-args should exit non-zero"
    FAIL=$((FAIL + 1))
  fi

  # 1b: session-id only (no type) → exit 1
  rc=0
  run_script "sess-1b" 2>/dev/null || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "PASS: 1b: session-only exits non-zero"
    PASS=$((PASS + 1))
  else
    echo "FAIL: 1b: session-only should exit non-zero"
    FAIL=$((FAIL + 1))
  fi

  # 1c: invalid type → exit 1 + stderr contains bad value
  rc=0
  local err_out
  err_out="$(run_script "sess-1c" "wf-xyz" 2>&1 1>/dev/null)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "PASS: 1c: invalid-type exits non-zero"
    PASS=$((PASS + 1))
  else
    echo "FAIL: 1c: invalid-type should exit non-zero"
    FAIL=$((FAIL + 1))
  fi
  check_contains "1c: invalid-type stderr contains bad value" "wf-xyz" "$err_out"

  # ---- 2: path traversal / session-id validation ----------------------------

  # 2a: session-id with ".." → exit 1
  rc=0
  run_script "../evil" "wf-plan" 2>/dev/null || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "PASS: 2a: dotdot traversal rejected"
    PASS=$((PASS + 1))
  else
    echo "FAIL: 2a: dotdot traversal should be rejected"
    FAIL=$((FAIL + 1))
  fi

  # 2b: session-id with "/" → exit 1
  rc=0
  run_script "foo/bar" "wf-plan" 2>/dev/null || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "PASS: 2b: slash in session-id rejected"
    PASS=$((PASS + 1))
  else
    echo "FAIL: 2b: slash in session-id should be rejected"
    FAIL=$((FAIL + 1))
  fi

  # 2c: session-id with backslash → exit 1 (allowlist rejects non-alphanumeric)
  rc=0
  run_script "..\\..\\etc\\passwd" "wf-plan" 2>/dev/null || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "PASS: 2c: backslash traversal rejected"
    PASS=$((PASS + 1))
  else
    echo "FAIL: 2c: backslash traversal should be rejected"
    FAIL=$((FAIL + 1))
  fi

  # ---- 3: no-existing-state path --------------------------------------------

  local SID3="wf-plan-new-$$"
  run_script "$SID3" "wf-plan"
  local STATE3="$TMPDIR_WT/${SID3}.json"

  if [ -f "$STATE3" ]; then
    echo "PASS: 3a: state file created"
    PASS=$((PASS + 1))
  else
    echo "FAIL: 3a: state file not created at $STATE3"
    FAIL=$((FAIL + 1))
    # remaining 3x cases are meaningless without the file
    echo "SKIP: 3b 3c 3d (no state file)"
    FAIL=$((FAIL + 3))
    return
  fi

  check "3b: workflow_type=wf-plan" "wf-plan" "$(json_val "$STATE3" 's.workflow_type')"
  check "3c: session_id matches" "$SID3" "$(json_val "$STATE3" 's.session_id')"
  check "3d: workflow_init status=pending" "pending" "$(json_val "$STATE3" 's.steps.workflow_init.status')"

  # ---- 4: existing-state overwrite ------------------------------------------

  local SID4="wf-plan-existing-$$"
  write_state_json "$SID4" '{"version":1,"session_id":"'"$SID4"'","workflow_type":"wf-code","steps":{"workflow_init":{"status":"complete","updated_at":null},"clarify_intent":{"status":"pending","updated_at":null}},"closes_issues":[999]}'
  run_script "$SID4" "wf-plan"
  local STATE4="$TMPDIR_WT/${SID4}.json"

  check "4a: workflow_type overwritten to wf-plan" "wf-plan" "$(json_val "$STATE4" 's.workflow_type')"
  check "4b: closes_issues[0] preserved" "999" "$(json_val "$STATE4" 's.closes_issues[0]')"
  check "4c: workflow_init.status preserved" "complete" "$(json_val "$STATE4" 's.steps.workflow_init.status')"

  # ---- 5: PP1 ordering invariant --------------------------------------------
  # workflow_type must survive a readState+writeState roundtrip (simulating
  # mark-step-handler.js running AFTER set-workflow-type in PP1→PP2 order).

  local SID5="wf-plan-order-$$"
  run_script "$SID5" "wf-plan"
  local PRESERVED
  PRESERVED="$(cd "$SCRIPT_AGENTS_DIR" && node -e "
    const {readState,writeState}=require('./hooks/lib/workflow-state');
    const st=readState('$SID5');
    writeState('$SID5',st);
    const st2=readState('$SID5');
    console.log(st2.workflow_type??'__NULL__');
  " 2>/dev/null || echo "__ERROR__")"
  check "5: workflow_type preserved after readState+writeState" "wf-plan" "$PRESERVED"
}

run_tests

echo "Total: $PASS passed, $FAIL failed"
exit "$FAIL"
