# integration-post-compact/progress-helpers.sh — workflow-state fixture helpers
# Tests: hooks/post-compact.js
# Tags: conv-lang, post-compact, workflow-state, scope:common
# Sourced by ../integration-post-compact.sh between conv-lang-cases.sh and
# progress-summary-cases.sh — defines only, runs no case. Provides
# _write_wf_state, _write_wf_state_with_reset_reason and
# _call_post_compact_with_state for the progress-summary and resume-hint
# fragments. Depends on helpers.sh for TMPDIR_BASE, EMPTY_CFG, POST_COMPACT,
# run_with_timeout.
# ===========================================================================
# T28–T34: Progress summary renderer (post-#1482 implementation)
# These tests define expected behavior that does NOT exist yet — they will
# FAIL until the inline progress summary renderer is added to post-compact.js.
# ===========================================================================

# Helper: write a workflow state file with the given step statuses.
# Usage: write_wf_state <sid> <step1:status> [<step2:status> ...]
# Steps not listed default to "pending".
_write_wf_state() {
    local sid="$1"; shift
    local wf_dir="$TMPDIR_BASE/workflow"
    mkdir -p "$wf_dir"
    # Build steps JSON via node so we don't have to hand-escape.
    local pairs_json="["
    local first=1
    for pair in "$@"; do
        local step="${pair%%:*}"
        local status="${pair#*:}"
        if [ "$first" = "1" ]; then
            pairs_json="${pairs_json}[\"${step}\",\"${status}\"]"
            first=0
        else
            pairs_json="${pairs_json},[\"${step}\",\"${status}\"]"
        fi
    done
    pairs_json="${pairs_json}]"
    node -e "
const fs=require('fs'),path=require('path');
const sid=process.argv[1];
const dir=process.argv[2];
const overrides=JSON.parse(process.argv[3]);
const VALID=[
  'workflow_init','clarify_intent','research','outline','detail',
  'branching_complete','write_tests','review_tests','run_tests',
  'review_security','docs','user_verification','cleanup','pre_final_report_gate'
];
const steps={};
for(const s of VALID) steps[s]={status:'pending',updated_at:null};
for(const [s,st] of overrides) steps[s]={status:st,updated_at:new Date().toISOString()};
const state={version:1,session_id:sid,created_at:new Date().toISOString(),steps,git_branch:'feature/1482-post-compact-progress',cwd:'/tmp'};
fs.mkdirSync(dir,{recursive:true});
fs.writeFileSync(path.join(dir,sid+'.json'),JSON.stringify(state,null,2),'utf8');
process.stdout.write('ok');
" "$sid" "$wf_dir" "$pairs_json" 2>/dev/null
}

# Helper: write state with reset_reason in user_verification
_write_wf_state_with_reset_reason() {
    local sid="$1" uv_status="$2" reset_reason="$3"
    local wf_dir="$TMPDIR_BASE/workflow"
    mkdir -p "$wf_dir"
    node -e "
const fs=require('fs'),path=require('path');
const sid=process.argv[1];
const dir=process.argv[2];
const uvStatus=process.argv[3];
const resetReason=process.argv[4]||null;
const VALID=[
  'workflow_init','clarify_intent','research','outline','detail',
  'branching_complete','write_tests','review_tests','run_tests',
  'review_security','docs','user_verification','cleanup','pre_final_report_gate'
];
const steps={};
for(const s of VALID) steps[s]={status:'complete',updated_at:new Date().toISOString()};
steps['user_verification']={status:uvStatus,updated_at:new Date().toISOString()};
if(resetReason) steps['user_verification'].reset_reason=resetReason;
const state={version:1,session_id:sid,created_at:new Date().toISOString(),steps,git_branch:'feature/1482-post-compact-progress',cwd:'/tmp'};
fs.mkdirSync(dir,{recursive:true});
fs.writeFileSync(path.join(dir,sid+'.json'),JSON.stringify(state,null,2),'utf8');
process.stdout.write('ok');
" "$sid" "$wf_dir" "$uv_status" "$reset_reason" 2>/dev/null
}

# Helper: call post-compact with state pre-written, return additionalContext
_call_post_compact_with_state() {
    local sid="$1"
    local raw
    raw=$(printf '{"session_id":"%s"}' "$sid" | \
        CLAUDE_WORKFLOW_DIR="$TMPDIR_BASE/workflow" \
        HOME="$TMPDIR_BASE/home" \
        AGENTS_CONFIG_DIR="$EMPTY_CFG" \
        run_with_timeout 30 node "$POST_COMPACT" 2>/dev/null)
    [ -z "$raw" ] && return 0
    node -e "
try {
  const o = JSON.parse(process.argv[1]);
  process.stdout.write(o.additionalContext || '');
} catch (e) {}
" "$raw" 2>/dev/null
}
