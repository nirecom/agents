#!/usr/bin/env bash
# tests/feature-supervisor-render-alert.sh
# Tests: bin/supervisor-render-alert, hooks/lib/supervisor-findings-render.js
# Tags: supervisor, em-supervisor, render-alert, cli, scope:issue-specific, pwsh-not-required, hook-registration
# L3 gap (what this test does NOT catch):
# - bin/supervisor-render-alert being invoked from a real supervisor subagent context / real Claude Code Stop chain
# - Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
#   via bin/check-verification-gate.sh category: hook-registration

# Covers bin/supervisor-render-alert (new CLI):
#  TA1 missing state file → fallback line, exit 0
#  TA2 notice-only findings → fallback line, exit 0
#  TA3 code/warning finding → formatted line, no /issue-create signal, exit 0
#  TA4 mixed severities → error/warning appear, notice absent, workflow finding gets /issue-create signal, exit 0
#  TA5 session-id as positional arg → same output as TA3
#  TA6 no session-id → exit 2, stderr contains "session-id required"
#  TA7 malformed JSON state file → fallback line, exit 0 (fail-open)
#  TA8 idempotency: invoke CLI twice, output identical, state file unchanged
#  TA9 security: shell-metachar payload in session-id does not execute
#
# Prompt-contract guards (agents/supervisor.md "Reporting back" section):
#  TS1 section does NOT contain "Provide first-aid guidance" (RED-EXPECTED now)
#  TS2 section mentions one-line ack contract (token: "one-line ack") (RED-EXPECTED now)
#  TS3 section mentions stop-l2-findings-display or Stop hook (RED-EXPECTED now)

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

CLI="$AGENTS_DIR/bin/supervisor-render-alert"
WRITER_NODE="$_AGENTS_DIR_NODE/hooks/lib/supervisor-state-writer.js"
SUPERVISOR_MD="$AGENTS_DIR/agents/supervisor.md"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t 'suprender'; }

node_dir() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi
}

if ! command -v node >/dev/null 2>&1; then
    skip "TA-all: node not available"
    echo ""
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 0
fi

FALLBACK_LINE="[EM Supervisor] Review complete — no actionable findings."

# Seed alert state via writeAlertState. Args: tmp_node sid findings_json
seed_state() {
    local tmp_node="$1" sid="$2" findings="$3"
    WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 5 node -e "
const w = require('$WRITER_NODE');
const patch = { findings: $findings, alert_phase: 'done' };
const ok = w.writeAlertState('$sid', patch);
if (!ok) { console.error('seed writeAlertState failed'); process.exit(3); }
" >/dev/null 2>&1
}

