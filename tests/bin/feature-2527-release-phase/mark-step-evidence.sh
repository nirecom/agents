#!/usr/bin/env bash
# mark-step-evidence.sh — #2527 3-3: MARK_STEP completes push_branch / merge_to_main only with evidence.
# Tests: hooks/workflow-mark/mark-step-handler.js, hooks/workflow-mark.js, hooks/workflow-state/record-step-verdict/release-steps.js
# Tags: scope:issue-specific, workflow, release-phase, mark-step, bootstrap
# TL2: workflow-mark.js fed the MARK_STEP sentinel as a PostToolUse Bash payload; fake gh.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

# TL3 gap (not caught here): a model emitting the sentinel instead of running the skill.
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh
# category: hook-registration.
RP_TMP="$(make_tmp)"
readonly RP_TMP
trap rp_teardown EXIT
harness_isolate "$RP_TMP"
rp_setup

mark() { mark_bash "$1" "$RP_REPO_M" "echo \"<<WORKFLOW_MARK_STEP_$2_complete>>\"" 0; }

case_begin "push_branch MARK_STEP without a PR is rejected" "hooks/workflow-mark/mark-step-handler.js"
mk_state '{"sid":"ms-pb-no","path":"pull_request","entered":true,"upto":"push_branch","steps":"push_branch=pending"}'
export RP_GH_MODE=NONE
mark ms-pb-no push_branch >/dev/null
check "push_branch stays pending" "$(last_status ms-pb-no push_branch)" "pending"
export RP_GH_MODE=fail
mark ms-pb-no push_branch >/dev/null
check "gh failure is no evidence (fail-closed)" "$(last_status ms-pb-no push_branch)" "pending"
case_end

case_begin "push_branch MARK_STEP with an OPEN PR is accepted" "hooks/workflow-mark/mark-step-handler.js"
mk_state '{"sid":"ms-pb-ok","path":"pull_request","entered":true,"upto":"push_branch","steps":"push_branch=pending"}'
export RP_GH_MODE=OPEN
mark ms-pb-ok push_branch >/dev/null
check "push_branch complete" "$(last_status ms-pb-ok push_branch)" "complete"
case_end

case_begin "push_branch via the real next-step --advance CLI completes only on an OPEN PR" "hooks/workflow-state/record-step-verdict/release-steps.js"
# Runs from the fixture repo (rp_setup cd + CLAUDE_PROJECT_DIR), whose origin/main exists, so a
# missing PR is never mistaken for a bootstrap push.
pb_complete_n() { ev_query "$1" 'e.filter((x) => x.kind === "step_status" && x.step === "push_branch" && x.status === "complete").length'; }
# gh mode | label | push_branch after | complete events | refusal shown
while IFS='|' read -r mode label want_st want_n refused; do
  [ -z "$mode" ] && continue
  sid="ms-pb-adv-$label"
  mk_state "{\"sid\":\"$sid\",\"path\":\"pull_request\",\"entered\":true,\"upto\":\"push_branch\",\"steps\":\"push_branch=pending\"}"
  export RP_GH_MODE="$mode"
  : > "$RP_GH_LOG"
  out="$(run_next_step "$sid" --advance --step push_branch --complete)"
  check "$label: push_branch $want_st" "$(last_status "$sid" push_branch)" "$want_st"
  check "$label: complete events recorded" "$(pb_complete_n "$sid")" "$want_n"
  check_contains "$label: the forge was consulted" "$(cat "$RP_GH_LOG")" "pr"
  if [ "$refused" = yes ]; then check_contains "$label: refused as no PR" "$out" "no pull request (OPEN or MERGED)"
  else check_not_contains "$label: no refusal" "$out" "NOT recorded"; fi
done <<'ROWS'
NONE|no-pr|pending|0|yes
fail|forge-unknown|pending|0|yes
OPEN|open-pr|complete|1|no
ROWS
case_end

case_begin "merge_to_main MARK_STEP with an OPEN (unmerged) PR is rejected" "hooks/workflow-mark/mark-step-handler.js"
mk_state '{"sid":"ms-dl-no","path":"pull_request","entered":true,"upto":"merge_to_main","steps":"merge_to_main=pending"}'
export RP_GH_MODE=OPEN
mark ms-dl-no merge_to_main >/dev/null
check "merge_to_main stays pending" "$(last_status ms-dl-no merge_to_main)" "pending"
check "approval untouched" "$(last_status ms-dl-no user_verification)" "complete"
case_end

