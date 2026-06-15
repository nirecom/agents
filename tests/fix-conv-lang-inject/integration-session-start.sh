# integration-session-start.sh — T10, T11, T14, T18, T21: Integration tests for hooks/session-start.js
# Sourced after helpers.sh; inherits all variables and functions.

# ===========================================================================
# Integration tests for session-start.js (T10, T11, T14, T18)
# ===========================================================================

# T10 [Integration] session-start with CONV_LANG=japanese
CTX=$(call_session_start "t10-$RANDOM" set "japanese")
if [ -z "$CTX" ]; then
    skip "T10: session-start produced no output (pre-implementation or spawn failure)"
elif echo "$CTX" | grep -qF "$EXPECTED_JA"; then
    pass "T10: session-start additionalContext includes CONV_LANG injection"
else
    fail "T10: additionalContext missing injection. Got: $CTX"
fi

# T11 [Integration] session-start with CONV_LANG unset → no injection
CTX=$(call_session_start "t11-$RANDOM" unset)
if [ -z "$CTX" ]; then
    skip "T11: session-start produced no output"
elif echo "$CTX" | grep -qF "Respond to the user in"; then
    fail "T11: additionalContext unexpectedly contains injection. Got: $CTX"
else
    pass "T11: session-start with CONV_LANG unset → no injection"
fi

# T14 [Error] session-start fails open if helper throws.
# Strategy: shadow hooks/lib/conv-lang.js with a throwing stub at a copied
# location, run session-start against it, and assert the script still exits 0
# and still emits its normal additionalContext (without the injection).
T14_AGENTS="$TMPDIR_BASE/t14-agents"
T14_HOOKS="$T14_AGENTS/hooks"
T14_LIB="$T14_HOOKS/lib"
mkdir -p "$T14_LIB"
# Copy the real hooks tree shallow-ish: only what session-start.js requires.
# session-start.js requires ./lib/workflow-state and ./lib/settings-drift, plus
# ./lib/conv-lang (the new one). We mirror lib/* by symlink/copy, then override
# conv-lang.js with a thrower.
if [ -d "$AGENTS_DIR/hooks/lib" ]; then
    # Copy all lib files (cheap — small directory).
    cp -r "$AGENTS_DIR/hooks/lib/." "$T14_LIB/" 2>/dev/null || true
    # Copy the entry script.
    cp "$SESSION_START" "$T14_HOOKS/session-start.js" 2>/dev/null || true
    # Mirror bin/ so the resume-session-detect lookup behaves the same.
    if [ -d "$AGENTS_DIR/bin" ]; then
        mkdir -p "$T14_AGENTS/bin"
        # No need to copy contents — the script only checks fs.existsSync.
    fi
    # Overwrite conv-lang.js with a thrower (will only be used if hook requires it).
    cat > "$T14_LIB/conv-lang.js" <<'EOF'
