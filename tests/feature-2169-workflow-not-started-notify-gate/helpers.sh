# tests/feature-2169-workflow-not-started-notify-gate/helpers.sh
# Tests: hooks/postuse-step-in-flight-mark.js, hooks/user-prompt-submit-mechanism-check.js, hooks/workflow-state/lifecycle.js, hooks/workflow-state/state-io.js, hooks/lib/mechanism-failure.js
# Tags: stall-detection, user-prompt-submit, prompt-notify, pre-workflow-init, wi-10-lookahead, regression-2169, scope:issue-specific, pwsh-not-required, TL1, TL2
# Shared fixture/dispatch helpers for the #2169 pre-workflow-init notify-gate
# test suite. Sourced by the top-level
# tests/feature-2169-workflow-not-started-notify-gate.sh dispatcher; relies on
# AGENTS_DIR / _AGENTS_DIR_NODE / RWT / AUTOMARK_HOOK / UPS_HOOK /
# STATEIO_NODE / LIFECYCLE_NODE / MECHFAIL_NODE / TTL_MS being set by the
# dispatcher before any function here is invoked.

make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t 'notstarted2169'; }
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

# dispatch_skill <tn> <sid> — the real PostToolUse auto-mark hook, driven with
# a Skill dispatch payload, so `research` gets marked in_progress via WI-10.
dispatch_skill() {
    printf '{"tool_name":"Skill","session_id":"%s","transcript_path":"","tool_input":{"description":"x"}}' "$2" \
        | CLAUDE_WORKFLOW_DIR="$1" WORKFLOW_PLANS_DIR="$1" AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" \
          "$RWT" 20 node "$(node_path "$AUTOMARK_HOOK")" >/dev/null 2>&1
}

# backdate_research <tmp> <sid> <ms-ago> — age research's own events so the
# in-flight record looks <ms-ago> milliseconds old.
backdate_research() {
    P="$(node_path "$1/$2.json")" MS="$3" "$RWT" 15 node -e "
const fs = require('fs');
const s = JSON.parse(fs.readFileSync(process.env.P, 'utf8'));
const at = new Date(Date.now() - Number(process.env.MS)).toISOString();
for (const e of s.events || []) { if (e.step === 'research') e.at = at; }
fs.writeFileSync(process.env.P, JSON.stringify(s));" >/dev/null 2>&1
}

# backdate_step <tmp> <sid> <step> <ms-ago> — generalizes backdate_research to
# any step name (needed by P9's second stalled step, `detail`). Same
# technique: rewrite the matching event's `at`; state-io/projection.js derives
# steps[step].updated_at from the latest event carrying that step, so this is
# not a parallel code path, just backdate_research with the field parameterized.
backdate_step() {
    P="$(node_path "$1/$2.json")" ST="$3" MS="$4" "$RWT" 15 node -e "
const fs = require('fs');
const s = JSON.parse(fs.readFileSync(process.env.P, 'utf8'));
const at = new Date(Date.now() - Number(process.env.MS)).toISOString();
for (const e of s.events || []) { if (e.step === process.env.ST) e.at = at; }
fs.writeFileSync(process.env.P, JSON.stringify(s));" >/dev/null 2>&1
}

# mark_step_in_progress <tn> <sid> <step> — direct markStep on an arbitrary
# STEP_IN_FLIGHT_ALLOWLIST step. dispatch_skill only ever marks `research`
# (the WI-10 lookahead is hardcoded to that step pre-adoption), so P9's second
# stalled step needs this instead. Same technique as seed_step_in_flight in
# tests/feature-1794-stop-guard-exemptions/helpers.sh.
mark_step_in_progress() {
    CLAUDE_WORKFLOW_DIR="$1" "$RWT" 15 node -e "
require('$STATEIO_NODE').markStep('$2', '$3', 'in_progress');" >/dev/null 2>&1
}

# seed_workflow_off <tmp> <sid> — writes a real .workflow-off marker file
# directly, same shape as write_marker_file() in
# tests/feature-workflow-off-session-override/helpers.sh, so
# isWorkflowOff(sid) (hooks/lib/session-markers.js) reads true. Used by P8 to
# activate a C4-only exemption (EXEMPTION_MATRIX["workflow-off"].c4===true)
# alongside a genuinely-started, TTL-expired session.
seed_workflow_off() {
    printf '{"set_at":"2026-01-01T00:00:00Z","reason":"test"}\n' > "$1/$2.workflow-off"
}

# seed_state_corrupt <tmp> <sid> — writes syntactically-invalid JSON directly
# as the session's state file (models M4 in
# tests/feature-1997-mechanism-failure/m-detect.sh). No dispatch/adoption
# happens first: readState() returns null for this file regardless, so the
# resulting session is pre-workflow-init by construction (verified below —
# see the P6 comment on why state-corrupt has no "started" counterpart).
seed_state_corrupt() {
    printf '{ this is not json' > "$1/$2.json"
}