case_begin "merge_to_main MARK_STEP with a MERGED PR is accepted and consumes the approval" "hooks/workflow-mark/mark-step-handler.js"
mk_state '{"sid":"ms-dl-ok","path":"pull_request","entered":true,"upto":"merge_to_main","steps":"merge_to_main=pending"}'
export RP_GH_MODE=MERGED
mark ms-dl-ok merge_to_main >/dev/null
check "merge_to_main complete" "$(last_status ms-dl-ok merge_to_main)" "complete"
check "user_verification reset by settleMergeToMain" "$(last_status ms-dl-ok user_verification)" "pending"
check "reset_reason post-merge" "$(last_reset ms-dl-ok user_verification)" "post-merge"
case_end

# Release approval binding: merge_to_main completes on MERGED evidence only when user_verification is
# complete or a delivery-boundary reset (pending + post-merge/post-push). The spec builds
# user_verification as <uv>; "absent" stops the walk before it so no UV event exists.
UV_NOT_RECORDED="user_verification (release approval) is not recorded"
uv_spec() {
  case "$2" in
    absent)    printf '{"sid":"%s","path":"pull_request","entered":true,"upto":"user_verification","steps":"merge_to_main=pending"}' "$1" ;;
    pending)   printf '{"sid":"%s","path":"pull_request","entered":true,"upto":"merge_to_main","steps":"user_verification=pending;merge_to_main=pending"}' "$1" ;;
    complete)  printf '{"sid":"%s","path":"pull_request","entered":true,"upto":"merge_to_main","steps":"merge_to_main=pending"}' "$1" ;;
    post-*)    printf '{"sid":"%s","path":"pull_request","entered":true,"upto":"merge_to_main","steps":"user_verification=pending;merge_to_main=pending","uvReset":"%s"}' "$1" "$2" ;;
  esac
}
# rcc <sid> <step> <gate> — checkReleaseCompletion's verdict as "ok" or "refused:<detail>".
rcc() {
  [ "$#" -ge 3 ] || { echo "rcc: argc=$#"; return 1; }
  run_with_timeout 30 node -e '
    const [sid, step, gate, repo] = process.argv.slice(1);
    let m; try { m = require(process.env.RP_SCRIPT_CHECKOUT_ROOT + "/hooks/workflow-state/record-step-verdict/release-steps.js"); }
    catch (e) { console.log("MISSING:" + e.code); process.exit(0); }
    const r = m.checkReleaseCompletion(sid, step, "complete", gate, { repoDir: repo }, () => repo);
    console.log(!r ? "null" : r.ok ? "ok" : "refused:" + r.detail);
  ' "$1" "$2" "$3" "$RP_REPO_M" 2>&1
}

case_begin "merge_to_main needs the release approval: checkReleaseCompletion x sentinel/advance/mark gates" "hooks/workflow-state/record-step-verdict/release-steps.js"
export RP_GH_MODE=MERGED
# uv | expected verdict (same for every gate)
while IFS='|' read -r uv want; do
  [ -z "$uv" ] && continue
  for gate in sentinel advance mark; do
    sid="ms-uv-u-$uv-$gate"
    mk_state "$(uv_spec "$sid" "$uv")"
    got="$(rcc "$sid" merge_to_main "$gate")"
    if [ "$want" = ok ]; then check "uv=$uv gate=$gate -> ok" "$got" "ok"
    else check "uv=$uv gate=$gate -> refused (approval)" "$got" "refused:${UV_NOT_RECORDED} for this session"; fi
  done
done <<'ROWS'
pending|refused
absent|refused
complete|ok
post-merge|ok
post-push|ok
ROWS
case_end

case_begin "evidence still precedes approval: no MERGED PR is refused as unobservable even with approval" "hooks/workflow-state/record-step-verdict/release-steps.js"
export RP_GH_MODE=OPEN
mk_state "$(uv_spec ms-uv-open complete)"
check "OPEN PR + uv complete -> not observable" "$(rcc ms-uv-open merge_to_main sentinel)" "refused:the delivery is not observable (PR not MERGED, or the default branch is not pushed clean)"
mk_state "$(uv_spec ms-uv-open-p pending)"
check "OPEN PR + uv pending -> evidence refusal wins" "$(rcc ms-uv-open-p merge_to_main advance)" "refused:the delivery is not observable (PR not MERGED, or the default branch is not pushed clean)"
case_end

case_begin "push_branch is not bound to the release approval" "hooks/workflow-state/record-step-verdict/release-steps.js"
export RP_GH_MODE=OPEN
for gate in sentinel advance mark; do
  mk_state "{\"sid\":\"ms-uv-pb-$gate\",\"path\":\"pull_request\",\"entered\":true,\"upto\":\"push_branch\",\"steps\":\"push_branch=pending\"}"
  check "push_branch + OPEN PR + no uv, gate=$gate -> ok" "$(rcc "ms-uv-pb-$gate" push_branch "$gate")" "ok"
