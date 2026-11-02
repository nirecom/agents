# shellcheck shell=bash
# tests/hooks/feature-2501-run-tests-unrunnable-accept/missing-file.sh
# Tests: hooks/workflow-mark/run-tests-accept-handler.js, hooks/workflow-run-tests.js, hooks/workflow-mark.js
# Tags: TL2, hooks, workflow-mark, run-tests, unrunnable, missing-test-file, escape-hatch, test-lang-exception:e2e, scope:issue-specific
# #2646: an UNRUNNABLE caused by a missing test file is a broken test path, not a missing
# runtime, so the accept sentinel refuses it. The run-tests hook records the count as
# unrunnable_missing_files on a contract-unrunnable run; the handler reads only that field.
# Sourced by the dispatcher after reject.sh.

echo ""
echo "=== missing-file: a run with a missing test file cannot be accepted ==="

case_begin "reject-missing-test-file-runs" "hooks/workflow-mark/run-tests-accept-handler.js"
# Table: <label>|<setup kind>|<recorded unrunnable_missing_files>|<recorded unrunnable_runtimes>.
# all-missing: every UNRUNNABLE is a gone file; mixed: one missing runtime and one gone file.
while IFS='|' read -r label kind want_missing want_runtimes; do
  [ -n "$label" ] || continue
  sid="f2646-rej-$label"
  setup_run "$sid" "$kind"
  assert_eq "$label fixture status: $(st field "$sid" run_tests status)" "$label fixture status: pending"
  assert_eq "$label fixture outcome: $(st field "$sid" run_tests run_outcome)" "$label fixture outcome: unrunnable"
  assert_eq "$label fixture exit code: $(st field "$sid" run_tests last_exit_code)" "$label fixture exit code: 77"
  assert_eq "$label recorded missing files: $(st field "$sid" run_tests unrunnable_missing_files)" \
    "$label recorded missing files: $want_missing"
  assert_eq "$label recorded runtimes: $(st field "$sid" run_tests unrunnable_runtimes)" \
    "$label recorded runtimes: $want_runtimes"
  before="$(snap "$sid")"
  out="$(mark "$sid" "$(acc_cmd "$REASON_OK")")"
  assert_eq "$label state unchanged: $(snap "$sid")" "$label state unchanged: $before"
  assert_eq "$label still pending: $(st field "$sid" run_tests status)" "$label still pending: pending"
  assert_eq "$label no accept recorded: $(st field "$sid" run_tests completion_basis)" \
    "$label no accept recorded: (absent)"
  msg_has "$label message names the missing test file" "missing test file" "$out"
  msg_has "$label message says to fix the test path" "fix the test path" "$out"
done <<'ROWS'
all-missing|allmissing|2|(absent)
mixed|mixed|1|Pester>=5.0
ROWS
case_end

case_begin "runtime-only-run-still-accepted" "hooks/workflow-mark/run-tests-accept-handler.js"
# Regression: a run whose only UNRUNNABLE lines are missing runtimes records 0 and is accepted.
sid="f2646-acc-runtime-only"
setup_run "$sid" unrun
assert_eq "runtime-only recorded missing files: $(st field "$sid" run_tests unrunnable_missing_files)" \
  "runtime-only recorded missing files: 0"
mark "$sid" "$(acc_cmd "$REASON_OK")" >/dev/null
assert_eq "runtime-only status: $(st field "$sid" run_tests status)" "runtime-only status: complete"
assert_eq "runtime-only basis: $(st field "$sid" run_tests completion_basis)" \
  "runtime-only basis: unrunnable-accepted"
case_end

case_begin "state-without-missing-files-key-accepted" "hooks/workflow-mark/run-tests-accept-handler.js"
# A state written before #2646 has no unrunnable_missing_files; a missing key reads as 0.
sid="f2646-acc-old-state"
st seed "$sid" write_tests complete >/dev/null
st seed "$sid" run_tests pending last_run_failed false contract_absent false run_outcome unrunnable \
  unrunnable_count 2 unrunnable_runtimes "Pester>=5.0" >/dev/null
assert_eq "old-state key absent: $(st field "$sid" run_tests unrunnable_missing_files)" "old-state key absent: (absent)"
mark "$sid" "$(acc_cmd "$REASON_OK")" >/dev/null
assert_eq "old-state status: $(st field "$sid" run_tests status)" "old-state status: complete"
assert_eq "old-state basis: $(st field "$sid" run_tests completion_basis)" "old-state basis: unrunnable-accepted"
assert_eq "old-state key still absent: $(st field "$sid" run_tests unrunnable_missing_files)" \
  "old-state key still absent: (absent)"
case_end

case_begin "seeded-missing-files-rejected-by-handler" "hooks/workflow-mark/run-tests-accept-handler.js"
# The handler alone refuses a recorded count > 0, whatever wrote it (recording and judging are separate).
sid="f2646-rej-seeded"
st seed "$sid" write_tests complete >/dev/null
st seed "$sid" run_tests pending last_run_failed false contract_absent false run_outcome unrunnable \
  unrunnable_count 3 unrunnable_runtimes "Pester>=5.0" unrunnable_missing_files 1 >/dev/null
before="$(snap "$sid")"
out="$(mark "$sid" "$(acc_cmd "$REASON_OK")")"
assert_eq "seeded state unchanged: $(snap "$sid")" "seeded state unchanged: $before"
assert_eq "seeded no accept recorded: $(st field "$sid" run_tests completion_basis)" \
  "seeded no accept recorded: (absent)"
msg_has "seeded message names the missing test file" "missing test file" "$out"
msg_has "seeded message is a rejection" "rejected" "$out"
case_end

case_begin "next-run-tombstones-missing-files" "hooks/workflow-run-tests.js"
# A count belongs to one run: a green run after the rejected one leaves no stale count behind.
sid="f2646-tomb"
setup_run "$sid" allmissing
assert_eq "tomb fixture count: $(st field "$sid" run_tests unrunnable_missing_files)" "tomb fixture count: 2"
mark "$sid" "$(acc_cmd "$REASON_OK")" >/dev/null
run_hook "$sid" 0 "$OUT_GREEN"
assert_eq "tomb status after green: $(st field "$sid" run_tests status)" "tomb status after green: complete"
assert_eq "tomb count after green: $(st field "$sid" run_tests unrunnable_missing_files)" \
  "tomb count after green: (absent)"
case_end

case_begin "worker-stdout-token-recorded" "hooks/workflow-run-tests.js"
# The worker-dispatch stdout route: the summary's `Missing test files: 2; ` token is the count, and
# the runtimes after the token are still read (WORKER_MISSING_RE skips the token).
sid="f2646-worker"
setup_run "$sid" worker-missing
assert_eq "worker status: $(st field "$sid" run_tests status)" "worker status: pending"
assert_eq "worker missing files: $(st field "$sid" run_tests unrunnable_missing_files)" "worker missing files: 2"
assert_eq "worker runtimes: $(st field "$sid" run_tests unrunnable_runtimes)" "worker runtimes: Pester>=5.0"
mark "$sid" "$(acc_cmd "$REASON_OK")" >/dev/null
assert_eq "worker accept refused: $(st field "$sid" run_tests status)" "worker accept refused: pending"
case_end
