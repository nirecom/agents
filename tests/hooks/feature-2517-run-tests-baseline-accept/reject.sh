# shellcheck shell=bash
# tests/hooks/feature-2517-run-tests-baseline-accept/reject.sh
# Tests: hooks/workflow-mark/run-tests-baseline-accept-handler.js, hooks/workflow-mark.js
# Tags: TL2, hooks, workflow-mark, run-tests, baseline, escape-hatch, security, scope:issue-specific
# The reject paths (#2517 Steps 3): outside a failing, pending, non-UNRUNNABLE run without a broken
# entry, the sentinel writes nothing and the message names why; a malformed sentinel is advisory
# only. Sourced by the dispatcher after _lib.sh.

echo ""
echo "=== reject: the sentinel writes nothing outside an acceptable failing run ==="

case_begin "reject-names-the-reason" "hooks/workflow-mark/run-tests-baseline-accept-handler.js"
# Table: <label>|<setup kind>|<reason sent>|<ERE the message must match>.
# unrcount: UNRUNNABLE>0 points at the #2501 sentinel; noclass: classify first; broken: never.
while IFS='|' read -r label kind reason want; do
  [ -n "$label" ] || continue
  sid="f2517-rej-$label"
  setup_state "$sid" "$kind"
  before="$(snap "$sid")"
  out="$(mark "$sid" "$(acc_cmd "$reason")")"
  assert_eq "$label state unchanged: $(snap "$sid")" "$label state unchanged: $before"
  assert_eq "$label no grant: $(st field "$sid" run_tests baseline_accept)" "$label no grant: (absent)"
  msg_has "$label message names the reason" "$want" "$out"
done <<'ROWS'
already-complete|complete|these failures predate the branch|pending|already|complete
outcome-pass|pass|these failures predate the branch|run_outcome|fail|not a failing
outcome-unrunnable|unrun|these failures predate the branch|UNRUNNABLE_ACCEPTED
unrunnable-count|unrcount|these failures predate the branch|UNRUNNABLE_ACCEPTED
no-classification|noclass|these failures predate the branch|run-tests-baseline
broken-entry|broken|these failures predate the branch|broken
reason-too-short|undet|ab|short
reason-short-after-whitespace|undet|a  b|short
ROWS
case_end

case_begin "reject-without-session-id" "hooks/workflow-mark/run-tests-baseline-accept-handler.js"
sid="f2517-rej-nosid"
setup_state "$sid" undet
before="$(snap "$sid")"
out="$(mark "" "$(acc_cmd "$REASON_OK")")"
assert_eq "no-session state unchanged: $(snap "$sid")" "no-session state unchanged: $before"
msg_has "no-session message names the session" "session" "$out"
case_end

case_begin "malformed-sentinel-is-advisory-only" "hooks/workflow-mark/run-tests-baseline-accept-handler.js"
# Table: <label>|<full command>  (a literal pipe in a command is written %PIPE%).
while IFS='|' read -r label cmd; do
  [ -n "$label" ] || continue
  cmd="$(unpipe "$cmd")"
  sid="f2517-mal-$label"
  setup_state "$sid" undet
  before="$(snap "$sid")"
  out="$(mark "$sid" "$cmd")"
  assert_eq "$label state unchanged: $(snap "$sid")" "$label state unchanged: $before"
  msg_has "$label advisory names the expected form" "malformed|must not contain" "$out"
done <<'ROWS'
gt|echo "<<WORKFLOW_RUN_TESTS_BASELINE_ACCEPTED: flaky > not ours>>"
paren|echo "<<WORKFLOW_RUN_TESTS_BASELINE_ACCEPTED: flaky (on main)>>"
backtick|echo "<<WORKFLOW_RUN_TESTS_BASELINE_ACCEPTED: flaky `x` on main>>"
semicolon|echo "<<WORKFLOW_RUN_TESTS_BASELINE_ACCEPTED: flaky; on main>>"
pipe|echo "<<WORKFLOW_RUN_TESTS_BASELINE_ACCEPTED: flaky %PIPE% on main>>"
ampersand|echo "<<WORKFLOW_RUN_TESTS_BASELINE_ACCEPTED: flaky & on main>>"
bare|echo "<<WORKFLOW_RUN_TESTS_BASELINE_ACCEPTED>>"
empty-reason|echo "<<WORKFLOW_RUN_TESTS_BASELINE_ACCEPTED: >>"
ROWS
case_end

case_begin "sentinels-do-not-cross" "hooks/workflow-mark/run-tests-baseline-accept-handler.js"
# The UNRUNNABLE sentinel on a baseline-acceptable run writes no grant, and the baseline sentinel
# on an UNRUNNABLE-only run completes nothing.
sid="f2517-cross-ua"
setup_state "$sid" undet
mark "$sid" "$(ua_cmd "$REASON_OK")" >/dev/null
assert_eq "UNRUNNABLE sentinel writes no grant: $(st field "$sid" run_tests baseline_accept)" \
  "UNRUNNABLE sentinel writes no grant: (absent)"
assert_eq "UNRUNNABLE sentinel completes nothing: $(st field "$sid" run_tests status)" \
  "UNRUNNABLE sentinel completes nothing: pending"
sid="f2517-cross-ba"
setup_state "$sid" unrun
mark "$sid" "$(acc_cmd "$REASON_OK")" >/dev/null
assert_eq "baseline sentinel completes nothing: $(st field "$sid" run_tests status)" \
  "baseline sentinel completes nothing: pending"
assert_eq "no unrunnable basis: $(st field "$sid" run_tests completion_basis)" "no unrunnable basis: (absent)"
case_end
