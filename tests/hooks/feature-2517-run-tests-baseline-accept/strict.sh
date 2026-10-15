# shellcheck shell=bash
# tests/hooks/feature-2517-run-tests-baseline-accept/strict.sh
# Tests: hooks/workflow-mark/run-tests-baseline-accept-handler.js, hooks/workflow-mark.js
# Tags: TL2, hooks, workflow-mark, run-tests, baseline, escape-hatch, security, scope:issue-specific
# The handler grants only what bin/run-tests-baseline accept would complete (#2517 review): an exact
# unrunnable_count of 0 on both paths, and on the listed path a classification that covers
# failing_tests by path-set identity with at least one entry and every non-preexisting entry
# undetermined. Rows come from strict_rows in _lib.sh. Sourced by the dispatcher after _lib.sh.

echo ""
echo "=== strict: the grant is refused wherever accept would refuse it ==="

# strict_row <id> — the strict_rows row <id> through the real hook; granted or rejected as listed.
strict_row() {
  local id kind verdict gkind sid before out
  IFS='|' read -r id kind verdict gkind <<<"$(strict_rows | grep "^$1|")"
  [[ -n "$kind" ]] || { fail "fixture: strict_rows has no row $1"; return; }
  sid="f2517-strict-$id"
  setup_state "$sid" "$kind"
  before="$(snap "$sid")"
  out="$(mark "$sid" "$(acc_cmd "$REASON_OK")")"
  if [[ "$verdict" == granted ]]; then
    assert_eq "$id grant kind: $(st path "$sid" run_tests baseline_accept kind)" "$id grant kind: $gkind"
    assert_eq "$id status stays pending: $(st field "$sid" run_tests status)" "$id status stays pending: pending"
    msg_has "$id message says grant recorded" "grant recorded" "$out"
  else
    assert_eq "$id no grant: $(st field "$sid" run_tests baseline_accept)" "$id no grant: (absent)"
    assert_eq "$id state unchanged: $(snap "$sid")" "$id state unchanged: $before"
    msg_has "$id message says rejected" "rejected" "$out"
  fi
}

case_begin "strict-H1-listless-unrunnable-null-rejected" "hooks/workflow-mark/run-tests-baseline-accept-handler.js"
strict_row H1
case_end

case_begin "strict-H2-listless-unrunnable-absent-rejected" "hooks/workflow-mark/run-tests-baseline-accept-handler.js"
strict_row H2
case_end

case_begin "strict-H3-listless-unrunnable-zero-granted" "hooks/workflow-mark/run-tests-baseline-accept-handler.js"
strict_row H3
case_end

case_begin "strict-H4-classification-missing-path-rejected" "hooks/workflow-mark/run-tests-baseline-accept-handler.js"
strict_row H4
case_end

case_begin "strict-H5-classification-foreign-path-rejected" "hooks/workflow-mark/run-tests-baseline-accept-handler.js"
strict_row H5
case_end

case_begin "strict-H6-classification-all-preexisting-rejected" "hooks/workflow-mark/run-tests-baseline-accept-handler.js"
strict_row H6
case_end

case_begin "strict-H7-listed-unrunnable-null-rejected" "hooks/workflow-mark/run-tests-baseline-accept-handler.js"
strict_row H7
case_end

case_begin "strict-H8-listed-undetermined-mix-granted" "hooks/workflow-mark/run-tests-baseline-accept-handler.js"
strict_row H8
case_end

case_begin "strict-H9-classification-duplicate-path-rejected" "hooks/workflow-mark/run-tests-baseline-accept-handler.js"
strict_row H9
case_end

case_begin "strict-H10-listless-unrunnable-negative-rejected" "hooks/workflow-mark/run-tests-baseline-accept-handler.js"
strict_row H10
case_end

case_begin "strict-H11-listless-unrunnable-string-zero-rejected" "hooks/workflow-mark/run-tests-baseline-accept-handler.js"
strict_row H11
case_end

case_begin "strict-H12-listed-unrunnable-negative-rejected" "hooks/workflow-mark/run-tests-baseline-accept-handler.js"
strict_row H12
case_end

case_begin "strict-H13-listed-unrunnable-string-zero-rejected" "hooks/workflow-mark/run-tests-baseline-accept-handler.js"
strict_row H13
case_end

case_begin "strict-H14-empty-list-timeout-granted" "hooks/workflow-mark/run-tests-baseline-accept-handler.js"
strict_row H14
case_end

case_begin "strict-H15-empty-list-runner-error-granted" "hooks/workflow-mark/run-tests-baseline-accept-handler.js"
strict_row H15
case_end

case_begin "strict-H16-listed-unrunnable-absent-rejected" "hooks/workflow-mark/run-tests-baseline-accept-handler.js"
strict_row H16
case_end

case_begin "strict-H17-listed-inherited-undetermined-mix-granted" "hooks/workflow-mark/run-tests-baseline-accept-handler.js"
strict_row H17
case_end
