# Part of tests/bin/feature-2544-worker-outcome-write.sh — sourced.
# Tests: hooks/lib/worker-dispatch-registry.js
# Tags: worker-dispatch, registry, write-scope, classifier, TL1, scope:issue-specific
# test-runner declares the control-outcome file scope and is the only worker whose
# dispatches record an outcome; every other name, real or not, answers false.

OUTCOME_SCOPE="control-outcome"

group_registry() {
    local out
    out="$(node - "$(np "$REGISTRY_JS")" "$OUTCOME_SCOPE" 2>&1 <<'JS'
const [lib, scope] = process.argv.slice(-2);
const reg = require(lib);
const say = (k, v) => console.log(k + "=" + v);
const names = Object.keys(reg.workers);
say("worker-count", names.length);
say("vocab", reg.WRITE_SCOPES.includes(scope) ? "has-scope" : "missing");
say("scope-export", reg.OUTCOME_SCOPE);
say("test-runner-scopes", JSON.stringify(reg.workers["test-runner"].writeScopes));
say("declarers", names.filter((n) => (reg.workers[n].writeScopes || []).includes(scope)).sort().join(","));
say("undeclared-scopes", names.flatMap((n) => (reg.workers[n].writeScopes || []).filter((s) => !reg.WRITE_SCOPES.includes(s)).map((s) => n + ":" + s)).join(","));
say("exported", typeof reg.recordsOutcome);
if (typeof reg.recordsOutcome !== "function") process.exit(0);
const verdict = (n) => { try { return String(reg.recordsOutcome(n)); } catch (e) { return "threw"; } };
say("true-for", names.filter((n) => reg.recordsOutcome(n) === true).sort().join(","));
say("false-for-count", names.filter((n) => reg.recordsOutcome(n) === false).length);
say("unknown-worker", verdict("no-such-worker"));
say("proto-name", verdict("__proto__"));
say("non-string", verdict(undefined));
JS
)"
    assert_eq "registry/vocabulary-has-the-outcome-scope" "has-scope" "$(kv "$out" vocab)"
    assert_eq "registry/OUTCOME_SCOPE-exported" "$OUTCOME_SCOPE" "$(kv "$out" scope-export)"
    assert_eq "registry/test-runner-declares-only-the-outcome-scope" "[\"$OUTCOME_SCOPE\"]" "$(kv "$out" test-runner-scopes)"
    assert_eq "registry/only-test-runner-declares-it" "test-runner" "$(kv "$out" declarers)"
    assert_eq "registry/every-declared-scope-is-in-the-vocabulary" "" "$(kv "$out" undeclared-scopes)"
    assert_eq "registry/recordsOutcome-exported" "function" "$(kv "$out" exported)"
    assert_eq "registry/recordsOutcome-true-only-for-test-runner" "test-runner" "$(kv "$out" true-for)"
    assert_eq "registry/recordsOutcome-false-for-every-other-worker" "$(( $(kv "$out" worker-count) - 1 ))" "$(kv "$out" false-for-count)"
    assert_eq "registry/recordsOutcome-false-for-unknown-worker" "false" "$(kv "$out" unknown-worker)"
    assert_eq "registry/recordsOutcome-false-for-proto-name" "false" "$(kv "$out" proto-name)"
    assert_eq "registry/recordsOutcome-false-for-non-string" "false" "$(kv "$out" non-string)"
}
