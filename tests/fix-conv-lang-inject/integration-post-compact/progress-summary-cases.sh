# integration-post-compact/progress-summary-cases.sh — T28..T36
# Tests: hooks/post-compact.js
# Tags: conv-lang, post-compact, workflow-state, scope:common
# Sourced by ../integration-post-compact.sh after progress-helpers.sh; cases run
# at source time. Owns the inline "Workflow progress:" summary renderer: step
# line count, status rendering, and branch/step-name content.
# ---------------------------------------------------------------------------
# T28 [Progress] post-compact with 3 complete steps → "Workflow progress:" section
# with exactly 10 step lines
# ---------------------------------------------------------------------------
T28_SID="t28-$RANDOM"
_write_wf_state "$T28_SID" \
    "workflow_init:complete" "clarify_intent:complete" "research:complete"
T28_CTX=$(_call_post_compact_with_state "$T28_SID")
if [ -z "$T28_CTX" ]; then
    fail "T28: post-compact produced no output (progress summary not implemented yet)"
elif ! echo "$T28_CTX" | grep -qF "Workflow progress:"; then
    fail "T28: additionalContext missing 'Workflow progress:' section. Got: $T28_CTX"
else
    T28_STEP_COUNT=$(echo "$T28_CTX" | grep -cE '^\s*(✓|○|…|\[complete\]|\[pending\]|\[in_progress\]|\[skipped\]|\[x\]|\[ \])' || \
                     echo "$T28_CTX" | grep -cE '(complete|pending|in_progress|skipped)' | head -n1 || echo 0)
    # Count lines that look like step entries (contain a step name from WORKFLOW_STEPS)
    T28_LINE_COUNT=$(echo "$T28_CTX" | grep -cE '(workflow_init|clarify_intent|research|outline|detail|write_tests|review_tests|run_tests|review_security|docs|user_verification|cleanup)' || true)
    if [ "$T28_LINE_COUNT" -eq 10 ]; then
        pass "T28: post-compact progress summary has exactly 10 step lines"
    else
        fail "T28: expected 10 step lines in progress summary, got $T28_LINE_COUNT. Context: $T28_CTX"
    fi
fi

# ---------------------------------------------------------------------------
# T29 [Fail-open] post-compact with no state file → valid JSON, no crash
# ---------------------------------------------------------------------------
T29_SID="t29-nosuchsid-$RANDOM"
T29_RAW=$(printf '{"session_id":"%s"}' "$T29_SID" | \
    CLAUDE_WORKFLOW_DIR="$TMPDIR_BASE/workflow-t29-empty" \
    HOME="$TMPDIR_BASE/home-t29" \
    AGENTS_CONFIG_DIR="$EMPTY_CFG" \
    run_with_timeout 30 node "$POST_COMPACT" 2>/dev/null)
T29_RC=$?
if [ "$T29_RC" -ne 0 ]; then
    fail "T29: post-compact crashed (rc=$T29_RC) when state file absent"
