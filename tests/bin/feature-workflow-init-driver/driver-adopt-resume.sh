#!/bin/bash
# tests/feature-workflow-init-driver/driver-adopt-resume.sh
# Tests: bin/workflow/workflow-init-driver, bin/workflow/lib/workflow-init/phases/adopt-prior-state.js, bin/workflow/lib/workflow-init/checkpoint.js
# Tags: workflow-init, driver, checkpoint-resume, adopt-prior-state, scope:issue-specific

# C17 — the adopt_prior_state answer replayed across a CHECKPOINT_VERSION bump (#2087),
# continuing the C series of driver-checkpoint-resume.sh (C1-C14) and
# driver-answer-validation.sh (C15-C16, C18-C20).

# TL3 gap: the adopt module is a fixture stub, so no real lineage-keyed state file is
# moved. Mitigated at WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: skill-orchestration.

set -u
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
require_sut

# --- C17: a stale checkpoint pending on the ADOPT offer replays its answer ------------
# adopt_prior_state is raised by the FIRST phase, before any issue is detected, so a
# plain detect-issues restart (C14a/C14b) throws the user's answer away and re-offers
# the same question — or, non-interactively, never offers it again. The
# version_mismatch branch must instead re-enter at adopt-prior-state carrying both the
# answer and the donor the stale checkpoint recorded.
c17_stale() {  # <ckpt-path> <sid> — v1 checkpoint pending on the adopt offer
    node -e '
const fs = require("fs"), path = require("path");
const p = process.argv[1];
fs.mkdirSync(path.dirname(p), { recursive: true });
fs.writeFileSync(p, JSON.stringify({
  version: 1, session_id: process.argv[2], phase: "adopt-prior-state",
  ask_id: "adopt_prior_state",
  state: { issues: [695], repo_map: {}, sid_pass: null, issue_json_cache: {},
    wip_results: {}, label_sets: {}, force_path_b: false, path_decision: null,
    adopt_candidate: "donor-sid-c17", adopt_decision: null }
}));
' "$1" "$2"
}

# C17a: the mock config root ships no hooks/workflow-state/inheritance/adopt.js, so the
# phase fail-opens (adoption is optional recovery and must never break workflow-init)
# and leaves the replayed fields observable in the checkpoint it writes.
setup_case wid-c17a
mock_issue 695 OPEN "type:task"
set_wip 695 same
c17_stale "$PLANS/wid-c17a-wi-checkpoint.json" wid-c17a
run_driver --resume "$PLANS/wid-c17a-wi-checkpoint.json" --answer adopt
assert_kv "C17a: adopt answer on a stale checkpoint → ACTION=done" ACTION done
CKPT2="$(get_kv CHECKPOINT)" || true
assert_ckpt "C17a: the answer is carried onto the fresh state" "$CKPT2" state.adopt_decision adopt
assert_ckpt "C17a: the stale donor is preserved onto the fresh state" "$CKPT2" state.adopt_candidate donor-sid-c17
assert_ckpt "C17a: the stale issue set is still recovered (C14a's contract holds)" "$CKPT2" state.issues "[695]"
teardown_case

# C17b: the entry PHASE itself. With a real adopt module present, re-entering at
# adopt-prior-state performs the adoption; a detect-issues restart (phase index 1)
# would skip it entirely and record nothing.
setup_case wid-c17b
mock_issue 695 OPEN "type:task"
set_wip 695 same
INH="$CFG/hooks/workflow-state/inheritance"
mkdir -p "$INH"
cat > "$INH/adopt.js" <<'ADOPTJS'
const fs = require("fs"), path = require("path");
const LOG = path.join(__dirname, "adopt-calls.log");
module.exports = {
  adoptState: (o) => { fs.appendFileSync(LOG, "adopt heir=" + o.heirSid + " donor=" + o.donorSid + "\n"); return { ok: true }; },
  listAdoptCandidates: () => ({ ok: true, candidates: [] }),
};
ADOPTJS
c17_stale "$PLANS/wid-c17b-wi-checkpoint.json" wid-c17b
run_driver --resume "$PLANS/wid-c17b-wi-checkpoint.json" --answer adopt
assert_kv "C17b: adopt answer completes the restarted pipeline → ACTION=done" ACTION done
if [ -f "$INH/adopt-calls.log" ] && grep -q '^adopt heir=wid-c17b donor=donor-sid-c17$' "$INH/adopt-calls.log"; then
    pass "C17b: restart re-entered at adopt-prior-state and adopted the recorded donor"
else
    fail "C17b: adopt-prior-state never ran on the restart; log=[$(cat "$INH/adopt-calls.log" 2>/dev/null | tr '\n' ';')]"
fi
teardown_case

# C17c: the other verdict of the same ask. `fresh` is the default and a plain no-op —
# it must be replayed as a decision (so the offer is not raised again) without
# performing any adoption.
setup_case wid-c17c
mock_issue 695 OPEN "type:task"
set_wip 695 same
INH="$CFG/hooks/workflow-state/inheritance"
mkdir -p "$INH"
cat > "$INH/adopt.js" <<'ADOPTJS'
const fs = require("fs"), path = require("path");
const LOG = path.join(__dirname, "adopt-calls.log");
module.exports = {
  adoptState: (o) => { fs.appendFileSync(LOG, "adopt heir=" + o.heirSid + " donor=" + o.donorSid + "\n"); return { ok: true }; },
  listAdoptCandidates: () => { fs.appendFileSync(LOG, "list\n"); return { ok: true, candidates: [] }; },
};
ADOPTJS
c17_stale "$PLANS/wid-c17c-wi-checkpoint.json" wid-c17c
run_driver --resume "$PLANS/wid-c17c-wi-checkpoint.json" --answer fresh
assert_kv "C17c: fresh answer on a stale checkpoint → ACTION=done" ACTION done
if [ -f "$INH/adopt-calls.log" ]; then
    fail "C17c: fresh performed adoption or re-listed candidates: [$(tr '\n' ';' < "$INH/adopt-calls.log")]"
else
    pass "C17c: fresh adopted nothing and did not re-offer (no adopt module call at all)"
fi
CKPT2="$(get_kv CHECKPOINT)" || true
assert_ckpt "C17c: fresh is recorded as the decision" "$CKPT2" state.adopt_decision fresh
assert_ckpt "C17c: the stale issue set is still recovered" "$CKPT2" state.issues "[695]"
teardown_case

finish
