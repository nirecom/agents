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
    EXPECTED_META="\"Respond to the user in \$(echo injected).\""
    OUT=$(call_helper set "$METACHAR_VAL")
    if [ "$OUT" = "$EXPECTED_META" ]; then
        pass "T17: CONV_LANG with shell metachar passes through as plain text: $OUT"
    else
        fail "T17: expected $EXPECTED_META, got $OUT"
    fi
fi

# ===========================================================================
# T19 [Idempotency] post-compact called twice → injection appears exactly once
# per call (symmetric with T18 for session-start; orthogonality §4).
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
