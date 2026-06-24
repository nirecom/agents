#!/bin/bash
# tests/feature-1071-tier3-session-close-worker.sh
# Tests: agents/session-close-worker.md, skills/session-close/SKILL.md
# Tags: static, agent, worker, session-close, gate-action, scope:issue-specific
#
# Tier 3 static contract test for issue #1071 (skill/agent fork+worker audit).
# Verifies the new session-close-worker agent contract and the updated gate
# semantics in session-close SKILL.md (fail-closed, not fail-open).
# Expected RED until #1071 creates agents/session-close-worker.md and updates
# skills/session-close/SKILL.md to a fail-closed gate path.
#
# L3 gap (what this test does NOT catch):
# - actual gate_action decision by the worker LLM (requires real claude -p session)
# - runtime sentinel ordering from a real Stop event
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKER_MD="${AGENTS_DIR}/agents/session-close-worker.md"
SC_MD="${AGENTS_DIR}/skills/session-close/SKILL.md"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; FAIL=$((FAIL + 1)); }

# ── Test 1: worker file exists ────────────────────────────────────────────────
test_worker_exists() {
    if [ -f "$WORKER_MD" ]; then
        pass "1: agents/session-close-worker.md exists"
    else
        fail "1: agents/session-close-worker.md missing"
    fi
}

# ── Test 2: output contract has 3 lines (status/summary/artifact_path) ────────
test_output_contract() {
    if [ ! -f "$WORKER_MD" ]; then
        fail "2: worker missing — cannot check output contract"
        return
    fi
    local has_status has_summary has_artifact
    has_status=0; has_summary=0; has_artifact=0
    grep -qE '^status:' "$WORKER_MD" && has_status=1
    grep -qE '^summary:' "$WORKER_MD" && has_summary=1
    grep -qE '^artifact_path:' "$WORKER_MD" && has_artifact=1
    if [ "$has_status" -eq 1 ] && [ "$has_summary" -eq 1 ] && [ "$has_artifact" -eq 1 ]; then
        pass "2: worker output contract has status:/summary:/artifact_path:"
    else
        fail "2: worker output contract incomplete" "status=$has_status summary=$has_summary artifact_path=$has_artifact"
    fi
}

# ── Test 3: gate_action: yield documented ─────────────────────────────────────
test_gate_action_yield() {
    if [ ! -f "$WORKER_MD" ]; then
        fail "3: worker missing — cannot check gate_action"
        return
    fi
    if grep -qF 'gate_action: yield' "$WORKER_MD" || grep -qF 'gate_action:yield' "$WORKER_MD" || grep -qF '"yield"' "$WORKER_MD" || grep -qF 'yield' "$WORKER_MD"; then
        # More precise: must literally document the yield value
        if grep -qE 'gate_action.*yield|yield.*gate_action' "$WORKER_MD"; then
            pass "3: worker documents gate_action: yield"
        else
            fail "3: worker does not document gate_action: yield (found 'yield' but not in gate_action context)"
        fi
    else
        fail "3: worker missing gate_action: yield documentation"
    fi
}

# ── Test 4: gate_action: proceed documented ───────────────────────────────────
test_gate_action_proceed() {
    if [ ! -f "$WORKER_MD" ]; then
        fail "4: worker missing — cannot check gate_action"
        return
    fi
    if grep -qE 'gate_action.*proceed|proceed.*gate_action' "$WORKER_MD"; then
        pass "4: worker documents gate_action: proceed"
    else
        fail "4: worker missing gate_action: proceed documentation"
    fi
}

# ── Test 5: yield semantics — SC-6 does NOT run when yield ───────────────────
test_yield_stops_sc6() {
    if [ ! -f "$WORKER_MD" ]; then
        fail "5: worker missing — cannot check yield semantics"
        return
    fi
    # Worker must document that yield means stop / SC-6 does not run
    if grep -qE 'yield.*(stop|SC-6.*not|do not.*SC-6|halt)' "$WORKER_MD" || \
       grep -qE '(stop|SC-6.*not|do not.*SC-6|halt).*yield' "$WORKER_MD"; then
        pass "5: worker documents that yield = stop / SC-6 does not run"
    else
        fail "5: worker missing yield→stop semantics (SC-6 must not run on yield)"
    fi
}

