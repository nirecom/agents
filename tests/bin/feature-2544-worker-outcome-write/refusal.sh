# Part of tests/bin/feature-2544-worker-outcome-write.sh — sourced.
# Tests: bin/worker-dispatch.js
# Tags: worker-dispatch, outcome, capability, refusal, identity, TL2, scope:issue-specific
# On a refused dispatch the outcome identity comes from the claim, never from the
# capability-validated value (which does not exist there): stem from the payload path,
# cwd from the raw payload bytes, and "" when the payload cwd is not a string.

# refused_outcome <label> <sid> <json> [preload] — dispatch, then print the outcome fields.
REF_F=""
refused_outcome() {
    local stem="worker-test-runner-2" p
    p="$(seed_payload "$2" "$stem" "$3")"
    set_canned "$PASS_CANNED"
    dispatch test-runner "$p" "${4:-}"
    assert_eq "$1/exit-0" "0" "$DRC"
    assert_eq "$1/stdout-status" "runner-error" "$(field_of status)"
    assert_eq "$1/one-outcome" "$stem.outcome.json " "$(outcomes_in "$2")"
    REF_F="$(outcome_fields "$2" "$stem")"
    assert_eq "$1/outcome-status-runner-error" "runner-error" "$(kv "$REF_F" status)"
    assert_eq "$1/stem-is-the-payload-stem" "$stem" "$(kv "$REF_F" stem)"
    assert_eq "$1/session-is-the-payload-session" "$2" "$(kv "$REF_F" session_id)"
    assert_eq "$1/payload-digest" "$(sha_of "$WF_RAW/$2.control/$stem.json")" "$(kv "$REF_F" payload_sha256)"
}

group_refusal_capability_raw_cwd() {
    refused_outcome "capability-outside-cwd" "s2544refout" "$(tr_json "$OUTSIDE")"
    assert_eq "capability-outside-cwd/cwd-is-the-raw-payload-string" "\"$OUTSIDE\"" "$(kv "$REF_F" cwd)"

    refused_outcome "capability-relative-cwd" "s2544refrel" "$(tr_json "./repo/../repo")"
    assert_eq "capability-relative-cwd/cwd-kept-unnormalised" '"./repo/../repo"' "$(kv "$REF_F" cwd)"
}

group_refusal_capability_nonstring_cwd() {
    refused_outcome "capability-numeric-cwd" "s2544refnum" '{"cwd":123,"test_args":[],"timeout_seconds":60}'
    assert_eq "capability-numeric-cwd/cwd-is-empty-string" '""' "$(kv "$REF_F" cwd)"
    refused_outcome "capability-missing-cwd" "s2544refmiss" '{"test_args":[],"timeout_seconds":60}'
    assert_eq "capability-missing-cwd/cwd-is-empty-string" '""' "$(kv "$REF_F" cwd)"
}

group_refusal_null_module() {
    refused_outcome "null-module" "s2544refnull" "$(tr_json)" "$NULL_PRELOAD"
    assert_eq "null-module/cwd-is-the-raw-payload-string" "\"$MAIN\"" "$(kv "$REF_F" cwd)"
    assert_has "null-module/summary-names-the-missing-worker" "not implemented" "$(kv "$REF_F" summary)"
    assert_eq "null-module/no-run-contract" "none" "$(kv "$REF_F" run_contract)"
}