done
case_end

case_begin "merge_to_main MARK_STEP (sentinel gate) with a MERGED PR but no approval stays pending" "hooks/workflow-mark/mark-step-handler.js"
export RP_GH_MODE=MERGED
# uv | merge_to_main after | uv reset_reason after | refusal shown
while IFS='|' read -r uv want_dl want_reset refused; do
  [ -z "$uv" ] && continue
  sid="ms-uv-s-$uv"
  mk_state "$(uv_spec "$sid" "$uv")"
  out="$(mark "$sid" merge_to_main)"
  check "uv=$uv: merge_to_main $want_dl" "$(last_status "$sid" merge_to_main)" "$want_dl"
  check "uv=$uv: uv reset_reason $want_reset" "$(last_reset "$sid" user_verification)" "$want_reset"
  if [ "$refused" = yes ]; then check_contains "uv=$uv: refusal names the approval" "$out" "$UV_NOT_RECORDED"
  else check_not_contains "uv=$uv: no approval refusal" "$out" "$UV_NOT_RECORDED"; fi
done <<'ROWS'
pending|pending|<none>|yes
absent|pending|<none>|yes
complete|complete|post-merge|no
post-merge|complete|post-merge|no
ROWS
case_end

case_begin "merge_to_main --advance (advance gate) with a MERGED PR but no approval is refused" "hooks/workflow-state/record-step-verdict.js"
export RP_GH_MODE=MERGED
while IFS='|' read -r uv want_dl refused; do
  [ -z "$uv" ] && continue
  sid="ms-uv-a-$uv"
  mk_state "$(uv_spec "$sid" "$uv")"
  out="$(run_next_step "$sid" --advance --step merge_to_main --complete)"
  check "uv=$uv: merge_to_main $want_dl" "$(last_status "$sid" merge_to_main)" "$want_dl"
  if [ "$refused" = yes ]; then check_contains "uv=$uv: refusal names the approval" "$out" "$UV_NOT_RECORDED"
  else check_not_contains "uv=$uv: no approval refusal" "$out" "$UV_NOT_RECORDED"; fi
done <<'ROWS'
pending|pending|yes
absent|pending|yes
complete|complete|no
post-merge|complete|no
ROWS
case_end

case_begin "direct merge_to_main MARK_STEP on a dirty tree is rejected" "hooks/workflow-mark/mark-step-handler.js"
export ENFORCE_WORKTREE=off RP_GH_MODE=NONE
# Direct evidence is bound to main (release-evidence.sh): merge_to_main from main, HEAD == origin/main.
git -C "$RP_REPO" checkout -q main
mk_state '{"sid":"ms-d","path":"direct","branch":"main","upto":"merge_to_main","steps":"merge_to_main=pending"}'
printf 'dirty\n' > "$RP_REPO/dirty.txt"
mark ms-d merge_to_main >/dev/null
check "merge_to_main stays pending" "$(last_status ms-d merge_to_main)" "pending"
rm -f "$RP_REPO/dirty.txt"
check "sanity: on main, clean, HEAD == origin/main" \
  "$(git -C "$RP_REPO" rev-parse --abbrev-ref HEAD)|$(git -C "$RP_REPO" status --porcelain)|$(git -C "$RP_REPO" rev-list --count origin/main...HEAD)" "main||0"
mark ms-d merge_to_main >/dev/null
check "clean + not ahead -> accepted" "$(last_status ms-d merge_to_main)" "complete"
check "reset_reason post-push" "$(last_reset ms-d user_verification)" "post-push"
git -C "$RP_REPO" checkout -q feature/2527-rp
case_end

# bs_repo <dir> <origin-url> — a fixture repo on feature/2527-rp with one commit, no
# refs/remotes/origin/*, and origin pointing at <origin-url> (local paths only).
bs_repo() {
  harness_git_init "$1"
  git -C "$1" config user.email t@example.com
  git -C "$1" config user.name t
  git -C "$1" config core.autocrlf false
  printf 'base\n' > "$1/README.md"
  git -C "$1" add README.md
  git -C "$1" commit -q -m base
  git -C "$1" branch -M feature/2527-rp
  git -C "$1" remote add origin "$2"
}
# mark_in <sid> <step> <repo> — the hook resolves the repo from CLAUDE_PROJECT_DIR (the payload's
# cwd sits under tool_input), so the project dir is re-pointed for this one call.
mark_in() { [ -n "${3:-}" ] || { echo "mark_in: empty repo arg"; return 1; }; CLAUDE_PROJECT_DIR="$3" mark_bash "$1" "$3" "echo \"<<WORKFLOW_MARK_STEP_$2_complete>>\"" 0; }
pb_decision() { ev_query "$1" '(e.filter((x) => x.kind === "step_annotation" && x.step === "push_branch" && x.key === "decision").slice(-1)[0] || { value: "<none>" }).value'; }