# ============================================================
# CLI test group (TA1..TA9)
# ============================================================
run_ta_cli_group() {
    if [ ! -f "$CLI" ]; then
        fail "TA-all [RED-EXPECTED]: bin/supervisor-render-alert not yet created (write-code pending)"
        return
    fi

    # TA1: no state file in tmp plans dir → fallback line, exit 0
    run_ta1_no_state() {
        local tmp tmp_node out
        tmp=$(make_tmp); tmp_node="$(node_dir "$tmp")"
        local sid="ta1-sid-$$"

        out=$(WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 10 bash "$CLI" --session-id "$sid" 2>/dev/null)
        local rc=$?
        rm -rf "$tmp"

        if [ $rc -ne 0 ]; then
            fail "TA1: missing state file → expected exit 0, got $rc"; return
        fi
        if [ "$out" != "$FALLBACK_LINE" ]; then
            fail "TA1: missing state file → expected fallback line, got: $(printf '%q' "${out:0:100}")"; return
        fi
        pass "TA1: missing state file → fallback line, exit 0"
    }

    # TA2: notice-only findings → fallback line, exit 0
    run_ta2_notice_only() {
        local tmp tmp_node out
        tmp=$(make_tmp); tmp_node="$(node_dir "$tmp")"
        local sid="ta2-sid-$$"

        seed_state "$tmp_node" "$sid" "[{\"categories\":[\"other\"],\"severity\":\"notice\",\"detail\":\"audit trail\",\"reporter\":\"test\"}]"

        out=$(WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 10 bash "$CLI" --session-id "$sid" 2>/dev/null)
        local rc=$?
        rm -rf "$tmp"

        if [ $rc -ne 0 ]; then
            fail "TA2: notice-only → expected exit 0, got $rc"; return
        fi
        if [ "$out" != "$FALLBACK_LINE" ]; then
            fail "TA2: notice-only → expected fallback line, got: $(printf '%q' "${out:0:100}")"; return
        fi
        pass "TA2: notice-only findings → fallback line, exit 0"
    }

    # TA3: code/warning finding → formatted line, no /issue-create signal, exit 0
    run_ta3_code_warning() {
        local tmp tmp_node out
        tmp=$(make_tmp); tmp_node="$(node_dir "$tmp")"
        local sid="ta3-sid-$$"

        seed_state "$tmp_node" "$sid" "[{\"categories\":[\"code\"],\"severity\":\"warning\",\"detail\":\"Fix missing check\",\"reporter\":\"supervisor\"}]"

        out=$(WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 10 bash "$CLI" --session-id "$sid" 2>/dev/null)
        local rc=$?
        rm -rf "$tmp"

        if [ $rc -ne 0 ]; then
            fail "TA3: exit code should be 0, got $rc"; return
        fi
        if ! echo "$out" | grep -q "^\[EM Supervisor\] warning (code): Fix missing check"; then
            fail "TA3: expected '[EM Supervisor] warning (code): Fix missing check' line, got: $(printf '%q' "${out:0:150}")"; return
        fi
        if echo "$out" | grep -q "/issue-create"; then
            fail "TA3: code category must NOT produce /issue-create signal, got: $(printf '%q' "${out:0:150}")"; return
        fi
        pass "TA3: code/warning finding → formatted line, no /issue-create signal, exit 0"
    }

    # TA4: mixed severities
    run_ta4_mixed() {
        local tmp tmp_node out
        tmp=$(make_tmp); tmp_node="$(node_dir "$tmp")"
        local sid="ta4-sid-$$"

        seed_state "$tmp_node" "$sid" "[{\"categories\":[\"code\"],\"severity\":\"error\",\"detail\":\"err-detail-x\",\"reporter\":\"t\"},{\"categories\":[\"workflow\"],\"severity\":\"warning\",\"detail\":\"warn-detail-y\",\"reporter\":\"t\"},{\"categories\":[\"other\"],\"severity\":\"notice\",\"detail\":\"NOTICE-SHOULD-NOT-APPEAR\",\"reporter\":\"t\"}]"

        out=$(WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 10 bash "$CLI" --session-id "$sid" 2>/dev/null)
        local rc=$?
        rm -rf "$tmp"

        if [ $rc -ne 0 ]; then
            fail "TA4: exit code should be 0, got $rc"; return
        fi
        if ! echo "$out" | grep -q "error (code)"; then
            fail "TA4: output must contain 'error (code)', got: $(printf '%q' "${out:0:200}")"; return
        fi
        if ! echo "$out" | grep -q "warning (workflow)"; then
            fail "TA4: output must contain 'warning (workflow)', got: $(printf '%q' "${out:0:200}")"; return
        fi
        if echo "$out" | grep -q "NOTICE-SHOULD-NOT-APPEAR"; then
            fail "TA4: notice finding must be filtered out, got: $(printf '%q' "${out:0:200}")"; return
        fi
        if ! echo "$out" | grep "warning (workflow)" | grep -q "/issue-create"; then
            fail "TA4: workflow finding must contain /issue-create signal, got: $(printf '%q' "${out:0:200}")"; return
        fi
        pass "TA4: mixed → error/warning present, notice absent, workflow has /issue-create, exit 0"
    }

    # TA5: session id as positional arg
    run_ta5_positional() {
        local tmp tmp_node out
        tmp=$(make_tmp); tmp_node="$(node_dir "$tmp")"
        local sid="ta5-sid-$$"

        seed_state "$tmp_node" "$sid" "[{\"categories\":[\"code\"],\"severity\":\"warning\",\"detail\":\"Fix missing check\",\"reporter\":\"supervisor\"}]"

        out=$(WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 10 bash "$CLI" "$sid" 2>/dev/null)
        local rc=$?
        rm -rf "$tmp"

        if [ $rc -ne 0 ]; then
            fail "TA5: positional arg → expected exit 0, got $rc"; return
        fi
        if ! echo "$out" | grep -q "^\[EM Supervisor\] warning (code): Fix missing check"; then
            fail "TA5: positional arg → expected same output as TA3, got: $(printf '%q' "${out:0:150}")"; return
        fi
        pass "TA5: session-id as positional arg → same output, exit 0"
    }

    # TA6: no session id → exit 2, stderr contains "session-id required"
    run_ta6_no_session_id() {
        local tmp tmp_node out_err
        tmp=$(make_tmp); tmp_node="$(node_dir "$tmp")"

        out_err=$(WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 10 bash "$CLI" 2>&1 >/dev/null)
        local rc=$?
        rm -rf "$tmp"

        if [ $rc -ne 2 ]; then
            fail "TA6: no session-id → expected exit 2, got $rc"; return
        fi
        if ! echo "$out_err" | grep -qi "session-id required"; then
            fail "TA6: stderr must contain 'session-id required', got: $(printf '%q' "${out_err:0:150}")"; return
        fi
        pass "TA6: no session-id → exit 2, stderr contains 'session-id required'"
    }

    # TA7: malformed JSON state file → fallback line, exit 0 (fail-open)
    run_ta7_malformed_json() {
        local tmp tmp_node out
        tmp=$(make_tmp); tmp_node="$(node_dir "$tmp")"
        local sid="ta7-sid-$$"

        # Write invalid JSON directly to state file location
        echo '{ not valid json' > "$tmp/${sid}-supervisor-state.json"

        out=$(WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 10 bash "$CLI" --session-id "$sid" 2>/dev/null)
        local rc=$?
        rm -rf "$tmp"

        if [ $rc -ne 0 ]; then
            fail "TA7: malformed JSON → expected exit 0 (fail-open), got $rc"; return
        fi
        if [ "$out" != "$FALLBACK_LINE" ]; then
            fail "TA7: malformed JSON → expected fallback line, got: $(printf '%q' "${out:0:100}")"; return
        fi
        pass "TA7: malformed JSON state file → fallback line, exit 0 (fail-open)"
    }

    # TA8: idempotency — invoke twice, output identical, state file unchanged
    run_ta8_idempotency() {
        local tmp tmp_node out1 out2 before after
        tmp=$(make_tmp); tmp_node="$(node_dir "$tmp")"
        local sid="ta8-sid-$$"

        seed_state "$tmp_node" "$sid" "[{\"categories\":[\"code\"],\"severity\":\"warning\",\"detail\":\"Fix missing check\",\"reporter\":\"supervisor\"}]"

        local state_file="$tmp/${sid}-supervisor-state.json"
        before=$(cat "$state_file" 2>/dev/null || echo "")

        out1=$(WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 10 bash "$CLI" --session-id "$sid" 2>/dev/null)
        out2=$(WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 10 bash "$CLI" --session-id "$sid" 2>/dev/null)
        after=$(cat "$state_file" 2>/dev/null || echo "")
        rm -rf "$tmp"

        if [ "$out1" != "$out2" ]; then
            fail "TA8: outputs differ across two invocations"; return
        fi
        if [ "$before" != "$after" ]; then
            fail "TA8: state file was mutated by CLI (read-only renderer must not mutate state)"; return
        fi
        pass "TA8: idempotency — identical output on second run, state file unchanged"
    }

    # TA9: security — shell-metachar session-id payload must not execute
    run_ta9_security() {
        local tmp tmp_node
        tmp=$(make_tmp); tmp_node="$(node_dir "$tmp")"
        # Payload: semicolon injection. If the CLI passes this unsanitized to shell, it would create INJECTED.
        local payload='x; touch INJECTED'
        local inject_target="$tmp/INJECTED"

        WORKFLOW_PLANS_DIR="$tmp_node" run_with_timeout 10 bash "$CLI" --session-id "$payload" >/dev/null 2>&1 || true
        local had_injection=0
        # Check both the tmp dir and cwd
        [ -f "$inject_target" ] && had_injection=1
        [ -f "INJECTED" ] && had_injection=1
        rm -f "INJECTED"
        rm -rf "$tmp"

        if [ "$had_injection" -eq 1 ]; then
            fail "TA9: shell metachar in session-id caused injection (file INJECTED was created)"; return
        fi
        pass "TA9: shell-metachar session-id payload did not cause injection"
    }

    run_ta1_no_state
    run_ta2_notice_only
    run_ta3_code_warning
    run_ta4_mixed
    run_ta5_positional
    run_ta6_no_session_id
    run_ta7_malformed_json
    run_ta8_idempotency
    run_ta9_security
}

