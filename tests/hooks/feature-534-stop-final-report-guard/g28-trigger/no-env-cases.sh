# tests/feature-534-stop-final-report-guard/g28-trigger/no-env-cases.sh
# Tests: hooks/stop-final-report-guard.js, bin/workflow/next-step
# Tags: hook, stop-guard, workflow-state, scope:issue-specific, TL2
#
# Sourced by ../g28-trigger.sh — no shebang, no runner. Owns the 系統B cases
# where the env file is ABSENT: G33 (gate reached, no report → block), G34
# (hand-written full report still blocks), G35..G39 (mid-workflow, no state,
# gate yield, workflow-off marker, gate already complete → exit 0) and G40
# (non-default CLAUDE_WORKFLOW_DIR still reaches the spawned next-step).
#
# Depends on ../g28-trigger.sh for: b_mk_state, b_run, b_stdin, b_is_block,
# b_reason_has, B_OUT, B_CODE — and on the grandparent for TMPDIR_BASE,
# HOOK_JS, node_path, require_hook, run_with_timeout, pass, fail, skip and the
# transcript-writing helpers.

# ---------------------------------------------------------------------------
# G33: 系統B core — no env file + gate reached + no FR heading → exit 2 + block
# ---------------------------------------------------------------------------
test_G33_no_env_gate_reached_no_report_blocks() {
    require_hook "G33_no_env_gate_reached_no_report_blocks" || return
    local sid="g33-sid"
    local plans_dir="$TMPDIR_BASE/g33-plans" wf_dir="$TMPDIR_BASE/g33-wf"
    mkdir -p "$plans_dir" "$wf_dir"
    b_mk_state "$wf_dir" "$sid" pre_final_report_gate

    local transcript="$TMPDIR_BASE/g33-transcript.jsonl"
    write_transcript_with_assistant "$transcript" "All done, wrapping up here."

    b_run "$HOOK_JS" "$(b_stdin "$sid" "$transcript")" \
        "$(node_path "$plans_dir")" "$(node_path "$wf_dir")"

    if [ "$B_CODE" = "2" ] && b_is_block && b_reason_has "session-close"; then
        pass "G33: no env-file + pre_final_report_gate reached → exit 2 + block pointing at /session-close"
    else
        fail "G33: expected exit 2 + decision:block mentioning session-close, got code=$B_CODE out=$(printf '%s' "$B_OUT" | head -c 220)"
    fi
}

# ---------------------------------------------------------------------------
# G34 (core case of #1611): no env file + gate reached + a COMPLETE hand-written
# 13-heading Final Report in the transcript → still exit 2.
# The close procedure never ran, so the report cannot be genuine.
# ---------------------------------------------------------------------------
test_G34_no_env_handwritten_full_report_still_blocks() {
    require_hook "G34_no_env_handwritten_full_report_still_blocks" || return
    local sid="g34-sid"
    local plans_dir="$TMPDIR_BASE/g34-plans" wf_dir="$TMPDIR_BASE/g34-wf"
    mkdir -p "$plans_dir" "$wf_dir"
    b_mk_state "$wf_dir" "$sid" pre_final_report_gate

    local transcript="$TMPDIR_BASE/g34-transcript.jsonl"
    write_transcript_with_assistant "$transcript" "$(full_canonical_report_text "$sid")"

    b_run "$HOOK_JS" "$(b_stdin "$sid" "$transcript")" \
        "$(node_path "$plans_dir")" "$(node_path "$wf_dir")"

    if [ "$B_CODE" = "2" ] && b_is_block; then
        pass "G34: hand-written 13-heading report without /session-close → exit 2 (not accepted)"
    else
        fail "G34: expected exit 2 + decision:block, got code=$B_CODE out=$(printf '%s' "$B_OUT" | head -c 220)"
    fi
}

# ---------------------------------------------------------------------------
# G35: no env file + workflow still mid-flight (docs pending) → exit 0
# (preserves the pre-#1611 no-op behaviour on ordinary turns)
# ---------------------------------------------------------------------------
test_G35_no_env_midworkflow_exit0() {
    require_hook "G35_no_env_midworkflow_exit0" || return
    local sid="g35-sid"
    local plans_dir="$TMPDIR_BASE/g35-plans" wf_dir="$TMPDIR_BASE/g35-wf"
    mkdir -p "$plans_dir" "$wf_dir"
    b_mk_state "$wf_dir" "$sid" docs user_verification cleanup pre_final_report_gate

    local transcript="$TMPDIR_BASE/g35-transcript.jsonl"
    write_transcript_with_assistant "$transcript" "Still working on the docs step."

    b_run "$HOOK_JS" "$(b_stdin "$sid" "$transcript")" \
        "$(node_path "$plans_dir")" "$(node_path "$wf_dir")"

    if [ "$B_CODE" = "0" ]; then
        pass "G35: no env-file + mid-workflow (docs pending) → exit 0"
    else
        fail "G35: expected exit 0, got code=$B_CODE out=$(printf '%s' "$B_OUT" | head -c 220)"
    fi
}

# ---------------------------------------------------------------------------
# G36: no env file + no workflow state file at all → exit 0
# ---------------------------------------------------------------------------
test_G36_no_env_no_state_exit0() {
    require_hook "G36_no_env_no_state_exit0" || return
    local sid="g36-sid"
    local plans_dir="$TMPDIR_BASE/g36-plans" wf_dir="$TMPDIR_BASE/g36-wf"
    mkdir -p "$plans_dir" "$wf_dir"

    local transcript="$TMPDIR_BASE/g36-transcript.jsonl"
    write_transcript_with_assistant "$transcript" "Non-workflow session, just chatting."

    b_run "$HOOK_JS" "$(b_stdin "$sid" "$transcript")" \
        "$(node_path "$plans_dir")" "$(node_path "$wf_dir")"

    if [ "$B_CODE" = "0" ]; then
        pass "G36: no env-file + no workflow state → exit 0"
    else
        fail "G36: expected exit 0, got code=$B_CODE out=$(printf '%s' "$B_OUT" | head -c 220)"
    fi
}

