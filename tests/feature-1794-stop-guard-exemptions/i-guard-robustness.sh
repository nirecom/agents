# i-guard-robustness.sh
# Tests: hooks/supervisor-guard.js, hooks/supervisor-guard/detect.js, hooks/stop-premature-stop-guard.js, hooks/workflow-state/lifecycle.js
# Tags: stop-hook, supervisor-guard, session-inherit, provenance, regression-1794, scope:issue-specific, pwsh-not-required, TL2
#
# I12 / I13 — the two robustness properties the #1794 adoption exemption must not
# cost us, both driven through the REAL spawned guards against a REAL inherited
# heir (the seed_donor_and_inherit fixture).
#
#   I12  scope: the exemption zeroes the C2 SCHEDULED-REVIEW arm only. A genuine
#        risk signal on the very same inherited-only session must still block.
#        I7 proves that for cumulative_severity=error; I12 is its symmetric
#        counterpart for the C1 sentinel hang, which reaches branch (3) of
#        supervisor-guard.js by a different route (transcript scan, not state).
#   I13  idempotency (skills/_shared/test-design.md): a guard is a classifier, so
#        re-running it against an unchanged state must keep returning the same
#        verdict in BOTH directions — no flapping, no accumulating side effect
#        that silently arms or disarms it on a later invocation.
#
# Sourced by tests/feature-1794-stop-guard-exemptions.sh.

# ---------------------------------------------------------------------------
# I12: inherited-only heir + a real C1 sentinel-hang transcript, and NO
#      supervisor state at all (so alert_armed_at cannot be the cause of a
#      block). Two positive anchors first — the heir really is inherited-only,
#      and detectSentinelHang really fires on the fixture transcript — then C2
#      must block with the C1 cause, not the C2 scheduled-review cause.
# ---------------------------------------------------------------------------
run_I12() {
    local tmp tp anchor hang problems=""
    tmp="$(make_tmp)"
    seed_donor_and_inherit "$tmp" "i12-donor" "i12-heir" "complete"
    anchor=$(inh_anchor "$tmp" "i12-heir")
    [ "$anchor" = "ANCHOR_OK" ] || problems="$problems [anchor:${anchor:-<err>}]"
    write_hang_transcript "$tmp/hang.jsonl"
    tp="$(node_path "$tmp/hang.jsonl")"
    hang=$(TP="$tp" "$RWT" 20 node -e "
const { detectSentinelHang } = require('$_AGENTS_DIR_NODE/hooks/supervisor-guard/detect.js');
process.stdout.write(String(detectSentinelHang(process.env.TP)));" 2>&1)
    [ "$hang" = "true" ] || problems="$problems [hang-fixture-not-detected:${hang:-<err>}]"
    inh_guard c2 "$tmp" "i12-heir" "$tp"
    rm -rf "$tmp" 2>/dev/null || true
    [ "$C2_RC" -eq 2 ] || problems="$problems [c2-rc=$C2_RC]"
    echo "$C2_OUT" | grep -q '"decision":"block"' || problems="$problems [c2-not-block:$C2_OUT]"
    echo "$C2_OUT" | grep -q 'sentinel hang' || problems="$problems [wrong-cause:$C2_OUT]"
    if [ -z "$problems" ]; then
        pass "I12: a real C1 sentinel hang still blocks C2 on an inherited-only heir"
    else
        fail "I12: C1 hang path over-suppressed by the adoption exemption;$problems"
    fi
}

# ---------------------------------------------------------------------------
# I13: idempotency of C4 in both directions against ONE unchanged fixture.
#      (a) inherited-only heir  -> three consecutive runs are all silent exit 0,
#          and no supervisor finding exists after any of them (the exemption is
#          not "first call wins"; nothing accumulates that would arm it later).
#      (b) the SAME heir after one genuine mark-step settlement -> three
#          consecutive runs all block with byte-identical stdout.
#      C4 is used for both directions on purpose: C2's alert retry counter
#      deliberately freezes the second consecutive block (ALERT_RETRY_THRESHOLD),
#      so C2 is not idempotent by design and asserting it would be wrong.
#      Recording a finding per block IS an intended C4 side effect, so (b)
#      asserts verdict stability, not the absence of writes.
# ---------------------------------------------------------------------------
run_I13() {
    local tmp anchor i out1 rc1 problems=""
    tmp="$(make_tmp)"
    seed_donor_and_inherit "$tmp" "i13-donor" "i13-heir" "complete"
    anchor=$(inh_anchor "$tmp" "i13-heir")
    [ "$anchor" = "ANCHOR_OK" ] || problems="$problems [anchor:${anchor:-<err>}]"

    # (a) silent direction, three times
    for i in 1 2 3; do
        inh_guard c4 "$tmp" "i13-heir"
        [ "$C4_RC" -eq 0 ] && [ -z "$C4_OUT" ] || problems="$problems [silent-run$i rc=$C4_RC out=$C4_OUT]"
        no_new_finding "$tmp/wf" "i13-heir" || problems="$problems [silent-run$i-recorded-a-finding]"
    done

    # (b) adopted direction, three times against the same fixture
    inh_node "$tmp" "require('$STATEIO_NODE').markStep('i13-heir', 'research', 'complete');"
    out1=""; rc1=""
    for i in 1 2 3; do
        inh_guard c4 "$tmp" "i13-heir"
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
