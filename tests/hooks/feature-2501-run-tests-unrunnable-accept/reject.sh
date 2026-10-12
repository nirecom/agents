# shellcheck shell=bash
# tests/hooks/feature-2501-run-tests-unrunnable-accept/reject.sh
# Tests: hooks/workflow-mark/run-tests-accept-handler.js, hooks/workflow-mark.js
# Tags: TL2, hooks, workflow-mark, run-tests, unrunnable, escape-hatch, security, scope:issue-specific
# The reject paths (#2501 D5-7): the sentinel accepts only an unrunnable-pending run. Every other
# state is left exactly as it was and the message names why; a malformed sentinel is advisory only.
# Sourced by the dispatcher after _lib.sh.

echo ""
echo "=== reject: the sentinel changes nothing outside an unrunnable-pending run ==="

case_begin "reject-names-the-reason" "hooks/workflow-mark/run-tests-accept-handler.js"
# Table: <label>|<setup kind>|<reason sent>|<ERE the message must match>.
# already-complete: a green run settled run_tests; legacy: 4 fields cannot prove UNRUNNABLE=0;
# fail: FAIL>0 is a code defect even with UNRUNNABLE>0; no-contract: nothing proves what ran.
while IFS='|' read -r label kind reason want; do
  [ -n "$label" ] || continue
  sid="f2501-rej-$label"
  setup_run "$sid" "$kind"
  before="$(snap "$sid")"
  out="$(mark "$sid" "$(acc_cmd "$reason")")"
  assert_eq "$label state unchanged: $(snap "$sid")" "$label state unchanged: $before"
  assert_eq "$label no accept recorded: $(st field "$sid" run_tests completion_basis)" \
    "$label no accept recorded: (absent)"
  msg_has "$label message names the reason" "$want" "$out"
done <<'ROWS'
already-complete|green|Pester 5 cannot be installed here|pending|already
legacy-shape|legacy|Pester 5 cannot be installed here|legacy|rebase
fail-gt-zero|fail|Pester 5 cannot be installed here|fail
no-contract|nocontract|Pester 5 cannot be installed here|contract
reason-too-short|unrun|ab|short
reason-short-after-whitespace|unrun|a  b|short
ROWS
case_end

case_begin "reject-without-session-id" "hooks/workflow-mark/run-tests-accept-handler.js"
# No resolvable session: nothing can be recorded, and the message says so.
sid="f2501-rej-nosid"
setup_run "$sid" unrun
before="$(snap "$sid")"
out="$(mark "" "$(acc_cmd "$REASON_OK")")"
assert_eq "no-session state unchanged: $(snap "$sid")" "no-session state unchanged: $before"
msg_has "no-session message names the session" "session" "$out"
case_end

case_begin "malformed-sentinel-is-advisory-only" "hooks/workflow-mark/run-tests-accept-handler.js"
# Reason characters outside [^>()`;|&] fail the strict regex and fall to LOOKSLIKE: the run stays
# pending and the message shows the expected form. Same for the bare and the empty-reason forms.
# Table: <label>~<full command>  (`~` delimits because `|` is one of the rejected characters).
while IFS='~' read -r label cmd; do
  [ -n "$label" ] || continue
  sid="f2501-mal-$label"
  setup_run "$sid" unrun
  before="$(snap "$sid")"
  out="$(mark "$sid" "$cmd")"
  assert_eq "$label state unchanged: $(snap "$sid")" "$label state unchanged: $before"
  msg_has "$label advisory names the expected form" "malformed|must not contain" "$out"
done <<'ROWS'
gt~echo "<<WORKFLOW_RUN_TESTS_UNRUNNABLE_ACCEPTED: Pester 5 > not here>>"
open-paren~echo "<<WORKFLOW_RUN_TESTS_UNRUNNABLE_ACCEPTED: Pester 5 (CI only)>>"
close-paren~echo "<<WORKFLOW_RUN_TESTS_UNRUNNABLE_ACCEPTED: Pester 5 missing) here>>"
backtick~echo "<<WORKFLOW_RUN_TESTS_UNRUNNABLE_ACCEPTED: Pester `5` missing>>"
semicolon~echo "<<WORKFLOW_RUN_TESTS_UNRUNNABLE_ACCEPTED: Pester 5; not here>>"
pipe~echo "<<WORKFLOW_RUN_TESTS_UNRUNNABLE_ACCEPTED: Pester 5 | not here>>"
ampersand~echo "<<WORKFLOW_RUN_TESTS_UNRUNNABLE_ACCEPTED: Pester 5 & uv missing>>"
bare~echo "<<WORKFLOW_RUN_TESTS_UNRUNNABLE_ACCEPTED>>"
empty-reason~echo "<<WORKFLOW_RUN_TESTS_UNRUNNABLE_ACCEPTED: >>"
ROWS
case_end
