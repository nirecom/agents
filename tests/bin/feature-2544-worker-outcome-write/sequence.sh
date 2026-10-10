# Part of tests/bin/feature-2544-worker-outcome-write.sh — sourced.
# Tests: bin/worker-dispatch.js
# Tags: worker-dispatch, outcome, claim-order, negative-assertion, TL2, scope:issue-specific
# The outcome follows the claim: a failure before the .dispatched marker writes nothing
# (no marker means the dispatch is never unsettled), and each of the four exits after
# the claim writes exactly one outcome, so a claimed dispatch can always be settled.

# pre_claim <label> <sid> <stem> <json> — dispatch a payload refused before the claim.
pre_claim() {
    local p
    p="$(seed_payload "$2" "$3" "$4")"
    set_canned "$PASS_CANNED"
    dispatch test-runner "$p"
    assert_eq "$1/no-dispatch-marker" "no" "$(has_file "$2" "$3.dispatched")"
    assert_eq "$1/no-outcome" "" "$(outcomes_in "$2")"
    assert_eq "$1/suite-never-started" "0" "$(count_lines "$(cat "$CALLLOG")")"
}

group_seq_no_write_before_claim() {
    local stem="worker-test-runner-1"
    pre_claim "unparseable-payload" "s2544bad" "$stem" '{"cwd":'
    pre_claim "unknown-field" "s2544field" "$stem" '{"cwd":"x","bogus_field":1}'
    pre_claim "not-an-object" "s2544array" "$stem" '[]'
}

# post_claim <label> <sid> <json> [preload] <want-summary-fragment>
post_claim() {
    local label="$1" sid="$2" stem="worker-test-runner-1" p f
    p="$(seed_payload "$sid" "$stem" "$3")"
    set_canned "$PASS_CANNED"
    dispatch test-runner "$p" "$4"
    assert_eq "$label/marker-taken" "yes" "$(has_file "$sid" "$stem.dispatched")"
    assert_eq "$label/exactly-one-outcome" "$stem.outcome.json " "$(outcomes_in "$sid")"
    f="$(outcome_fields "$sid" "$stem")"
    assert_eq "$label/outcome-status-is-the-stdout-status" "$(field_of status)" "$(kv "$f" status)"
    assert_eq "$label/outcome-stem-is-the-payload-stem" "$stem" "$(kv "$f" stem)"
    assert_has "$label/stdout-summary" "$5" "$(field_of summary)"
}

group_seq_writes_after_claim() {
    post_claim "post-claim-normal" "s2544pc1" "$(tr_json)" "" ""
    assert_eq "post-claim-normal/status-pass" "pass" "$(field_of status)"
    post_claim "post-claim-capability" "s2544pc2" "$(tr_json "$OUTSIDE")" "" "capability: "
    assert_eq "post-claim-capability/status-runner-error" "runner-error" "$(field_of status)"
    post_claim "post-claim-null-module" "s2544pc3" "$(tr_json)" "$NULL_PRELOAD" "not implemented"
    assert_eq "post-claim-null-module/status-runner-error" "runner-error" "$(field_of status)"
    post_claim "post-claim-worker-throw" "s2544pc4" "$(tr_json)" "$THROW_PRELOAD" "worker error: "
    assert_eq "post-claim-worker-throw/status-runner-error" "runner-error" "$(field_of status)"
}
