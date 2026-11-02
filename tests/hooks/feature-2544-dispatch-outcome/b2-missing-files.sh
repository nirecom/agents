# shellcheck shell=bash
# tests/hooks/feature-2544-dispatch-outcome/b2-missing-files.sh
# Tests: hooks/workflow-run-tests/dispatch-outcome.js, hooks/workflow-run-tests/record-run.js, hooks/lib/missing-test-files.js
# Tags: workflow, run-tests, worker-dispatch, outcome-file, hook, ingest, unrunnable, missing-test-file, test-lang-exception:e2e, tl2, scope:issue-specific
# Sourced by ../feature-2544-dispatch-outcome.sh after b-ingest.sh — helpers come from common.sh.
# #2646: the outcome-file route records the worker summary's `Missing test files: N; ` token
# as unrunnable_missing_files, and still reads the runtimes that follow the token.

# f2544_b2_missing <tag> <summary> <want-missing-files> <want-runtimes>: an unrunnable outcome
# (current contract, UNRUNNABLE=2) whose worker summary is <summary>.
f2544_b2_missing() {
  local tag="$1" sid="f2544-b2-$1" stem="$F2544_T-1"
  local over="{\"exit_code\":0,\"worker_result\":{\"summary\":\"$2\"}}"
  f2544_ready "$sid"
  f2544_probe seed "$sid" run_tests complete
  f2544_dispatched "$sid" "$stem"
  f2544_probe outcome "$sid" "$stem" unrunnable 3 0 '[]' "$over" '{"unrunnable":2}'
  f2544_hook "$sid" "$F2544_UNRELATED_CMD"
  f2544_ingested "B2/$tag: ingested marker written" "$sid" "$stem" || return 0
  f2544_eq "B2/$tag: run_tests is demoted to pending" "$(f2544_status "$sid")" "pending"
  f2544_eq "B2/$tag: run_outcome is unrunnable" "$(f2544_field "$sid" run_outcome)" "unrunnable"
  f2544_eq "B2/$tag: unrunnable_missing_files" "$(f2544_field "$sid" unrunnable_missing_files)" "$3"
  f2544_eq "B2/$tag: unrunnable_runtimes" "$(f2544_field "$sid" unrunnable_runtimes)" "$4"
}

# The next passing outcome clears the count: it belongs to one run.
f2544_b2_tombstone() {
  local sid="f2544-b2-tomb" stem="$F2544_T-1" next="$F2544_T-2"
  local over='{"exit_code":0,"worker_result":{"summary":"Missing test files: 2; PASS=3 FAIL=0 SKIP=0 UNRUNNABLE=2"}}'
  f2544_ready "$sid"
  f2544_probe seed "$sid" run_tests complete
  f2544_dispatched "$sid" "$stem"
  f2544_probe outcome "$sid" "$stem" unrunnable 3 0 '[]' "$over" '{"unrunnable":2}'
  f2544_hook "$sid" "$F2544_UNRELATED_CMD"
  f2544_ingested "B2/tombstone: first outcome ingested" "$sid" "$stem" || return 0
  f2544_eq "B2/tombstone: control — count recorded" "$(f2544_field "$sid" unrunnable_missing_files)" "2"
  f2544_dispatched "$sid" "$next"
  f2544_probe outcome "$sid" "$next" pass 3 0 '[]' '{}' '{"unrunnable":0}'
  f2544_hook "$sid" "$F2544_UNRELATED_CMD"
  f2544_eq "B2/tombstone: the passing run completes" "$(f2544_status "$sid")" "complete"
  f2544_eq "B2/tombstone: unrunnable_missing_files is cleared" "$(f2544_field "$sid" unrunnable_missing_files)" "absent"
}

case_begin "outcome-summary-missing-files-token" "hooks/workflow-run-tests/dispatch-outcome.js"
# Table: <tag>|<worker summary>|<want unrunnable_missing_files>|<want unrunnable_runtimes>.
# legacy-no-token: a summary written before #2646 records an explicit 0, not an absent key.
# overflow: a token too wide to read is counted as 1, so it can never be read as "no missing file".
while IFS='|' read -r tag summary want_missing want_runtimes; do
  [ -n "$tag" ] || continue
  f2544_b2_missing "$tag" "$summary" "$want_missing" "$want_runtimes"
done <<'ROWS'
legacy-no-token|Missing runtimes: python (2 files); PASS=3 FAIL=0 SKIP=0 UNRUNNABLE=2|0|python
token-and-runtimes|Missing test files: 2; Missing runtimes: python (1 files); PASS=3 FAIL=0 SKIP=0 UNRUNNABLE=2|2|python
overflow-token|Missing test files: 9999999999; Missing runtimes: python (1 files); PASS=3 FAIL=0 SKIP=0 UNRUNNABLE=2|1|python
ROWS
case_end

case_begin "next-outcome-clears-missing-files" "hooks/workflow-run-tests/record-run.js"
f2544_b2_tombstone
case_end
