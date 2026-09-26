#!/usr/bin/env bash
# Tests: hooks/lib/conv-lang.js, hooks/post-compact.js, hooks/workflow-mark.js
# Tags: scope:issue-specific
# integration-workflow-mark.sh — T-WM1, T-WM2, T-WM3:
# Integration tests for workflow-mark.js post-merge reset_reason field (#1161).
#
# These tests verify that after #1161 is implemented, workflow-mark.js:
#   - T-WM1: gh pr merge success → state has reset_reason="post-merge"
#   - T-WM2: git push to protected branch → user_verification reset has NO reset_reason
#   - T-WM3: gh pr merge exit_code=1 → user_verification NOT reset
#
# Tests will FAIL until the source change is implemented.
#
# L3 gap (what this test does NOT catch):
# - real claude -p session verifying the injected context actually changes assistant behavior
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration
#
# Invocation pattern follows tests/feature-workflow-mark-subagent-backstop.sh.
# Sourced after helpers.sh; inherits TMPDIR_BASE, AGENTS_DIR, pass/fail functions.

WORKFLOW_MARK="$AGENTS_DIR/hooks/workflow-mark.js"
WM_WORKFLOW_DIR="$TMPDIR_BASE/workflow-wm"
WM_ENV_FILE="$TMPDIR_BASE/wm-claude_env"
mkdir -p "$WM_WORKFLOW_DIR"

# read_wm_field <sid> <step> <field>
# Reads a raw field value from a step object in the state JSON.
_wm_read_field() {
    local sid="$1" step="$2" field="$3"
    node -e "
const fs=require('fs'),path=require('path');
try {
  const s=JSON.parse(fs.readFileSync(path.join(process.argv[1],process.argv[2]+'.json'),'utf8'));
  const v=(s.steps[process.argv[3]]||{})[process.argv[4]];
  process.stdout.write(v===undefined?'MISSING':v===null?'NULL':String(v));
} catch(e){ process.stdout.write('ERR:'+e.message); }
" "$WM_WORKFLOW_DIR" "$sid" "$step" "$field" 2>/dev/null || true
}

# read_wm_status <sid> <step>
_wm_read_status() {
    _wm_read_field "$1" "$2" "status"
}

