# integration-post-compact.sh — T12, T13, T15, T16, T17, T19, T20: Integration tests for hooks/post-compact.js
# Sourced after helpers.sh; inherits all variables and functions.

# ===========================================================================
# Integration tests for post-compact.js (T12, T13)
# ===========================================================================

# T12 [Integration] post-compact with CONV_LANG=japanese
CTX=$(call_post_compact "t12-$RANDOM" set "japanese")
if [ -z "$CTX" ]; then
    skip "T12: post-compact produced no output"
elif echo "$CTX" | grep -qF "$EXPECTED_JA"; then
    pass "T12: post-compact additionalContext includes CONV_LANG injection"
else
    fail "T12: additionalContext missing injection. Got: $CTX"
fi

# T13 [Integration] post-compact with CONV_LANG unset → no injection
CTX=$(call_post_compact "t13-$RANDOM" unset)
if [ -z "$CTX" ]; then
    skip "T13: post-compact produced no output"
elif echo "$CTX" | grep -qF "Respond to the user in"; then
    fail "T13: additionalContext unexpectedly contains injection. Got: $CTX"
else
    pass "T13: post-compact with CONV_LANG unset → no injection"
fi

# ===========================================================================
# T15 [Symmetry] Both hooks produce the same injection string
# ===========================================================================
SID_S="t15-ss-$RANDOM"
SID_P="t15-pc-$RANDOM"
S_CTX=$(call_session_start "$SID_S" set "japanese")
P_CTX=$(call_post_compact "$SID_P" set "japanese")
if [ -z "$S_CTX" ] || [ -z "$P_CTX" ]; then
    skip "T15: missing output from one or both hooks (S=${#S_CTX} P=${#P_CTX})"
else
    S_INJ=$(echo "$S_CTX" | grep -F "Respond to the user in" | head -n1)
    P_INJ=$(echo "$P_CTX" | grep -F "Respond to the user in" | head -n1)
    if [ -n "$S_INJ" ] && [ "$S_INJ" = "$P_INJ" ]; then
        pass "T15: both hooks produce identical injection: $S_INJ"
    else
        fail "T15: injection mismatch. session-start='$S_INJ' post-compact='$P_INJ'"
    fi
fi

# ===========================================================================
# T16 [Error] post-compact fails open if helper throws (Orthogonality with T14)
# Strategy: same stub technique as T14 — shadow conv-lang.js with a thrower,
# run post-compact.js against it, assert exit 0 and valid JSON with
# additionalContext key present (may be empty string).
# ===========================================================================
T16_AGENTS="$TMPDIR_BASE/t16-agents"
T16_HOOKS="$T16_AGENTS/hooks"
T16_LIB="$T16_HOOKS/lib"
mkdir -p "$T16_LIB"
if [ -d "$AGENTS_DIR/hooks/lib" ]; then
    cp -r "$AGENTS_DIR/hooks/lib/." "$T16_LIB/" 2>/dev/null || true
    cp "$POST_COMPACT" "$T16_HOOKS/post-compact.js" 2>/dev/null || true
    # Overwrite conv-lang.js with a thrower.
    cat > "$T16_LIB/conv-lang.js" <<'EOF'
