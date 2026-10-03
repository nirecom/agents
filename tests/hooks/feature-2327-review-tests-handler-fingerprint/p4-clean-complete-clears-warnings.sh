#!/usr/bin/env bash
# Tests: hooks/workflow-mark/review-tests-handler.js, hooks/workflow-state/state-io/review-tests.js
# Tags: tl2, workflow, review-tests, warnings-accepted, scope:issue-specific, pwsh-not-required
# TL3 gap: no real claude -p PostToolUse firing; checkReviewTests is called directly, not via PreToolUse.
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight (bin/check-verification-gate.sh: hook-registration).
# #2495: a clean COMPLETE clears warnings_summary / warnings_accepted_reason left by an earlier WARNINGS round.
# Sourced by the dispatcher (harness and p1 helpers live there); run_mark sets its own env, so p2's env swap is irrelevant.

if [ -z "${AGENTS_N:-}" ]; then
    fail "p4 precondition: AGENTS_N is empty (p1 helpers not loaded)"
    return 0 2>/dev/null || exit 1
fi

P4_CHECKER_N="$AGENTS_N/hooks/workflow-gate/review-tests-checker.js"
P4_REASON="user accepts remaining gaps"

p4_eq() { if [ "$3" = "$2" ]; then pass "$1"; else fail "$1" "expected [$2] got [$3]"; fi; }

# p4_stage_repo <name> -> prints repo path; stages one test file and one impl file.
p4_stage_repo() {
    local repo; repo="$(setup_repo "$1")"
    stage_file "$repo" "tests/foo.sh" "echo test"
    stage_file "$repo" "hooks/impl.js" "v1"
    echo "$repo"
}

# p4_send <repo> <sid> <COMPLETE|WARNINGS|ACCEPTED> [<fingerprint> <warnings-count>]
p4_send() {
    local repo="$1" sid="$2" kind="$3" fp="${4:-}" n="${5:-2}" cmd
    case "$kind" in
        COMPLETE)  cmd="echo \"<<WORKFLOW_REVIEW_TESTS_COMPLETE: fingerprint=$fp>>\"" ;;
        WARNINGS)  cmd="echo \"<<WORKFLOW_REVIEW_TESTS_WARNINGS: fingerprint=$fp warnings=$n>>\"" ;;
        ACCEPTED)  cmd="echo \"<<WORKFLOW_REVIEW_TESTS_WARNINGS_ACCEPTED: $P4_REASON>>\"" ;;
        *) fail "p4_send: unknown kind [$kind]"; return 1 ;;
    esac
    run_mark "$repo" "$(build_mark_json "$cmd" "$sid" "$(np "$repo")")" >/dev/null
}

# p4_gate <repo> <sid> -> "<action>/<reason>" from checkReviewTests on the stored step state.
p4_gate() {
    run_with_timeout 15 node -e "
try {
  var S = require('$AGENTS_N/hooks/workflow-state/state-io.js');
  var m = require(process.argv[1]);
  var st = S.readState(process.argv[2]);
  var rt = st && st.steps && st.steps.review_tests;
  var r = m.checkReviewTests('review_tests', rt, {docsOnly:false, writeTestsEvidenceBypassed:false, repoDir:process.argv[3]});
  process.stdout.write(r.action + '/' + (r.reason || '-'));
}
catch(e) { process.stdout.write('ERROR:' + e.message); }
" -- "$P4_CHECKER_N" "$2" "$(np "$1")" 2>/dev/null
}

case_begin "warnings-then-clean-complete-clears-warnings" "hooks/workflow-state/state-io/review-tests.js"
P4_R1="$(p4_stage_repo "p4-clean-after-warnings")"; P4_S1="p4c1-$$"
P4_FP1="$(compute_fingerprint "$(np "$P4_R1")")"
if [ -z "$P4_FP1" ]; then
    fail "P4-1 setup: fingerprint unavailable"
else
    write_state_json "$P4_S1"
    p4_send "$P4_R1" "$P4_S1" WARNINGS "$P4_FP1"
    p4_eq "P4-1 premise: WARNINGS records warnings_summary" "\"fingerprint=$P4_FP1 warnings=2\"" "$(read_step_field "$P4_S1" warnings_summary)"
    p4_eq "P4-1 premise: gate blocks on warnings-pending" "block/warnings-pending" "$(p4_gate "$P4_R1" "$P4_S1")"
    p4_send "$P4_R1" "$P4_S1" COMPLETE "$P4_FP1"
    p4_eq "P4-1 clean COMPLETE: status complete" "complete" "$(read_step_status "$P4_S1")"
    p4_eq "P4-1 clean COMPLETE: warnings_summary cleared" "MISSING" "$(read_step_field "$P4_S1" warnings_summary)"
    P4_GATE1="$(p4_gate "$P4_R1" "$P4_S1")"
    p4_eq "P4-1 clean COMPLETE: gate skips" "skip" "${P4_GATE1%%/*}"
fi
case_end

case_begin "warnings-accepted-reason-cleared-on-clean-complete" "hooks/workflow-state/state-io/review-tests.js"
P4_R2="$(p4_stage_repo "p4-reason-cleared")"; P4_S2="p4c2-$$"
P4_FP2="$(compute_fingerprint "$(np "$P4_R2")")"
if [ -z "$P4_FP2" ]; then
    fail "P4-2 setup: fingerprint unavailable"
