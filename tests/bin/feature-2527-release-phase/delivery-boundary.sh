#!/usr/bin/env bash
# delivery-boundary.sh — #2527 3-2: a delivery-boundary reset settles user_verification for navigation only.
# Tests: hooks/workflow-state/effective-state/delivery-boundary.js, bin/workflow/lib/next-step/verdict.js
# Tags: scope:issue-specific, workflow, release-phase, delivery-boundary
# TL2: v5 fixtures + real next-step + fake gh. Recorded status is read from the raw state file.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

# TL3 gap (not caught here): a real `gh pr merge` against GitHub followed by the live hook chain.
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh
# category: hook-registration.
RP_TMP="$(make_tmp)"
readonly RP_TMP
trap rp_teardown EXIT
harness_isolate "$RP_TMP"
rp_setup

# post_merge_state <sid> — right after `gh pr merge`: uv pending (post-merge), merge_to_main pending.
post_merge_state() {
  mk_state "{\"sid\":\"$1\",\"path\":\"pull_request\",\"entered\":true,\"upto\":\"user_verification\",\"steps\":\"user_verification=complete;user_verification=pending;merge_to_main=pending\",\"uvReset\":\"post-merge\"}"
}

case_begin "post-merge pending + gh MERGED -> past merge_to_main, not back to approval" "hooks/workflow-state/effective-state/delivery-boundary.js"
post_merge_state bm-merged
export RP_GH_MODE=MERGED
out="$(run_next_step bm-merged)"
check "navigates to cleanup (worktree-end)" "$(field "$out" NEXT_SKILL)" "worktree-end"
check_not_contains "never routes back to get-release-approval" "$out" "NEXT_SKILL=get-release-approval"
check "merge_to_main persisted complete by evidence" "$(last_status bm-merged merge_to_main)" "complete"
check "recorded user_verification stays pending" "$(last_status bm-merged user_verification)" "pending"
check "recorded reset_reason kept" "$(last_reset bm-merged user_verification)" "post-merge"
case_end

case_begin "post-merge pending + gh failure -> NEXT_SKILL=merge-to-main (idempotent retry)" "hooks/workflow-state/effective-state/delivery-boundary.js"
post_merge_state bm-fail
export RP_GH_MODE=fail
: > "$RP_GH_LOG"
out="$(run_next_step bm-fail)"
check "NEXT_SKILL=merge-to-main" "$(field "$out" NEXT_SKILL)" "merge-to-main"
check "REASON=merge_to_main" "$(field "$out" REASON)" "merge_to_main"
check_contains "the evaluated merge_to_main step queried gh" "$(cat "$RP_GH_LOG")" "pr"
check "merge_to_main stays pending in the record" "$(last_status bm-fail merge_to_main)" "pending"
check "user_verification stays pending in the record" "$(last_status bm-fail user_verification)" "pending"
case_end

case_begin "post-push reset behaves the same as post-merge" "hooks/workflow-state/effective-state/delivery-boundary.js"
mk_state '{"sid":"bm-push","path":"pull_request","entered":true,"upto":"user_verification","steps":"user_verification=pending;merge_to_main=pending","uvReset":"post-push"}'
export RP_GH_MODE=fail
out="$(run_next_step bm-push)"
check "post-push pending also routes to merge-to-main" "$(field "$out" NEXT_SKILL)" "merge-to-main"
case_end

case_begin "plain pending (no boundary reset) -> back to get-release-approval" "bin/workflow/lib/next-step/verdict.js"
mk_state '{"sid":"bm-plain","path":"pull_request","entered":true,"upto":"user_verification","steps":"user_verification=pending;merge_to_main=pending"}'
export RP_GH_MODE=MERGED
out="$(run_next_step bm-plain)"
check "NEXT_SKILL=get-release-approval" "$(field "$out" NEXT_SKILL)" "get-release-approval"
check "REASON=user_verification" "$(field "$out" REASON)" "user_verification"
check "recorded user_verification stays pending" "$(last_status bm-plain user_verification)" "pending"
check "merge_to_main is not evaluated ahead of the approval" "$(last_status bm-plain merge_to_main)" "pending"
case_end

case_begin "other reset reasons are not a delivery boundary" "hooks/workflow-state/effective-state/delivery-boundary.js"
mk_state '{"sid":"bm-other","path":"pull_request","entered":true,"upto":"user_verification","steps":"user_verification=pending;merge_to_main=pending","uvReset":"manual-reset"}'
export RP_GH_MODE=MERGED
out="$(run_next_step bm-other)"
check "non-boundary reset_reason returns to approval" "$(field "$out" NEXT_SKILL)" "get-release-approval"
case_end

case_begin "isDeliveryBoundaryReset predicate" "hooks/workflow-state/effective-state/delivery-boundary.js"
pred="$(run_with_timeout 30 node -e '
  let m; try { m = require(process.env.RP_SCRIPT_CHECKOUT_ROOT + "/hooks/workflow-state/effective-state/delivery-boundary.js"); }
  catch (e) { console.log("MISSING:" + e.code); process.exit(0); }
  const f = m.isDeliveryBoundaryReset;
  console.log([f({ status: "pending", reset_reason: "post-merge" }), f({ status: "pending", reset_reason: "post-push" }),
    f({ status: "pending" }), f({ status: "pending", reset_reason: "other" })].join(","));
' 2>&1)"
check "post-merge,post-push true; none/other false" "$pred" "true,true,false,false"
case_end