# ── Test 6: no sentinels in worker ────────────────────────────────────────────
test_no_sentinels() {
    if [ ! -f "$WORKER_MD" ]; then
        fail "6: worker missing — cannot check sentinels"
        return
    fi
    if grep -qE '<<WORKFLOW_' "$WORKER_MD"; then
        fail "6: worker contains workflow sentinels (prohibited in worker context)"
    else
        pass "6: worker contains no workflow sentinels"
    fi
}

# ── Test 7: no AskUserQuestion in worker ──────────────────────────────────────
test_no_ask() {
    if [ ! -f "$WORKER_MD" ]; then
        fail "7: worker missing — cannot check AskUserQuestion"
        return
    fi
    if grep -qF 'AskUserQuestion' "$WORKER_MD"; then
        fail "7: worker contains AskUserQuestion (prohibited — user confirmation is main context's job)"
    else
        pass "7: worker contains no AskUserQuestion"
    fi
}

# ── Test 8: no skill invocations in worker ────────────────────────────────────
test_no_skill_invocations() {
    if [ ! -f "$WORKER_MD" ]; then
        fail "8: worker missing — cannot check skill invocations"
        return
    fi
    if grep -qE '`/[a-z]' "$WORKER_MD"; then
        fail "8: worker contains skill invocations (prohibited)"
    else
        pass "8: worker contains no skill invocations"
    fi
}

# ── Test 9: session-close SKILL.md emits sentinel on success path ─────────────
test_sc_skill_sentinel_on_success() {
    if [ ! -f "$SC_MD" ]; then
        fail "9: skills/session-close/SKILL.md missing"
        return
    fi
    if grep -qE '<<WORKFLOW_MARK_STEP_' "$SC_MD"; then
        pass "9: session-close SKILL.md emits WORKFLOW_MARK_STEP sentinel on success"
    else
        fail "9: session-close SKILL.md missing WORKFLOW_MARK_STEP sentinel"
    fi
}

# ── Test 10: session-close SKILL.md: yield → STOP after sentinel ─────────────
test_sc_skill_yield_stop() {
    if [ ! -f "$SC_MD" ]; then
        fail "10: skills/session-close/SKILL.md missing"
        return
    fi
    if grep -qE 'yield.*(stop|STOP|halt|do not.*SC-6|SC-6.*not)' "$SC_MD" || \
       grep -qE '(stop|STOP|halt).*yield' "$SC_MD"; then
        pass "10: session-close SKILL.md documents yield → STOP (SC-6 skipped)"
    else
        fail "10: session-close SKILL.md missing yield→STOP semantics"
    fi
}

# ── Test 11: session-close SKILL.md: proceed → SC-6 runs ─────────────────────
test_sc_skill_proceed_continues() {
    if [ ! -f "$SC_MD" ]; then
        fail "11: skills/session-close/SKILL.md missing"
        return
    fi
    if grep -qE 'proceed.*(SC-6|continue)|(SC-6|continue).*proceed' "$SC_MD"; then
        pass "11: session-close SKILL.md documents proceed → SC-6 continues"
    else
        fail "11: session-close SKILL.md missing proceed→SC-6 semantics"
    fi
}

# ── Test 12: session-close SKILL.md: worker failed → STOP (fail-closed) ──────
test_sc_skill_failed_stop() {
    if [ ! -f "$SC_MD" ]; then
        fail "12: skills/session-close/SKILL.md missing"
        return
    fi
    if grep -qE 'failed.*(stop|STOP|halt|abort)|(stop|STOP|halt|abort).*failed' "$SC_MD"; then
        pass "12: session-close SKILL.md documents worker failed → STOP (fail-closed)"
    else
        fail "12: session-close SKILL.md missing fail-closed (worker failed → STOP)"
    fi
}

# ── Test 13: session-close SKILL.md has NO fail-open path ────────────────────
test_sc_skill_no_fail_open() {
    if [ ! -f "$SC_MD" ]; then
        fail "13: skills/session-close/SKILL.md missing"
        return
    fi
    if grep -qiE 'fail.open|fail open' "$SC_MD"; then
        fail "13: session-close SKILL.md still has 'fail-open' text (must be fail-closed)"
    else
        pass "13: session-close SKILL.md has no 'fail-open' text (correctly fail-closed)"
    fi
}

test_worker_exists
test_output_contract
test_gate_action_yield
test_gate_action_proceed
test_yield_stops_sc6
test_no_sentinels
test_no_ask
test_no_skill_invocations
test_sc_skill_sentinel_on_success
test_sc_skill_yield_stop
test_sc_skill_proceed_continues
test_sc_skill_failed_stop
test_sc_skill_no_fail_open

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $FAIL
