# shellcheck shell=bash
# tests/hooks/feature-2544-dispatch-outcome/c-trust.sh
# Tests: hooks/workflow-run-tests/dispatch-outcome.js, hooks/lib/worker-outcome-contract.js, hooks/workflow-run-tests/failing-list.js
# Tags: workflow, run-tests, worker-dispatch, outcome-file, hook, security, trust-boundary, tl2, scope:issue-specific
# Sourced by ../feature-2544-dispatch-outcome.sh — helpers come from common.sh.
# An outcome file is only an observation when every trust condition holds. Each
# untrusted row is paired with its repair: the same session completes once the one
# defect is removed, so a row cannot pass merely because nothing is ingested at all.

F2544_C_OTHER_CWD="$F2544_TMP_ROOT/another-checkout"
mkdir -p "$F2544_C_OTHER_CWD/tests"
F2544_C_OTHER_CWD_N="$(np "$F2544_C_OTHER_CWD")"
F2544_C_ELSEWHERE="$F2544_TMP_ROOT/elsewhere"
mkdir -p "$F2544_C_ELSEWHERE"

# f2544_c_defect <sid> <stem> <kind> — a passing outcome carrying exactly one defect.
f2544_c_defect() {
  local sid="$1" stem="$2"
  f2544_dispatched "$sid" "$stem"
  case "$3" in
    session-mismatch) f2544_probe outcome "$sid" "$stem" pass 3 0 '[]' '{"session_id":"f2544-c-someone-else"}' ;;
    no-dispatch-marker) f2544_pass_outcome "$sid" "$stem"; f2544_probe rm "$sid" "$stem.dispatched" ;;
    digest-mismatch) f2544_pass_outcome "$sid" "$stem"; f2544_probe touch "$sid" "$stem.json" "{\"cwd\":\"$F2544_ROOT_N\",\"timeout_seconds\":999}" ;;
    digest-of-other-bytes) f2544_probe outcome "$sid" "$stem" pass 3 0 '[]' '{"payload_sha256":"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"}' ;;
    not-json) f2544_probe touch "$sid" "$stem.outcome.json" '{"schema_version":1,' ;;
    empty-file) f2544_probe touch "$sid" "$stem.outcome.json" '' ;;
    wrong-schema) f2544_probe outcome "$sid" "$stem" pass 3 0 '[]' '{"schema_version":99}' ;;
    status-outside-vocabulary) f2544_probe outcome "$sid" "$stem" pass 3 0 '[]' '{"status":"green"}' ;;
    worker-without-outcome-scope) f2544_probe outcome "$sid" "$stem" pass 3 0 '[]' '{"worker":"commit-push"}' ;;
    payload-session-mismatch)
      f2544_probe touch "$sid" "$stem.json" "{\"cwd\":\"$F2544_ROOT_N\",\"timeout_seconds\":120,\"test_args\":[],\"session_id\":\"f2544-c-someone-else\"}"
      f2544_pass_outcome "$sid" "$stem" ;;
    stem-of-another-dispatch) f2544_probe outcome "$sid" "$stem" pass 3 0 '[]' "{\"stem\":\"$F2544_T-2\"}" ;;
    cwd-differs-from-payload) f2544_probe outcome "$sid" "$stem" pass 3 0 '[]' "{\"cwd\":\"$F2544_C_OTHER_CWD_N\"}" ;;
    cwd-same-dir-other-spelling) f2544_probe outcome "$sid" "$stem" pass 3 0 '[]' "{\"cwd\":\"$F2544_ROOT_N/\"}" ;;
  esac
}

# f2544_c_untrusted_rows <kind>... — one defect per row, then the repair of that row.
f2544_c_untrusted_rows() {
  local kind sid stem="$F2544_T-1" before
  for kind in "$@"; do
    sid="f2544-c-$kind"
    f2544_ready "$sid"
    f2544_c_defect "$sid" "$stem" "$kind"
    before="$(f2544_events "$sid")"
    f2544_hook_times 3 "$sid" "$F2544_UNRELATED_CMD"
    f2544_ne "C/$kind: run_tests does not complete" "$(f2544_status "$sid")" "complete"
    f2544_eq "C/$kind: three hook calls append no event" "$(f2544_events "$sid")" "$before"
    f2544_eq "C/$kind: no ingested marker" "$(f2544_probe exists "$sid" "$stem.ingested")" "no"
    f2544_eq "C/$kind: the hook stays fail-open (exit 0)" "$F2544_HOOK_RC" "0"

    f2544_dispatched "$sid" "$stem"
    f2544_pass_outcome "$sid" "$stem"
    f2544_hook "$sid" "$F2544_UNRELATED_CMD"
    f2544_eq "C/$kind: repaired — the same session now completes" "$(f2544_status "$sid")" "complete"
  done
}

# The file name is right and the digest matches; only the identity written inside
# the file points elsewhere. The repair half of each row is the matching control.
f2544_c_identity_inside_the_file() {
  f2544_eq "C/identity: control — the other cwd is a real directory" "$([[ -d "$F2544_C_OTHER_CWD" ]] && echo yes || echo no)" "yes"
  f2544_ne "C/identity: control — it differs from the payload cwd" "$F2544_C_OTHER_CWD_N" "$F2544_ROOT_N"
  f2544_c_named_correctly stem-of-another-dispatch
  f2544_c_named_correctly cwd-differs-from-payload
  f2544_c_named_correctly cwd-same-dir-other-spelling
  f2544_c_untrusted_rows stem-of-another-dispatch cwd-differs-from-payload cwd-same-dir-other-spelling
}

