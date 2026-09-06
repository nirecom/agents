# tests/feature-2169-workflow-not-started-notify-gate/p-basic.sh
# Tests: hooks/user-prompt-submit-mechanism-check.js, hooks/workflow-state/lifecycle.js, hooks/postuse-step-in-flight-mark.js
# Tags: stall-detection, user-prompt-submit, prompt-notify, pre-workflow-init, wi-10-lookahead, regression-2169, scope:issue-specific, pwsh-not-required, TL1, TL2
# P1-P3 — the core pre-workflow-init suppression contract: a bare WI-10
# dispatch with no /workflow-init suppresses (P1), suppression is idempotent
# across repeated prompts (P1b), a genuinely-started session is unaffected
# (P2), and the ledger-ordering guarantee behind the gate placement holds (P3).
# Sourced by the top-level tests/feature-2169-workflow-not-started-notify-gate.sh
# dispatcher; depends on helpers.sh being sourced first.

run_P1() {
    local tmp tn problems=""
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    dispatch_skill "$tn" p1
    [ -f "$tmp/p1.json" ] || problems="$problems [dispatch did not create a state file — fixture setup failed]"

    rstatus="$(research_status "$tn" p1)"
    [ "$rstatus" = "in_progress" ] ||
        problems="$problems [research status after dispatch is '${rstatus:-<err>}', expected in_progress — fixture setup failed]"

    out=$(CLAUDE_WORKFLOW_DIR="$tn" WORKFLOW_PLANS_DIR="$tn" "$RWT" 20 node -e "
process.stdout.write(String(require('$LIFECYCLE_NODE').isWorkflowStarted('p1')));" 2>/dev/null)
    [ "$out" = "false" ] || problems="$problems [isWorkflowStarted=${out:-<err>}, expected false after a bare WI-10 dispatch]"

    backdate_research "$tmp" p1 $((TTL_MS + 60000))

    kinds="$(stalled_kinds_for "$tn" p1)"
    case "$kinds" in
        *"research:in-flight-expired"*) : ;;
        *) problems="$problems [detectStalledSteps does not report research:in-flight-expired after backdating; got '${kinds:-<empty>}' — TTL math or fixture is wrong]" ;;
    esac

    run_ups "$tn" p1
    [ "$UPS_RC" -eq 0 ] || problems="$problems [hook exited $UPS_RC]"
    compact="$(printf '%s' "$UPS_OUT" | tr -d ' \n\r')"
    case "$compact" in
        ""|"{}") : ;;
        *) problems="$problems [expected an empty {} payload, got '$UPS_OUT']" ;;
    esac
    strays="$(ls "$tmp" 2>/dev/null | grep 'stall-reported' | tr '\n' ' ')"
    [ -z "$strays" ] ||
        problems="$problems [a stall-reported ledger was written while the session was pre-adoption: $strays]"
    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "P1: a Skill dispatch with no /workflow-init leaves research in_progress past the TTL WITHOUT a prompt-time notification or ledger write"
    else
        fail "P1: the pre-workflow-init notify gate is broken;$problems"
    fi
}

# P1b (round-2 — review C2): idempotency. P1 above submits only ONE prompt
# before adoption; an implementation that suppresses only the FIRST
# pre-adoption prompt (not every one) would still pass P1. Repeats run_ups
# against the SAME expired pre-adoption state and asserts every call is
# suppressed, not just the first.
run_P1b() {
    local tmp tn problems="" i compact
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    dispatch_skill "$tn" p1b
    backdate_research "$tmp" p1b $((TTL_MS + 60000))

    for i in 1 2 3; do
        run_ups "$tn" p1b
        [ "$UPS_RC" -eq 0 ] || problems="$problems [call $i: hook exited $UPS_RC]"
        compact="$(printf '%s' "$UPS_OUT" | tr -d ' \n\r')"
        case "$compact" in
            ""|"{}") : ;;
            *) problems="$problems [call $i: expected an empty {} payload, got '$UPS_OUT']" ;;
        esac
        [ ! -f "$tmp/p1b.stall-reported" ] ||
            problems="$problems [call $i: a stall-reported ledger was written during the pre-adoption window]"
    done

    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "P1b: repeated prompts (3x) against the SAME expired pre-adoption state are ALL suppressed, not just the first, with no ledger write on any call"
    else
        fail "P1b: the pre-workflow-init notify gate is not idempotent across repeated prompts;$problems"
    fi
}

