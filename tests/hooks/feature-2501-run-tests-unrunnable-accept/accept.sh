# shellcheck shell=bash
# tests/hooks/feature-2501-run-tests-unrunnable-accept/accept.sh
# Tests: hooks/workflow-mark/run-tests-accept-handler.js, hooks/workflow-mark.js
# Tags: TL2, hooks, workflow-mark, run-tests, unrunnable, escape-hatch, scope:issue-specific
# The accept path (#2501 D5-7): a run_tests left pending only because tests could not run
# (current contract, FAIL=0, UNRUNNABLE>0) completes on the sentinel, with the gap recorded, and
# the accepted run never reopens write_code. Sourced by the dispatcher after _lib.sh.

echo ""
echo "=== accept: an unrunnable-pending run_tests completes on the sentinel ==="

case_begin "accept-completes-hook-written-unrunnable-run" "hooks/workflow-mark/run-tests-accept-handler.js"
# End to end: the real run-tests hook leaves the pending state (D5-4), the real workflow-mark records.
sid="f2501-acc-a1"
setup_run "$sid" unrun
assert_eq "fixture status: $(st field "$sid" run_tests status)" "fixture status: pending"
assert_eq "fixture outcome: $(st field "$sid" run_tests run_outcome)" "fixture outcome: unrunnable"
assert_eq "fixture runtimes: $(st field "$sid" run_tests unrunnable_runtimes)" "fixture runtimes: Pester>=5.0"
out="$(mark "$sid" "$(acc_cmd "$REASON_OK")")"
assert_eq "status: $(st field "$sid" run_tests status)" "status: complete"
assert_eq "completion_basis: $(st field "$sid" run_tests completion_basis)" "completion_basis: unrunnable-accepted"
assert_eq "unrunnable_count kept: $(st field "$sid" run_tests unrunnable_count)" "unrunnable_count kept: 2"
assert_eq "unrunnable_runtimes kept: $(st field "$sid" run_tests unrunnable_runtimes)" "unrunnable_runtimes kept: Pester>=5.0"
assert_eq "accept reason: $(st field "$sid" run_tests unrunnable_accept_reason)" "accept reason: $REASON_OK"
assert_eq "run_outcome stays: $(st field "$sid" run_tests run_outcome)" "run_outcome stays: unrunnable"
msg_has "accept message names the sentinel" "UNRUNNABLE_ACCEPTED" "$out"
case_end

case_begin "accept-reads-recorded-runtimes" "hooks/workflow-mark/run-tests-accept-handler.js"
# The handler reads the hook-written annotations (CPR-SSOT) and never re-parses stdout: a state
# seeded exactly as the hook leaves it is accepted, and its two-label runtimes survive verbatim.
sid="f2501-acc-a1b"
st seed "$sid" write_tests complete >/dev/null
st seed "$sid" run_tests pending last_run_failed false contract_absent false run_outcome unrunnable \
  unrunnable_count 3 unrunnable_runtimes "Pester>=5.0,uv" >/dev/null
out="$(mark "$sid" "$(acc_cmd "$REASON_OK")")"
assert_eq "seeded status: $(st field "$sid" run_tests status)" "seeded status: complete"
assert_eq "seeded basis: $(st field "$sid" run_tests completion_basis)" "seeded basis: unrunnable-accepted"
assert_eq "seeded count: $(st field "$sid" run_tests unrunnable_count)" "seeded count: 3"
assert_eq "seeded runtimes: $(st field "$sid" run_tests unrunnable_runtimes)" "seeded runtimes: Pester>=5.0,uv"
assert_eq "seeded reason: $(st field "$sid" run_tests unrunnable_accept_reason)" "seeded reason: $REASON_OK"
case_end

case_begin "accepted-run-does-not-reopen-write-code" "hooks/workflow-mark/run-tests-accept-handler.js"
# "unrunnable" is not a code defect: it is outside FAILING_RUN_OUTCOMES, so accepting it must not
# make write-code-resume reopen write_code. The fail control proves the probe can see a reopen.
sid="f2501-acc-a5"
st seq "$sid" >/dev/null
run_hook "$sid" 0 "$OUT_UNRUN"
mark "$sid" "$(acc_cmd "$REASON_OK")" >/dev/null
assert_eq "accepted run_tests: $(st field "$sid" run_tests status)" "accepted run_tests: complete"
assert_eq "after accept: $(st resume "$sid")" "after accept: write_code=complete from=state"
sid="f2501-acc-a5-control"
st seq "$sid" >/dev/null
st seed "$sid" run_tests pending last_run_failed true run_outcome fail >/dev/null
assert_eq "fail control: $(st resume "$sid")" "fail control: write_code=pending from=write-code-resumed"
case_end