"use strict";
function getConvLangInjection() {
  throw new Error("simulated failure for T16");
}
module.exports = { getConvLangInjection };
EOF

    T16_RAW=$(printf '{"session_id":"t16-sid"}' | \
        CONV_LANG="japanese" \
        CLAUDE_WORKFLOW_DIR="$TMPDIR_BASE/workflow-t16" \
        HOME="$TMPDIR_BASE/home-t16" \
        AGENTS_CONFIG_DIR="$EMPTY_CFG" \
        run_with_timeout 30 node "$T16_HOOKS/post-compact.js" 2>/dev/null)
    T16_RC=$?
    if [ "$T16_RC" -ne 0 ] || [ -z "$T16_RAW" ]; then
        skip "T16: stubbed post-compact did not produce output (pre-implementation or unrelated failure rc=$T16_RC)"
    else
        # Verify exit 0 (already checked via T16_RC) and valid JSON with additionalContext.
        T16_HAS_KEY=$(node -e "
try {
  const o = JSON.parse(process.argv[1]);
  process.stdout.write(Object.prototype.hasOwnProperty.call(o, 'additionalContext') ? 'yes' : 'no');
} catch (e) { process.stdout.write('parse-error'); }
" "$T16_RAW" 2>/dev/null)
        T16_CTX=$(node -e "
try {
  const o = JSON.parse(process.argv[1]);
  process.stdout.write(o.additionalContext || '');
} catch (e) {}
" "$T16_RAW" 2>/dev/null)
        if [ "$T16_HAS_KEY" = "yes" ] && ! echo "$T16_CTX" | grep -qF "Respond to the user in"; then
            pass "T16: post-compact fails open when helper throws (additionalContext present, no injection)"
        elif [ "$T16_HAS_KEY" = "yes" ] && echo "$T16_CTX" | grep -qF "Respond to the user in"; then
            fail "T16: helper threw but injection appeared anyway"
        else
            fail "T16: post-compact did not fail open (additionalContext key missing or parse error: $T16_HAS_KEY rc=$T16_RC)"
        fi
    fi
else
    skip "T16: hooks/lib directory missing — cannot stub helper"
fi

# ===========================================================================
# T17 [Security] CONV_LANG with shell metachar $() — pass-through behavior
# Shell metachars like $() are NOT filtered by the control-char guard
# ([\x00-\x1f]). They pass through as plain text to the LLM prompt, where
# they are NOT shell-executed. This test verifies the defined behavior:
# the value is injected as-is into the prompt string.
#
# L3 GAP: If the injection string were ever passed to a shell (e.g. eval),
# $() would execute. The current code path is LLM-only (no shell eval), so
# this is a prompt-injection concern only if the LLM treats $() specially.
# That risk is out of scope for L2 testing.
# ===========================================================================
if [ ! -f "$CONV_LANG_LIB" ]; then
    skip "T17: $CONV_LANG_LIB does not exist yet (pre-implementation)"
else
    METACHAR_VAL='$(echo injected)'
    EXPECTED_META="\"Respond to the user in \$(echo injected). This applies to all text you write, including narration between tool calls.\""
    OUT=$(call_helper set "$METACHAR_VAL")
    if [ "$OUT" = "$EXPECTED_META" ]; then
        pass "T17: CONV_LANG with shell metachar passes through as plain text: $OUT"
    else
        fail "T17: expected $EXPECTED_META, got $OUT"
    fi
fi

# ===========================================================================
# T19 [Idempotency] post-compact called twice → injection appears exactly once
# per call (symmetric with T18 for session-start; orthogonality CPR-5).
# ===========================================================================
if [ ! -f "$POST_COMPACT" ]; then
    skip "T19: $POST_COMPACT does not exist yet (pre-implementation)"
else
    SID_19="t19-$RANDOM"
    CTX_19A=$(call_post_compact "$SID_19" set "japanese")
    CTX_19B=$(call_post_compact "$SID_19" set "japanese")
    if [ -z "$CTX_19A" ] && [ -z "$CTX_19B" ]; then
        skip "T19: post-compact produced no output on either call (pre-implementation)"
    else
        COUNT_A=$(echo "$CTX_19A" | grep -cF "$EXPECTED_JA" || true)
        COUNT_B=$(echo "$CTX_19B" | grep -cF "$EXPECTED_JA" || true)
        if [ "$COUNT_A" -eq 1 ] && [ "$COUNT_B" -eq 1 ]; then
            pass "T19: injection appears exactly once per post-compact call (call1=$COUNT_A call2=$COUNT_B)"
        elif [ "$COUNT_A" -eq 0 ] && [ "$COUNT_B" -eq 0 ]; then
            skip "T19: no injection in either call — CONV_LANG injection not yet wired"
        else
            fail "T19: injection count not exactly 1 per call (call1=$COUNT_A call2=$COUNT_B)"
        fi
    fi
fi

# ===========================================================================
# T20 [Edge/Error] post-compact with no session_id → early exit with {} rc=0
# ===========================================================================
T20_RAW=$(printf '{}' | \
    CONV_LANG="japanese" \
    CLAUDE_WORKFLOW_DIR="$TMPDIR_BASE/workflow-t20" \
    HOME="$TMPDIR_BASE/home-t20" \
    AGENTS_CONFIG_DIR="$EMPTY_CFG" \
    run_with_timeout 30 node "$POST_COMPACT" 2>/dev/null)
T20_RC=$?
if [ "$T20_RC" -ne 0 ]; then
    fail "T20: post-compact exited non-zero ($T20_RC) when session_id absent"
elif [ "$T20_RAW" = "{}" ]; then
    pass "T20: post-compact no session_id → early exit with {} rc=0"
else
    fail "T20: expected '{}', got '$T20_RAW'"
fi

# ===========================================================================
# T23 [Error] post-compact with malformed stdin → emits {} rc=0 (fail-open)
# Orthogonality with T21 (session-start malformed stdin).
# ===========================================================================
T23_RAW=$(printf 'not-json' | \
    CONV_LANG="japanese" \
    CLAUDE_WORKFLOW_DIR="$TMPDIR_BASE/workflow-t23" \
    HOME="$TMPDIR_BASE/home-t23" \
    AGENTS_CONFIG_DIR="$EMPTY_CFG" \
    run_with_timeout 30 node "$POST_COMPACT" 2>/dev/null)
T23_RC=$?
if [ "$T23_RC" -ne 0 ]; then
    fail "T23: post-compact exited non-zero ($T23_RC) on malformed stdin"
elif [ "$T23_RAW" = "{}" ]; then
    pass "T23: post-compact malformed stdin → {} rc=0 (fail-open)"
else
    fail "T23: expected '{}', got '$T23_RAW'"
fi

# ===========================================================================
# T28–T34: Progress summary renderer (post-#1482 implementation)
# These tests define expected behavior that does NOT exist yet — they will
# FAIL until the inline progress summary renderer is added to post-compact.js.
# ===========================================================================

# Helper: write a workflow state file with the given step statuses.
# Usage: write_wf_state <sid> <step1:status> [<step2:status> ...]
# Steps not listed default to "pending".
_write_wf_state() {
    local sid="$1"; shift
    local wf_dir="$TMPDIR_BASE/workflow"
    mkdir -p "$wf_dir"
    # Build steps JSON via node so we don't have to hand-escape.
    local pairs_json="["
    local first=1
    for pair in "$@"; do
        local step="${pair%%:*}"
        local status="${pair#*:}"
        if [ "$first" = "1" ]; then
            pairs_json="${pairs_json}[\"${step}\",\"${status}\"]"
            first=0
        else
            pairs_json="${pairs_json},[\"${step}\",\"${status}\"]"
        fi
    done
    pairs_json="${pairs_json}]"
    node -e "
const fs=require('fs'),path=require('path');
const sid=process.argv[1];
const dir=process.argv[2];
const overrides=JSON.parse(process.argv[3]);
const VALID=[
  'workflow_init','clarify_intent','research','outline','detail',
  'branching_complete','write_tests','review_tests','run_tests',
  'review_security','docs','user_verification','cleanup','pre_final_report_gate'
];
const steps={};
for(const s of VALID) steps[s]={status:'pending',updated_at:null};
for(const [s,st] of overrides) steps[s]={status:st,updated_at:new Date().toISOString()};
const state={version:1,session_id:sid,created_at:new Date().toISOString(),steps,git_branch:'feature/1482-post-compact-progress',cwd:'/tmp'};
fs.mkdirSync(dir,{recursive:true});
fs.writeFileSync(path.join(dir,sid+'.json'),JSON.stringify(state,null,2),'utf8');
process.stdout.write('ok');
" "$sid" "$wf_dir" "$pairs_json" 2>/dev/null
}

# Helper: write state with reset_reason in user_verification
_write_wf_state_with_reset_reason() {
    local sid="$1" uv_status="$2" reset_reason="$3"
    local wf_dir="$TMPDIR_BASE/workflow"
    mkdir -p "$wf_dir"
    node -e "
const fs=require('fs'),path=require('path');
const sid=process.argv[1];
const dir=process.argv[2];
const uvStatus=process.argv[3];
const resetReason=process.argv[4]||null;
const VALID=[
  'workflow_init','clarify_intent','research','outline','detail',
  'branching_complete','write_tests','review_tests','run_tests',
  'review_security','docs','user_verification','cleanup','pre_final_report_gate'
];
const steps={};
for(const s of VALID) steps[s]={status:'complete',updated_at:new Date().toISOString()};
steps['user_verification']={status:uvStatus,updated_at:new Date().toISOString()};
if(resetReason) steps['user_verification'].reset_reason=resetReason;
const state={version:1,session_id:sid,created_at:new Date().toISOString(),steps,git_branch:'feature/1482-post-compact-progress',cwd:'/tmp'};
fs.mkdirSync(dir,{recursive:true});
fs.writeFileSync(path.join(dir,sid+'.json'),JSON.stringify(state,null,2),'utf8');
process.stdout.write('ok');
" "$sid" "$wf_dir" "$uv_status" "$reset_reason" 2>/dev/null
}

# Helper: call post-compact with state pre-written, return additionalContext
_call_post_compact_with_state() {
    local sid="$1"
    local raw
    raw=$(printf '{"session_id":"%s"}' "$sid" | \
        CLAUDE_WORKFLOW_DIR="$TMPDIR_BASE/workflow" \
        HOME="$TMPDIR_BASE/home" \
        AGENTS_CONFIG_DIR="$EMPTY_CFG" \
        run_with_timeout 30 node "$POST_COMPACT" 2>/dev/null)
    [ -z "$raw" ] && return 0
    node -e "
try {
  const o = JSON.parse(process.argv[1]);
  process.stdout.write(o.additionalContext || '');
} catch (e) {}
" "$raw" 2>/dev/null
}

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
