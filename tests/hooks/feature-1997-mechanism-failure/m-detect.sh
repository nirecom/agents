# m-detect.sh — M1-M5: detectStalledSteps, the pure read that classifies WHAT
# went wrong with the workflow mechanism (#1997).
# Sourced by tests/feature-1997-mechanism-failure.sh.
# Tests: hooks/lib/mechanism-failure.js
# Tags: mechanism-failure, stall-detection, regression-1997, scope:issue-specific, pwsh-not-required, TL1

# ---------------------------------------------------------------------------
# M1: the healthy case. An in-flight step inside its TTL is work in progress,
#     not a stall — without this row a detector that flagged everything would
#     pass M2-M5 and drown the supervisor log in false reports.
# ---------------------------------------------------------------------------
run_M1() {
    local tmp tn
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    seed_in_flight "$tmp" "$tn" m1 research $((TTL_MS - 60000))
    assert_detect M1 "research in_progress at TTL-1min yields no findings" "<empty>" "$tn" m1
    rm -rf "$tmp" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# M2: the #1979 shape — a step that went in_progress and was never settled. Past
#     the TTL it is a stalled mechanism, and the finding must name both the step
#     and the kind so the supervisor entry is actionable.
# ---------------------------------------------------------------------------
run_M2() {
    local tmp tn
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    seed_in_flight "$tmp" "$tn" m2 write_tests $((TTL_MS + 60000))
    assert_detect M2 "write_tests in_progress at TTL+1min yields {write_tests, in-flight-expired}" \
        "write_tests:in-flight-expired" "$tn" m2
    rm -rf "$tmp" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# M3/M4: state-level failures. These have no step to blame, so they report under
#        the reserved `(state)` pseudo-step. Absent and corrupt are separate
#        kinds on purpose — "never initialized" and "written then damaged" call
#        for different human responses.
# ---------------------------------------------------------------------------
run_M3() {
    local tmp tn
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    assert_detect M3 "missing state file yields {(state), state-absent}" "(state):state-absent" "$tn" m3-absent
    rm -rf "$tmp" 2>/dev/null || true
}

run_M4() {
    local tmp tn
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    printf '{ this is not json' > "$tmp/m4.json"
    assert_detect M4 "corrupt state JSON yields {(state), state-corrupt}" "(state):state-corrupt" "$tn" m4
    rm -rf "$tmp" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# M5: an in_progress record with no usable timestamp. It can never expire on the
#     age axis, so a detector keyed purely on age would stay silent forever —
#     the exact silent-failure class #1997 exists to surface. Reported as its own
#     kind rather than folded into in-flight-expired: the remedy differs.
# ---------------------------------------------------------------------------
run_M5() {
    local tmp tn
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    seed_in_flight "$tmp" "$tn" m5 detail 60000
    P="$(node_path "$tmp/m5.json")" "$RWT" 15 node -e "
const fs = require('fs');
const s = JSON.parse(fs.readFileSync(process.env.P, 'utf8'));
for (const e of s.events || []) { if (e.step === 'detail') delete e.at; }
fs.writeFileSync(process.env.P, JSON.stringify(s));" >/dev/null 2>&1
    assert_detect M5 "in_progress with no updated_at yields {detail, invalid-timestamp}" \
        "detail:invalid-timestamp" "$tn" m5
    rm -rf "$tmp" 2>/dev/null || true
}
