#!/bin/bash
# Tests: hooks/workflow-mark.js, hooks/workflow-mark/confirm-next-step-handler.js, hooks/lib/workflow-state.js, hooks/lib/sentinel-patterns.js
# Tags: confirm-plan, co-emission, sentinel, hook, workflow-mark, transition-hint
# Verifies the structural fix for #842: when a CONFIRM_<STAGE> sentinel is echoed
# and the user clicks Allow, workflow-mark.js (PostToolUse) injects a next-step
# hint into additionalContext so the workflow continues even if the LLM did NOT
# co-emit the follow-up tool calls in the same assistant turn.
set -u

AGENTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MARK_HOOK="$AGENTS_DIR/hooks/workflow-mark.js"
HANDLER="$AGENTS_DIR/hooks/workflow-mark/confirm-next-step-handler.js"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 120 "$@"
    else
        perl -e 'alarm 120; exec @ARGV' -- "$@"
    fi
}

# Skip gracefully if source files not yet created
if [ ! -f "$MARK_HOOK" ] || [ ! -f "$HANDLER" ]; then
    echo "SKIP: workflow-mark.js or confirm-next-step-handler.js not present"
    echo ""
    echo "Results: 0 passed, 0 failed (skipped)"
    exit 0
fi

extract_additional_context() {
    printf '%s' "$1" | node -e "
      let b='';process.stdin.on('data',c=>b+=c);
      process.stdin.on('end',()=>{
        try {
          const d=JSON.parse(b);
          process.stdout.write(d.additionalContext||'');
        } catch(e) {}
      });
    " 2>/dev/null || true
}

# Build a PostToolUse-style hook input JSON for an echo sentinel
build_mark_json() {
    local cmd="$1" sid="${2:-test-confirm}"
    local esc="${cmd//\\/\\\\}"
    esc="${esc//\"/\\\"}"
    printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"tool_response":{"exit_code":0,"stdout":"","stderr":""},"session_id":"%s"}' \
        "$esc" "$sid"
}

# ---------------------------------------------------------------------------
# T1: CONFIRM_INTENT → hint points at clarify-intent Completion
# ---------------------------------------------------------------------------
echo "=== T1: WORKFLOW_CONFIRM_INTENT → next-step hint for clarify-intent ==="
T1_JSON=$(build_mark_json 'echo "<<WORKFLOW_CONFIRM_INTENT: scope clarified>>"')
T1_OUT=$(printf '%s' "$T1_JSON" | run_with_timeout node "$MARK_HOOK" 2>/dev/null || true)
T1_CTX=$(extract_additional_context "$T1_OUT")
if printf '%s' "$T1_CTX" | grep -qF "CONFIRM_INTENT approved"; then
    pass "T1a hint announces CONFIRM_INTENT approved"
else
    fail "T1a missing 'CONFIRM_INTENT approved' — got: $T1_CTX"
fi
if printf '%s' "$T1_CTX" | grep -qF "WORKFLOW_CLARIFY_INTENT_COMPLETE"; then
    pass "T1b hint references WORKFLOW_CLARIFY_INTENT_COMPLETE next sentinel"
else
    fail "T1b missing WORKFLOW_CLARIFY_INTENT_COMPLETE — got: $T1_CTX"
fi
if printf '%s' "$T1_CTX" | grep -qF "make-outline-plan"; then
    pass "T1c hint names the next skill (make-outline-plan)"
else
    fail "T1c missing make-outline-plan — got: $T1_CTX"
fi

# ---------------------------------------------------------------------------
# T2: CONFIRM_OUTLINE → hint points at make-outline-plan Completion
# ---------------------------------------------------------------------------
echo "=== T2: WORKFLOW_CONFIRM_OUTLINE → next-step hint for make-outline-plan ==="
T2_JSON=$(build_mark_json 'echo "<<WORKFLOW_CONFIRM_OUTLINE: approach A>>"')
T2_OUT=$(printf '%s' "$T2_JSON" | run_with_timeout node "$MARK_HOOK" 2>/dev/null || true)
T2_CTX=$(extract_additional_context "$T2_OUT")
if printf '%s' "$T2_CTX" | grep -qF "CONFIRM_OUTLINE approved"; then
    pass "T2a hint announces CONFIRM_OUTLINE approved"
else
    fail "T2a missing 'CONFIRM_OUTLINE approved' — got: $T2_CTX"
fi
if printf '%s' "$T2_CTX" | grep -qF "WORKFLOW_MARK_STEP_outline_complete"; then
    pass "T2b hint references WORKFLOW_MARK_STEP_outline_complete"
else
    fail "T2b missing WORKFLOW_MARK_STEP_outline_complete — got: $T2_CTX"
fi
if printf '%s' "$T2_CTX" | grep -qF "WORKFLOW_OUTLINE_PLAN_COMPLETE"; then
    pass "T2c hint references WORKFLOW_OUTLINE_PLAN_COMPLETE"
else
    fail "T2c missing WORKFLOW_OUTLINE_PLAN_COMPLETE — got: $T2_CTX"