else
    T29_VALID=$(node -e "
try {
  const o = JSON.parse(process.argv[1] || '{}');
  process.stdout.write(typeof o === 'object' ? 'yes' : 'no');
} catch(e) { process.stdout.write('no'); }
" "$T29_RAW" 2>/dev/null)
    if [ "$T29_VALID" = "yes" ]; then
        pass "T29: post-compact with no state file → valid JSON, no crash (fail-open)"
    else
        fail "T29: post-compact with no state file → invalid JSON or crash. Got: $T29_RAW"
    fi
fi

# ---------------------------------------------------------------------------
# T30 [Annotation] user_verification=pending + reset_reason="post-merge"
#     → annotation "(reset after pr merge — expected)" appears
# ---------------------------------------------------------------------------
T30_SID="t30-$RANDOM"
_write_wf_state_with_reset_reason "$T30_SID" "pending" "post-merge"
T30_CTX=$(_call_post_compact_with_state "$T30_SID")
if [ -z "$T30_CTX" ]; then
    fail "T30: post-compact produced no output (progress summary not implemented yet)"
elif echo "$T30_CTX" | grep -qF "reset after pr merge"; then
    pass "T30: user_verification reset_reason=post-merge → annotation '(reset after pr merge — expected)' present"
else
    fail "T30: annotation missing. Expected 'reset after pr merge' in: $T30_CTX"
fi

# ---------------------------------------------------------------------------
# T31 [No annotation] user_verification=pending but NO reset_reason
#     → no "(reset after pr merge — expected)" annotation
# ---------------------------------------------------------------------------
T31_SID="t31-$RANDOM"
_write_wf_state_with_reset_reason "$T31_SID" "pending" ""
T31_CTX=$(_call_post_compact_with_state "$T31_SID")
if [ -z "$T31_CTX" ]; then
    fail "T31: post-compact produced no output (progress summary not implemented yet)"
elif echo "$T31_CTX" | grep -qF "reset after pr merge"; then
    fail "T31: unexpected annotation when no reset_reason. Got: $T31_CTX"
else
    pass "T31: user_verification=pending with no reset_reason → no post-merge annotation"
fi

# ---------------------------------------------------------------------------
# T32 [Regression] CONV_LANG=any → no "Respond to the user in any." injection
#     (regression for T-A1 in the post-compact integration path)
# ---------------------------------------------------------------------------
T32_SID="t32-$RANDOM"
T32_CTX=$(call_post_compact "$T32_SID" set "any")
if echo "$T32_CTX" | grep -qF "Respond to the user in any"; then
    fail "T32: CONV_LANG=any produced injection — no-op not effective in post-compact. Got: $T32_CTX"
else
    pass "T32: CONV_LANG=any → no 'Respond to the user in any.' in post-compact output"
fi

# ---------------------------------------------------------------------------
# T33 [Count] post-compact summary contains exactly 10 step entries (not 14)
# Same count assertion as T28 but with a fully-complete state to ensure
# internal-gate steps don't leak when all 14 steps are written.
# ---------------------------------------------------------------------------
T33_SID="t33-$RANDOM"
# Write all 14 steps as complete (including internal gates branching_complete, pre_final_report_gate)
_write_wf_state "$T33_SID" \
    "workflow_init:complete" "clarify_intent:complete" "research:complete" \
    "outline:complete" "detail:complete" "branching_complete:complete" \
    "write_tests:complete" "review_tests:complete" "run_tests:complete" \
    "review_security:complete" "docs:complete" "user_verification:complete" \
    "cleanup:complete" "pre_final_report_gate:complete"
T33_CTX=$(_call_post_compact_with_state "$T33_SID")
if [ -z "$T33_CTX" ]; then
    fail "T33: post-compact produced no output (progress summary not implemented yet)"
elif ! echo "$T33_CTX" | grep -qF "Workflow progress:"; then
    fail "T33: 'Workflow progress:' section missing. Got: $T33_CTX"
else
    T33_LINE_COUNT=$(echo "$T33_CTX" | grep -cE '(workflow_init|clarify_intent|research|outline|detail|write_tests|review_tests|run_tests|review_security|docs|user_verification|cleanup)' || true)
    if [ "$T33_LINE_COUNT" -eq 10 ]; then
        pass "T33: progress summary has exactly 10 step entries (not 14)"
    else
        fail "T33: expected 10 step entries, got $T33_LINE_COUNT. Context: $T33_CTX"
    fi
fi

# ---------------------------------------------------------------------------
# T34 [Exclusion] branching_complete and pre_final_report_gate do NOT appear
#     in post-compact output (internal-gate steps excluded from WORKFLOW_STEPS)
# ---------------------------------------------------------------------------
T34_SID="t34-$RANDOM"
_write_wf_state "$T34_SID" \
    "workflow_init:complete" "branching_complete:complete" "pre_final_report_gate:complete"
T34_CTX=$(_call_post_compact_with_state "$T34_SID")
if [ -z "$T34_CTX" ]; then
    fail "T34: post-compact produced no output (progress summary not implemented yet)"
else
    T34_HAS_BRANCHING=$(echo "$T34_CTX" | grep -cF "branching_complete" || true)
    T34_HAS_PREGATE=$(echo "$T34_CTX" | grep -cF "pre_final_report_gate" || true)
    if [ "$T34_HAS_BRANCHING" -eq 0 ] && [ "$T34_HAS_PREGATE" -eq 0 ]; then
        pass "T34: branching_complete and pre_final_report_gate excluded from progress output"
    else
        fail "T34: internal-gate steps leaked into output (branching_complete=$T34_HAS_BRANCHING pre_final_report_gate=$T34_HAS_PREGATE). Context: $T34_CTX"
    fi
fi

# ---------------------------------------------------------------------------
# T35 [Error] post-compact with a state file containing corrupt JSON → rc=0,
#     valid JSON output (fail-open). Distinct from T29 (absent file): here the
#     file EXISTS but its contents are not parseable JSON.
# ---------------------------------------------------------------------------
T35_SID="t35-corrupt-$RANDOM"
T35_DIR="$TMPDIR_BASE/workflow-t35-corrupt"
mkdir -p "$T35_DIR"
printf 'not-valid-json' > "$T35_DIR/${T35_SID}.json"
T35_RAW=$(printf '{"session_id":"%s"}' "$T35_SID" | \
    CLAUDE_WORKFLOW_DIR="$T35_DIR" \
    HOME="$TMPDIR_BASE/home-t35" \
    AGENTS_CONFIG_DIR="$EMPTY_CFG" \
    run_with_timeout 30 node "$POST_COMPACT" 2>/dev/null)
T35_RC=$?
if [ "$T35_RC" -ne 0 ]; then
    fail "T35: post-compact crashed (rc=$T35_RC) when state file contains corrupt JSON"
else
    T35_VALID=$(node -e "
try {
  const o = JSON.parse(process.argv[1] || '{}');
  process.stdout.write(typeof o === 'object' ? 'yes' : 'no');
} catch(e) { process.stdout.write('no'); }
" "$T35_RAW" 2>/dev/null)
    if [ "$T35_VALID" = "yes" ]; then
        pass "T35: post-compact with corrupt-JSON state file → valid JSON, no crash (fail-open)"
    else
        fail "T35: post-compact with corrupt-JSON state file → invalid JSON or crash. Got: $T35_RAW"
    fi
fi

# ---------------------------------------------------------------------------
# T36 [Edge] post-compact with all 10 workflow steps at "pending" → "Workflow
#     progress:" section appears with exactly 10 step lines.
# _write_wf_state with no step arguments defaults every step to "pending".
# ---------------------------------------------------------------------------
T36_SID="t36-allpending-$RANDOM"
_write_wf_state "$T36_SID"
T36_CTX=$(_call_post_compact_with_state "$T36_SID")
if [ -z "$T36_CTX" ]; then
    fail "T36: post-compact produced no output (progress summary not implemented yet)"
elif ! echo "$T36_CTX" | grep -qF "Workflow progress:"; then
    fail "T36: additionalContext missing 'Workflow progress:' section. Got: $T36_CTX"
else
    T36_LINE_COUNT=$(echo "$T36_CTX" | grep -cE '(workflow_init|clarify_intent|research|outline|detail|write_tests|review_tests|run_tests|review_security|docs|user_verification|cleanup)' || true)
    if [ "$T36_LINE_COUNT" -eq 10 ]; then
        pass "T36: all-pending state → progress summary has exactly 10 step lines"
    else
        fail "T36: expected 10 step lines with all-pending state, got $T36_LINE_COUNT. Context: $T36_CTX"
    fi
fi