# write_wm_state <sid> <uv_status>
# Writes a minimal state file with user_verification at the given status.
_write_wm_state() {
    local sid="$1" uv_status="$2"
    local now
    now=$(node -e "console.log(new Date().toISOString())" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")
    node -e "
const fs=require('fs'),path=require('path');
const sid=process.argv[1];
const dir=process.argv[2];
const uvStatus=process.argv[3];
const now=process.argv[4];
const VALID=[
  'workflow_init','clarify_intent','research','outline','detail',
  'branching_complete','write_tests','review_tests','run_tests',
  'review_security','docs','user_verification','cleanup','pre_final_report_gate'
];
const steps={};
for(const s of VALID) steps[s]={status:'complete',updated_at:now};
steps['user_verification']={status:uvStatus,updated_at:now};
const state={version:1,session_id:sid,created_at:now,steps,git_branch:'main',cwd:'/tmp'};
fs.mkdirSync(dir,{recursive:true});
fs.writeFileSync(path.join(dir,sid+'.json'),JSON.stringify(state,null,2),'utf8');
process.stdout.write('ok');
" "$sid" "$WM_WORKFLOW_DIR" "$uv_status" "$now" 2>/dev/null
}

# write_wm_env_file <sid>
_write_wm_env_file() {
    printf 'CLAUDE_SESSION_ID=%s\n' "$1" > "$WM_ENV_FILE"
}

# run_wm_hook <json>
# Pipes a PostToolUse payload to workflow-mark.js; suppresses all output.
_run_wm_hook() {
    local json="$1"
    local tmpf
    tmpf=$(node -e "
const fs=require('fs'),os=require('os'),path=require('path'),crypto=require('crypto');
const f=path.join(os.tmpdir(),'wm-in-'+crypto.randomBytes(4).toString('hex')+'.json');
fs.writeFileSync(f,process.argv[1],'utf8');
process.stdout.write(f);
" "$json" 2>/dev/null)
    CLAUDE_WORKFLOW_DIR="$WM_WORKFLOW_DIR" \
    CLAUDE_ENV_FILE="$WM_ENV_FILE" \
    AGENTS_CONFIG_DIR="$EMPTY_CFG" \
    run_with_timeout 30 node "$WORKFLOW_MARK" < "$tmpf" >/dev/null 2>&1 || true
    node -e "require('fs').unlinkSync(process.argv[1])" "$tmpf" 2>/dev/null || true
}

if [ ! -f "$WORKFLOW_MARK" ]; then
    skip "T-WM1..T-WM3: $WORKFLOW_MARK does not exist — skipping workflow-mark tests"
else

# ===========================================================================
# T-WM1: gh pr merge success → state has reset_reason="post-merge"
# After #1161, markStep is called with { reset_reason: "post-merge" } extraField.
# ===========================================================================
T_WM1_SID="wm1-$RANDOM"
_write_wm_env_file "$T_WM1_SID"
_write_wm_state "$T_WM1_SID" "complete"
_run_wm_hook "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"gh pr merge --squash\"},\"tool_response\":{\"exit_code\":0,\"stdout\":\"Merged!\",\"stderr\":\"\"},\"session_id\":\"$T_WM1_SID\"}"
WM1_STATUS=$(_wm_read_status "$T_WM1_SID" "user_verification")
WM1_RESET_REASON=$(_wm_read_field "$T_WM1_SID" "user_verification" "reset_reason")
if [ "$WM1_STATUS" = "pending" ] && [ "$WM1_RESET_REASON" = "post-merge" ]; then
    pass "T-WM1: gh pr merge success → user_verification=pending with reset_reason=post-merge"
elif [ "$WM1_STATUS" = "pending" ] && [ "$WM1_RESET_REASON" = "MISSING" ]; then
    fail "T-WM1: user_verification reset to pending but reset_reason field missing (implementation not done)"
elif [ "$WM1_STATUS" = "complete" ]; then
    fail "T-WM1: user_verification NOT reset (status still complete) — merge detection may have failed"
else
    fail "T-WM1: unexpected state: status=$WM1_STATUS reset_reason=$WM1_RESET_REASON"
fi

# ===========================================================================
# T-WM2: git push to protected branch → user_verification reset has NO reset_reason
# The git-push-protected path resets without adding reset_reason (only pr merge adds it).
# ===========================================================================
T_WM2_SID="wm2-$RANDOM"
_write_wm_env_file "$T_WM2_SID"
_write_wm_state "$T_WM2_SID" "complete"
_run_wm_hook "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git push origin main\"},\"tool_response\":{\"exit_code\":0,\"stdout\":\"\",\"stderr\":\"\"},\"session_id\":\"$T_WM2_SID\"}"
WM2_STATUS=$(_wm_read_status "$T_WM2_SID" "user_verification")
WM2_RESET_REASON=$(_wm_read_field "$T_WM2_SID" "user_verification" "reset_reason")
if [ "$WM2_STATUS" = "pending" ] && [ "$WM2_RESET_REASON" = "MISSING" ]; then
    pass "T-WM2: git push protected → user_verification=pending with NO reset_reason field"
elif [ "$WM2_STATUS" = "pending" ] && [ "$WM2_RESET_REASON" = "post-merge" ]; then
    fail "T-WM2: git push incorrectly set reset_reason=post-merge (should only apply to gh pr merge)"
elif [ "$WM2_STATUS" = "complete" ]; then
    fail "T-WM2: user_verification NOT reset (status still complete) — push detection may have failed"
else
    fail "T-WM2: unexpected state: status=$WM2_STATUS reset_reason=$WM2_RESET_REASON"
fi

# ===========================================================================
# T-WM3: gh pr merge with exit_code=1 → user_verification NOT reset
# workflow-mark.js exits early on non-zero exit_code for merge commands.
# ===========================================================================
T_WM3_SID="wm3-$RANDOM"
_write_wm_env_file "$T_WM3_SID"
_write_wm_state "$T_WM3_SID" "complete"
_run_wm_hook "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"gh pr merge --squash\"},\"tool_response\":{\"exit_code\":1,\"stdout\":\"\",\"stderr\":\"error: merge failed\"},\"session_id\":\"$T_WM3_SID\"}"
WM3_STATUS=$(_wm_read_status "$T_WM3_SID" "user_verification")
if [ "$WM3_STATUS" = "complete" ]; then
    pass "T-WM3: gh pr merge exit_code=1 → user_verification NOT reset (remains complete)"
else
    fail "T-WM3: expected user_verification=complete after failed merge, got $WM3_STATUS"
fi

# ===========================================================================
# T-WM4: [Idempotency] fire the gh pr merge PostToolUse payload twice for the
# same session_id → user_verification stays "pending" and reset_reason stays
# "post-merge" (not corrupted/duplicated). A second merge sentinel must be a
# no-op on the already-reset state.
# ===========================================================================
T_WM4_SID="wm4-$RANDOM"
_write_wm_env_file "$T_WM4_SID"
_write_wm_state "$T_WM4_SID" "complete"
MERGE_PAYLOAD="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"gh pr merge --squash\"},\"tool_response\":{\"exit_code\":0,\"stdout\":\"Merged!\",\"stderr\":\"\"},\"session_id\":\"$T_WM4_SID\"}"
# Fire merge sentinel first time
_run_wm_hook "$MERGE_PAYLOAD"
WM4_STATUS1=$(_wm_read_status "$T_WM4_SID" "user_verification")
WM4_REASON1=$(_wm_read_field "$T_WM4_SID" "user_verification" "reset_reason")
# Fire merge sentinel second time (idempotency check)
_run_wm_hook "$MERGE_PAYLOAD"
WM4_STATUS2=$(_wm_read_status "$T_WM4_SID" "user_verification")
WM4_REASON2=$(_wm_read_field "$T_WM4_SID" "user_verification" "reset_reason")
if [ "$WM4_STATUS1" = "pending" ] && [ "$WM4_REASON1" = "post-merge" ] && \
   [ "$WM4_STATUS2" = "pending" ] && [ "$WM4_REASON2" = "post-merge" ]; then
    pass "T-WM4: idempotent — second gh pr merge sentinel preserves reset_reason=post-merge"
elif [ "$WM4_STATUS1" != "pending" ] || [ "$WM4_REASON1" != "post-merge" ]; then
    fail "T-WM4: first call did not set expected state (status=$WM4_STATUS1 reason=$WM4_REASON1)"
else
    fail "T-WM4: second call corrupted state (status=$WM4_STATUS2 reason=$WM4_REASON2)"
fi

fi # end if WORKFLOW_MARK exists
