#!/usr/bin/env bash
# next-step-release.sh — #2527 3-1: every release-phase step names its skill, no GATE line.
# Tests: bin/workflow/lib/next-step/steps.js, bin/workflow/lib/next-step/verdict.js
# Tags: scope:issue-specific, workflow, release-phase, next-step
# TL2: v5 state fixtures + the real next-step CLI + a fake gh (NONE) so no step resolves by evidence.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

# TL3 gap (not caught here): whether the model actually invokes the named skill after reading
# NEXT_SKILL. Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: skill-orchestration.
rp_setup
trap rp_teardown EXIT
ALL_OUT=""

# expect_skill <label> <sid> <want-skill> <want-reason>
expect_skill() {
  local out; out="$(run_next_step "$2")"
  ALL_OUT="$ALL_OUT
$out"
  check "$1: NEXT_SKILL" "$(field "$out" NEXT_SKILL)" "$3"
  check "$1: REASON" "$(field "$out" REASON)" "$4"
}

case_begin "pull_request push_branch -> commit-push" "bin/workflow/lib/next-step/steps.js"
mk_state '{"sid":"pr-push","path":"pull_request","entered":true,"upto":"push_branch","steps":"push_branch=pending"}'
expect_skill "pr push_branch" pr-push commit-push push_branch
case_end

case_begin "pull_request user_verification -> get-release-approval" "bin/workflow/lib/next-step/steps.js"
mk_state '{"sid":"pr-uv","path":"pull_request","entered":true,"upto":"user_verification","steps":"user_verification=pending"}'
expect_skill "pr user_verification" pr-uv get-release-approval user_verification
case_end

case_begin "pull_request merge_to_main -> merge-to-main" "bin/workflow/lib/next-step/steps.js"
mk_state '{"sid":"pr-mtm","path":"pull_request","entered":true,"upto":"merge_to_main","steps":"merge_to_main=pending"}'
expect_skill "pr merge_to_main" pr-mtm merge-to-main merge_to_main
case_end

case_begin "pull_request cleanup -> worktree-end" "bin/workflow/lib/next-step/steps.js"
mk_state '{"sid":"pr-cleanup","path":"pull_request","entered":true,"upto":"cleanup","steps":"cleanup=pending"}'
expect_skill "pr cleanup" pr-cleanup worktree-end cleanup
case_end

case_begin "pull_request pre_final_report_gate -> session-close" "bin/workflow/lib/next-step/steps.js"
mk_state '{"sid":"pr-close","path":"pull_request","entered":true,"upto":"pre_final_report_gate"}'
expect_skill "pr pre_final" pr-close session-close pre_final_report_gate
case_end

# direct: live env matches the recorded path; an untracked file keeps the merge_to_main evidence false.
export ENFORCE_WORKTREE=off
printf 'dirty\n' > "$RP_REPO/dirty.txt"

case_begin "direct user_verification -> get-release-approval (push_branch table-skipped)" "bin/workflow/lib/next-step/verdict.js"
mk_state '{"sid":"d-uv","path":"direct","upto":"user_verification","steps":"user_verification=pending"}'
expect_skill "direct user_verification" d-uv get-release-approval user_verification
case_end

case_begin "direct merge_to_main -> merge-to-main" "bin/workflow/lib/next-step/verdict.js"
mk_state '{"sid":"d-mtm","path":"direct","upto":"merge_to_main","steps":"merge_to_main=pending"}'
expect_skill "direct merge_to_main" d-mtm merge-to-main merge_to_main
case_end

case_begin "direct pre_final_report_gate -> session-close (cleanup table-skipped)" "bin/workflow/lib/next-step/verdict.js"
mk_state '{"sid":"d-close","path":"direct","upto":"pre_final_report_gate"}'
expect_skill "direct pre_final" d-close session-close pre_final_report_gate
case_end

case_begin "no GATE line on any release step" "bin/workflow/lib/next-step/verdict.js"
gate_lines="$(printf '%s\n' "$ALL_OUT" | grep -c '^GATE' || true)"
check "release steps emit no GATE line (CONFIRM_* all on)" "$gate_lines" "0"
invoke_count="$(printf '%s\n' "$ALL_OUT" | grep -c '^ACTION=invoke' || true)"
check "all 8 release verdicts are ACTION=invoke (guards a vacuous GATE check)" "$invoke_count" "8"
case_end

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit "$FAIL"