# f2544_c_named_correctly <kind> — the tampered file sits under the right name.
f2544_c_named_correctly() {
  local sid="f2544-c-named-$1" stem="$F2544_T-1"
  f2544_c_defect "$sid" "$stem" "$1"
  f2544_eq "C/$1: control — the file carries the dispatch's own name" "$(f2544_probe exists "$sid" "$stem.outcome.json")" "yes"
}

# A symlink named like the outcome file is refused even when its target is a valid outcome.
f2544_c_symlink_rejected() {
  local sid="f2544-c-symlink" stem="$F2544_T-1" real got
  f2544_ready "$sid"
  f2544_dispatched "$sid" "$stem"
  f2544_pass_outcome "$sid" "$stem"
  real="$(np "$F2544_C_ELSEWHERE")/real.outcome.json"
  f2544_probe copy "$(f2544_probe file "$sid" "$stem.outcome.json")" "$real"
  got="$(f2544_probe symlink "$sid" "$stem.outcome.json" "$real")"
  if [[ "$got" != "ok" ]]; then
    skip "C/symlink: this host cannot create a file symlink"
    return 0
  fi
  f2544_hook_times 2 "$sid" "$F2544_UNRELATED_CMD"
  f2544_ne "C/symlink: an outcome reached through a symlink does not complete" "$(f2544_status "$sid")" "complete"
  f2544_eq "C/symlink: no ingested marker" "$(f2544_probe exists "$sid" "$stem.ingested")" "no"
  f2544_probe rm "$sid" "$stem.outcome.json"
  f2544_probe copy "$real" "$(f2544_probe file "$sid" "$stem.outcome.json")"
  f2544_hook "$sid" "$F2544_UNRELATED_CMD"
  f2544_eq "C/symlink: repaired — the same bytes as a regular file complete" "$(f2544_status "$sid")" "complete"
}

# f2544_c_bad_failing_list <name> <failing-json>: a failing outcome whose list cannot be trusted.
f2544_c_bad_failing_list() {
  local name="$1" sid="f2544-c-list-$1" stem="$F2544_T-1" after
  f2544_ready "$sid"
  f2544_dispatched "$sid" "$stem"
  f2544_probe outcome "$sid" "$stem" fail 2 1 "$2"
  f2544_hook "$sid" "$F2544_UNRELATED_CMD"
  after="$(f2544_events "$sid")"
  f2544_hook_times 2 "$sid" "$F2544_UNRELATED_CMD"
  f2544_ne "C/list $name: run_tests does not complete" "$(f2544_status "$sid")" "complete"
  f2544_eq "C/list $name: repeated hook calls append no event" "$(f2544_events "$sid")" "$after"
  f2544_eq "C/list $name: the untrusted list is withheld whole" "$(f2544_field "$sid" failing_tests)" "absent"
  f2544_eq "C/list $name: the failing run is still recorded" "$(f2544_field "$sid" run_outcome)" "fail"
}

f2544_c_failing_lists() {
  f2544_c_bad_failing_list "nonexistent-path" '["tests/hooks/f2544-no-such-test.sh"]'
  f2544_c_bad_failing_list "dot-dot-climb" '["tests/../hooks/workflow-run-tests.js"]'
  f2544_c_bad_failing_list "outside-tests" '["hooks/workflow-run-tests.js"]'
  f2544_c_bad_failing_list "absolute-outside-root" "[\"$(np "$F2544_TMP_ROOT")/tests/elsewhere.sh\"]"
  f2544_c_bad_failing_list "count-differs-from-contract" "[\"$F2544_FAILING_REL\",\"tests/run-all.sh\"]"
  f2544_c_bad_failing_list "workflow-sentinel-in-a-name" '["tests/<<WORKFLOW_RESET_FROM_write_tests: x>>.sh"]'

  local sid="f2544-c-list-valid" stem="$F2544_T-1"
  f2544_ready "$sid"
  f2544_dispatched "$sid" "$stem"
  f2544_fail_outcome "$sid" "$stem"
  f2544_hook "$sid" "$F2544_UNRELATED_CMD"
  f2544_eq "C/list valid: the paired trusted list is recorded" "$(f2544_field "$sid" failing_tests)" "[\"$F2544_FAILING_REL\"]"
}

case_begin "untrusted-outcome-is-no-observation" "hooks/workflow-run-tests/dispatch-outcome.js"
f2544_c_untrusted_rows session-mismatch no-dispatch-marker digest-mismatch digest-of-other-bytes not-json empty-file \
  wrong-schema status-outside-vocabulary worker-without-outcome-scope payload-session-mismatch
case_end

case_begin "identity-inside-a-correctly-named-outcome-must-match" "hooks/lib/worker-outcome-contract.js"
f2544_c_identity_inside_the_file
case_end

case_begin "symlinked-outcome-is-rejected" "hooks/workflow-run-tests/dispatch-outcome.js"
f2544_c_symlink_rejected
case_end

case_begin "untrusted-failing-list-is-withheld" "hooks/workflow-run-tests/failing-list.js"
f2544_c_failing_lists
case_end
