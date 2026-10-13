#!/usr/bin/env bash
# feature-2527-merge-gate-graphql.sh — #2527 4-1: the merge gate and the post-merge reset see GraphQL merges.
# Tests: hooks/workflow-gate.js, hooks/lib/merge-detect/graphql.js
# Tags: scope:issue-specific, workflow, merge-gate, TL2
# TL2: workflow-gate.js / workflow-mark.js spawned with Bash payloads over a v5 fixture state
# (AUTO_MERGE_PR unset in .env = on, so the stage-4 release refusal never decides these rows;
# no auto_merge_pr state field, so today's fail-closed writeState accepts the uv reset).
# Kinds are reused (judgment B): the gate names gh-pr-merge / glab-mr-merge in its block text.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../tests/lib/harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/feature-2527-auto-merge-pr-fix/_lib.sh"

# TL3 gap (not caught here): Claude Code really routing a `gh api graphql` Bash call through
# the registered PreToolUse hook. Closest-to-action mitigation: forge branch protection.
# category: hook-registration.
AMP_TMP="$(make_tmp)"
readonly AMP_TMP
trap amp_teardown EXIT
harness_isolate "$AMP_TMP"
amp_setup

GQL_GH="gh api graphql -f query='mutation{mergePullRequest(input:{pullRequestId:\"PR_1\"}){clientMutationId}}'"
GQL_GH_AUTO="gh api graphql -F query='mutation{enablePullRequestAutoMerge(input:{pullRequestId:\"PR_1\"}){clientMutationId}}'"
GQL_GLAB="glab api graphql --raw-field query='mutation{mergeRequestAccept(input:{projectPath:\"o/r\",iid:\"1\"}){errors}}'"
GQL_READ="gh api graphql -f query='query{repository(owner:\"o\",name:\"r\"){pullRequest(number:1){mergeable}}}'"

case_begin "merge gate: GraphQL merges blocked while user_verification is pending" "hooks/workflow-gate.js"
mk_state '{"sid":"gg-pend","path":"pull_request","upto":"user_verification","steps":"user_verification=pending"}'
out="$(gate_bash gg-pend "$AMP_REPO_M" "$GQL_GH")"
check "mergePullRequest decision is block" "$(hook_decision "$out")" "block"
check_contains "mergePullRequest blocked as gh-pr-merge" "$out" "gh-pr-merge blocked"
out="$(gate_bash gg-pend "$AMP_REPO_M" "$GQL_GH_AUTO")"
check "enablePullRequestAutoMerge decision is block" "$(hook_decision "$out")" "block"
check_contains "enablePullRequestAutoMerge blocked as gh-pr-merge" "$out" "gh-pr-merge blocked"
out="$(gate_bash gg-pend "$AMP_REPO_M" "$GQL_GLAB")"
check "mergeRequestAccept decision is block" "$(hook_decision "$out")" "block"
check_contains "mergeRequestAccept blocked as glab-mr-merge" "$out" "glab-mr-merge blocked"
out="$(gate_bash gg-pend "$AMP_REPO_M" "rtk $GQL_GH")"
check "wrapped GraphQL merge decision is block" "$(hook_decision "$out")" "block"
out="$(gate_bash gg-pend "$AMP_REPO_M" "gh pr merge --squash")"
check "baseline: gh pr merge decision is block" "$(hook_decision "$out")" "block"
check "uv still pending after the blocks" "$(field "$(raw_state gg-pend)" UV)" "pending"
case_end

case_begin "merge gate: a read-only GraphQL query is never merge-gated" "hooks/workflow-gate.js"
mk_state '{"sid":"gg-read","path":"pull_request","upto":"user_verification","steps":"user_verification=pending"}'
out="$(gate_bash gg-read "$AMP_REPO_M" "$GQL_READ")"
check "read query decision is approve" "$(hook_decision "$out")" "approve"
check_not_contains "read query not blocked" "$out" "merge blocked"
case_end

case_begin "merge gate: GraphQL merges approved once user_verification is complete" "hooks/workflow-gate.js"
mk_state '{"sid":"gg-ok","path":"pull_request","upto":"user_verification","steps":"user_verification=complete"}'
out="$(gate_bash gg-ok "$AMP_REPO_M" "$GQL_GH")"
check "mergePullRequest decision is approve" "$(hook_decision "$out")" "approve"
out="$(gate_bash gg-ok "$AMP_REPO_M" "$GQL_GLAB")"
check "mergeRequestAccept decision is approve" "$(hook_decision "$out")" "approve"
case_end

case_begin "workflow-mark: a successful GraphQL merge resets uv with post-merge" "hooks/lib/merge-detect/graphql.js"
mk_state '{"sid":"gm-gh","path":"pull_request","upto":"user_verification","steps":"user_verification=complete"}'
mark_bash gm-gh "$AMP_REPO_M" "$GQL_GH" 0 >/dev/null
r="$(raw_state gm-gh)"
check "uv pending after mergePullRequest" "$(field "$r" UV)" "pending"
check "reset_reason post-merge (mergePullRequest)" "$(field "$r" UVRESET)" "post-merge"
mk_state '{"sid":"gm-glab","path":"pull_request","upto":"user_verification","steps":"user_verification=complete"}'
mark_bash gm-glab "$AMP_REPO_M" "$GQL_GLAB" 0 >/dev/null
r="$(raw_state gm-glab)"
check "uv pending after mergeRequestAccept" "$(field "$r" UV)" "pending"
check "reset_reason post-merge (mergeRequestAccept)" "$(field "$r" UVRESET)" "post-merge"
case_end

case_begin "workflow-mark: a failed GraphQL merge and a read query reset nothing" "hooks/lib/merge-detect/graphql.js"
mk_state '{"sid":"gm-fail","path":"pull_request","upto":"user_verification","steps":"user_verification=complete"}'
mark_bash gm-fail "$AMP_REPO_M" "$GQL_GH" 1 >/dev/null
check "uv stays complete after exit 1" "$(field "$(raw_state gm-fail)" UV)" "complete"
mk_state '{"sid":"gm-read","path":"pull_request","upto":"user_verification","steps":"user_verification=complete"}'
mark_bash gm-read "$AMP_REPO_M" "$GQL_READ" 0 >/dev/null
check "uv stays complete after a read query" "$(field "$(raw_state gm-read)" UV)" "complete"
case_end

case_begin "workflow-mark baseline: gh pr merge resets uv with post-merge on this fixture" "hooks/workflow-gate.js"
mk_state '{"sid":"gm-base","path":"pull_request","upto":"user_verification","steps":"user_verification=complete"}'
mark_bash gm-base "$AMP_REPO_M" "gh pr merge --squash --delete-branch" 0 >/dev/null
r="$(raw_state gm-base)"
check "baseline: uv pending after gh pr merge" "$(field "$r" UV)" "pending"
check "baseline: reset_reason post-merge" "$(field "$r" UVRESET)" "post-merge"
case_end

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit "$FAIL"