else
    write_state_json "$P4_S2"
    p4_send "$P4_R2" "$P4_S2" WARNINGS "$P4_FP2"
    p4_send "$P4_R2" "$P4_S2" ACCEPTED
    p4_eq "P4-2 premise: acceptance reason recorded" "\"$P4_REASON\"" "$(read_step_field "$P4_S2" warnings_accepted_reason)"
    p4_send "$P4_R2" "$P4_S2" COMPLETE "$P4_FP2"
    p4_eq "P4-2 clean COMPLETE: warnings_accepted_reason cleared" "MISSING" "$(read_step_field "$P4_S2" warnings_accepted_reason)"
    p4_eq "P4-2 clean COMPLETE: warnings_summary cleared" "MISSING" "$(read_step_field "$P4_S2" warnings_summary)"
fi
case_end

case_begin "warnings-path-keeps-recording" "hooks/workflow-state/state-io/review-tests.js"
P4_R3="$(p4_stage_repo "p4-warnings-path")"; P4_S3="p4c3-$$"
P4_FP3="$(compute_fingerprint "$(np "$P4_R3")")"
if [ -z "$P4_FP3" ]; then
    fail "P4-3 setup: fingerprint unavailable"
else
    # Sentinel route only: write_state_json would overwrite the whole state file.
    write_state_json "$P4_S3"
    p4_send "$P4_R3" "$P4_S3" WARNINGS "$P4_FP3" 2
    p4_send "$P4_R3" "$P4_S3" ACCEPTED
    p4_eq "P4-3 premise: acceptance reason recorded" "\"$P4_REASON\"" "$(read_step_field "$P4_S3" warnings_accepted_reason)"
    p4_send "$P4_R3" "$P4_S3" WARNINGS "$P4_FP3" 5
    p4_eq "P4-3 new WARNINGS: warnings_summary is the new payload" "\"fingerprint=$P4_FP3 warnings=5\"" "$(read_step_field "$P4_S3" warnings_summary)"
    p4_eq "P4-3 new WARNINGS: gate blocks on warnings-pending" "block/warnings-pending" "$(p4_gate "$P4_R3" "$P4_S3")"
    p4_eq "P4-3 new WARNINGS: stale acceptance reason cleared" "MISSING" "$(read_step_field "$P4_S3" warnings_accepted_reason)"
fi
case_end

case_begin "warnings-accepted-path-keeps-reason" "hooks/workflow-state/state-io/review-tests.js"
P4_R4="$(p4_stage_repo "p4-accepted-path")"; P4_S4="p4c4-$$"
P4_FP4="$(compute_fingerprint "$(np "$P4_R4")")"
if [ -z "$P4_FP4" ]; then
    fail "P4-4 setup: fingerprint unavailable"
else
    write_state_json "$P4_S4"
    p4_send "$P4_R4" "$P4_S4" WARNINGS "$P4_FP4"
    p4_eq "P4-4 premise: WARNINGS records warnings_summary" "\"fingerprint=$P4_FP4 warnings=2\"" "$(read_step_field "$P4_S4" warnings_summary)"
    p4_send "$P4_R4" "$P4_S4" ACCEPTED
    p4_eq "P4-4 ACCEPTED: warnings_summary cleared" "MISSING" "$(read_step_field "$P4_S4" warnings_summary)"
    p4_eq "P4-4 ACCEPTED: acceptance reason kept" "\"$P4_REASON\"" "$(read_step_field "$P4_S4" warnings_accepted_reason)"
    P4_GATE4="$(p4_gate "$P4_R4" "$P4_S4")"
    p4_eq "P4-4 ACCEPTED: gate skips" "skip" "${P4_GATE4%%/*}"
fi
case_end

case_begin "clean-complete-no-prior-warnings-unchanged" "hooks/workflow-state/state-io/review-tests.js"
P4_R5="$(p4_stage_repo "p4-no-prior")"; P4_S5="p4c5-$$"
P4_FP5="$(compute_fingerprint "$(np "$P4_R5")")"
if [ -z "$P4_FP5" ]; then
    fail "P4-5 setup: fingerprint unavailable"
else
    write_state_json "$P4_S5"
    p4_send "$P4_R5" "$P4_S5" COMPLETE "$P4_FP5"
    p4_eq "P4-5 clean COMPLETE: status complete" "complete" "$(read_step_status "$P4_S5")"
    p4_eq "P4-5 clean COMPLETE: warnings_summary absent" "MISSING" "$(read_step_field "$P4_S5" warnings_summary)"
    p4_eq "P4-5 clean COMPLETE: warnings_accepted_reason absent" "MISSING" "$(read_step_field "$P4_S5" warnings_accepted_reason)"
    P4_MAN5="$(read_step_field "$P4_S5" review_scope_manifest)"
    case "$P4_MAN5" in *'"v":1'*) pass "P4-5 clean COMPLETE: manifest recorded" ;; *) fail "P4-5 clean COMPLETE: manifest recorded" "got=$P4_MAN5" ;; esac
    P4_GATE5="$(p4_gate "$P4_R5" "$P4_S5")"
    p4_eq "P4-5 clean COMPLETE: gate skips" "skip" "${P4_GATE5%%/*}"
fi
case_end
