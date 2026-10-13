#!/usr/bin/env bash
# web-merge-channel.sh — #2527 4-4: AUTO_MERGE_PR=off web-merge evidence, release wait, and the WAIT line.
# Tests: bin/workflow/lib/next-step/release-wait.js, hooks/workflow-state/release-approval.js, bin/workflow/lib/parse-next-step-output.js
# Tags: scope:issue-specific, workflow, release-phase, web-merge, gh-stub
# TL2: v5 fixtures (auto_merge_pr fixed at branching) + the real next-step CLI + node-copy gh stubs
# (fake-forge.js) answering state / mergeStateStatus, with a delay knob for the query time budget.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

# TL3 gap (not caught here): a live GitHub mergeStateStatus answer and the harness relaunching
# Claude after the human merges on the web. Closest-to-action mitigation: WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: hook-registration.
RP_TMP="$(make_tmp)"
readonly RP_TMP
trap rp_teardown EXIT
harness_isolate "$RP_TMP"
rp_setup
rp_fake_forge "$RP_TMP/forgebin" gh glab

WAIT_SPEC='"path":"pull_request","autoMerge":"off","entered":true,"upto":"user_verification","steps":"user_verification=pending"'
# ns <state> <mergeStateStatus> <sid> [args...] — next-step against the fake forge.
ns() {
  local st="$1" merge="$2"
  shift 2
  FAKE_FORGE_STATE="$st" FAKE_FORGE_MERGE="$merge" run_next_step "$@"
}
ev_len() { ev_query "$1" "e.length"; }
uv_complete_n() { ev_query "$1" 'e.filter((x) => x.kind === "step_status" && x.step === "user_verification" && x.status === "complete").length'; }
now_ms() { date +%s%3N; }

case_begin "OPEN + CLEAN: invoke get-release-approval with WAIT=human-web-merge, state unchanged" "bin/workflow/lib/next-step/release-wait.js"
mk_state "{\"sid\":\"wm-clean\",$WAIT_SPEC}"
before="$(ev_len wm-clean)"
: > "$RP_TMP/forge.log"
out="$(ns OPEN CLEAN wm-clean)"
check "ACTION invoke" "$(field "$out" ACTION)" "invoke"
check "NEXT_SKILL get-release-approval" "$(field "$out" NEXT_SKILL)" "get-release-approval"
check "WAIT line" "$(field "$out" WAIT)" "human-web-merge"
check "no event appended" "$(ev_len wm-clean)" "$before"
check "user_verification still pending" "$(last_status wm-clean user_verification)" "pending"
check_contains "the forge was queried" "$(cat "$RP_TMP/forge.log")" "|gh pr view"
# Plan 4-4: evidence + mergeStateForBranch share one memoized gh call per next-step run.
check "exactly one gh pr view per next-step run (memoized forge query)" "$(grep -cF '|gh pr view' "$RP_TMP/forge.log")" "1"
case_end

case_begin "OPEN + not CLEAN: invoke without a WAIT line (recovery is Claude's work)" "bin/workflow/lib/next-step/release-wait.js"
for merge in BEHIND DIRTY BLOCKED DRAFT; do
  mk_state "{\"sid\":\"wm-$merge\",$WAIT_SPEC}"
  out="$(ns OPEN "$merge" "wm-$merge")"
  check "$merge: ACTION invoke" "$(field "$out" ACTION)" "invoke"
  check "$merge: NEXT_SKILL get-release-approval" "$(field "$out" NEXT_SKILL)" "get-release-approval"
  check_not_contains "$merge: no WAIT line" "$out" "WAIT="
  check "$merge: user_verification still pending" "$(last_status "wm-$merge" user_verification)" "pending"
done
case_end

case_begin "MERGED: one next-step run settles merge_to_main and moves to worktree-end" "hooks/workflow-state/release-approval.js"
mk_state "{\"sid\":\"wm-merged\",$WAIT_SPEC}"
out="$(ns MERGED CLEAN wm-merged)"
check "NEXT_SKILL worktree-end" "$(field "$out" NEXT_SKILL)" "worktree-end"
check "REASON cleanup" "$(field "$out" REASON)" "cleanup"
check "merge_to_main complete" "$(last_status wm-merged merge_to_main)" "complete"
check "no user_verification complete event (web merge is the approval)" "$(uv_complete_n wm-merged)" "0"
check_not_contains "no WAIT line" "$out" "WAIT="
case_end

case_begin "CLOSED: ACTION=blocked with the reopen hint" "bin/workflow/lib/next-step/release-wait.js"
mk_state "{\"sid\":\"wm-closed\",$WAIT_SPEC}"
out="$(ns CLOSED CLEAN wm-closed)"
check "ACTION blocked" "$(field "$out" ACTION)" "blocked"
check_contains "hint" "$(field "$out" NEXT_HINT)" "PR was closed without merge; reopen or re-run /commit-push"
check_not_contains "no WAIT line" "$out" "WAIT="
check "user_verification still pending" "$(last_status wm-closed user_verification)" "pending"
case_end

case_begin "unreadable PR state (gh failure / slow gh): blocked within the C4 budget" "bin/workflow/lib/next-step/release-wait.js"
UNREAD_HINT="cannot read PR state; check gh auth / network and re-run /get-release-approval"
mk_state "{\"sid\":\"wm-fail\",$WAIT_SPEC}"
out="$(ns FAIL CLEAN wm-fail)"
check "gh failure: ACTION blocked" "$(field "$out" ACTION)" "blocked"
check_contains "gh failure: hint" "$(field "$out" NEXT_HINT)" "$UNREAD_HINT"
mk_state "{\"sid\":\"wm-slow\",$WAIT_SPEC}"
t0="$(now_ms)"
out="$(FAKE_FORGE_DELAY_MS=4000 ns OPEN CLEAN wm-slow)"
elapsed=$(( $(now_ms) - t0 ))
check "slow gh: ACTION blocked" "$(field "$out" ACTION)" "blocked"
check_contains "slow gh: hint" "$(field "$out" NEXT_HINT)" "$UNREAD_HINT"
check "slow gh: whole next-step run under 5000ms (got ${elapsed}ms)" "$([ "$elapsed" -lt 5000 ] && echo yes || echo no)" "yes"
case_end

