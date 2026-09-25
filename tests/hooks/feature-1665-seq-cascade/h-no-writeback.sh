#!/bin/bash
# tests/feature-1665-seq-cascade/h-no-writeback.sh
# Tests: bin/workflow/lib/next-step/verdict.js, hooks/workflow-state/effective-state.js, hooks/workflow-state/effective-state/write-code-resume.js
# Tags: workflow-state, write-code-resume, cascade, persist-resolutions, append-only, scope:issue-specific, pwsh-not-required, TL2
#
# H — a masked step is never written back to the event stream.
#
# WHY: stage-4 evidence resolution ends by calling persistResolutions(), which
# appends a real `step_status: complete` event with origin
# "next-step-evidence-resolution". If the cascade masked a step but left it in
# the `resolutions` array, that append would durably record a completion the
# session had just decided to reopen — an append-only stream cannot take it back.
# So the cascade must REMOVE masked steps from `resolutions`, not merely rewrite
# their derived status.
#
# The control session proves the harness can actually observe a write-back: if it
# could not, H1 would be vacuously true.
#
# TL3 gap (what this test does NOT catch):
# - Whether next-step is invoked by the real session loop at the right moment.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: skill-orchestration.

CASE_TAG=h
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

REPO="$TMPROOT/repo-h"
mk_repo "$REPO"
mkdir -p "$REPO/docs"
printf 'note\n' > "$REPO/docs/history.md"
git -C "$REPO" add -A >/dev/null 2>&1
REPO_N="$(nrm "$REPO")"
export CLAUDE_PROJECT_DIR="$REPO_N"

SID_MASK="seq1665-h-mask"
SID_CTRL="seq1665-h-ctrl"

seed() { # env: SEED_SID, SEED_OUTCOME ("" = none)
    js_g '
const S = require(process.env.M_SIO);
const sid = process.env.SEED_SID;
const outcome = process.env.SEED_OUTCOME;
for (const [s, st] of [
  ["workflow_init", "complete"], ["clarify_intent", "complete"],
  ["research", "skipped"], ["outline", "skipped"], ["detail", "skipped"],
  ["branching_complete", "complete"], ["write_tests", "complete"],
  ["review_tests", "complete"], ["write_code", "complete"],
  ["review_security", "complete"],
]) S.markStep(sid, s, st);
if (outcome) S.markStep(sid, "run_tests", "pending", { run_outcome: outcome });
else S.markStep(sid, "run_tests", "complete");
console.log("seeded=" + sid);
'
}

SEED_SID="$SID_MASK" SEED_OUTCOME="fail"; export SEED_SID SEED_OUTCOME; seed
require_js_ok "H seed (masked)" || { finish; exit; }
SEED_SID="$SID_CTRL" SEED_OUTCOME=""; export SEED_SID SEED_OUTCOME; seed
require_js_ok "H seed (control)" || { finish; exit; }

"$RWT" 120 node "$NEXT_STEP" --session "$SID_MASK" >/dev/null 2>&1
"$RWT" 120 node "$NEXT_STEP" --session "$SID_CTRL" >/dev/null 2>&1

count_writeback() { # env: PROBE_SID
    "$RWT" 120 node -e '
const S = require(process.env.M_SIO);
const st = S.readState(process.env.PROBE_SID);
const n = st.events.filter((e) =>
  e.kind === "step_status" && e.origin === "next-step-evidence-resolution").length;
console.log(n);
' 2>&1
}

PROBE_SID="$SID_MASK"; export PROBE_SID
MASK_N="$(count_writeback)"
PROBE_SID="$SID_CTRL"; export PROBE_SID
CTRL_N="$(count_writeback)"

assert_eq "H1 no evidence-resolution write-back while the cascade is active" "0" "$MASK_N"
if [ "${CTRL_N:-0}" -gt 0 ] 2>/dev/null; then
    pass "H2 control session DOES write back (non-vacuity: $CTRL_N event(s))"
else
    fail "H2 control session wrote back nothing -- H1 would be vacuous (got [$CTRL_N])"
fi

# H3 — the masked step must also be absent from the derived resolutions the
# cascade hands back, which is what persistResolutions consumes.
PROBE_SID_MASK="$SID_MASK"; export PROBE_SID_MASK
js_g '
const S = require(process.env.M_SIO);
const { reconcileEffectiveState } = require(process.env.M_ES);
const sid = process.env.PROBE_SID_MASK;
const st = S.readState(sid);
const eff = reconcileEffectiveState(st, sid, { resolveAll: true });
const names = (eff.resolutions || []).map((r) => r.step);
console.log("H3.write_code_in_resolutions=" + names.includes("write_code"));
console.log("H3.write_code_status=" + eff.steps.write_code.status);
'
if require_js_ok "H3: resolutions probe"; then
    assert_js "H3 masked write_code is not offered for persistence" H3.write_code_in_resolutions "false"
    assert_js "H3 masked write_code is reopened (non-vacuity)" H3.write_code_status "pending"
fi

finish