export ENFORCE_WORKTREE=on RP_GH_MODE=NONE
BS_REMOTE="$RP_TMP/bs-remote.git"
git init -q --bare "$BS_REMOTE"
git -C "$BS_REMOTE" config core.hooksPath /dev/null
BS_REPO="$RP_TMP/bs-repo"
bs_repo "$BS_REPO" "$(np "$BS_REMOTE")"
BS_REPO_M="$(np "$BS_REPO")"
BS_SPEC_TAIL="\"path\":\"pull_request\",\"entered\":true,\"cwd\":\"$BS_REPO_M\",\"upto\":\"push_branch\",\"steps\":\"push_branch=pending;user_verification=complete;merge_to_main=pending\"}"
mk_state "{\"sid\":\"ms-bs\",$BS_SPEC_TAIL"

case_begin "push_branch MARK_STEP with no PR and an empty origin is accepted as bootstrap" "hooks/workflow-state/record-step-verdict/release-steps.js"
check "sanity: origin has no heads" "$(git -C "$BS_REPO" ls-remote --heads origin)" ""
mark_in ms-bs push_branch "$BS_REPO_M" >/dev/null
check "push_branch complete" "$(last_status ms-bs push_branch)" "complete"
check "recorded decision bootstrap" "$(pb_decision ms-bs)" "bootstrap"
case_end

case_begin "bootstrap merge_to_main MARK_STEP before origin has the default branch is rejected" "hooks/workflow-state/record-step-verdict/release-steps.js"
out="$(mark_in ms-bs merge_to_main "$BS_REPO_M")"
check "merge_to_main stays pending" "$(last_status ms-bs merge_to_main)" "pending"
check_contains "refused as no release evidence" "$out" "the delivery is not observable"
# A pushed default branch whose tip is not HEAD is still no bootstrap delivery.
git -C "$BS_REPO" push -q origin HEAD:main
git -C "$BS_REPO" fetch -q origin
printf 'later\n' >> "$BS_REPO/README.md"
git -C "$BS_REPO" commit -q -am later
check "sanity: HEAD != origin/main" "$(git -C "$BS_REPO" rev-list --count origin/main..HEAD)" "1"
out="$(mark_in ms-bs merge_to_main "$BS_REPO_M")"
check "HEAD ahead of origin/main: merge_to_main stays pending" "$(last_status ms-bs merge_to_main)" "pending"
check_contains "HEAD ahead: refused as no release evidence" "$out" "the delivery is not observable"
case_end

case_begin "bootstrap merge_to_main MARK_STEP with HEAD == origin/main is accepted" "hooks/workflow-state/record-step-verdict/release-steps.js"
git -C "$BS_REPO" push -q origin HEAD:main
git -C "$BS_REPO" fetch -q origin
check "sanity: HEAD == origin/main" "$(git -C "$BS_REPO" rev-parse HEAD)" "$(git -C "$BS_REPO" rev-parse refs/remotes/origin/main)"
mark_in ms-bs merge_to_main "$BS_REPO_M" >/dev/null
check "merge_to_main complete" "$(last_status ms-bs merge_to_main)" "complete"
check "reset_reason post-push (bootstrap settle)" "$(last_reset ms-bs user_verification)" "post-push"
case_end

case_begin "push_branch MARK_STEP with no PR and an unreachable origin is rejected" "hooks/workflow-state/record-step-verdict/release-steps.js"
BS_GONE="$RP_TMP/bs-gone"
bs_repo "$BS_GONE" "$(np "$RP_TMP/no-such-remote.git")"
BS_GONE_M="$(np "$BS_GONE")"
mk_state "{\"sid\":\"ms-bs-gone\",\"path\":\"pull_request\",\"entered\":true,\"cwd\":\"$BS_GONE_M\",\"upto\":\"push_branch\",\"steps\":\"push_branch=pending\"}"
out="$(mark_in ms-bs-gone push_branch "$BS_GONE_M")"
check "push_branch stays pending" "$(last_status ms-bs-gone push_branch)" "pending"
check "no bootstrap decision recorded" "$(pb_decision ms-bs-gone)" "<none>"
check_contains "refused as no PR" "$out" "no pull request (OPEN or MERGED)"
case_end

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit "$FAIL"