case_begin "navigateBoundaryStatus: branching_complete post-push settles on merge_to_main settled or a post-push approval reset" "hooks/workflow-state/effective-state/delivery-boundary.js"
# label | state.steps JSON | expected navigate status for branching_complete (pending)
while IFS='|' read -r label steps want; do
  [ -z "$label" ] && continue
  got="$(run_with_timeout 30 node -e '
    let m; try { m = require(process.env.RP_SCRIPT_CHECKOUT_ROOT + "/hooks/workflow-state/effective-state/delivery-boundary.js"); }
    catch (e) { console.log("MISSING:" + e.code); process.exit(0); }
    console.log(String(m.navigateBoundaryStatus("branching_complete", "pending", { steps: JSON.parse(process.argv[1]) })));
  ' "$steps" 2>&1)"
  check "$label" "$got" "$want"
done <<'ROWS'
uv post-push, merge_to_main absent -> complete|{"branching_complete":{"status":"pending","reset_reason":"post-push"},"user_verification":{"status":"pending","reset_reason":"post-push"}}|complete
uv post-push, merge_to_main pending -> complete|{"branching_complete":{"status":"pending","reset_reason":"post-push"},"user_verification":{"status":"pending","reset_reason":"post-push"},"merge_to_main":{"status":"pending"}}|complete
uv post-merge, merge_to_main absent -> null|{"branching_complete":{"status":"pending","reset_reason":"post-push"},"user_verification":{"status":"pending","reset_reason":"post-merge"}}|null
uv complete, merge_to_main absent -> null|{"branching_complete":{"status":"pending","reset_reason":"post-push"},"user_verification":{"status":"complete"}}|null
uv absent, merge_to_main absent -> null|{"branching_complete":{"status":"pending","reset_reason":"post-push"}}|null
uv plain pending, merge_to_main absent -> null|{"branching_complete":{"status":"pending","reset_reason":"post-push"},"user_verification":{"status":"pending"}}|null
merge_to_main complete, uv complete -> complete|{"branching_complete":{"status":"pending","reset_reason":"post-push"},"user_verification":{"status":"complete"},"merge_to_main":{"status":"complete"}}|complete
merge_to_main skipped, uv absent -> complete|{"branching_complete":{"status":"pending","reset_reason":"post-push"},"merge_to_main":{"status":"skipped"}}|complete
branching reset not post-push -> null|{"branching_complete":{"status":"pending","reset_reason":"post-merge"},"user_verification":{"status":"pending","reset_reason":"post-push"}}|null
branching without reset_reason -> null|{"branching_complete":{"status":"pending"},"user_verification":{"status":"pending","reset_reason":"post-push"},"merge_to_main":{"status":"complete"}}|null
ROWS
other="$(run_with_timeout 30 node -e '
  let m; try { m = require(process.env.RP_SCRIPT_CHECKOUT_ROOT + "/hooks/workflow-state/effective-state/delivery-boundary.js"); }
  catch (e) { console.log("MISSING:" + e.code); process.exit(0); }
  const st = { steps: { branching_complete: { status: "pending", reset_reason: "post-push" },
    user_verification: { status: "pending", reset_reason: "post-push" } } };
  console.log([m.navigateBoundaryStatus("branching_complete", "complete", st),
    m.navigateBoundaryStatus("merge_to_main", "pending", st),
    m.navigateBoundaryStatus("branching_complete", "pending", null)].map(String).join(","));
' 2>&1)"
check "non-pending status / other steps / null state -> null" "$other" "null,null,null"
case_end

case_begin "interrupted direct delivery: navigation reaches merge_to_main, not branching" "hooks/workflow-state/effective-state/delivery-boundary.js"
export ENFORCE_WORKTREE=off RP_GH_MODE=NONE
# A protected push to main landed after approval (uv post-push) and reset branching_complete
# post-push, but /merge-to-main has not recorded merge_to_main yet. A dirty tree keeps merge_to_main unobservable.
git -C "$RP_REPO" checkout -q main
printf 'dirty\n' > "$RP_REPO/dirty-nav.txt"
mk_state '{"sid":"bm-direct","path":"direct","branch":"main","upto":"user_verification","steps":"user_verification=complete;user_verification=pending;branching_complete=pending;merge_to_main=pending","uvReset":"post-push","annotate":"branching_complete.reset_reason=post-push"}'
out="$(run_next_step bm-direct)"
check "NEXT_SKILL=merge-to-main" "$(field "$out" NEXT_SKILL)" "merge-to-main"
check "REASON=merge_to_main" "$(field "$out" REASON)" "merge_to_main"
check_not_contains "never rewinds to branching" "$out" "REASON=branching_complete"
check "recorded branching_complete stays pending" "$(last_status bm-direct branching_complete)" "pending"
check "merge_to_main not recorded without evidence" "$(last_status bm-direct merge_to_main)" "pending"
# Contrast: approval still complete (no post-push reset) -> the branching reset is not settled.
mk_state '{"sid":"bm-direct-nouv","path":"direct","branch":"main","upto":"user_verification","steps":"user_verification=complete;branching_complete=pending;merge_to_main=pending","annotate":"branching_complete.reset_reason=post-push"}'
out="$(run_next_step bm-direct-nouv)"
check_contains "without a post-push approval reset the branching reset stays unsettled" "$out" "branching_complete is pending"
check_not_contains "and navigation does not reach merge_to_main" "$out" "NEXT_SKILL=merge-to-main"
rm -f "$RP_REPO/dirty-nav.txt"
git -C "$RP_REPO" checkout -q feature/2527-rp
export ENFORCE_WORKTREE=on
case_end

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit "$FAIL"
