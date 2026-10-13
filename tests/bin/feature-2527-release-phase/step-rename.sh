#!/usr/bin/env bash
# step-rename.sh — #2527 3-14: step deliver -> merge_to_main, skill /deliver -> /merge-to-main.
# Tests: hooks/workflow-state/step-table.js, hooks/workflow-state/state-io/projection.js, bin/workflow/lib/next-step/steps.js, hooks/user-prompt-submit-mechanism-check.js
# Tags: scope:issue-specific, issue-2527, workflow, release-phase, step-rename, TL2
# TL2: static grep of the tree + v5 fixtures holding legacy `step:"deliver"` events, read through
# the real projection, next-step and mechanism-check modules.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

# TL3 gap (not caught here): a live session state written by the pre-rename code on this branch
# being resumed by a real Claude Code session after the rename lands.
RP_TMP="$(make_tmp)"
readonly RP_TMP
trap rp_teardown EXIT
harness_isolate "$RP_TMP"
rp_setup
ROOT="$_HELPERS_SCRIPT_CHECKOUT_ROOT"

# ============================================================================================
case_begin "no old step / skill name left in the tree" "hooks/workflow-state/step-table.js"
OLD_RE="\"deliver\"|'deliver'|/deliver\b|skills/deliver|\bdeliver:|settleDeliver|Deliver[A-Z(]"
# Allowlist: only the canonicalStepName mapping in step-table.js (a line naming merge_to_main).
# Append-only records (history / changelog / archives) are not renamed.
hits="$(git -C "$ROOT" grep -nE "$OLD_RE" -- hooks bin skills rules agents docs claude-global \
  ':!docs/history.md' ':!CHANGELOG.md' ':!**/CHANGELOG.md' ':!**/_archive/**' ':!**/_archived/**' 2>/dev/null \
  | grep -vE '^hooks/workflow-state/step-table\.js:[0-9]+:.*merge_to_main')"
if [ -z "$hits" ]; then
  pass "no old deliver step / skill reference outside the canonicalStepName mapping"
else
  fail "old deliver step / skill references remain" "$(printf '%s\n' "$hits" | head -n 15)"
fi
check "skills/deliver/ is gone" "$([ -e "$ROOT/skills/deliver" ] && echo present || echo absent)" "absent"
check "skills/merge-to-main/SKILL.md exists" "$([ -f "$ROOT/skills/merge-to-main/SKILL.md" ] && echo present || echo absent)" "present"
case_end

# ============================================================================================
case_begin "canonicalStepName maps deliver only" "hooks/workflow-state/step-table.js"
got="$(run_with_timeout 30 node -e '
  const m = require(process.env.RP_SCRIPT_CHECKOUT_ROOT + "/hooks/workflow-state/step-table.js");
  if (typeof m.canonicalStepName !== "function") { console.log("<canonicalStepName not exported>"); process.exit(0); }
  console.log(["deliver", "merge_to_main", "push_branch", "cleanup", "delivery_path"].map(m.canonicalStepName).join(","));
' 2>&1)"
check "deliver -> merge_to_main, others unchanged" "$got" "merge_to_main,merge_to_main,push_branch,cleanup,delivery_path"
case_end

# proj <sid> — "<merge_to_main status>|<has steps.deliver>" through the real readState projection.
proj() {
  run_with_timeout 30 node -e '
    const ws = require(process.env.RP_SCRIPT_CHECKOUT_ROOT + "/hooks/workflow-state");
    const st = ws.readState(process.argv[1]);
    const s = (st && st.steps) || {};
    console.log((s.merge_to_main ? s.merge_to_main.status : "<none>") + "|" + (Object.prototype.hasOwnProperty.call(s, "deliver") ? "has-deliver" : "no-deliver"));
  ' "$1" 2>&1
}

# ============================================================================================
case_begin "legacy deliver event projects to merge_to_main" "hooks/workflow-state/state-io/projection.js"
mk_state '{"sid":"sr-legacy","path":"pull_request","entered":true,"upto":"user_verification","steps":"user_verification=complete;deliver=complete"}'
check "deliver complete -> merge_to_main complete, no steps.deliver" "$(proj sr-legacy)" "complete|no-deliver"
export RP_GH_MODE=MERGED
out="$(run_next_step sr-legacy)"
skill="$(field "$out" NEXT_SKILL)"
case "$skill" in
  merge-to-main|worktree-end|session-close) pass "next-step returns /merge-to-main or a later skill ($skill)" ;;
  *) fail "next-step returns /merge-to-main or a later skill" "got NEXT_SKILL=[$skill] REASON=$(field "$out" REASON)" ;;
