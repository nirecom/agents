#!/usr/bin/env bash
# delivery-settle.sh — #2527 3-2b: deliver complete + user_verification boundary reset in one write.
# Tests: hooks/workflow-state/delivery-settle.js, hooks/workflow-state/record-step-verdict.js, hooks/workflow-state/effective-state.js
# Tags: scope:issue-specific, workflow, release-phase, delivery-settle
# TL2: direct module call + advance CLI + verdict persistResolutions. "One appendEvents" is proxied
# by the three events occupying contiguous seqs (no other writer runs in between).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

# TL3 gap (not caught here): a concurrent hook appending between two separate writes in a live
# session. Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: hook-registration.
RP_TMP="$(make_tmp)"
readonly RP_TMP
trap rp_teardown EXIT
harness_isolate "$RP_TMP"
rp_setup

# settle_shape <sid> — "<span>|<uv reset value>" over the last deliver-complete, uv-pending and
# uv reset_reason events; span 2 means the three are contiguous seqs.
settle_shape() {
  local expr
  IFS= read -r -d '' expr <<'JS'
(() => {
  const lastOf = (p) => { const r = e.filter(p); return r.length ? r[r.length - 1] : null; };
  const d = lastOf((x) => x.kind === "step_status" && x.step === "deliver" && x.status === "complete");
  const u = lastOf((x) => x.kind === "step_status" && x.step === "user_verification" && x.status === "pending");
  const r = lastOf((x) => x.kind === "step_annotation" && x.step === "user_verification" && x.key === "reset_reason");
  if (!d || !u || !r) return "missing:" + [!!d, !!u, !!r].join(",");
  const s = [d.seq, u.seq, r.seq];
  return (Math.max(...s) - Math.min(...s)) + "|" + r.value;
})()
JS
  ev_query "$1" "$expr"
}

case_begin "settleDeliver direct call writes the three events together" "hooks/workflow-state/delivery-settle.js"
mk_state '{"sid":"ds-unit","path":"pull_request","entered":true,"upto":"deliver","steps":"deliver=pending"}'
unit="$(run_with_timeout 30 node -e '
  let m; try { m = require(process.env.RP_SCRIPT_CHECKOUT_ROOT + "/hooks/workflow-state/delivery-settle.js"); }
  catch (e) { console.log("MISSING:" + e.code); process.exit(0); }
  m.settleDeliver("ds-unit", { kind: "post-merge", provenance: "declared", origin: "test-2527-rp" });
  console.log("OK");
' 2>&1)"
check "settleDeliver ran" "$unit" "OK"
check "deliver complete + uv pending + reset contiguous" "$(settle_shape ds-unit)" "2|post-merge"
check "user_verification now pending" "$(last_status ds-unit user_verification)" "pending"
case_end

case_begin "settleDeliver skips uv events when uv is already boundary-reset" "hooks/workflow-state/delivery-settle.js"
mk_state '{"sid":"ds-dup","path":"pull_request","entered":true,"upto":"user_verification","steps":"user_verification=pending;deliver=pending","uvReset":"post-merge"}'
before="$(ev_count ds-dup user_verification)"
run_with_timeout 30 node -e '
  let m; try { m = require(process.env.RP_SCRIPT_CHECKOUT_ROOT + "/hooks/workflow-state/delivery-settle.js"); }
  catch (e) { console.log("MISSING:" + e.code); process.exit(0); }
  m.settleDeliver("ds-dup", { kind: "post-merge", provenance: "declared", origin: "test-2527-rp" });
' 2>&1
check "deliver complete written" "$(last_status ds-dup deliver)" "complete"
check "no extra user_verification events" "$(ev_count ds-dup user_verification)" "$before"
case_end

case_begin "settleDeliver called twice is idempotent (no duplicate deliver / uv events)" "hooks/workflow-state/delivery-settle.js"
mk_state '{"sid":"ds-twice","path":"pull_request","entered":true,"upto":"deliver","steps":"deliver=pending"}'
IFS= read -r -d '' settle_twice_js <<'JS'
let m; try { m = require(process.env.RP_SCRIPT_CHECKOUT_ROOT + "/hooks/workflow-state/delivery-settle.js"); }
catch (e) { console.log("MISSING:" + e.code); process.exit(0); }
m.settleDeliver("ds-twice", { kind: "post-merge", provenance: "declared", origin: "test-2527-rp" });
console.log("OK");
JS
check "first settle ran" "$(run_with_timeout 30 node -e "$settle_twice_js" 2>&1)" "OK"
deliver_after_first="$(ev_count ds-twice deliver)"
uv_after_first="$(ev_count ds-twice user_verification)"
check "second settle ran" "$(run_with_timeout 30 node -e "$settle_twice_js" 2>&1)" "OK"
check "no duplicate deliver event" "$(ev_count ds-twice deliver)" "$deliver_after_first"
check "no duplicate user_verification event" "$(ev_count ds-twice user_verification)" "$uv_after_first"
check "settled shape unchanged" "$(settle_shape ds-twice)" "2|post-merge"
case_end

case_begin "advance path (pull_request, gh MERGED) settles deliver and resets uv post-merge" "hooks/workflow-state/record-step-verdict.js"
mk_state '{"sid":"ds-adv-pr","path":"pull_request","entered":true,"upto":"deliver","steps":"deliver=pending"}'
export RP_GH_MODE=MERGED
out="$(run_next_step ds-adv-pr --advance --step deliver --complete)"
check "deliver complete" "$(last_status ds-adv-pr deliver)" "complete"
check "same-write uv reset (post-merge)" "$(settle_shape ds-adv-pr)" "2|post-merge"
case_end

case_begin "advance path (direct, worker push unseen by hooks) resets uv post-push" "hooks/workflow-state/record-step-verdict.js"
export ENFORCE_WORKTREE=off RP_GH_MODE=NONE
# Direct evidence is bound to main (release-evidence.sh): deliver from main, HEAD == origin/main.
git -C "$RP_REPO" checkout -q main
check "sanity: on main, clean, HEAD == origin/main" \
  "$(git -C "$RP_REPO" rev-parse --abbrev-ref HEAD)|$(git -C "$RP_REPO" status --porcelain)|$(git -C "$RP_REPO" rev-list --count origin/main...HEAD)" "main||0"
mk_state '{"sid":"ds-adv-d","path":"direct","branch":"main","upto":"deliver","steps":"deliver=pending"}'
out="$(run_next_step ds-adv-d --advance --step deliver --complete)"
check "deliver complete (clean tree, not ahead of origin/main)" "$(last_status ds-adv-d deliver)" "complete"
check "same-write uv reset (post-push)" "$(settle_shape ds-adv-d)" "2|post-push"
git -C "$RP_REPO" checkout -q feature/2527-rp
export ENFORCE_WORKTREE=on
case_end

case_begin "persistResolutions path (verdict, gh MERGED) settles through settleDeliver" "hooks/workflow-state/effective-state.js"
mk_state '{"sid":"ds-persist","path":"pull_request","entered":true,"upto":"deliver","steps":"deliver=pending"}'
export RP_GH_MODE=MERGED
out="$(run_next_step ds-persist)"
check "deliver persisted complete" "$(last_status ds-persist deliver)" "complete"
check "same-write uv reset (post-merge)" "$(settle_shape ds-persist)" "2|post-merge"
check "navigation moves on to cleanup" "$(field "$out" NEXT_SKILL)" "worktree-end"
case_end

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit "$FAIL"