run_P2() {
    local tmp tn problems=""
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    dispatch_skill "$tn" p2

    rstatus="$(research_status "$tn" p2)"
    [ "$rstatus" = "in_progress" ] ||
        problems="$problems [research status after dispatch is '${rstatus:-<err>}', expected in_progress — fixture setup failed]"

    complete_workflow_init "$tn" p2
    out=$(CLAUDE_WORKFLOW_DIR="$tn" WORKFLOW_PLANS_DIR="$tn" "$RWT" 20 node -e "
process.stdout.write(String(require('$LIFECYCLE_NODE').isWorkflowStarted('p2')));" 2>/dev/null)
    [ "$out" = "true" ] || problems="$problems [isWorkflowStarted=${out:-<err>}, expected true once workflow_init genuinely completed]"

    backdate_research "$tmp" p2 $((TTL_MS + 60000))

    kinds="$(stalled_kinds_for "$tn" p2)"
    case "$kinds" in
        *"research:in-flight-expired"*) : ;;
        *) problems="$problems [detectStalledSteps does not report research:in-flight-expired after backdating; got '${kinds:-<empty>}' — TTL math or fixture is wrong]" ;;
    esac

    run_ups "$tn" p2
    [ "$UPS_RC" -eq 0 ] || problems="$problems [hook exited $UPS_RC]"
    compact="$(printf '%s' "$UPS_OUT" | tr -d ' \n\r')"
    case "$compact" in
        *'"blocks":true'*) : ;;
        *) problems="$problems [expected blocks:true (same as R3 pre-#2169), got '${UPS_OUT:-<empty>}']" ;;
    esac
    case "$compact" in
        *research*) : ;;
        *) problems="$problems [the stalled step is not named in the output]" ;;
    esac
    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "P2: a genuine WI-10 dispatch, once workflow_init actually completes, still surfaces the TTL-expired research stall (unchanged by the #2169 gate)"
    else
        fail "P2: the #2169 gate over-suppressed a genuinely-started session;$problems"
    fi
}

run_P3() {
    local tmp tn problems="" adopt_at ledger_info entry_count reported_at
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    dispatch_skill "$tn" p3
    backdate_research "$tmp" p3 $((TTL_MS + 60000))

    run_ups "$tn" p3   # pre-adoption: must not report (same as P1)
    [ ! -f "$tmp/p3.stall-reported" ] ||
        problems="$problems [reportMechanismFailureOnce fired during the pre-adoption window: ledger exists before adoption]"

    adopt_at=$(node -e "process.stdout.write(new Date().toISOString())")
    complete_workflow_init "$tn" p3   # NOW genuinely adopt
    run_ups "$tn" p3
    compact="$(printf '%s' "$UPS_OUT" | tr -d ' \n\r')"
    case "$compact" in
        *'"blocks":true'*) : ;;
        *) problems="$problems [post-adoption prompt did not notify: '${UPS_OUT:-<empty>}']" ;;
    esac

    ledger_info=$(node -e "
const fs = require('fs');
try {
  const raw = fs.readFileSync(process.argv[1], 'utf8');
  const ledger = JSON.parse(raw);
  const findings = Array.isArray(ledger.findings) ? ledger.findings : [];
  process.stdout.write(String(findings.length) + '|' + (findings[0] && findings[0].reported_at ? findings[0].reported_at : ''));
} catch (e) { process.stdout.write('ERR:' + e.message); }" "$(node_path "$tmp/p3.stall-reported")" 2>/dev/null)
    entry_count="${ledger_info%%|*}"
    reported_at="${ledger_info#*|}"
    if [ "$entry_count" != "1" ]; then
        problems="$problems [ledger findings count is not exactly 1 after the first post-adoption prompt: '$ledger_info']"
    elif [ -z "$reported_at" ]; then
        problems="$problems [ledger entry has no reported_at: '$ledger_info']"
    else
        cmp=$(node -e "
process.stdout.write(Date.parse(process.argv[1]) >= Date.parse(process.argv[2]) ? 'OK' : 'BAD');" "$reported_at" "$adopt_at")
        [ "$cmp" = "OK" ] ||
            problems="$problems [ledger reported_at ($reported_at) is BEFORE the adoption event ($adopt_at) — the report happened during the exempt window]"
    fi

    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "P3: reportMechanismFailureOnce is called 0 times during the pre-adoption window and exactly once on the first post-adoption prompt, with the ledger's reported_at at-or-after the adoption event"
    else
        fail "P3: the ledger-ordering guarantee behind the gate placement is broken;$problems"
    fi
}
