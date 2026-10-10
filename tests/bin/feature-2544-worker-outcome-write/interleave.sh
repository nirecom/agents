# Part of tests/bin/feature-2544-worker-outcome-write.sh — sourced.
# Tests: hooks/workflow-state/dispatch-settlement.js
# Tags: worker-dispatch, outcome, sequence, interleaving, TL2, scope:issue-specific
# Two dispatches in one session: each writes its own outcome bound to its own payload
# bytes, neither touches the other's, and the settlement reader names the later one.

# latest_of <sid> — latestDispatch for test-runner as "<stem>/<seq>", or none / load-error.
latest_of() {
    node - "$(np "$SETTLE_JS")" "$1" 2>&1 <<'JS'
const [lib, sid] = process.argv.slice(-2);
let m = null;
try { m = require(lib); } catch (e) { console.log("load-error"); process.exit(0); }
const r = m.latestDispatch({ sessionId: sid, worker: "test-runner" });
console.log(r ? r.stem + "/" + r.seq : "none");
JS
}

group_interleave_two_dispatches() {
    local sid="s2544two" a="worker-test-runner-9" b="worker-test-runner-10" pa pb first fa fb
    pa="$(seed_payload "$sid" "$a" "$(tr_json "$MAIN" "tests/bin/nine.sh")")"
    pb="$(seed_payload "$sid" "$b" "$(tr_json "$MAIN" "tests/bin/ten.sh")")"
    set_canned "$FAIL_CANNED"
    dispatch test-runner "$pa"
    first="$(sha_of "$WF_RAW/$sid.control/$a.outcome.json")"
    assert_eq "two/latest-after-the-first" "$a/9" "$(latest_of "$sid")"
    set_canned "$PASS_CANNED"
    dispatch test-runner "$pb"
    assert_eq "two/both-outcomes-present" "$b.outcome.json $a.outcome.json " "$(outcomes_in "$sid")"
    assert_eq "two/the-first-outcome-is-untouched" "$first" "$(sha_of "$WF_RAW/$sid.control/$a.outcome.json")"
    fa="$(outcome_fields "$sid" "$a")"; fb="$(outcome_fields "$sid" "$b")"
    assert_eq "two/first-digest-is-its-own-payload" "$(sha_of "$WF_RAW/$sid.control/$a.json")" "$(kv "$fa" payload_sha256)"
    assert_eq "two/second-digest-is-its-own-payload" "$(sha_of "$WF_RAW/$sid.control/$b.json")" "$(kv "$fb" payload_sha256)"
    assert_eq "two/statuses-are-their-own" "fail:pass" "$(kv "$fa" status):$(kv "$fb" status)"
    assert_eq "two/latest-is-numeric-not-lexical" "$b/10" "$(latest_of "$sid")"
}
