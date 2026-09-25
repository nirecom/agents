# tests/feature-534-stop-final-report-guard/g28-trigger.sh
# Tests: hooks/stop-final-report-guard.js, hooks/stop-premature-stop-guard.js, bin/workflow/next-step, settings.json
# Tags: hook, settings, config, stop-guard, workflow-state, scope:issue-specific, TL2
#
# Trigger-decoupling tests for issue #1611 (Track B: env-file-independent trigger).
# Sourced by feature-534-stop-final-report-guard.sh — no shebang, no runner.
#
# Function numbering continues at G33 because G28–G32 are already taken by
# g21-g27.sh; the filename follows the plan, the numbering follows the suite.
#
# Contract under test (new):
#   Track A — env file readable+parsable → Final Report shape validation (unchanged).
#   Track B — env file ABSENT and `bin/workflow/next-step --session <sid>` reports
#           ACTION=invoke with REASON='pre_final_report_gate' → the close
#           procedure was never started; block unconditionally (exit 2), WITHOUT
#           scanning the transcript. A hand-written 13-heading report must NOT
#           be accepted.
#   Escape hatches for Track B: <sid>-session-close-gate.json gate_action:yield,
#           <sid>.workflow-off marker, pre_final_report_gate marked complete.
#   Anything else → exit 0.
#
# These tests also pin the child-process environment inheritance regression:
# next-step is spawned from the hook and must still see CLAUDE_WORKFLOW_DIR.

# ---------------------------------------------------------------------------
# Local fixture helpers (parent-scope: TMPDIR_BASE, HOOK_JS, node_path, ...)
# ---------------------------------------------------------------------------

PREMATURE_HOOK_JS="$(dirname "$HOOK_JS")/stop-premature-stop-guard.js"

# b_mk_state <workflow-dir> <sid> [pending-step ...]
# Writes a workflow state file with every step complete except the listed ones.
b_mk_state() {
    node -e '
const fs = require("fs");
const dir = process.argv[1], sid = process.argv[2];
const pendings = process.argv.slice(3);
// Mirrors VALID_STEPS. #1665 inserted write_code between review_tests and run_tests;
// a step missing here is never written complete, so it silently stays pending and the
// "every step complete except the listed ones" premise of every case below breaks.
const V = ["workflow_init","clarify_intent","research","outline","detail",
           "branching_complete","write_tests","review_tests","write_code","run_tests",
           "review_security","docs","user_verification","cleanup",
           "pre_final_report_gate"];
const steps = {};
const now = new Date().toISOString();
for (const s of V) steps[s] = { status: "complete", updated_at: now };
for (const s of pendings) steps[s] = { status: "pending", updated_at: null };
fs.mkdirSync(dir, { recursive: true });
fs.writeFileSync(dir + "/" + sid + ".json", JSON.stringify(
  { version: 1, session_id: sid, created_at: now, steps, workflow_type: "wf-code" }, null, 2));
' "$@"
}

# b_run <hook-js> <stdin-json> <plans-dir> <workflow-dir>
# Runs a Stop hook with an isolated plans dir + workflow dir.
# Sets B_OUT (stdout) and B_CODE (exit code).
B_OUT=""
B_CODE=0
b_run() {
    local hook="$1" stdin_json="$2" plans_dir="$3" wf_dir="$4"
    B_OUT="$(WORKFLOW_PLANS_DIR="$plans_dir" \
             CLAUDE_WORKFLOW_DIR="$wf_dir" \
             CLAUDE_PROJECT_DIR="$wf_dir" \
             run_with_timeout 120 node "$hook" <<< "$stdin_json" 2>/dev/null)"
    B_CODE=$?
}

# b_stdin <sid> <transcript-path>
b_stdin() {
    printf '{"session_id":"%s","transcript_path":"%s"}' "$1" "$(node_path "$2")"
}

# b_is_block → 0 when B_OUT is a decision:block JSON object.
b_is_block() {
    printf '%s' "$B_OUT" | node -e "
let s='';process.stdin.on('data',c=>s+=c);process.stdin.on('end',()=>{
  try { process.exit(JSON.parse(s.trim()).decision === 'block' ? 0 : 1); }
  catch (e) { process.exit(1); }
});" 2>/dev/null
}

# b_reason_has <needle> → 0 when the block reason contains <needle>.
b_reason_has() {
    printf '%s' "$B_OUT" | REASON_NEEDLE="$1" node -e "
let s='';process.stdin.on('data',c=>s+=c);process.stdin.on('end',()=>{
  try {
    const r = JSON.parse(s.trim()).reason || '';
    process.exit(r.includes(process.env.REASON_NEEDLE) ? 0 : 1);
  } catch (e) { process.exit(1); }
});" 2>/dev/null
}
# ---------------------------------------------------------------------------
# Cases — sourced sub-fragments (Pattern A split; rules/coding/file-split.md).
# ${BASH_SOURCE[0]} inside a sourced file is THIS file, so the sub-fragment dir
# resolves next to it regardless of where the grandparent entrypoint lives.
# ---------------------------------------------------------------------------
G28_FRAGMENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/g28-trigger"
# shellcheck source=tests/feature-534-stop-final-report-guard/g28-trigger/no-env-cases.sh
. "$G28_FRAGMENT_DIR/no-env-cases.sh"
# shellcheck source=tests/feature-534-stop-final-report-guard/g28-trigger/env-and-failopen-cases.sh
. "$G28_FRAGMENT_DIR/env-and-failopen-cases.sh"