# strip_timestamp <tmp> <sid> <step> — deletes the `at` field from <step>'s
# event(s), turning an in_progress record into one with no usable timestamp
# (models M5 in tests/feature-1997-mechanism-failure/m-detect.sh, generalized
# to accept a step so it works after either dispatch_skill alone or
# dispatch_skill + complete_workflow_init).
strip_timestamp() {
    P="$(node_path "$1/$2.json")" ST="$3" "$RWT" 15 node -e "
const fs = require('fs');
const s = JSON.parse(fs.readFileSync(process.env.P, 'utf8'));
for (const e of s.events || []) { if (e.step === process.env.ST) delete e.at; }
fs.writeFileSync(process.env.P, JSON.stringify(s));" >/dev/null 2>&1
}

# complete_workflow_init <tn> <sid> — genuinely adopt the session (real
# markStep), so isWorkflowStarted flips from false to true.
complete_workflow_init() {
    CLAUDE_WORKFLOW_DIR="$1" "$RWT" 15 node -e "
require('$STATEIO_NODE').markStep('$2', 'workflow_init', 'complete');" >/dev/null 2>&1
}

# run_ups <tn> <sid> — the real UserPromptSubmit hook as a child process. Sets
# UPS_OUT / UPS_RC.
run_ups() {
    UPS_OUT=$(SID="$2" "$RWT" 15 node -e "
process.stdout.write(JSON.stringify({ session_id: process.env.SID, transcript_path: '',
  prompt: 'where are we?', hook_event_name: 'UserPromptSubmit' }));" \
        | CLAUDE_WORKFLOW_DIR="$1" WORKFLOW_PLANS_DIR="$1" AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" \
          "$RWT" 25 node "$(node_path "$UPS_HOOK")" 2>/dev/null)
    UPS_RC=$?
}

# research_status <tn> <sid> — the on-disk status of the research step.
research_status() {
    CLAUDE_WORKFLOW_DIR="$1" WORKFLOW_PLANS_DIR="$1" "$RWT" 20 node -e "
const s = require('$STATEIO_NODE').readState('$2');
process.stdout.write(String(s && s.steps && s.steps.research && s.steps.research.status));" 2>/dev/null
}

# stalled_kinds_for <tn> <sid> — "step:kind" for every finding
# detectStalledSteps reports, newline-joined.
stalled_kinds_for() {
    CLAUDE_WORKFLOW_DIR="$1" WORKFLOW_PLANS_DIR="$1" "$RWT" 20 node -e "
const findings = require('$MECHFAIL_NODE').detectStalledSteps('$2') || [];
process.stdout.write(findings.map((f) => f.step + ':' + f.kind).join('\n'));" 2>/dev/null
}

# seed_malicious_step <tmp> <sid> <step> — writes a raw v3 state file directly
# (bypassing appendEvents/validateEvent, whose VALID_STEPS check the normal
# markStep dispatch path can never violate) with ONE step_status event whose
# `step` is an attacker-chosen string and no `at` timestamp, so
# detectStalledSteps reports it as `invalid-timestamp` on the very first read.
# assertStreamIntegrity (state-io/projection.js, run by readState) checks seq
# contiguity/provenance/status only — never event.step against VALID_STEPS —
# so this is exactly the "state file rewritten outside the normal
# appendEvents path" case isKnownStep() in
# hooks/user-prompt-submit-mechanism-check.js guards against (#2169 C1).
seed_malicious_step() {
    P="$(node_path "$1/$2.json")" SID="$2" ST="$3" "$RWT" 15 node -e "
const fs = require('fs');
const state = {
  version: 3,
  session_id: process.env.SID,
  created_at: new Date().toISOString(),
  session_start_context: { cwd: null, git_branch: null },
  workflow_type: 'wf-code',
  events: [ {
    seq: 1, kind: 'step_status', step: process.env.ST, status: 'in_progress',
    provenance: 'observed', origin: 'mark-step',
  } ],
};
fs.writeFileSync(process.env.P, JSON.stringify(state));" >/dev/null 2>&1
}

# mark_step_with_origin <tmp> <sid> <step> <origin> — direct markStep for an
# arbitrary step+origin pair. Used to build SAME-step, multi-event sequences
# that differ only in origin over time, to exercise
# isLookaheadOnlyInFlight's "last step_status event for the step wins" rule
# (#2169 C2) — mark_step_in_progress above always uses the default
# ("mark-step") origin, so it cannot construct this on its own.
mark_step_with_origin() {
    CLAUDE_WORKFLOW_DIR="$1" "$RWT" 15 node -e "
require('$STATEIO_NODE').markStep('$2', '$3', 'in_progress', {}, { origin: '$4' });" >/dev/null 2>&1
}
