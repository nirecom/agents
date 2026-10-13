#!/usr/bin/env bash
# delivery-path-note.sh — #2527 3-10: DELIVERY_PATH_MISMATCH appears only when recorded != live.
# Tests: bin/workflow/lib/next-step/delivery-path-note.js, bin/workflow/lib/parse-next-step-output.js
# Tags: scope:issue-specific, workflow, release-phase, delivery-path
# TL2: real next-step with ENFORCE_WORKTREE flipped against the recorded delivery_path.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

# TL3 gap (not caught here): a model reading the note and choosing the recovery route.
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh
# category: skill-orchestration.
RP_TMP="$(make_tmp)"
readonly RP_TMP
trap rp_teardown EXIT
harness_isolate "$RP_TMP"
rp_setup

mismatch_lines() { printf '%s\n' "$1" | grep -c '^DELIVERY_PATH_MISMATCH=' || true; }

case_begin "recorded pull_request + live on -> no note" "bin/workflow/lib/next-step/delivery-path-note.js"
mk_state '{"sid":"dp-same","path":"pull_request","entered":true,"upto":"user_verification","steps":"user_verification=pending"}'
export ENFORCE_WORKTREE=on
out="$(run_next_step dp-same)"
check "verdict produced (guards a vacuous absence)" "$(field "$out" NEXT_SKILL)" "get-release-approval"
check "no DELIVERY_PATH_MISMATCH line" "$(mismatch_lines "$out")" "0"
case_end

case_begin "recorded pull_request + live off -> exactly one note, recorded value still drives" "bin/workflow/lib/next-step/delivery-path-note.js"
export ENFORCE_WORKTREE=off
out="$(run_next_step dp-same)"
check "exactly one note line" "$(mismatch_lines "$out")" "1"
check "note content" "$(field "$out" DELIVERY_PATH_MISMATCH)" "recorded:pull_request live:direct hooks-enforce:live recover:WORKFLOW_RESET_FROM_branching_complete"
check "navigation keeps the recorded path" "$(field "$out" NEXT_SKILL)" "get-release-approval"
case_end

case_begin "recorded direct + live on -> note in the other direction" "bin/workflow/lib/next-step/delivery-path-note.js"
mk_state '{"sid":"dp-d","path":"direct","upto":"user_verification","steps":"user_verification=pending"}'
export ENFORCE_WORKTREE=on
out="$(run_next_step dp-d)"
check "exactly one note line" "$(mismatch_lines "$out")" "1"
check "note content" "$(field "$out" DELIVERY_PATH_MISMATCH)" "recorded:direct live:pull_request hooks-enforce:live recover:WORKFLOW_RESET_FROM_branching_complete"
case_end

case_begin "parse-next-step-output accepts DELIVERY_PATH_MISMATCH as optional" "bin/workflow/lib/parse-next-step-output.js"
parsed="$(run_with_timeout 30 node -e '
  const p = require(process.env.RP_SCRIPT_CHECKOUT_ROOT + "/bin/workflow/lib/parse-next-step-output.js");
  const base = "ACTION=invoke\nNEXT_SKILL=get-release-approval\nNEXT_HINT=x\nREASON=user_verification\n";
  const withNote = p.parseNextStepOutput(base + "DELIVERY_PATH_MISMATCH=recorded:pull_request live:direct\n");
  const without = p.parseNextStepOutput(base);
  console.log([p.OPTIONAL_KEYS.includes("DELIVERY_PATH_MISMATCH"), withNote.ACTION,
    withNote.DELIVERY_PATH_MISMATCH, without.ACTION, JSON.stringify(without.DELIVERY_PATH_MISMATCH)].join("|"));
' 2>&1)"
check "optional key listed, parsed when present, empty when absent" "$parsed" "true|invoke|recorded:pull_request live:direct|invoke|\"\""
case_end

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit "$FAIL"
