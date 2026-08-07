# integration-post-compact/resume-hint-cases.sh — T37..T41
# Tests: hooks/post-compact.js
# Tags: conv-lang, post-compact, workflow-state, scope:common
# Sourced by ../integration-post-compact.sh last; cases run at source time.
# Owns the /resume-session hint line: present while any non-excluded step is
# pending, absent otherwise (including the user_verification reset_reason
# exclusion).
# ===========================================================================
# T37–T41: Workflow resume hint in post-compact output (post-#1552 feature)
# These tests define expected behavior for the /resume-session hint line.
# EXPECTED_HINT is the exact string post-compact.js must append when the
# workflow is in progress (i.e. has at least one non-excluded pending step).
# ===========================================================================
EXPECTED_HINT="→ Workflow is in progress. Run /resume-session to resume from the current step."

# ---------------------------------------------------------------------------
# T37 [Hint present] Some steps pending (normal in-progress case)
#     → hint line appears in additionalContext
# ---------------------------------------------------------------------------
T37_SID="t37-$RANDOM"
_write_wf_state "$T37_SID" \
    "workflow_init:complete" "clarify_intent:complete" "research:pending"
T37_CTX=$(_call_post_compact_with_state "$T37_SID")
if [ -z "$T37_CTX" ]; then
    fail "T37: post-compact produced no output"
elif echo "$T37_CTX" | grep -qF "$EXPECTED_HINT"; then
    pass "T37: some steps pending → hint line present"
else
    fail "T37: hint line missing for in-progress workflow. Got: $T37_CTX"
fi

# ---------------------------------------------------------------------------
# T38 [Hint absent] All steps complete → no hint line
# ---------------------------------------------------------------------------
T38_SID="t38-$RANDOM"
_write_wf_state "$T38_SID" \
    "workflow_init:complete" "clarify_intent:complete" "research:complete" \
    "outline:complete" "detail:complete" "write_tests:complete" \
    "review_security:complete" "docs:complete" "user_verification:complete" \
    "cleanup:complete"
T38_CTX=$(_call_post_compact_with_state "$T38_SID")
if [ -z "$T38_CTX" ]; then
    fail "T38: post-compact produced no output"
elif echo "$T38_CTX" | grep -qF "$EXPECTED_HINT"; then
    fail "T38: hint line unexpectedly present when all steps complete. Got: $T38_CTX"
else
    pass "T38: all steps complete → no hint line"
fi

# ---------------------------------------------------------------------------
# T39 [Hint absent — exclusion] user_verification=pending + reset_reason=post-merge
#     is the only pending step → hint line must NOT appear (excluded condition)
# ---------------------------------------------------------------------------
T39_SID="t39-$RANDOM"
_write_wf_state_with_reset_reason "$T39_SID" "pending" "post-merge"
T39_CTX=$(_call_post_compact_with_state "$T39_SID")
if [ -z "$T39_CTX" ]; then
    fail "T39: post-compact produced no output"
elif echo "$T39_CTX" | grep -qF "$EXPECTED_HINT"; then
    fail "T39: hint line appeared despite post-merge exclusion. Got: $T39_CTX"
else
    pass "T39: user_verification=pending+reset_reason=post-merge → hint excluded"
fi

# ---------------------------------------------------------------------------
# T40 [Hint absent — fail-open] No state file → no hint line (fail-open)
# Note: _write_wf_state is intentionally NOT called before _call_post_compact_with_state.
# We use a unique empty workflow dir so no state file exists for this SID.
# ---------------------------------------------------------------------------
T40_SID="t40-nosuchsid-$RANDOM"
T40_RAW=$(printf '{"session_id":"%s"}' "$T40_SID" | \
    CLAUDE_WORKFLOW_DIR="$TMPDIR_BASE/workflow-t40-empty" \
    HOME="$TMPDIR_BASE/home-t40" \
    AGENTS_CONFIG_DIR="$EMPTY_CFG" \
    run_with_timeout 30 node "$POST_COMPACT" 2>/dev/null)
T40_CTX=$(node -e "
try {
  const o = JSON.parse(process.argv[1] || '{}');
  process.stdout.write(o.additionalContext || '');
} catch (e) {}
" "$T40_RAW" 2>/dev/null)
if echo "$T40_CTX" | grep -qF "$EXPECTED_HINT"; then
    fail "T40: hint line appeared when no state file exists (fail-open violated). Got: $T40_CTX"
else
    pass "T40: no state file → no hint line (fail-open)"
fi

# ---------------------------------------------------------------------------
# T41 [Hint present] user_verification=pending but NO reset_reason
#     → not excluded → hint line must appear
# ---------------------------------------------------------------------------
T41_SID="t41-$RANDOM"
_write_wf_state_with_reset_reason "$T41_SID" "pending" ""
T41_CTX=$(_call_post_compact_with_state "$T41_SID")
if [ -z "$T41_CTX" ]; then
    fail "T41: post-compact produced no output"
elif echo "$T41_CTX" | grep -qF "$EXPECTED_HINT"; then
    pass "T41: user_verification=pending (no reset_reason) → hint line present"
else
    fail "T41: hint line missing when user_verification=pending with no reset_reason. Got: $T41_CTX"
fi
