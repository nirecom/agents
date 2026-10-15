# shellcheck shell=bash
# tests/hooks/feature-2517-run-tests-baseline-accept/grant.sh
# Tests: hooks/workflow-mark/run-tests-baseline-accept-handler.js, hooks/workflow-mark.js
# Tags: TL2, hooks, workflow-mark, run-tests, baseline, escape-hatch, scope:issue-specific
# The grant path (#2517 Steps 3): the sentinel writes ONE baseline_accept annotation bound to the
# current run (run_seq, outcome_source, accepted_run_outcome) and leaves run_tests pending; only
# bin/run-tests-baseline completes it. Sourced by the dispatcher after _lib.sh.

echo ""
echo "=== grant: the sentinel records a run-bound grant and nothing else ==="

case_begin "grant-undetermined-only" "hooks/workflow-mark/run-tests-baseline-accept-handler.js"
sid="f2517-grant-undet"
setup_state "$sid" undet
seq="$(st field "$sid" run_tests updated_seq)"
out="$(mark "$sid" "$(acc_cmd "$REASON_OK")")"
assert_eq "kind: $(st path "$sid" run_tests baseline_accept kind)" "kind: undetermined"
assert_eq "reason: $(st path "$sid" run_tests baseline_accept reason)" "reason: $REASON_OK"
assert_eq "run_seq bound to the run: $(st path "$sid" run_tests baseline_accept run_seq)" \
  "run_seq bound to the run: $seq"
assert_eq "updated_seq unchanged: $(st field "$sid" run_tests updated_seq)" "updated_seq unchanged: $seq"
assert_eq "accepted_run_outcome: $(st path "$sid" run_tests baseline_accept accepted_run_outcome)" \
  "accepted_run_outcome: fail"
assert_eq "status stays pending: $(st field "$sid" run_tests status)" "status stays pending: pending"
assert_eq "no completion_basis: $(st field "$sid" run_tests completion_basis)" "no completion_basis: (absent)"
assert_eq "run_outcome untouched: $(st field "$sid" run_tests run_outcome)" "run_outcome untouched: fail"
msg_has "message points at bin/run-tests-baseline" "run-tests-baseline" "$out"
case_end

case_begin "grant-failing-list-unrecorded" "hooks/workflow-mark/run-tests-baseline-accept-handler.js"
# Table: <setup kind>|<expected kind>. A null and an empty list are the same blind spot.
while IFS='|' read -r kind want; do
  [ -n "$kind" ] || continue
  sid="f2517-grant-$kind"
  setup_state "$sid" "$kind"
  out="$(mark "$sid" "$(acc_cmd "$REASON_OK")")"
  assert_eq "$kind kind: $(st path "$sid" run_tests baseline_accept kind)" "$kind kind: $want"
  assert_eq "$kind status: $(st field "$sid" run_tests status)" "$kind status: pending"
  # The exit-3 blind spot is named at grant time: no list means broken cannot be told apart.
  msg_has "$kind message names the blind spot" "broken|no (recorded )?failing list|without a failing list" "$out"
done <<'ROWS'
nolist|failing-list-unrecorded
emptylist|failing-list-unrecorded
ROWS
case_end

case_begin "grant-copies-accepted-run-outcome" "hooks/workflow-mark/run-tests-baseline-accept-handler.js"
# Each failing value is kept as the grant's accepted_run_outcome (the note reads it after accept()
# has overwritten run_outcome with "pass").
while IFS='|' read -r kind want; do
  [ -n "$kind" ] || continue
  sid="f2517-grant-ro-$kind"
  setup_state "$sid" "$kind"
  mark "$sid" "$(acc_cmd "$REASON_OK")" >/dev/null
  assert_eq "$kind accepted_run_outcome: $(st path "$sid" run_tests baseline_accept accepted_run_outcome)" \
    "$kind accepted_run_outcome: $want"
done <<'ROWS'
nolist|fail
timeout|timeout
runner-error|runner-error
ROWS
case_end

case_begin "grant-copies-outcome-source" "hooks/workflow-mark/run-tests-baseline-accept-handler.js"
# A dispatch-ingested run carries outcome_source; the grant copies it so accept() can tell when
# the outcome behind the run was replaced. A Bash-stdout run carries none: the grant holds null.
sid="f2517-grant-src"
setup_state "$sid" undet
st ann "$sid" outcome_source '{"stem":"worker-test-runner-7","payload_sha256":"aa","outcome_sha256":"bb"}' >/dev/null
seq="$(st field "$sid" run_tests updated_seq)"
mark "$sid" "$(acc_cmd "$REASON_OK")" >/dev/null
assert_eq "stem copied: $(st path "$sid" run_tests baseline_accept outcome_source.stem)" \
  "stem copied: worker-test-runner-7"
assert_eq "digest copied: $(st path "$sid" run_tests baseline_accept outcome_source.outcome_sha256)" \
  "digest copied: bb"
assert_eq "seq after annotation-only seed: $(st path "$sid" run_tests baseline_accept run_seq)" \
  "seq after annotation-only seed: $seq"
sid="f2517-grant-nosrc"
setup_state "$sid" undet
mark "$sid" "$(acc_cmd "$REASON_OK")" >/dev/null
assert_eq "no source recorded: $(st path "$sid" run_tests baseline_accept outcome_source)" \
  "no source recorded: (absent)"
assert_eq "grant still written: $(st path "$sid" run_tests baseline_accept kind)" "grant still written: undetermined"
case_end
