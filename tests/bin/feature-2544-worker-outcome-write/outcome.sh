# Part of tests/bin/feature-2544-worker-outcome-write.sh — sourced.
# Tests: bin/worker-dispatch.js
# Tags: worker-dispatch, outcome, exclusive-create, negative-assertion, TL2, scope:issue-specific
# Outcome write: one file per claimed dispatch on every path after the marker, and
# none on the paths that never claim one. A write that fails turns the stdout result
# into runner-error, so the caller never reads a pass the hook can never confirm.

# one_outcome <label> <sid> <stem> — exactly this dispatch's outcome, and the control
# dir holds nothing beyond payload, marker and outcome.
one_outcome() {
    assert_eq "$1/exactly-one-outcome" "$3.outcome.json " "$(outcomes_in "$2")"
    assert_eq "$1/control-dir-holds-payload-marker-outcome-only" \
        "$3.dispatched $3.json $3.outcome.json " "$(ctrl_ls "$2")"
}
# outcome_identity <label> <sid> <stem> <fields> — the worker-independent outer fields.
outcome_identity() {
    assert_eq "$1/outcome-parses" "ok" "$(kv "$4" parse)"
    assert_eq "$1/schema-version" "1" "$(kv "$4" schema_version)"
    assert_eq "$1/worker" "test-runner" "$(kv "$4" worker)"
    assert_eq "$1/stem" "$3" "$(kv "$4" stem)"
    assert_eq "$1/session-id" "$2" "$(kv "$4" session_id)"
    assert_eq "$1/payload-sha256" "$(sha_of "$WF_RAW/$2.control/$3.json")" "$(kv "$4" payload_sha256)"
    assert_eq "$1/status-is-the-stdout-status" "$(field_of status)" "$(kv "$4" status)"
    assert_eq "$1/exit-code-is-the-stdout-exit-code" "$(field_of exit_code)" "$(kv "$4" exit_code)"
    assert_eq "$1/summary-is-a-string" "string" "$(kv "$4" summary_type)"
}
# not_success <label> <fields> — a path that did not pass never records "pass".
not_success() {
    local st; st="$(kv "$2" status)"
    if [ -n "$st" ] && [ "$st" != "pass" ]; then pass "$1/outcome-status-is-not-success"
    else fail "$1/outcome-status-is-not-success" "status=$(printf '%q' "$st")"; fi
}

group_outcome_normal() {
    local sid="s2544ok" stem="worker-test-runner-1" p f
    p="$(seed_payload "$sid" "$stem" "$(tr_json)")"
    set_canned "$PASS_CANNED"
    dispatch test-runner "$p"
    assert_eq "normal/exit-0" "0" "$DRC"
    assert_eq "normal/stdout-status" "pass" "$(field_of status)"
    assert_eq "normal/stdout-leads-with-run-contract" "RUN_CONTRACT: PASS=2 FAIL=0 SKIP=0 EXECUTED=2" "$(printf '%s\n' "$DOUT" | head -1)"
    one_outcome "normal" "$sid" "$stem"
    f="$(outcome_fields "$sid" "$stem")"
    outcome_identity "normal" "$sid" "$stem" "$f"
    assert_eq "normal/outcome-status-pass" "pass" "$(kv "$f" status)"
    assert_eq "normal/cwd-is-the-raw-payload-cwd" "\"$MAIN\"" "$(kv "$f" cwd)"
    assert_eq "normal/duration-ms-is-a-number" "number" "$(kv "$f" duration_ms_type)"
    assert_eq "normal/failing-tests-empty" "[]" "$(kv "$f" failing_tests)"
    assert_eq "normal/log-tail-recorded" "yes" "$(kv "$f" log_tail_present)"
    assert_eq "normal/summary-is-the-stdout-summary" "$(field_of summary)" "$(kv "$f" summary)"
    assert_eq "normal/run-contract-recorded" '{"pass":2,"fail":0,"skip":0,"executed":2}' "$(kv "$f" run_contract)"
    assert_eq "normal/stderr-quiet" "" "$DERR"
}

group_outcome_suite_fail() {
    local sid="s2544red" stem="worker-test-runner-1" p f
    p="$(seed_payload "$sid" "$stem" "$(tr_json)")"
    set_canned "$FAIL_CANNED"
    dispatch test-runner "$p"
    assert_eq "suite-fail/exit-0" "0" "$DRC"
    assert_eq "suite-fail/stdout-status" "fail" "$(field_of status)"
    one_outcome "suite-fail" "$sid" "$stem"
    f="$(outcome_fields "$sid" "$stem")"
    outcome_identity "suite-fail" "$sid" "$stem" "$f"
    not_success "suite-fail" "$f"
    assert_eq "suite-fail/failing-tests-recorded" '["tests/bin/a.sh"]' "$(kv "$f" failing_tests)"
}

group_outcome_worker_error() {
    local sid="s2544throw" stem="worker-test-runner-1" p f
    p="$(seed_payload "$sid" "$stem" "$(tr_json)")"
    set_canned "$PASS_CANNED"
    dispatch test-runner "$p" "$THROW_PRELOAD"
    assert_eq "worker-error/exit-0" "0" "$DRC"
    assert_eq "worker-error/stdout-status" "runner-error" "$(field_of status)"
    assert_has "worker-error/stdout-names-the-worker-error" "worker error: stubbed worker failure" "$(field_of summary)"
    one_outcome "worker-error" "$sid" "$stem"
    f="$(outcome_fields "$sid" "$stem")"
    outcome_identity "worker-error" "$sid" "$stem" "$f"
    not_success "worker-error" "$f"
    assert_eq "worker-error/no-run-contract-invented" "none" "$(kv "$f" run_contract)"
}