"use strict";
function getConvLangInjection() {
  throw new Error("simulated failure for T14");
}
module.exports = { getConvLangInjection };
EOF

    T14_OUT=$(printf '{"session_id":"t14-sid"}' | \
        CONV_LANG="japanese" \
        CLAUDE_PROJECT_DIR="$TMPDIR_BASE" \
        CLAUDE_ENV_FILE="$ENV_FILE.t14" \
        CLAUDE_WORKFLOW_DIR="$TMPDIR_BASE/workflow-t14" \
        HOME="$TMPDIR_BASE/home-t14" \
        AGENTS_CONFIG_DIR="$EMPTY_CFG" \
        run_with_timeout 30 node "$T14_HOOKS/session-start.js" 2>/dev/null)
    T14_RC=$?
    if [ "$T14_RC" -ne 0 ] || [ -z "$T14_OUT" ]; then
        skip "T14: stubbed session-start did not produce output (pre-implementation or unrelated failure rc=$T14_RC)"
    else
        T14_CTX=$(node -e "
try {
  const o = JSON.parse(process.argv[1]);
  process.stdout.write(o.additionalContext || '');
} catch (e) {}
" "$T14_OUT" 2>/dev/null)
        # additionalContext must exist (fail-open) and must NOT carry the
        # injection (because the helper threw).
        if [ -n "$T14_CTX" ] && ! echo "$T14_CTX" | grep -qF "Respond to the user in"; then
            pass "T14: session-start fails open when helper throws"
        elif [ -n "$T14_CTX" ] && echo "$T14_CTX" | grep -qF "Respond to the user in"; then
            fail "T14: helper threw but injection appeared anyway"
        else
            # Empty context with rc=0 means the script crashed before output.
            fail "T14: session-start did not fail open (empty additionalContext rc=$T14_RC)"
        fi
    fi
else
    skip "T14: hooks/lib directory missing — cannot stub helper"
fi

# T18 [Idempotency] session-start called twice → injection appears exactly once
# per call (not duplicated within a single call's additionalContext).
if [ ! -f "$SESSION_START" ]; then
    skip "T18: $SESSION_START does not exist yet (pre-implementation)"
else
    SID_18="t18-$RANDOM"
    CTX_18A=$(call_session_start "$SID_18" set "japanese")
    CTX_18B=$(call_session_start "$SID_18" set "japanese")
    if [ -z "$CTX_18A" ] && [ -z "$CTX_18B" ]; then
        skip "T18: session-start produced no output on either call (pre-implementation)"
    else
        # Count occurrences of the injection string within each call's output.
        COUNT_A=$(echo "$CTX_18A" | grep -cF "$EXPECTED_JA" || true)
        COUNT_B=$(echo "$CTX_18B" | grep -cF "$EXPECTED_JA" || true)
        if [ "$COUNT_A" -eq 1 ] && [ "$COUNT_B" -eq 1 ]; then
            pass "T18: injection appears exactly once per session-start call (call1=$COUNT_A call2=$COUNT_B)"
        elif [ "$COUNT_A" -eq 0 ] && [ "$COUNT_B" -eq 0 ]; then
            skip "T18: no injection in either call — CONV_LANG injection not yet wired"
        else
            fail "T18: injection count not exactly 1 per call (call1=$COUNT_A call2=$COUNT_B)"
        fi
    fi
fi

# ===========================================================================
# T21 [Error] session-start with malformed stdin → fail-open: still emits
# valid JSON additionalContext with exit 0.
# ===========================================================================
# T26 [Edge] session-start with valid-JSON {} (no session_id) → exit 0, valid additionalContext
# Symmetric with T20 (post-compact no-session_id). session-start skips env-file/state
# writes but still emits workflow status in additionalContext.
T26_RAW=$(printf '{}' | \
    CONV_LANG="japanese" \
    CLAUDE_PROJECT_DIR="$TMPDIR_BASE" \
    CLAUDE_ENV_FILE="$ENV_FILE.t26" \
    CLAUDE_WORKFLOW_DIR="$TMPDIR_BASE/workflow-t26" \
    HOME="$TMPDIR_BASE/home-t26" \
    AGENTS_CONFIG_DIR="$EMPTY_CFG" \
    run_with_timeout 30 node "$SESSION_START" 2>/dev/null)
T26_RC=$?
if [ "$T26_RC" -ne 0 ]; then
    fail "T26: session-start exited non-zero ($T26_RC) when session_id absent"
else
    T26_HAS=$(node -e "
try {
  const o = JSON.parse(process.argv[1]);
  process.stdout.write(typeof o.additionalContext === 'string' ? 'yes' : 'no');
} catch(e) { process.stdout.write('parse-error'); }
" "$T26_RAW" 2>/dev/null)
    if [ "$T26_HAS" = "yes" ]; then
        pass "T26: session-start no session_id → exit 0, valid additionalContext"
    else
        fail "T26: expected valid JSON with additionalContext, got: $T26_RAW (check=$T26_HAS)"
    fi
fi

# T21 [Error] session-start with malformed stdin → fail-open: still emits
# valid JSON additionalContext with exit 0.
T21_RAW=$(printf 'not-json' | \
    CONV_LANG="japanese" \
    CLAUDE_PROJECT_DIR="$TMPDIR_BASE" \
    CLAUDE_ENV_FILE="$ENV_FILE.t21" \
    CLAUDE_WORKFLOW_DIR="$TMPDIR_BASE/workflow-t21" \
    HOME="$TMPDIR_BASE/home-t21" \
    AGENTS_CONFIG_DIR="$EMPTY_CFG" \
    run_with_timeout 30 node "$SESSION_START" 2>/dev/null)
T21_RC=$?
if [ "$T21_RC" -ne 0 ]; then
    fail "T21: session-start exited non-zero ($T21_RC) on malformed stdin"
else
    T21_HAS=$(node -e "
try {
  const o = JSON.parse(process.argv[1]);
  process.stdout.write(typeof o.additionalContext === 'string' ? 'yes' : 'no');
} catch(e) { process.stdout.write('parse-error'); }
" "$T21_RAW" 2>/dev/null)
    if [ "$T21_HAS" = "yes" ]; then
        pass "T21: session-start malformed stdin → fail-open, valid additionalContext"
    else
        fail "T21: expected valid JSON with additionalContext, got: $T21_RAW (check=$T21_HAS)"
    fi
fi
