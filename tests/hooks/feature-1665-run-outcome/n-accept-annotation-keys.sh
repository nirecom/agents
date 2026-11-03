# shellcheck shell=bash
# tests/hooks/feature-1665-run-outcome/n-accept-annotation-keys.sh
# Tests: hooks/workflow-state/state-io/events.js
# Tags: workflow, run-tests, unrunnable, escape-hatch, annotation, tombstone, TL1, scope:issue-specific
#
# TL1 — the two accept annotations (#2501 D5-7) are known keys in STEP_ANNOTATION_KEYS, and
# markStep -> readState round-trips their values and their null tombstone. EXPECTED RED until
# D5-7 adds both keys (the round-trip itself already holds for unknown keys).

# _n_probe <sid> — the table membership plus a set / read / tombstone / read round-trip.
_n_probe() {
    run_with_timeout 30 node -e '
const [agents, sid] = process.argv.slice(1);
const E = require(agents + "/hooks/workflow-state/state-io/events");
const S = require(agents + "/hooks/workflow-state");
const keys = ["unrunnable_runtimes", "unrunnable_accept_reason"];
const table = Array.from(E.STEP_ANNOTATION_KEYS || []);
const out = [];
for (const k of keys) out.push(k + ".known=" + table.includes(k));
S.markStep(sid, "write_tests", "complete");
S.markStep(sid, "run_tests", "complete", { unrunnable_runtimes: "Pester>=5.0,uv", unrunnable_accept_reason: "no Pester here" });
let e = S.readState(sid).steps.run_tests;
out.push("set=" + e.unrunnable_runtimes + "|" + e.unrunnable_accept_reason);
S.markStep(sid, "run_tests", "pending", { unrunnable_runtimes: null, unrunnable_accept_reason: null });
e = S.readState(sid).steps.run_tests;
const gone = (v) => (v === undefined || v === null ? "absent" : String(v));
out.push("tombstoned=" + gone(e.unrunnable_runtimes) + "|" + gone(e.unrunnable_accept_reason));
process.stdout.write(out.join(" "));
' "$AGENTS_WIN" "$1" 2>/dev/null || echo "ERR:probe-crashed"
}

run_n_accept_annotation_keys_cases() {
    echo ""
    echo "=== n-accept-annotation-keys (TL1: accept annotations are known keys and round-trip) ==="

    local got
    got="$(_n_probe "f1665-n1")"
    assert_contains "N1/unrunnable-runtimes-is-a-known-key" "unrunnable_runtimes.known=true" "$got"
    assert_contains "N1/unrunnable-accept-reason-is-a-known-key" "unrunnable_accept_reason.known=true" "$got"
    assert_contains "N2/values-round-trip" "set=Pester>=5.0,uv|no Pester here" "$got"
    assert_contains "N3/null-tombstones-both" "tombstoned=absent|absent" "$got"

    # #2688: the baseline user grant is retired, so baseline_accept leaves the table; the run's own
    # evidence keys (failing_test_exits, run_parts) and the completion note (baseline_note) join it.
    got="$(run_with_timeout 30 node -e '
const E = require(process.argv[1] + "/hooks/workflow-state/state-io/events");
const t = Array.from(E.STEP_ANNOTATION_KEYS || []);
process.stdout.write(["baseline_accept", "failing_test_exits", "run_parts", "baseline_note"].map((k) => k + ".known=" + t.includes(k)).join(" "));
' "$AGENTS_WIN" 2>/dev/null || echo "ERR:probe-crashed")"
    assert_contains "N4/baseline-accept-is-no-longer-a-known-key" "baseline_accept.known=false" "$got"
    assert_contains "N4/failing-test-exits-is-a-known-key" "failing_test_exits.known=true" "$got"
    assert_contains "N4/run-parts-is-a-known-key" "run_parts.known=true" "$got"
    assert_contains "N4/baseline-note-is-a-known-key" "baseline_note.known=true" "$got"
}
