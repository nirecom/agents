# axis-a.sh — Axis A: Normal / idempotency cases (B-15..B-21)
# Sourced by feature-resolve-session-id-sh.sh; inherits all globals and helpers.

# ===========================================================================
# B-15: wip-state/session-id.sh resolve_session_id — CLAUDE_CODE_SESSION_ID
# beats a newer foreign JSONL (concurrent-session fix, #1082).
# Post-migration: sources WIP_SID_HELPER only; bridge called internally.
# ===========================================================================
setup
if [ ! -f "$WIP_SID_HELPER" ]; then
    fail "B-15: $WIP_SID_HELPER not found"
else
    FAKE_CWD="$TMP/b15-cwd"
    mkdir -p "$FAKE_CWD"
    ENCODED=$(enc "$FAKE_CWD")
    mk_jsonl "$CLAUDE_TRANSCRIPT_BASE_DIR/$ENCODED" "foreign-sid-b15"
    # Make foreign file newer so JSONL scan would return it without P2 guard.
    touch -t 202701010000 "$CLAUDE_TRANSCRIPT_BASE_DIR/$ENCODED/foreign-sid-b15.jsonl"
    OUT=$(bash -c "
        unset CLAUDE_SESSION_ID CLAUDE_ENV_FILE
        export CLAUDE_CODE_SESSION_ID='own-sid-b15'
        export CLAUDE_TRANSCRIPT_BASE_DIR='$CLAUDE_TRANSCRIPT_BASE_DIR'
        export AGENTS_CONFIG_DIR='$AGENTS_DIR'
        cd '$FAKE_CWD'
        source '$WIP_SID_HELPER'
        resolve_session_id
    " 2>/dev/null)
    RC=$?
    if [ "$RC" -eq 0 ] && [ "$OUT" = "own-sid-b15" ]; then
        pass "B-15: resolve_session_id: CLAUDE_CODE_SESSION_ID beats newer foreign JSONL"
    else
        fail "B-15: rc=$RC out='$OUT' expected='own-sid-b15'"
    fi
fi
teardown

# ===========================================================================
# B-16: wip-state/session-id.sh resolve_session_id — CLAUDE_CODE_SESSION_ID
# unset → JSONL fallback still works (no regression for headless/CI).
# B-16 uses a non-git temp CWD; fail-open lets P7 scan proceed.
# ===========================================================================
setup
if [ ! -f "$WIP_SID_HELPER" ]; then
    fail "B-16: $WIP_SID_HELPER not found"
else
    FAKE_CWD="$TMP/b16-cwd"
    mkdir -p "$FAKE_CWD"
    ENCODED=$(enc "$FAKE_CWD")
    mk_jsonl "$CLAUDE_TRANSCRIPT_BASE_DIR/$ENCODED" "headless-sid-b16"
    OUT=$(bash -c "
        unset CLAUDE_SESSION_ID CLAUDE_ENV_FILE CLAUDE_CODE_SESSION_ID
        export CLAUDE_TRANSCRIPT_BASE_DIR='$CLAUDE_TRANSCRIPT_BASE_DIR'
        export AGENTS_CONFIG_DIR='$AGENTS_DIR'
        cd '$FAKE_CWD'
        source '$WIP_SID_HELPER'
        resolve_session_id
    " 2>/dev/null)
    RC=$?
    if [ "$RC" -eq 0 ] && [ "$OUT" = "headless-sid-b16" ]; then
        pass "B-16: resolve_session_id: CLAUDE_CODE_SESSION_ID unset → JSONL fallback no regression"
    else
        fail "B-16: rc=$RC out='$OUT' expected='headless-sid-b16'"
    fi
fi
teardown

# ===========================================================================
# B-17: codex_core_init SESSION_ID — CLAUDE_CODE_SESSION_ID beats newer JSONL.
# ===========================================================================
setup
if [ ! -f "$CODEX_CORE" ]; then
    fail "B-17: $CODEX_CORE not found"
else
    FAKE_CWD="$TMP/b17-cwd"
    mkdir -p "$FAKE_CWD"
    ENCODED=$(enc "$FAKE_CWD")
    mk_jsonl "$CLAUDE_TRANSCRIPT_BASE_DIR/$ENCODED" "foreign-codex-b17"
    touch -t 202701010000 "$CLAUDE_TRANSCRIPT_BASE_DIR/$ENCODED/foreign-codex-b17.jsonl"
    OUT=$(bash -c "
        unset CLAUDE_SESSION_ID CLAUDE_ENV_FILE
        export CLAUDE_CODE_SESSION_ID='own-codex-b17'
        export CLAUDE_TRANSCRIPT_BASE_DIR='$CLAUDE_TRANSCRIPT_BASE_DIR'
        export AGENTS_CONFIG_DIR='$AGENTS_DIR'
        export NO_LOG=true
        cd '$FAKE_CWD'
        source '$CODEX_CORE'
        codex_core_init 'test-label' >/dev/null 2>&1
        printf '%s' \"\$SESSION_ID\"
    " 2>/dev/null)
    if [ "$OUT" = "own-codex-b17" ]; then
        pass "B-17: codex_core_init: CLAUDE_CODE_SESSION_ID beats newer foreign JSONL"
    else
        fail "B-17: out='$OUT' expected='own-codex-b17'"
    fi
fi
teardown

# ===========================================================================
# B-18: gemini_core_init SESSION_ID — CLAUDE_CODE_SESSION_ID beats newer JSONL.
# ===========================================================================
setup
if [ ! -f "$GEMINI_CORE" ]; then
    fail "B-18: $GEMINI_CORE not found"
else
    FAKE_CWD="$TMP/b18-cwd"
    mkdir -p "$FAKE_CWD"
    ENCODED=$(enc "$FAKE_CWD")
    mk_jsonl "$CLAUDE_TRANSCRIPT_BASE_DIR/$ENCODED" "foreign-gemini-b18"
    touch -t 202701010000 "$CLAUDE_TRANSCRIPT_BASE_DIR/$ENCODED/foreign-gemini-b18.jsonl"
    OUT=$(bash -c "
        unset CLAUDE_SESSION_ID CLAUDE_ENV_FILE
        export CLAUDE_CODE_SESSION_ID='own-gemini-b18'
        export CLAUDE_TRANSCRIPT_BASE_DIR='$CLAUDE_TRANSCRIPT_BASE_DIR'
        export AGENTS_CONFIG_DIR='$AGENTS_DIR'
        export NO_LOG=true
        cd '$FAKE_CWD'
        source '$GEMINI_CORE'
        gemini_core_init 'test-label' >/dev/null 2>&1
        printf '%s' \"\$SESSION_ID\"
    " 2>/dev/null)
    if [ "$OUT" = "own-gemini-b18" ]; then
        pass "B-18: gemini_core_init: CLAUDE_CODE_SESSION_ID beats newer foreign JSONL"
    else
        fail "B-18: out='$OUT' expected='own-gemini-b18'"
    fi
fi
teardown

# ===========================================================================
# B-19: bridge — CLAUDE_CODE_SESSION_ID priority (P2); idempotency check.
# Non-git temp CWD; newer foreign JSONL present; bridge must return own SID.
# Called twice to verify identical output (idempotency).
# ===========================================================================
setup
FAKE_CWD="$TMP/b19-cwd"
mkdir -p "$FAKE_CWD"
ENCODED=$(enc "$FAKE_CWD")
mk_jsonl "$CLAUDE_TRANSCRIPT_BASE_DIR/$ENCODED" "foreign-b19"
touch -t 202701010000 "$CLAUDE_TRANSCRIPT_BASE_DIR/$ENCODED/foreign-b19.jsonl"
OUT1=$(bash -c "
    unset CLAUDE_SESSION_ID CLAUDE_ENV_FILE
    export CLAUDE_CODE_SESSION_ID='own-sid-b19'
    export CLAUDE_TRANSCRIPT_BASE_DIR='$CLAUDE_TRANSCRIPT_BASE_DIR'
    export AGENTS_CONFIG_DIR='$AGENTS_DIR'
    cd '$FAKE_CWD'
    bash '$BRIDGE'
" 2>/dev/null)
RC1=$?
OUT2=$(bash -c "
    unset CLAUDE_SESSION_ID CLAUDE_ENV_FILE
    export CLAUDE_CODE_SESSION_ID='own-sid-b19'
    export CLAUDE_TRANSCRIPT_BASE_DIR='$CLAUDE_TRANSCRIPT_BASE_DIR'
    export AGENTS_CONFIG_DIR='$AGENTS_DIR'
    cd '$FAKE_CWD'
    bash '$BRIDGE'
" 2>/dev/null)
RC2=$?
if [ "$RC1" -eq 0 ] && [ "$OUT1" = "own-sid-b19" ] && [ "$RC2" -eq 0 ] && [ "$OUT2" = "own-sid-b19" ]; then
    pass "B-19: bridge CLAUDE_CODE_SESSION_ID priority + idempotency (called twice, same output)"
else
    fail "B-19: rc1=$RC1 out1='$OUT1' rc2=$RC2 out2='$OUT2' expected='own-sid-b19'"
fi
teardown

# ===========================================================================
# B-20: codex_core_init AND gemini_core_init JSONL fallback via bridge.
# All SID env unset, non-git temp CWD, own-repo JSONL present.
# Fail-open in isSameGitRepo admits temp CWD (not a real foreign git repo).
# ===========================================================================
setup
FAKE_CWD="$TMP/b20-cwd"
mkdir -p "$FAKE_CWD"
ENCODED=$(enc "$FAKE_CWD")
mk_jsonl "$CLAUDE_TRANSCRIPT_BASE_DIR/$ENCODED" "jsonl-sid-b20"

if [ ! -f "$CODEX_CORE" ]; then
    fail "B-20a: $CODEX_CORE not found"
else
    OUT=$(bash -c "
        unset CLAUDE_SESSION_ID CLAUDE_ENV_FILE CLAUDE_CODE_SESSION_ID
        export CLAUDE_TRANSCRIPT_BASE_DIR='$CLAUDE_TRANSCRIPT_BASE_DIR'
        export AGENTS_CONFIG_DIR='$AGENTS_DIR'
        export NO_LOG=true
        cd '$FAKE_CWD'
        source '$CODEX_CORE'
        codex_core_init 'test-label' >/dev/null 2>&1
        printf '%s' \"\$SESSION_ID\"
    " 2>/dev/null)
    if [ "$OUT" = "jsonl-sid-b20" ]; then
        pass "B-20a: codex_core_init JSONL fallback via bridge (fail-open admits temp CWD)"
    else
        fail "B-20a: out='$OUT' expected='jsonl-sid-b20'"
    fi
fi

if [ ! -f "$GEMINI_CORE" ]; then
    fail "B-20b: $GEMINI_CORE not found"
else
    OUT=$(bash -c "
        unset CLAUDE_SESSION_ID CLAUDE_ENV_FILE CLAUDE_CODE_SESSION_ID
        export CLAUDE_TRANSCRIPT_BASE_DIR='$CLAUDE_TRANSCRIPT_BASE_DIR'
        export AGENTS_CONFIG_DIR='$AGENTS_DIR'
        export NO_LOG=true
        cd '$FAKE_CWD'
        source '$GEMINI_CORE'
        gemini_core_init 'test-label' >/dev/null 2>&1
        printf '%s' \"\$SESSION_ID\"
    " 2>/dev/null)
    if [ "$OUT" = "jsonl-sid-b20" ]; then
        pass "B-20b: gemini_core_init JSONL fallback via bridge (fail-open admits temp CWD)"
    else
        fail "B-20b: out='$OUT' expected='jsonl-sid-b20'"
    fi
fi
teardown

# ===========================================================================
# B-21: aggregate-wip-check.sh SID injection via bridge.
# aggregate-wip-check.sh resolves the bridge SCRIPT-RELATIVELY (from its own
# location in the real worktree), so the real bridge is always exercised — no
# fixture bridge is created. The fake AGENTS_CONFIG_DIR tree exists ONLY to
# intercept the wip-state.sh dispatch (that lookup is env-based by design).
# wip-set-resume.sh SID block is symmetric to B-21a (Skipped-Because below).
# ===========================================================================
setup
FIXTURE_DIR="$TMP/b21-fixture"
mkdir -p "$FIXTURE_DIR/bin/github-issues"

# Fake wip-state.sh: capture args to file, echo "none".
CAPTURE_FILE_CHECK="$TMP/b21-check-capture.txt"
cat > "$FIXTURE_DIR/bin/github-issues/wip-state.sh" <<WIP_EOF
#!/bin/bash
CMD="\$1"; shift
case "\$CMD" in
    check) printf '%s\n' "\$*" >> '$CAPTURE_FILE_CHECK'; echo "none" ;;
    *)     echo "none" ;;
esac
WIP_EOF
chmod +x "$FIXTURE_DIR/bin/github-issues/wip-state.sh"

REAL_AGG="$AGENTS_DIR/skills/workflow-init/scripts/aggregate-wip-check.sh"
if [ ! -f "$REAL_AGG" ]; then
    fail "B-21a: aggregate-wip-check.sh not found"
else
    OUT=$(bash -c "
        unset CLAUDE_SESSION_ID CLAUDE_ENV_FILE
        export CLAUDE_CODE_SESSION_ID='own-sid-b21'
        export CLAUDE_TRANSCRIPT_BASE_DIR='$CLAUDE_TRANSCRIPT_BASE_DIR'
        export AGENTS_CONFIG_DIR='$FIXTURE_DIR'
        bash '$REAL_AGG' 42
    " 2>/dev/null)
    # NOTE: with every check returning "none", aggregate-wip-check.sh emits
    # "ALL_SAME none" (the all_same branch precedes ALL_NONE, which is
    # unreachable for uniform results) — scratch-validated against the real script.
    if [ "$OUT" = "ALL_SAME none" ] && grep -q "\-\-session-id own-sid-b21" "$CAPTURE_FILE_CHECK" 2>/dev/null; then
        pass "B-21a: aggregate-wip-check.sh passes --session-id via bridge (CLAUDE_CODE_SESSION_ID=own-sid-b21)"
    else
        fail "B-21a: out='$OUT' capture='$(cat "$CAPTURE_FILE_CHECK" 2>/dev/null)' expected 'ALL_SAME none' + --session-id"
    fi
fi

# SKIPPED: B-21b wip-set-resume.sh full two-pass flow (label probe + WIP set).
# Because: requires live gh/GitHub API or an elaborate multi-script fixture
# (jq, gh, wip-set-single.sh). The SID injection block is structurally
# symmetric to aggregate-wip-check.sh, asserted by B-21a. No pass/fail emitted.
# L3 gap: see dispatcher header — wip-set-resume.sh full two-pass flow.
teardown

# ===========================================================================
# B-35: P7 mtime ordering — newest JSONL basename wins.
# Two JSONL files in the encoded-CWD transcript dir with distinct mtimes;
# the bridge must print the newer one.
# ===========================================================================
setup
FAKE_CWD="$TMP/b35-cwd"
mkdir -p "$FAKE_CWD"
DIR_B35="$CLAUDE_TRANSCRIPT_BASE_DIR/$(enc "$FAKE_CWD")"
mkdir -p "$DIR_B35"
echo "{}" > "$DIR_B35/old-sid-b35.jsonl"
touch -t 202001010000 "$DIR_B35/old-sid-b35.jsonl"
echo "{}" > "$DIR_B35/new-sid-b35.jsonl"
touch -t 202601010000 "$DIR_B35/new-sid-b35.jsonl"
run_bridge "$FAKE_CWD"
if [ "$BRIDGE_RC" -eq 0 ] && [ "$BRIDGE_OUT" = "new-sid-b35" ]; then
    pass "B-35: bridge P7 returns mtime-newest JSONL basename (new-sid-b35)"
else
    fail "B-35: rc=$BRIDGE_RC out='$BRIDGE_OUT' expected='new-sid-b35'"
fi
teardown