run_ta_cli_group

# ============================================================
# Prompt-contract guards for agents/supervisor.md
# ============================================================
run_ts_prompt_guards() {
    if [ ! -f "$SUPERVISOR_MD" ]; then
        skip "TS-all: agents/supervisor.md not found"
        return
    fi

    # TS1 [RED-EXPECTED]: "Reporting back" section must NOT contain "Provide first-aid guidance"
    # (regression guard: the old prose must be replaced by a fixed one-line ack contract)
    if grep -q "Provide first-aid guidance" "$SUPERVISOR_MD"; then
        fail "TS1 [RED-EXPECTED]: agents/supervisor.md Reporting back section still contains 'Provide first-aid guidance' (write-code must remove this prose)"
    else
        pass "TS1: 'Provide first-aid guidance' absent from supervisor.md (write-code already landed or not present)"
    fi

    # TS2 [RED-EXPECTED]: section must include fixed one-line ack contract.
    # Token that write-code must include: "one-line ack"
    # (case-insensitive; write-code must include this exact phrase in the Reporting back section)
    if grep -qi "one-line ack" "$SUPERVISOR_MD"; then
        pass "TS2: supervisor.md contains 'one-line ack' return contract"
    else
        fail "TS2 [RED-EXPECTED]: supervisor.md does not contain 'one-line ack' (write-code must add fixed return value contract using this phrase)"
    fi

    # TS3 [RED-EXPECTED]: section must mention the Stop hook that surfaces the actionable summary.
    # Token: "stop-l2-findings-display" OR "Stop hook"
    if grep -q "stop-l2-findings-display\|Stop hook" "$SUPERVISOR_MD"; then
        pass "TS3: supervisor.md mentions the Stop hook (stop-l2-findings-display or Stop hook)"
    else
        fail "TS3 [RED-EXPECTED]: supervisor.md does not mention stop-l2-findings-display or Stop hook (write-code must document where the hard actionable-summary guarantee lives)"
    fi
}

run_ts_prompt_guards

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
