# shellcheck shell=bash
# tests/feature-1665-run-outcome/d-worker-route.sh
# Tests: hooks/workflow-run-tests.js, hooks/workflow-run-tests/outcome.js, bin/worker-dispatch/emit.js
# Tags: workflow, run-outcome, worker-dispatch, classifier, hook, TL2, scope:issue-specific
#
# TL2 — real hook process against real emit.js payload shapes.
#
# WHY (CPR-WPH): on the worker-dispatch route the OS exit code is 0 BY CONSTRUCTION
# ("I produced a result"), never the suite verdict, so the non-zero fast path can
# structurally never fire here. The header's `status:` line is the only place the
# runner gets to say how the run went — and bin/worker-dispatch/workers/test-runner.js
# is a plain script, not an LLM, so that line is a mechanical observation. That is
# what makes it fit to become run_outcome verbatim.
#
# Every payload below is emit.js's real rendered shape: the contract (when present)
# as the FIRST line at offset 0, the verdict fields unindented, then exactly one
# `log_tail: |` marker whose block scalar runs to end of output.

_wd_payload() {
    # _wd_payload <contract-line-or-empty> <status> <exit_code>
    local contract="$1" status="$2" ec="$3"
    if [ -n "$contract" ]; then printf '%s\n' "$contract"; fi
    printf 'status: %s\n' "$status"
    printf 'exit_code: %s\n' "$ec"
    printf 'duration_seconds: 4\n'
    printf "summary: 'worker run'\n"
    printf 'failing_tests: []\n'
    printf 'log_tail: |\n'
    printf '  PASS: alpha\n'
    printf '  PASS: beta\n'
}
# NOTE: the log tail here deliberately carries NO `RUN_CONTRACT:` line. #1902's
# stdoutAttributed() counts contract lines over the WHOLE stdout, so a contract
# inside the block scalar makes the payload unattributable by design — that is
# the byte-attribution defence, and exercising it belongs to f-log-tail-scope.sh.
# Planting one here would make every row below unattributed and mask the outcome
# classifier this file is actually testing (CPR-SC: one concern per fixture).

run_d_worker_route_cases() {
    echo ""
    echo "=== d-worker-route (TL2: worker status becomes the outcome) ==="

    local sid out

    # --- D1..D3: the three failure words pass through VERBATIM -------------
    # name | contract line | status | want-outcome
    local name contract status want
    while IFS='|' read -r name contract status want; do
        [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
        name="${name//[[:space:]]/}"; status="${status//[[:space:]]/}"; want="${want//[[:space:]]/}"
        contract="${contract#"${contract%%[![:space:]]*}"}"; contract="${contract%"${contract##*[![:space:]]}"}"
        sid="f1665-d-$name"
        seed_step "$sid" write_tests complete
        out="$(_wd_payload "$contract" "$status" 1)"
        drive_hook "$DISPATCH_CMD" 0 "$sid" "$out" >/dev/null
        assert_eq "D/$name-outcome" "$want" "$(step_field "$sid" run_tests run_outcome)"
        # The status axis must not complete on any of these — the worker vetoed.
        assert_ne "D/$name-status-not-complete" "complete" "$(step_field "$sid" run_tests status)"
    done <<'TABLE'
status-fail         | RUN_CONTRACT: PASS=3 FAIL=2 SKIP=0 EXECUTED=5 | fail         | fail
status-timeout      |                                              | timeout      | timeout
status-runner-error |                                              | runner-error | runner-error
# uppercase must normalise: parseWorkerVerdict lowercases before the allowlist
status-upper-fail   |                                              | FAIL         | fail
# the worker's word outranks a green contract in the same payload
fail-beats-green    | RUN_CONTRACT: PASS=5 FAIL=0 SKIP=0 EXECUTED=5 | fail         | fail
TABLE

    # --- D4: status: pass but the contract is not trustworthy -------------
    # Two trusted renderings that disagree = nothing is attributable. The worker's
    # own "pass" is NOT a row-1 value, so there is no rescue: outcome is null.
    sid="f1665-d-pass-allskip"
    seed_step "$sid" write_tests complete
    out="$(_wd_payload "RUN_CONTRACT: PASS=0 FAIL=0 SKIP=5 EXECUTED=5" pass 0)"
    drive_hook "$DISPATCH_CMD" 0 "$sid" "$out" >/dev/null
    assert_eq "D4/all-skip-outcome-null" "(absent)" "$(step_field "$sid" run_tests run_outcome)"
    assert_eq "D4/all-skip-status-pending" "pending" "$(step_field "$sid" run_tests status)"

    sid="f1665-d-pass-nocontract"
    seed_step "$sid" write_tests complete
    out="$(_wd_payload "" pass 0)"
    drive_hook "$DISPATCH_CMD" 0 "$sid" "$out" >/dev/null
    assert_eq "D4b/no-contract-outcome-null" "(absent)" "$(step_field "$sid" run_tests run_outcome)"

    # --- D5: an explicit veto (exit_code != 0 with status: pass) ----------
    sid="f1665-d-veto"
    seed_step "$sid" write_tests complete
    out="$(_wd_payload "RUN_CONTRACT: PASS=5 FAIL=0 SKIP=0 EXECUTED=5" pass 3)"
    drive_hook "$DISPATCH_CMD" 0 "$sid" "$out" >/dev/null
    assert_eq "D5/vetoed-outcome-null" "(absent)" "$(step_field "$sid" run_tests run_outcome)"
    assert_eq "D5/vetoed-status-pending" "pending" "$(step_field "$sid" run_tests status)"

    # --- D6: a missing status: line vetoes (allowlist, not denylist) ------
    sid="f1665-d-nostatus"
    seed_step "$sid" write_tests complete
    out="RUN_CONTRACT: PASS=5 FAIL=0 SKIP=0 EXECUTED=5
exit_code: 0
summary: 'no status line at all'
log_tail: |
  PASS: alpha
  PASS: beta"
    drive_hook "$DISPATCH_CMD" 0 "$sid" "$out" >/dev/null
    assert_eq "D6/absent-status-outcome-null" "(absent)" "$(step_field "$sid" run_tests run_outcome)"

    # --- D7: control — the fully green worker run -------------------------
    # CPR-ORTH: the sanctioned-input verdict of the same classifier. Without it a
    # fix that demotes everything would look correct.
    sid="f1665-d-green"
    seed_step "$sid" write_tests complete
    out="$(_wd_payload "RUN_CONTRACT: PASS=7 FAIL=0 SKIP=0 EXECUTED=7" pass 0)"
    drive_hook "$DISPATCH_CMD" 0 "$sid" "$out" >/dev/null
    assert_eq "D7/green-status-complete" "complete" "$(step_field "$sid" run_tests status)"
    assert_eq "D7/green-outcome-pass" "pass" "$(step_field "$sid" run_tests run_outcome)"
}