group_outcome_capability() {
    local sid="s2544cap" stem="worker-test-runner-1" p f
    p="$(seed_payload "$sid" "$stem" "$(tr_json "$OUTSIDE")")"
    set_canned "$PASS_CANNED"
    dispatch test-runner "$p"
    assert_eq "capability/exit-0" "0" "$DRC"
    assert_eq "capability/stdout-status" "runner-error" "$(field_of status)"
    assert_has "capability/stdout-names-the-capability-failure" "capability: " "$(field_of summary)"
    assert_eq "capability/suite-never-started" "0" "$(count_lines "$(cat "$CALLLOG")")"
    one_outcome "capability" "$sid" "$stem"
    f="$(outcome_fields "$sid" "$stem")"
    outcome_identity "capability" "$sid" "$stem" "$f"
    not_success "capability" "$f"
}

# Attack shape: something other than this dispatch put a file at the outcome name first.
# The dispatcher must lose that race loudly, never replace the bytes, and never report
# a result on stdout that no outcome file backs.
group_outcome_preexisting() {
    local sid="s2544forged" stem="worker-test-runner-1" p planted before
    p="$(seed_payload "$sid" "$stem" "$(tr_json)")"
    planted="$WF_RAW/$sid.control/$stem.outcome.json"
    printf '%s' '{"forged":true,"status":"pass"}' > "$planted"
    before="$(sha_of "$planted")"
    set_canned "$PASS_CANNED"
    dispatch test-runner "$p"
    assert_eq "planted/exit-0" "0" "$DRC"
    assert_eq "planted/bytes-unchanged" "$before" "$(sha_of "$planted")"
    assert_eq "planted/still-the-only-outcome" "$stem.outcome.json " "$(outcomes_in "$sid")"
    assert_eq "planted/stdout-is-runner-error" "runner-error" "$(field_of status)"
    assert_has "planted/stdout-says-the-outcome-was-not-written" "outcome record could not be written" "$(field_of summary)"
}

group_outcome_not_written() {
    local sid stem p first leg before
    set_canned "$PASS_CANNED"

    sid="s2544twice"; stem="worker-test-runner-1"
    p="$(seed_payload "$sid" "$stem" "$(tr_json)")"
    dispatch test-runner "$p"
    first="$(sha_of "$WF_RAW/$sid.control/$stem.outcome.json")"
    dispatch test-runner "$p"
    assert_eq "redispatch/exit-1" "1" "$DRC"
    assert_has "redispatch/stdout-says-already-dispatched" "already dispatched" "$(field_of summary)"
    if [ "$first" = "MISSING" ]; then fail "redispatch/first-outcome-untouched" "the first dispatch wrote no outcome"
    else assert_eq "redispatch/first-outcome-untouched" "$first" "$(sha_of "$WF_RAW/$sid.control/$stem.outcome.json")"; fi
    assert_eq "redispatch/no-second-outcome" "$stem.dispatched $stem.json $stem.outcome.json " "$(ctrl_ls "$sid")"

    sid="s2544early"
    p="$(seed_payload "$sid" "$stem" '{"cwd":"x","bogus_field":1}')"
    dispatch test-runner "$p"
    assert_eq "pre-marker-failure/exit-0" "0" "$DRC"
    assert_eq "pre-marker-failure/nothing-added" "$stem.json " "$(ctrl_ls "$sid")"

    leg="$PLANS_RAW/legacy-2544-run.json"
    printf '%s' "$(tr_json)" > "$leg"
    before="$(find "$TMPD" -name '*.outcome.json' | LC_ALL=C sort)"
    dispatch test-runner "$(np "$leg")"
    assert_eq "legacy-payload/exit-0" "0" "$DRC"
    assert_eq "legacy-payload/stdout-status" "pass" "$(field_of status)"
    assert_eq "legacy-payload/no-outcome-anywhere" "$before" "$(find "$TMPD" -name '*.outcome.json' | LC_ALL=C sort)"

    sid="s2544other"; stem="worker-issue-close-finalize-1"
    p="$(seed_payload "$sid" "$stem" "$(finalize_json "$sid")")"
    set_canned "$FINALIZE_CANNED"
    dispatch issue-close-finalize "$p"
    assert_eq "non-recording-worker/exit-0" "0" "$DRC"
    assert_eq "non-recording-worker/marker-taken" "yes" "$(has_file "$sid" "$stem.dispatched")"
    assert_eq "non-recording-worker/no-outcome" "" "$(outcomes_in "$sid")"
}

# The outcome name is occupied by a directory, so the write cannot succeed by any route.
group_outcome_write_failure() {
    local stem="worker-test-runner-1" p
    set_canned "$PASS_CANNED"
    p="$(seed_payload "s2544blocked" "$stem" "$(tr_json)")"
    mkdir -p "$WF_RAW/s2544blocked.control/$stem.outcome.json"
    dispatch test-runner "$p"
    assert_eq "write-failure/exit-0" "0" "$DRC"
    assert_eq "write-failure/stdout-status-is-runner-error" "runner-error" "$(field_of status)"
    assert_has "write-failure/stdout-names-the-failed-record" "outcome record could not be written" "$(field_of summary)"
    assert_eq "write-failure/blocker-untouched" "$stem.dispatched $stem.json $stem.outcome.json " "$(ctrl_ls "s2544blocked")"
}