esac
check_not_contains "next-step never names the deliver skill" "$out" "NEXT_SKILL=deliver"
export RP_GH_MODE=NONE
case_end

case_begin "both names fold as one step in seq order" "hooks/workflow-state/state-io/projection.js"
mk_state '{"sid":"sr-old-new","path":"pull_request","entered":true,"upto":"user_verification","steps":"user_verification=complete;deliver=complete;merge_to_main=pending"}'
check "deliver complete then merge_to_main pending -> pending" "$(proj sr-old-new)" "pending|no-deliver"
mk_state '{"sid":"sr-new-old","path":"pull_request","entered":true,"upto":"user_verification","steps":"user_verification=complete;merge_to_main=pending;deliver=complete"}'
check "merge_to_main pending then deliver complete -> complete" "$(proj sr-new-old)" "complete|no-deliver"
case_end

# proj_ann <sid> — "<merge_to_main status>|<merge_to_main.decision or <none>>|<has steps.deliver>".
proj_ann() {
  run_with_timeout 30 node -e '
    const ws = require(process.env.RP_SCRIPT_CHECKOUT_ROOT + "/hooks/workflow-state");
    const st = ws.readState(process.argv[1]);
    const s = (st && st.steps) || {};
    const m = s.merge_to_main;
    console.log([m ? m.status : "<none>", m && m.decision !== undefined ? String(m.decision) : "<none>",
      Object.prototype.hasOwnProperty.call(s, "deliver") ? "has-deliver" : "no-deliver"].join("|"));
  ' "$1" 2>&1
}
# append_event <sid> <event-json> — appends one raw event (next seq) to the v5 fixture state file.
append_event() {
  run_with_timeout 30 node -e '
    const fs = require("fs");
    const f = process.env.WORKFLOW_STATE_DIR + "/" + process.argv[1] + ".json";
    const s = JSON.parse(fs.readFileSync(f, "utf8"));
    const ev = JSON.parse(process.argv[2]);
    s.events.push(Object.assign({ seq: s.events.length + 1, at: "2026-01-02T00:00:00.000Z", provenance: "observed", origin: "fixture-2527-rp" }, ev));
    fs.writeFileSync(f, JSON.stringify(s, null, 2));
  ' "$1" "$2" 2>&1
}

case_begin "legacy deliver step_annotation / step_annotations_cleared fold into merge_to_main" "hooks/workflow-state/state-io/projection.js"
mk_state '{"sid":"sr-ann","path":"pull_request","entered":true,"upto":"user_verification","steps":"user_verification=complete;merge_to_main=complete","annotate":"deliver.decision=legacy-ann"}'
check "deliver annotation lands on merge_to_main, no steps.deliver" "$(proj_ann sr-ann)" "complete|legacy-ann|no-deliver"
mk_state '{"sid":"sr-clr","path":"pull_request","entered":true,"upto":"user_verification","steps":"user_verification=complete;merge_to_main=complete","annotate":"merge_to_main.decision=new-ann"}'
append_event sr-clr '{"kind":"step_annotations_cleared","step":"deliver"}' >/dev/null
check "deliver annotations_cleared clears merge_to_main annotations, no steps.deliver" "$(proj_ann sr-clr)" "complete|<none>|no-deliver"
case_end

# ============================================================================================
case_begin "mechanism-check recognises a legacy deliver step" "hooks/user-prompt-submit-mechanism-check.js"
got="$(run_with_timeout 30 node -e '
  const m = require(process.env.RP_SCRIPT_CHECKOUT_ROOT + "/hooks/user-prompt-submit-mechanism-check.js");
  console.log(String(m.isKnownStep("deliver")) + "|" + String(m.isKnownStep("merge_to_main")) + "|" + m.describe([{ step: "deliver", kind: "stalled" }]));
' 2>&1)"
check "isKnownStep(deliver) and isKnownStep(merge_to_main)" "${got%%|mechanism*}" "true|true"
check_not_contains "describe never prints (unrecognized-step) for deliver" "$got" "(unrecognized-step)"
case_end

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit "$FAIL"
