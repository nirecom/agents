# i-guard-robustness.sh
# Tests: hooks/supervisor-guard.js, hooks/supervisor-guard/detect.js, hooks/stop-premature-stop-guard.js, hooks/workflow-state/lifecycle.js
# Tags: stop-hook, supervisor-guard, session-inherit, provenance, regression-1794, scope:issue-specific, pwsh-not-required, TL2
# I12 / I13 — robustness of the #1794 adoption exemption, through the REAL spawned guards against a
# REAL inherited session-downstream (seed_upstream_and_inherit): I12 scope (only the C2 scheduled-review
# arm is zeroed; a C1 sentinel hang still blocks), I13 idempotency (skills/_shared/test-design.md).
# Sourced by tests/hooks/feature-1794-stop-guard-exemptions.sh.

# I12: inherited-only downstream + a real C1 sentinel-hang transcript and NO supervisor state; after two
# positive anchors (inherited-only, detectSentinelHang fires) C2 must block with the C1 cause.
run_I12() {
    local tmp tp anchor hang problems=""
    tmp="$(make_tmp)"
    seed_upstream_and_inherit "$tmp" "i12-upstream" "i12-downstream" "complete"
    anchor=$(inh_anchor "$tmp" "i12-downstream")
    [ "$anchor" = "ANCHOR_OK" ] || problems="$problems [anchor:${anchor:-<err>}]"
    write_hang_transcript "$tmp/hang.jsonl"
    tp="$(node_path "$tmp/hang.jsonl")"
    hang=$(TP="$tp" "$RWT" 20 node -e "
const { detectSentinelHang } = require('$_SCRIPT_CHECKOUT_ROOT_NODE/hooks/supervisor-guard/detect.js');
process.stdout.write(String(detectSentinelHang(process.env.TP)));" 2>&1)
    [ "$hang" = "true" ] || problems="$problems [hang-fixture-not-detected:${hang:-<err>}]"
    inh_guard c2 "$tmp" "i12-downstream" "$tp"
    rm -rf "$tmp" 2>/dev/null || true
    [ "$C2_RC" -eq 2 ] || problems="$problems [c2-rc=$C2_RC]"
    echo "$C2_OUT" | grep -q '"decision":"block"' || problems="$problems [c2-not-block:$C2_OUT]"
    echo "$C2_OUT" | grep -q 'sentinel hang' || problems="$problems [wrong-cause:$C2_OUT]"
    if [ -z "$problems" ]; then
        pass "I12: a real C1 sentinel hang still blocks C2 on an inherited-only downstream"
    else
        fail "I12: C1 hang path over-suppressed by the adoption exemption;$problems"
    fi
}

# I13: C4 idempotency both ways on ONE fixture — (a) inherited-only downstream: three silent exit-0 runs
# and no supervisor finding; (b) the same downstream after one real mark-step: three identical blocks.
# C4, not C2: C2's ALERT_RETRY_THRESHOLD freezes repeat blocks by design; (b) checks the verdict only.
run_I13() {
    local tmp anchor i out1 rc1 problems=""
    tmp="$(make_tmp)"
    seed_upstream_and_inherit "$tmp" "i13-upstream" "i13-downstream" "complete"
    anchor=$(inh_anchor "$tmp" "i13-downstream")
    [ "$anchor" = "ANCHOR_OK" ] || problems="$problems [anchor:${anchor:-<err>}]"

    # (a) silent direction, three times
    for i in 1 2 3; do
        inh_guard c4 "$tmp" "i13-downstream"
        [ "$C4_RC" -eq 0 ] && [ -z "$C4_OUT" ] || problems="$problems [silent-run$i rc=$C4_RC out=$C4_OUT]"
        no_new_finding "$tmp/wf" "i13-downstream" || problems="$problems [silent-run$i-recorded-a-finding]"
    done

    # (b) adopted direction, three times against the same fixture
    inh_node "$tmp" "require('$STATEIO_NODE').markStep('i13-downstream', 'research', 'complete');"
    out1=""; rc1=""
    for i in 1 2 3; do
        inh_guard c4 "$tmp" "i13-downstream"
        [ "$C4_RC" -eq 2 ] || problems="$problems [block-run$i-rc=$C4_RC]"
        echo "$C4_OUT" | grep -q '"decision":"block"' || problems="$problems [block-run$i-not-block:$C4_OUT]"
        if [ "$i" -eq 1 ]; then
            out1="$C4_OUT"; rc1="$C4_RC"
        else
            [ "$C4_OUT" = "$out1" ] && [ "$C4_RC" = "$rc1" ] || problems="$problems [block-run$i-differs-from-run1]"
        fi
    done
    rm -rf "$tmp" 2>/dev/null || true

    if [ -z "$problems" ]; then
        pass "I13: C4 is idempotent on an unchanged state in both directions (3x silent, then 3x identical block)"
    else
        fail "I13: guard verdict flapped or accumulated a side effect across repeated runs;$problems"
    fi
}
