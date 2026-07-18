# state-seeds.sh — workflow/supervisor state seeding helpers for T1-T11 and H1-H8 tests
# Sourced by tests/feature-1498-stop-premature-stop-guard.sh

# Seed a workflow state that has workflow_init=complete and clarify_intent=complete
# and a given step ACTION by writing the next-step output into env.
# $1=tmp_dir $2=sid $3=action (invoke|done|blocked)
seed_workflow_state() {
    local tmp="$1" sid="$2" action="$3"
    local wf_dir="$tmp/workflow"
    mkdir -p "$wf_dir"
    WF_DIR="$wf_dir" SID="$sid" run_with_timeout 10 node -e "
const fs = require('fs');
const path = require('path');
const dir = process.env.WF_DIR;
const sid = process.env.SID;
const filePath = path.join(dir, sid + '.json');
const now = new Date().toISOString();
const steps = {
  workflow_init: { status: 'complete', updated_at: now },
  clarify_intent: { status: 'complete', updated_at: now },
  research: { status: 'complete', updated_at: now },
  outline: { status: 'complete', updated_at: now },
  detail: { status: 'complete', updated_at: now },
  branching_complete: { status: 'complete', updated_at: now },
  write_tests: { status: 'pending', updated_at: null },
  review_tests: { status: 'pending', updated_at: null },
  run_tests: { status: 'pending', updated_at: null },
  review_security: { status: 'pending', updated_at: null },
  docs: { status: 'pending', updated_at: null },
  user_verification: { status: 'pending', updated_at: null },
  cleanup: { status: 'pending', updated_at: null },
  pre_final_report_gate: { status: 'pending', updated_at: null },
};
const state = { version: 1, session_id: sid, created_at: now, steps, workflow_type: 'wf-code' };
fs.mkdirSync(dir, { recursive: true });
fs.writeFileSync(filePath, JSON.stringify(state, null, 2));
" >/dev/null 2>&1
}

# Seed a workflow state with workflow_init NOT complete (pending).
seed_workflow_state_no_init() {
    local tmp="$1" sid="$2"
    local wf_dir="$tmp/workflow"
    mkdir -p "$wf_dir"
    WF_DIR="$wf_dir" SID="$sid" run_with_timeout 10 node -e "
const fs = require('fs');
const path = require('path');
const dir = process.env.WF_DIR;
const sid = process.env.SID;
const filePath = path.join(dir, sid + '.json');
const now = new Date().toISOString();
const steps = {
  workflow_init: { status: 'pending', updated_at: null },
  clarify_intent: { status: 'pending', updated_at: null },
  research: { status: 'pending', updated_at: null },
  outline: { status: 'pending', updated_at: null },
  detail: { status: 'pending', updated_at: null },
  branching_complete: { status: 'pending', updated_at: null },
  write_tests: { status: 'pending', updated_at: null },
  review_tests: { status: 'pending', updated_at: null },
  run_tests: { status: 'pending', updated_at: null },
  review_security: { status: 'pending', updated_at: null },
  docs: { status: 'pending', updated_at: null },
  user_verification: { status: 'pending', updated_at: null },
  cleanup: { status: 'pending', updated_at: null },
  pre_final_report_gate: { status: 'pending', updated_at: null },
};
const state = { version: 1, session_id: sid, created_at: now, steps, workflow_type: 'wf-code' };
fs.mkdirSync(dir, { recursive: true });
fs.writeFileSync(filePath, JSON.stringify(state, null, 2));
" >/dev/null 2>&1
}

# Seed a workflow state with all steps done (workflow Done state).
seed_workflow_state_done() {
    local tmp="$1" sid="$2"
    local wf_dir="$tmp/workflow"
    mkdir -p "$wf_dir"
    WF_DIR="$wf_dir" SID="$sid" run_with_timeout 10 node -e "
const fs = require('fs');
const path = require('path');
const dir = process.env.WF_DIR;
const sid = process.env.SID;
const filePath = path.join(dir, sid + '.json');
const now = new Date().toISOString();
const steps = {
  workflow_init: { status: 'complete', updated_at: now },
  clarify_intent: { status: 'complete', updated_at: now },
  research: { status: 'complete', updated_at: now },
  outline: { status: 'complete', updated_at: now },
  detail: { status: 'complete', updated_at: now },
  branching_complete: { status: 'complete', updated_at: now },
  write_tests: { status: 'complete', updated_at: now },
  review_tests: { status: 'complete', updated_at: now },
  run_tests: { status: 'complete', updated_at: now },
  review_security: { status: 'complete', updated_at: now },
  docs: { status: 'complete', updated_at: now },
  user_verification: { status: 'complete', updated_at: now },
  cleanup: { status: 'complete', updated_at: now },
  pre_final_report_gate: { status: 'complete', updated_at: now },
};
const state = { version: 1, session_id: sid, created_at: now, steps, workflow_type: 'wf-code' };
fs.mkdirSync(dir, { recursive: true });
fs.writeFileSync(filePath, JSON.stringify(state, null, 2));
" >/dev/null 2>&1
}

# Seed a workflow state that causes next-step to return ACTION=blocked.
# Uses closes_issues=[] with clarify_intent pending — next-step emits blocked (closes_issues-empty).
# $1=tmp_dir $2=sid
seed_workflow_state_blocked() {
    local tmp="$1" sid="$2"
    local wf_dir="$tmp/workflow"
    mkdir -p "$wf_dir"
    WF_DIR="$wf_dir" SID="$sid" run_with_timeout 10 node -e "
const fs = require('fs'), path = require('path');
const wfDir = process.env.WF_DIR, sid = process.env.SID;
const filePath = path.join(wfDir, sid + '.json');
const now = new Date().toISOString();
const state = { version: 1, session_id: sid, created_at: now, steps: { workflow_init: { status: 'complete', updated_at: now }, clarify_intent: { status: 'pending', updated_at: null }, research: { status: 'pending', updated_at: null }, outline: { status: 'pending', updated_at: null }, detail: { status: 'pending', updated_at: null }, branching_complete: { status: 'pending', updated_at: null }, write_tests: { status: 'pending', updated_at: null }, review_tests: { status: 'pending', updated_at: null }, run_tests: { status: 'pending', updated_at: null }, review_security: { status: 'pending', updated_at: null }, docs: { status: 'pending', updated_at: null }, user_verification: { status: 'pending', updated_at: null }, cleanup: { status: 'pending', updated_at: null }, pre_final_report_gate: { status: 'pending', updated_at: null } }, workflow_type: 'wf-code', closes_issues: [] };
fs.writeFileSync(filePath, JSON.stringify(state));
" >/dev/null 2>&1
}

# Seed supervisor state for a session. $1=tmp $2=sid $3=alert_armed_at (or "")
seed_supervisor_state() {
    local tmp="$1" sid="$2" armed_at="$3"
    local plans_dir="$tmp/plans"
    mkdir -p "$plans_dir"
    WORKFLOW_PLANS_DIR="$plans_dir" SID="$sid" ARMED_AT="$armed_at" run_with_timeout 10 node -e "
const w = require('$WRITER_NODE');
const s = require('$SCHEMA_NODE');
const fs = require('fs');
const sid = process.env.SID;
const armedAt = process.env.ARMED_AT;
const st = s.createEmptyState(sid);
if (armedAt) {
  st.alert.alert_armed_at = armedAt;
  st.alert.alert_phase = 'pending';
}
const stPath = w.getStatePath(sid);
fs.writeFileSync(stPath, JSON.stringify(st));
" >/dev/null 2>&1
}
