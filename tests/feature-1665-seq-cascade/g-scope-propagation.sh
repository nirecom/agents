#!/bin/bash
# tests/feature-1665-seq-cascade/g-scope-propagation.sh
# Tests: hooks/workflow-state/effective-state.js, bin/workflow/lib/next-step/verdict.js, bin/workflow/lib/next-step/list.js, bin/workflow/lib/next-step/advance-shared.js, hooks/workflow-gate.js
# Tags: workflow-state, write-code-resume, cascade, propagation, next-step, workflow-gate, scope:issue-specific, pwsh-not-required, TL2
#
# G — R5 propagation scope: the cascade lives INSIDE reconcileEffectiveState, so
# every consumer of that function inherits it for free. This case drives the
# three user-visible consumers as real subprocesses and asserts they all agree.
#
# WHY it must be one implementation and not three: if `next-step` reopened
# write_code but the gate still saw it complete, a session could commit code that
# no one re-reviewed after the failing test run — the exact hole #1665 closes.
#
# Classifier coverage (CPR-ORTH): each assertion is paired with a control session
# whose only difference is run_outcome=pass, so an over-blocking implementation
# fails just as loudly as an under-blocking one.
#
# TL3 gap (what this test does NOT catch):
# - Whether workflow-gate.js is actually registered as a PreToolUse hook in the
#   deployed settings.json (this case spawns the hook script directly).
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: hook-registration.

CASE_TAG=g
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

REPO="$TMPROOT/repo-g"
mk_repo "$REPO"
REPO_N="$(nrm "$REPO")"
export CLAUDE_PROJECT_DIR="$REPO_N"

SID_FAIL="seq1665-g-fail"
SID_PASS="seq1665-g-pass"
SID_ADV="seq1665-g-adv"

# Seeded via env (the `js` helper does not forward argv).
seed() {
    js_g '
const S = require(process.env.M_SIO);
const sid = process.env.SEED_SID;
for (const [s, st] of [
  ["workflow_init", "complete"], ["clarify_intent", "complete"],
  ["research", "skipped"], ["outline", "skipped"], ["detail", "skipped"],
  ["branching_complete", "complete"], ["write_tests", "complete"],
  ["review_tests", "complete"], ["write_code", "complete"],
  ["review_security", "complete"],
]) S.markStep(sid, s, st);
S.markStep(sid, "run_tests", "pending", { run_outcome: process.env.SEED_OUTCOME });
console.log("seeded=" + sid);
'
}

SEED_SID="$SID_FAIL" SEED_OUTCOME="fail"; export SEED_SID SEED_OUTCOME; seed
require_js_ok "G seed (fail)" || { finish; exit; }
SEED_SID="$SID_PASS" SEED_OUTCOME="pass"; export SEED_SID SEED_OUTCOME; seed
require_js_ok "G seed (pass)" || { finish; exit; }
SEED_SID="$SID_ADV" SEED_OUTCOME="fail"; export SEED_SID SEED_OUTCOME; seed
require_js_ok "G seed (advance)" || { finish; exit; }

# --------------------------------------------------------- G1/G2: verdict.js
NS_FAIL="$("$RWT" 120 node "$NEXT_STEP" --session "$SID_FAIL" 2>&1)"
NS_PASS="$("$RWT" 120 node "$NEXT_STEP" --session "$SID_PASS" 2>&1)"

assert_contains "G1 next-step reopens write_code after a failing run" "NEXT_SKILL=write-code" "$NS_FAIL"
assert_contains "G2 next-step tells the session to run it" "ACTION=invoke" "$NS_FAIL"
assert_not_contains "G2 control: passing run does not reopen write_code" "NEXT_SKILL=write-code" "$NS_PASS"

# ------------------------------------------------------------- G3/G4: list.js
LS_FAIL="$("$RWT" 120 node "$NEXT_STEP" --list --session "$SID_FAIL" 2>&1)"
LS_PASS="$("$RWT" 120 node "$NEXT_STEP" --list --session "$SID_PASS" 2>&1)"
# list.js pads the ordinal to width 2 with a LEADING SPACE (pad2), so rows 1-9
# render as "[x]  9  step" — the row regex must accept " N" as well as "NN".
ROWS="$(printf '%s\n' "$LS_FAIL" | grep -cE '^\[.\] [ 0-9][0-9]  ')"
assert_eq "G3 --list renders one row per VALID_STEPS entry" "16" "$ROWS"

WC_ROW_FAIL="$(printf '%s\n' "$LS_FAIL" | grep -E '^\[.\] [ 0-9][0-9]  write_code ' || true)"
WC_ROW_PASS="$(printf '%s\n' "$LS_PASS" | grep -E '^\[.\] [ 0-9][0-9]  write_code ' || true)"
assert_ne "G4 --list has a write_code row" "" "$WC_ROW_FAIL"
assert_not_contains "G4 masked write_code is not rendered complete" "[x]" "$WC_ROW_FAIL"
assert_contains "G4 control: unmasked write_code IS rendered complete" "[x]" "$WC_ROW_PASS"

# ----------------------------------------------------- G5/G6: workflow-gate.js
run_gate() { # run_gate <sid>
    printf '%s' "{\"session_id\":\"$1\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m x\",\"cwd\":\"$REPO_N\"}}" \
        | "$RWT" 120 node "$GATE_HOOK" 2>&1
}
GATE_FAIL="$(run_gate "$SID_FAIL")"
GATE_PASS="$(run_gate "$SID_PASS")"

assert_contains "G5 gate blocks the commit while write_code is reopened" '"decision":"block"' "$GATE_FAIL"
assert_contains "G5 gate names write_code as incomplete" "write_code" "$GATE_FAIL"
assert_not_contains "G6 control: passing run leaves write_code out of the block list" "write_code" "$GATE_PASS"

# ------------------------------------------------------ G7: advance-shared.js
ADV="$("$RWT" 120 node "$NEXT_STEP" --advance --step run_tests --status complete --next --session "$SID_ADV" 2>&1)"
assert_contains "G7 advance-shared resolves the current step through the cascade" "ADVANCE_SCOPE=not-current-step" "$ADV"

finish