fi
if printf '%s' "$T2_CTX" | grep -qF "make-detail-plan"; then
    pass "T2d hint names the next skill (make-detail-plan)"
else
    fail "T2d missing make-detail-plan — got: $T2_CTX"
fi

# ---------------------------------------------------------------------------
# T3: CONFIRM_DETAIL → hint points at make-detail-plan Completion
# ---------------------------------------------------------------------------
echo "=== T3: WORKFLOW_CONFIRM_DETAIL → next-step hint for make-detail-plan ==="
T3_JSON=$(build_mark_json 'echo "<<WORKFLOW_CONFIRM_DETAIL: file-level plan>>"')
T3_OUT=$(printf '%s' "$T3_JSON" | run_with_timeout node "$MARK_HOOK" 2>/dev/null || true)
T3_CTX=$(extract_additional_context "$T3_OUT")
if printf '%s' "$T3_CTX" | grep -qF "CONFIRM_DETAIL approved"; then
    pass "T3a hint announces CONFIRM_DETAIL approved"
else
    fail "T3a missing 'CONFIRM_DETAIL approved' — got: $T3_CTX"
fi
if printf '%s' "$T3_CTX" | grep -qF "WORKFLOW_MARK_STEP_detail_complete"; then
    pass "T3b hint references WORKFLOW_MARK_STEP_detail_complete"
else
    fail "T3b missing WORKFLOW_MARK_STEP_detail_complete — got: $T3_CTX"
fi
if printf '%s' "$T3_CTX" | grep -qF "WORKFLOW_BRANCHING_COMPLETE"; then
    pass "T3c hint references WORKFLOW_BRANCHING_COMPLETE"
else
    fail "T3c missing WORKFLOW_BRANCHING_COMPLETE — got: $T3_CTX"
fi
if printf '%s' "$T3_CTX" | grep -qF "write-tests"; then
    pass "T3d hint names the next skill (write-tests)"
else
    fail "T3d missing write-tests — got: $T3_CTX"
fi

# ---------------------------------------------------------------------------
# T4: CONFIRM sentinel must NOT mark a workflow step (it is a gate, not a completion).
#     If the handler accidentally went through markStep with a non-existent step, the
#     hook would write to stderr / exit 2. Here we just confirm exit 0 and no step
#     name leaks into the hint.
# ---------------------------------------------------------------------------
echo "=== T4: CONFIRM sentinel does not register a workflow step ==="
T4_JSON=$(build_mark_json 'echo "<<WORKFLOW_CONFIRM_OUTLINE: gate-only>>"')
# Reuse T2 output — call again under set -e style assertions
if printf '%s' "$T4_JSON" | run_with_timeout node "$MARK_HOOK" >/dev/null 2>&1; then
    pass "T4 hook exits 0 on CONFIRM_OUTLINE (gate, not step)"
else
    fail "T4 hook returned non-zero exit on CONFIRM_OUTLINE"
fi

# ---------------------------------------------------------------------------
# T5: Non-CONFIRM sentinel (e.g. MARK_STEP_outline_complete) must NOT pick up the
#     CONFIRM hint — verifies handler dispatch is mutually exclusive.
# ---------------------------------------------------------------------------
echo "=== T5: MARK_STEP sentinel does not receive CONFIRM hint ==="
T5_JSON=$(build_mark_json 'echo "<<WORKFLOW_MARK_STEP_outline_complete>>"')
T5_OUT=$(printf '%s' "$T5_JSON" | run_with_timeout node "$MARK_HOOK" 2>/dev/null || true)
T5_CTX=$(extract_additional_context "$T5_OUT")
if printf '%s' "$T5_CTX" | grep -qF "CONFIRM_OUTLINE approved"; then
    fail "T5 MARK_STEP_outline_complete incorrectly received CONFIRM_OUTLINE hint — got: $T5_CTX"
else
    pass "T5 MARK_STEP_outline_complete does NOT receive CONFIRM hint"
fi

# ---------------------------------------------------------------------------
# T6: Exit code != 0 on the echo → no hint emitted (workflow-mark short-circuits).
# ---------------------------------------------------------------------------
echo "=== T6: failed echo (exit_code=1) → no CONFIRM hint ==="
T6_JSON='{"tool_name":"Bash","tool_input":{"command":"echo \"<<WORKFLOW_CONFIRM_INTENT: x>>\""},"tool_response":{"exit_code":1,"stdout":"","stderr":""},"session_id":"test-confirm"}'
T6_OUT=$(printf '%s' "$T6_JSON" | run_with_timeout node "$MARK_HOOK" 2>/dev/null || true)
T6_CTX=$(extract_additional_context "$T6_OUT")
if printf '%s' "$T6_CTX" | grep -qF "CONFIRM_INTENT approved"; then
    fail "T6 failed echo should NOT emit CONFIRM hint — got: $T6_CTX"
else
    pass "T6 failed echo → no CONFIRM hint emitted"
fi

# ---------------------------------------------------------------------------
echo
if [ "$ERRORS" -eq 0 ]; then
    echo "All tests passed!"
    exit 0
else
    echo "$ERRORS test(s) failed"
    exit 1
fi