# ---------------------------------------------------------------------------
# G37: 系統B escape hatch (a) — session-close gate says yield → exit 0
# ---------------------------------------------------------------------------
test_G37_no_env_gate_yield_exit0() {
    require_hook "G37_no_env_gate_yield_exit0" || return
    local sid="g37-sid"
    local plans_dir="$TMPDIR_BASE/g37-plans" wf_dir="$TMPDIR_BASE/g37-wf"
    mkdir -p "$plans_dir" "$wf_dir"
    b_mk_state "$wf_dir" "$sid" pre_final_report_gate
    printf '{"gate_action":"yield"}' > "$plans_dir/${sid}-session-close-gate.json"

    local transcript="$TMPDIR_BASE/g37-transcript.jsonl"
    write_transcript_with_assistant "$transcript" "Supervisor yielded; stopping here."

    b_run "$HOOK_JS" "$(b_stdin "$sid" "$transcript")" \
        "$(node_path "$plans_dir")" "$(node_path "$wf_dir")"

    if [ "$B_CODE" = "0" ]; then
        pass "G37: 系統B + gate_action:yield → exit 0 (escape hatch a)"
    else
        fail "G37: expected exit 0, got code=$B_CODE out=$(printf '%s' "$B_OUT" | head -c 220)"
    fi
}

# ---------------------------------------------------------------------------
# G38: 系統B escape hatch (b) — <sid>.workflow-off marker → exit 0
# ---------------------------------------------------------------------------
test_G38_no_env_workflow_off_exit0() {
    require_hook "G38_no_env_workflow_off_exit0" || return
    local sid="g38-sid"
    local plans_dir="$TMPDIR_BASE/g38-plans" wf_dir="$TMPDIR_BASE/g38-wf"
    mkdir -p "$plans_dir" "$wf_dir"
    b_mk_state "$wf_dir" "$sid" pre_final_report_gate
    printf 'off' > "$wf_dir/${sid}.workflow-off"

    local transcript="$TMPDIR_BASE/g38-transcript.jsonl"
    write_transcript_with_assistant "$transcript" "Workflow enforcement is off for this session."

    b_run "$HOOK_JS" "$(b_stdin "$sid" "$transcript")" \
        "$(node_path "$plans_dir")" "$(node_path "$wf_dir")"

    if [ "$B_CODE" = "0" ]; then
        pass "G38: 系統B + workflow-off marker → exit 0 (escape hatch b)"
    else
        fail "G38: expected exit 0, got code=$B_CODE out=$(printf '%s' "$B_OUT" | head -c 220)"
    fi
}

# ---------------------------------------------------------------------------
# G39: 系統B escape hatch (c) — pre_final_report_gate manually complete → exit 0
# ---------------------------------------------------------------------------
test_G39_no_env_gate_complete_exit0() {
    require_hook "G39_no_env_gate_complete_exit0" || return
    local sid="g39-sid"
    local plans_dir="$TMPDIR_BASE/g39-plans" wf_dir="$TMPDIR_BASE/g39-wf"
    mkdir -p "$plans_dir" "$wf_dir"
    b_mk_state "$wf_dir" "$sid"   # every step complete, gate included

    local transcript="$TMPDIR_BASE/g39-transcript.jsonl"
    write_transcript_with_assistant "$transcript" "Gate was marked complete by hand."

    b_run "$HOOK_JS" "$(b_stdin "$sid" "$transcript")" \
        "$(node_path "$plans_dir")" "$(node_path "$wf_dir")"

    if [ "$B_CODE" = "0" ]; then
        pass "G39: 系統B + pre_final_report_gate complete → exit 0 (escape hatch c)"
    else
        fail "G39: expected exit 0, got code=$B_CODE out=$(printf '%s' "$B_OUT" | head -c 220)"
    fi
}

# ---------------------------------------------------------------------------
# G40 (regression): the spawned next-step must inherit CLAUDE_WORKFLOW_DIR.
# The state lives ONLY in a non-default nested temp dir; if the hook spawns
# next-step with a scrubbed env, the state is invisible and the hook exits 0.
# ---------------------------------------------------------------------------
test_G40_nondefault_workflow_dir_env_inheritance() {
    require_hook "G40_nondefault_workflow_dir_env_inheritance" || return
    local sid="g40-sid"
    local plans_dir="$TMPDIR_BASE/g40-plans"
    local wf_dir="$TMPDIR_BASE/g40-nested/deeper/wf"
    mkdir -p "$plans_dir" "$wf_dir"
    b_mk_state "$wf_dir" "$sid" pre_final_report_gate

    local transcript="$TMPDIR_BASE/g40-transcript.jsonl"
    write_transcript_with_assistant "$transcript" "Done; state lives in a non-default workflow dir."

    b_run "$HOOK_JS" "$(b_stdin "$sid" "$transcript")" \
        "$(node_path "$plans_dir")" "$(node_path "$wf_dir")"

    if [ "$B_CODE" = "2" ] && b_is_block; then
        pass "G40: non-default CLAUDE_WORKFLOW_DIR still reaches 系統B → exit 2 (env inherited by next-step)"
    else
        fail "G40: expected exit 2 + block (env inheritance regression), got code=$B_CODE out=$(printf '%s' "$B_OUT" | head -c 220)"
    fi
}

