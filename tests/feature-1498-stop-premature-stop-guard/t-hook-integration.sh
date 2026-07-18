# t-hook-integration.sh — T1-T11 integration tests for stop-premature-stop-guard.js
# Sourced by tests/feature-1498-stop-premature-stop-guard.sh

# ---------------------------------------------------------------------------
# T1: workflow active (ACTION=invoke) → decision:block in stdout
# ---------------------------------------------------------------------------
run_t1() {
    require_source "$HOOK" "T1: workflow active + ACTION=invoke -> decision:block" || return
    local tmp sid
    tmp="$(mktemp -d)"
    sid="t1-sid"
    seed_workflow_state "$tmp" "$sid" "invoke"
    local out rc
    out=$(echo "{\"stop_hook_active\":false,\"session_id\":\"$sid\",\"transcript_path\":\"\"}" \
        | CLAUDE_WORKFLOW_DIR="$tmp/workflow" WORKFLOW_PLANS_DIR="$tmp/plans" \
          run_with_timeout 15 node "$HOOK_NODE" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if echo "$out" | grep -q '"decision"' && echo "$out" | grep -q '"block"'; then
        pass "T1: workflow active + ACTION=invoke -> decision:block"
    else
        fail "T1: expected decision:block (rc=$rc, out=$out)"
    fi
}

# ---------------------------------------------------------------------------
# T2: non-workflow session (no workflow state file) → exit 0 pass-through
# ---------------------------------------------------------------------------
run_t2() {
    require_source "$HOOK" "T2: non-workflow session -> exit 0 pass-through" || return
    local tmp sid out rc
    tmp="$(mktemp -d)"
    sid="t2-sid-no-workflow"
    # No workflow state file seeded
    out=$(echo "{\"stop_hook_active\":false,\"session_id\":\"$sid\",\"transcript_path\":\"\"}" \
        | CLAUDE_WORKFLOW_DIR="$tmp/workflow" WORKFLOW_PLANS_DIR="$tmp/plans" \
          run_with_timeout 15 node "$HOOK_NODE" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ]; then
        pass "T2: non-workflow session -> exit 0 pass-through"
    else
        fail "T2: expected exit 0 (rc=$rc, out=$out)"
    fi
}

# ---------------------------------------------------------------------------
# T3: stop_hook_active=true → exit 0 (loop prevention)
# ---------------------------------------------------------------------------
run_t3() {
    require_source "$HOOK" "T3: stop_hook_active=true -> exit 0" || return
    local tmp sid out rc
    tmp="$(mktemp -d)"
    sid="t3-sid"
    seed_workflow_state "$tmp" "$sid" "invoke"
    out=$(echo "{\"stop_hook_active\":true,\"session_id\":\"$sid\",\"transcript_path\":\"\"}" \
        | CLAUDE_WORKFLOW_DIR="$tmp/workflow" WORKFLOW_PLANS_DIR="$tmp/plans" \
          run_with_timeout 15 node "$HOOK_NODE" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ]; then
        pass "T3: stop_hook_active=true -> exit 0"
    else
        fail "T3: expected exit 0 (rc=$rc, out=$out)"
    fi
}

# ---------------------------------------------------------------------------
# T4: ACTION=done → exit 0 pass-through
# ---------------------------------------------------------------------------
run_t4() {
    require_source "$HOOK" "T4: ACTION=done -> exit 0 pass-through" || return
    local tmp sid out rc
    tmp="$(mktemp -d)"
    sid="t4-sid"
    # Seed workflow state where next-step would return ACTION=done (all done)
    seed_workflow_state_done "$tmp" "$sid"
    out=$(echo "{\"stop_hook_active\":false,\"session_id\":\"$sid\",\"transcript_path\":\"\"}" \
        | CLAUDE_WORKFLOW_DIR="$tmp/workflow" WORKFLOW_PLANS_DIR="$tmp/plans" \
          run_with_timeout 15 node "$HOOK_NODE" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && ! echo "$out" | grep -q '"decision"'; then
        pass "T4: ACTION=done -> exit 0 pass-through"
    else
        fail "T4: expected exit 0 no decision (rc=$rc, out=$out)"
    fi
}

# ---------------------------------------------------------------------------
# T5: ACTION=blocked → exit 0 pass-through
# Uses closes_issues=[] + clarify_intent=pending: next-step returns ACTION=blocked.
# ---------------------------------------------------------------------------
run_t5() {
    require_source "$HOOK" "T5: ACTION=blocked -> exit 0 pass-through" || return
    local tmp sid out rc
    tmp="$(mktemp -d)"
    sid="t5-sid"
    seed_workflow_state_blocked "$tmp" "$sid"
    out=$(echo "{\"stop_hook_active\":false,\"session_id\":\"$sid\",\"transcript_path\":\"\"}" \
        | CLAUDE_WORKFLOW_DIR="$tmp/workflow" WORKFLOW_PLANS_DIR="$tmp/plans" \
          run_with_timeout 15 node "$HOOK_NODE" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && ! echo "$out" | grep -q '"block"'; then
        pass "T5: ACTION=blocked -> exit 0 no block"
    else
        fail "T5: expected exit 0 no block for ACTION=blocked (rc=$rc, out=$out)"
    fi
}

# ---------------------------------------------------------------------------
# T6: isWorkflowOff=true → exit 0 pass-through (no block even when ACTION=invoke)
# session-markers.js reads <CLAUDE_WORKFLOW_DIR>/<sid>.workflow-off (not a separate marker dir)
# ---------------------------------------------------------------------------
run_t6() {
    require_source "$HOOK" "T6: isWorkflowOff=true -> exit 0 pass-through" || return
    local tmp sid out rc wf_dir
    tmp="$(mktemp -d)"
    sid="t6-sid"
    wf_dir="$tmp/workflow"
    mkdir -p "$wf_dir"
    # session-markers.js checks <getWorkflowDir()>/<sid>.workflow-off
    # CLAUDE_WORKFLOW_DIR is used by getWorkflowDir(), so the marker goes there.
    touch "$wf_dir/${sid}.workflow-off"
    seed_workflow_state "$tmp" "$sid" "invoke"
    out=$(echo "{\"stop_hook_active\":false,\"session_id\":\"$sid\",\"transcript_path\":\"\"}" \
        | CLAUDE_WORKFLOW_DIR="$wf_dir" WORKFLOW_PLANS_DIR="$tmp/plans" \
          run_with_timeout 15 node "$HOOK_NODE" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && ! echo "$out" | grep -q '"block"'; then
        pass "T6: isWorkflowOff=true -> exit 0 no block"
    else
        fail "T6: expected exit 0 no block when workflow-off marker present (rc=$rc, out=$out)"
    fi
}

# ---------------------------------------------------------------------------
# T7: next-step timeout/error → exit 0 (fail-open)
# ---------------------------------------------------------------------------
run_t7() {
    require_source "$HOOK" "T7: next-step timeout/error -> exit 0 fail-open" || return
    local tmp sid out rc
    tmp="$(mktemp -d)"
    sid="t7-sid"
    # Point CLAUDE_WORKFLOW_DIR at a non-existent path so state read fails → fail-open
    out=$(echo "{\"stop_hook_active\":false,\"session_id\":\"$sid\",\"transcript_path\":\"\"}" \
        | CLAUDE_WORKFLOW_DIR="$tmp/nonexistent-wf" WORKFLOW_PLANS_DIR="$tmp/plans" \
          run_with_timeout 15 node "$HOOK_NODE" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ]; then
        pass "T7: next-step error -> exit 0 fail-open"
    else
        fail "T7: expected exit 0 fail-open on error (rc=$rc, out=$out)"
    fi
}

# ---------------------------------------------------------------------------
# T8: dual-ID (input.session_id != WORKFLOW_SESSION_ID) + ACTION=invoke
#     → uses CC session ID for next-step (C1 regression)
# ---------------------------------------------------------------------------
run_t8() {
    require_source "$HOOK" "T8: dual-ID + ACTION=invoke -> CC session ID for next-step" || return
    local tmp cc_sid ws_sid out rc
    tmp="$(mktemp -d)"
    cc_sid="t8-cc-sid"
    ws_sid="t8-ws-sid"
    # Seed workflow state under CC session ID (what the hook should use for next-step)
    seed_workflow_state "$tmp" "$cc_sid" "invoke"
    out=$(echo "{\"stop_hook_active\":false,\"session_id\":\"$cc_sid\",\"transcript_path\":\"\"}" \
        | CLAUDE_WORKFLOW_DIR="$tmp/workflow" WORKFLOW_PLANS_DIR="$tmp/plans" \
          WORKFLOW_SESSION_ID="$ws_sid" \
          run_with_timeout 15 node "$HOOK_NODE" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if echo "$out" | grep -q '"decision"' && echo "$out" | grep -q '"block"'; then
        pass "T8: dual-ID + ACTION=invoke -> decision:block (CC next-step used)"
    else
        fail "T8: expected decision:block with CC next-step (rc=$rc, out=$out)"
    fi
}

# ---------------------------------------------------------------------------
# T9: dual-ID + CC state armed → CC ID for appendFinding (C2 CC-UUID path)
# ---------------------------------------------------------------------------
run_t9() {
    require_source "$HOOK" "T9: dual-ID + CC state armed -> CC ID for appendFinding" || return
    local tmp cc_sid ws_sid out rc
    tmp="$(mktemp -d)"
    cc_sid="t9-cc-sid"
    ws_sid="t9-ws-sid"
    seed_workflow_state "$tmp" "$cc_sid" "invoke"
    seed_supervisor_state "$tmp" "$cc_sid" "2026-07-17T00:00:00.000Z"
    out=$(echo "{\"stop_hook_active\":false,\"session_id\":\"$cc_sid\",\"transcript_path\":\"\"}" \
        | CLAUDE_WORKFLOW_DIR="$tmp/workflow" WORKFLOW_PLANS_DIR="$tmp/plans" \
          WORKFLOW_SESSION_ID="$ws_sid" \
          run_with_timeout 15 node "$HOOK_NODE" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    # Hook must block: workflow active (ACTION=invoke), CC state is armed.
    if echo "$out" | grep -q '"block"'; then
        pass "T9: dual-ID + CC state armed -> decision:block"
    else
        fail "T9: expected decision:block (rc=$rc, out=$out)"
    fi
}

# ---------------------------------------------------------------------------
# T10: dual-ID + CC state unarmed + wsid env set → still uses CC SID for
#      appendFinding; hook blocks whenever ACTION=invoke regardless of wsid
# ---------------------------------------------------------------------------
run_t10() {
    require_source "$HOOK" "T10: dual-ID + CC unarmed + wsid env set -> decision:block" || return
    local tmp cc_sid ws_sid out rc
    tmp="$(mktemp -d)"
    cc_sid="t10-cc-sid"
    ws_sid="t10-ws-sid"
    seed_workflow_state "$tmp" "$cc_sid" "invoke"
    # CC state unarmed (empty), wsid env present — hook must still block on ACTION=invoke
    seed_supervisor_state "$tmp" "$cc_sid" ""
    out=$(echo "{\"stop_hook_active\":false,\"session_id\":\"$cc_sid\",\"transcript_path\":\"\"}" \
        | CLAUDE_WORKFLOW_DIR="$tmp/workflow" WORKFLOW_PLANS_DIR="$tmp/plans" \
          WORKFLOW_SESSION_ID="$ws_sid" \
          run_with_timeout 15 node "$HOOK_NODE" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if echo "$out" | grep -q '"block"'; then
        pass "T10: dual-ID + CC unarmed + wsid env -> decision:block (CC SID used)"
    else
        fail "T10: expected decision:block (rc=$rc, out=$out)"
    fi
}

# ---------------------------------------------------------------------------
# T11: pre-init state (all steps pending, ACTION=invoke for workflow_init)
#      → decision:block (hook blocks pre-init sessions too, not only mid-workflow)
# ---------------------------------------------------------------------------
run_t11() {
    require_source "$HOOK" "T11: pre-init state + ACTION=invoke -> decision:block" || return
    local tmp sid out rc
    tmp="$(mktemp -d)"
    sid="t11-sid"
    seed_workflow_state_no_init "$tmp" "$sid"
    out=$(echo "{\"stop_hook_active\":false,\"session_id\":\"$sid\",\"transcript_path\":\"\"}" \
        | CLAUDE_WORKFLOW_DIR="$tmp/workflow" WORKFLOW_PLANS_DIR="$tmp/plans" \
          run_with_timeout 15 node "$HOOK_NODE" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if echo "$out" | grep -q '"block"'; then
        pass "T11: pre-init state + ACTION=invoke -> decision:block"
    else
        fail "T11: expected decision:block for pre-init invoke (rc=$rc, out=$out)"
    fi
}

# ---------------------------------------------------------------------------
# T12: empty stdin → exit 0 (fail-open on missing input)
# ---------------------------------------------------------------------------
run_t12() {
    require_source "$HOOK" "T12: empty stdin -> exit 0 fail-open" || return
    local out rc
    out=$(echo -n "" | run_with_timeout 15 node "$HOOK_NODE" 2>/dev/null)
    rc=$?
    if [ $rc -eq 0 ]; then
        pass "T12: empty stdin -> exit 0 fail-open"
    else
        fail "T12: expected exit 0 on empty stdin (rc=$rc, out=$out)"
    fi
}

# ---------------------------------------------------------------------------
# T13: malformed (non-JSON) input → exit 0 (fail-open on parse error)
# ---------------------------------------------------------------------------
run_t13() {
    require_source "$HOOK" "T13: malformed JSON -> exit 0 fail-open" || return
    local out rc
    out=$(echo "not-valid-json" | run_with_timeout 15 node "$HOOK_NODE" 2>/dev/null)
    rc=$?
    if [ $rc -eq 0 ]; then
        pass "T13: malformed JSON -> exit 0 fail-open"
    else
        fail "T13: expected exit 0 on malformed JSON (rc=$rc, out=$out)"
    fi
}

# ---------------------------------------------------------------------------
# T14: session_id fails SESSION_ID_RE (contains spaces) → exit 0 pass-through
# ---------------------------------------------------------------------------
run_t14() {
    require_source "$HOOK" "T14: invalid session_id (spaces) -> exit 0 pass-through" || return
    local tmp out rc
    tmp="$(mktemp -d)"
    out=$(echo "{\"stop_hook_active\":false,\"session_id\":\"sid with spaces\",\"transcript_path\":\"\"}" \
        | CLAUDE_WORKFLOW_DIR="$tmp/workflow" WORKFLOW_PLANS_DIR="$tmp/plans" \
          run_with_timeout 15 node "$HOOK_NODE" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && ! echo "$out" | grep -q '"block"'; then
        pass "T14: invalid session_id -> exit 0 pass-through"
    else
        fail "T14: expected exit 0 for invalid session_id (rc=$rc, out=$out)"
    fi
}

# ---------------------------------------------------------------------------
# T15: next-step binary absent (AGENTS_CONFIG_DIR points to empty dir,
#      but workflow state IS present) → exit 0 fail-open
# ---------------------------------------------------------------------------
run_t15() {
    require_source "$HOOK" "T15: next-step binary absent -> exit 0 fail-open" || return
    local tmp sid out rc fake_agents
    tmp="$(mktemp -d)"
    sid="t15-sid"
    fake_agents="$tmp/fake-agents"
    mkdir -p "$fake_agents"
    seed_workflow_state "$tmp" "$sid" "invoke"
    out=$(echo "{\"stop_hook_active\":false,\"session_id\":\"$sid\",\"transcript_path\":\"\"}" \
        | CLAUDE_WORKFLOW_DIR="$tmp/workflow" WORKFLOW_PLANS_DIR="$tmp/plans" \
          AGENTS_CONFIG_DIR="$fake_agents" \
          run_with_timeout 15 node "$HOOK_NODE" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && ! echo "$out" | grep -q '"block"'; then
        pass "T15: next-step binary absent -> exit 0 fail-open"
    else
        fail "T15: expected exit 0 when next-step missing (rc=$rc, out=$out)"
    fi
}

# ---------------------------------------------------------------------------
# T16: ACTION=invoke → reason string contains NEXT_SKILL value
# Verifies that the skill name is propagated into the block reason message.
# ---------------------------------------------------------------------------
run_t16() {
    require_source "$HOOK" "T16: ACTION=invoke -> reason contains NEXT_SKILL" || return
    local tmp sid out rc
    tmp="$(mktemp -d)"
    sid="t16-sid"
    seed_workflow_state "$tmp" "$sid" "invoke"
    out=$(echo "{\"stop_hook_active\":false,\"session_id\":\"$sid\",\"transcript_path\":\"\"}" \
        | CLAUDE_WORKFLOW_DIR="$tmp/workflow" WORKFLOW_PLANS_DIR="$tmp/plans" \
          run_with_timeout 15 node "$HOOK_NODE" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    # The reason field must mention NEXT_SKILL; next-step returns NEXT_SKILL for this session.
    if echo "$out" | grep -q '"block"' && echo "$out" | grep -q 'NEXT_SKILL='; then
        pass "T16: decision:block reason contains NEXT_SKILL"
    else
        fail "T16: expected reason with NEXT_SKILL in block output (rc=$rc, out=$out)"
    fi
}