case_begin "AUTO_MERGE_PR=on + MERGED keeps the dialog behaviour (no WAIT, approval still asked)" "hooks/workflow-state/release-approval.js"
mk_state '{"sid":"wm-on","path":"pull_request","autoMerge":"on","entered":true,"upto":"user_verification","steps":"user_verification=pending"}'
out="$(ns MERGED CLEAN wm-on)"
check "NEXT_SKILL get-release-approval" "$(field "$out" NEXT_SKILL)" "get-release-approval"
check_not_contains "no WAIT line" "$out" "WAIT="
check "merge_to_main not settled by the web merge" "$(last_status wm-on merge_to_main)" "<none>"
case_end

case_begin "web-merge: a delivery-boundary reset is no approval; OPEN + CLEAN still waits" "hooks/workflow-state/release-approval.js"
mk_state '{"sid":"wm-reset","path":"pull_request","autoMerge":"off","entered":true,"upto":"user_verification","steps":"user_verification=complete;user_verification=pending","uvReset":"post-push"}'
out="$(ns OPEN CLEAN wm-reset)"
check "NEXT_SKILL get-release-approval" "$(field "$out" NEXT_SKILL)" "get-release-approval"
check "WAIT line" "$(field "$out" WAIT)" "human-web-merge"
check "merge_to_main not reached" "$(last_status wm-reset merge_to_main)" "<none>"
case_end

case_begin "direct delivery stays on the dialog channel even with AUTO_MERGE_PR=off" "hooks/workflow-state/release-approval.js"
export ENFORCE_WORKTREE=off
printf 'dirty\n' > "$RP_REPO/dirty.txt"
mk_state '{"sid":"wm-direct","path":"direct","autoMerge":"off","upto":"user_verification","steps":"user_verification=pending"}'
: > "$RP_TMP/forge.log"
out="$(ns OPEN CLEAN wm-direct)"
check "NEXT_SKILL get-release-approval" "$(field "$out" NEXT_SKILL)" "get-release-approval"
check_not_contains "no WAIT line" "$out" "WAIT="
check "no forge query on direct" "$(grep -c . "$RP_TMP/forge.log")" "0"
chan="$(run_with_timeout 30 node "$RP_SCRIPT_CHECKOUT_ROOT/bin/workflow/release-channel" --session wm-direct 2>&1)"
check_contains "release-channel CLI: direct -> user-verified-dialog" "$chan" "user-verified-dialog"
rm -f "$RP_REPO/dirty.txt"
export ENFORCE_WORKTREE=on
chan="$(run_with_timeout 30 node "$RP_SCRIPT_CHECKOUT_ROOT/bin/workflow/release-channel" --session wm-clean 2>&1)"
check_contains "release-channel CLI: pull_request + off -> web-merge" "$chan" "web-merge"
case_end

case_begin "merge_to_main --advance under web-merge: MERGED accepted, OPEN refused" "hooks/workflow-state/release-approval.js"
mk_state "{\"sid\":\"wm-adv-ok\",$WAIT_SPEC}"
out="$(ns MERGED CLEAN wm-adv-ok --advance --step merge_to_main --complete)"
check "MERGED: merge_to_main complete" "$(last_status wm-adv-ok merge_to_main)" "complete"
check_not_contains "MERGED: no refusal" "$out" "NOT recorded"
mk_state "{\"sid\":\"wm-adv-no\",$WAIT_SPEC}"
out="$(ns OPEN CLEAN wm-adv-no --advance --step merge_to_main --complete)"
check "OPEN: merge_to_main not complete" "$(last_status wm-adv-no merge_to_main)" "<none>"
check_contains "OPEN: refused (no-release-evidence)" "$out" "merge_to_main NOT recorded"
case_end

case_begin "user_verification MARK_STEP is still refused under web-merge" "hooks/workflow-state/release-approval.js"
mk_state "{\"sid\":\"wm-mark\",$WAIT_SPEC}"
FAKE_FORGE_STATE=MERGED mark_bash wm-mark "$RP_REPO_M" 'echo "<<WORKFLOW_MARK_STEP_user_verification_complete>>"' 0 >/dev/null
check "user_verification stays pending" "$(last_status wm-mark user_verification)" "pending"
check "no user_verification complete event" "$(uv_complete_n wm-mark)" "0"
case_end

case_begin "TL1: parseNextStepOutput carries WAIT (empty when absent)" "bin/workflow/lib/parse-next-step-output.js"
got="$(run_with_timeout 30 node -e '
  const p = require(process.env.RP_SCRIPT_CHECKOUT_ROOT + "/bin/workflow/lib/parse-next-step-output.js");
  const base = "ACTION=invoke\nNEXT_SKILL=get-release-approval\nNEXT_HINT=x\nREASON=user_verification\n";
  console.log([p.parseNextStepOutput(base + "WAIT=human-web-merge\n").WAIT, String(p.parseNextStepOutput(base).WAIT)].join("|"));
' 2>&1)"
check "WAIT parsed / absent -> empty" "$got" "human-web-merge|"
case_end

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit "$FAIL"
