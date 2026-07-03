# axis-c.sh — Axis C: Error / fallback / resolution-chain cases (B-23..B-25, B-31..B-34)
# Sourced by feature-resolve-session-id-sh.sh; inherits all globals and helpers.

# ===========================================================================
# B-23: bridge rc=2 + stderr when all SID sources absent and transcript base empty.
# Must run from non-git temp CWD with no WORKTREE_NOTES.md up its git chain.
# ===========================================================================
setup
NONGIT_CWD="$TMP/b23-nongit"
mkdir -p "$NONGIT_CWD"
STDERR_OUT=$(bash -c "
    unset CLAUDE_SESSION_ID CLAUDE_ENV_FILE CLAUDE_CODE_SESSION_ID
    export CLAUDE_TRANSCRIPT_BASE_DIR='$CLAUDE_TRANSCRIPT_BASE_DIR'
    export AGENTS_CONFIG_DIR='$AGENTS_DIR'
    cd '$NONGIT_CWD'
    bash '$BRIDGE'
" 2>&1 >/dev/null)
RC=$?
if [ "$RC" -eq 2 ] && echo "$STDERR_OUT" | grep -q "resolve-session-id"; then
    pass "B-23: bridge rc=2 + stderr contains 'resolve-session-id' when unresolvable"
else
    fail "B-23: rc=$RC stderr='$STDERR_OUT' (expected rc=2, stderr with 'resolve-session-id')"
fi
teardown

# ===========================================================================
# B-24: codex_core_init AND gemini_core_init timestamp fallback when all SID
# sources absent and transcript base empty.
# ===========================================================================
setup
NONGIT_CWD="$TMP/b24-nongit"
mkdir -p "$NONGIT_CWD"

if [ ! -f "$CODEX_CORE" ]; then
    fail "B-24a: $CODEX_CORE not found"
else
    OUT=$(bash -c "
        unset CLAUDE_SESSION_ID CLAUDE_ENV_FILE CLAUDE_CODE_SESSION_ID
        export CLAUDE_TRANSCRIPT_BASE_DIR='$CLAUDE_TRANSCRIPT_BASE_DIR'
        export AGENTS_CONFIG_DIR='$AGENTS_DIR'
        export NO_LOG=true
        cd '$NONGIT_CWD'
        source '$CODEX_CORE'
        codex_core_init 'test-label' >/dev/null 2>&1
        printf '%s' \"\$SESSION_ID\"
    " 2>/dev/null)
    if echo "$OUT" | grep -qE '^[0-9]{8}_[0-9]{6}$'; then
        pass "B-24a: codex_core_init timestamp fallback when bridge unresolvable (SESSION_ID=$OUT)"
    else
        fail "B-24a: out='$OUT' expected YYYYMMDD_HHMMSS pattern"
    fi
fi

if [ ! -f "$GEMINI_CORE" ]; then
    fail "B-24b: $GEMINI_CORE not found"
else
    OUT=$(bash -c "
        unset CLAUDE_SESSION_ID CLAUDE_ENV_FILE CLAUDE_CODE_SESSION_ID
        export CLAUDE_TRANSCRIPT_BASE_DIR='$CLAUDE_TRANSCRIPT_BASE_DIR'
        export AGENTS_CONFIG_DIR='$AGENTS_DIR'
        export NO_LOG=true
        cd '$NONGIT_CWD'
        source '$GEMINI_CORE'
        gemini_core_init 'test-label' >/dev/null 2>&1
        printf '%s' \"\$SESSION_ID\"
    " 2>/dev/null)
    if echo "$OUT" | grep -qE '^[0-9]{8}_[0-9]{6}$'; then
        pass "B-24b: gemini_core_init timestamp fallback when bridge unresolvable (SESSION_ID=$OUT)"
    else
        fail "B-24b: out='$OUT' expected YYYYMMDD_HHMMSS pattern"
    fi
fi
teardown

# ===========================================================================
# B-25: aggregate-wip-check.sh graceful degradation when SID is UNRESOLVABLE.
# Since #1251 the script locates the bridge SCRIPT-RELATIVELY (BASH_SOURCE),
# so the bridge is always present regardless of AGENTS_CONFIG_DIR — the old
# "bridge absent from fixture AGENTS_CONFIG_DIR tree" premise is obsolete.
# Instead, fully isolate every SID source in the child env (no P2/P3/P4 env,
# empty transcript base, non-git CWD so P6/P7 fail): the real bridge returns
# rc=2 → SID_SET stays 0 → no --session-id, and the script must not abort.
# The fake wip-state.sh capture tree still dispatches via AGENTS_CONFIG_DIR
# (that dispatch is env-based by design).
# ===========================================================================
setup
FIXTURE_DIR="$TMP/b25-fixture"
mkdir -p "$FIXTURE_DIR/bin/github-issues"

CAPTURE_FILE="$TMP/b25-capture.txt"
cat > "$FIXTURE_DIR/bin/github-issues/wip-state.sh" <<WIP_EOF
#!/bin/bash
CMD="\$1"; shift
case "\$CMD" in
    check) printf '%s\n' "\$*" >> '$CAPTURE_FILE'; echo "none" ;;
    *)     echo "none" ;;
esac
WIP_EOF
chmod +x "$FIXTURE_DIR/bin/github-issues/wip-state.sh"

NONGIT_CWD="$TMP/b25-nongit"
mkdir -p "$NONGIT_CWD"

REAL_AGG="$AGENTS_DIR/skills/workflow-init/scripts/aggregate-wip-check.sh"
if [ ! -f "$REAL_AGG" ]; then
    fail "B-25: aggregate-wip-check.sh not found"
else
    OUT=$(bash -c "
        unset CLAUDE_SESSION_ID CLAUDE_ENV_FILE CLAUDE_CODE_SESSION_ID
        export CLAUDE_TRANSCRIPT_BASE_DIR='$CLAUDE_TRANSCRIPT_BASE_DIR'
        export AGENTS_CONFIG_DIR='$FIXTURE_DIR'
        cd '$NONGIT_CWD'
        bash '$REAL_AGG' 99
    " 2>/dev/null)
    CAPTURE=$(cat "$CAPTURE_FILE" 2>/dev/null || echo "")
    # Script must not abort; capture must NOT have --session-id. Output is
    # "ALL_SAME none" — uniform "none" results take the all_same branch
    # (ALL_NONE unreachable there; scratch-validated against the real script).
    if [ "$OUT" = "ALL_SAME none" ] && ! echo "$CAPTURE" | grep -q "\-\-session-id"; then
        pass "B-25: aggregate-wip-check.sh degrades gracefully (no --session-id, no abort) when SID unresolvable"
    else
        fail "B-25: out='$OUT' capture='$CAPTURE' (expected 'ALL_SAME none', no --session-id)"
    fi
fi
teardown

# ===========================================================================
# B-31: P3 — CLAUDE_ENV_FILE (KEY=VALUE) provides the SID when P2 is unset.
# ===========================================================================
setup
ENVFILE_B31="$TMP/b31-envfile"
printf 'CLAUDE_SESSION_ID=envfile-sid-b31\n' > "$ENVFILE_B31"
NONGIT_CWD="$TMP/b31-nongit"
mkdir -p "$NONGIT_CWD"
run_bridge "$NONGIT_CWD" "CLAUDE_ENV_FILE=$ENVFILE_B31"
if [ "$BRIDGE_RC" -eq 0 ] && [ "$BRIDGE_OUT" = "envfile-sid-b31" ]; then
    pass "B-31: bridge P3 reads CLAUDE_SESSION_ID from KEY=VALUE CLAUDE_ENV_FILE"
else
    fail "B-31: rc=$BRIDGE_RC out='$BRIDGE_OUT' expected='envfile-sid-b31'"
fi
teardown

# ===========================================================================
# B-32: P4 — CLAUDE_SESSION_ID env var when P2 and P3 are unset.
# ===========================================================================
setup
NONGIT_CWD="$TMP/b32-nongit"
mkdir -p "$NONGIT_CWD"
run_bridge "$NONGIT_CWD" "CLAUDE_SESSION_ID=envvar-sid-b32"
if [ "$BRIDGE_RC" -eq 0 ] && [ "$BRIDGE_OUT" = "envvar-sid-b32" ]; then
    pass "B-32: bridge P4 falls back to CLAUDE_SESSION_ID env var"
else
    fail "B-32: rc=$BRIDGE_RC out='$BRIDGE_OUT' expected='envvar-sid-b32'"
fi
teardown

# ===========================================================================
# B-33: P6 — WORKTREE_NOTES.md Session-ID line read from CWD.
# P6 reads WORKTREE_NOTES.md from CWD before the git-common-dir probe,
# so a plain non-git temp dir works.
# ===========================================================================
setup
NOTES_CWD="$TMP/b33-notes-cwd"
mkdir -p "$NOTES_CWD"
printf 'Session-ID: notes-sid-b33\n' > "$NOTES_CWD/WORKTREE_NOTES.md"
run_bridge "$NOTES_CWD"
if [ "$BRIDGE_RC" -eq 0 ] && [ "$BRIDGE_OUT" = "notes-sid-b33" ]; then
    pass "B-33: bridge P6 reads WORKTREE_NOTES.md Session-ID line from CWD"
else
    fail "B-33: rc=$BRIDGE_RC out='$BRIDGE_OUT' expected='notes-sid-b33'"
fi
teardown

# ===========================================================================
# B-34: invalid CLAUDE_CODE_SESSION_ID falls through to P4 (table-driven).
# P2 gate: value must be non-empty and match ^[A-Za-z0-9_-]+$ after trim.
# Empty / whitespace-only / charset-invalid values must NOT be returned —
# the chain falls to CLAUDE_SESSION_ID (P4) which holds a valid fallback.
# ===========================================================================
setup
NONGIT_CWD="$TMP/b34-nongit"
mkdir -p "$NONGIT_CWD"
while IFS='|' read -r row_name p2_val; do
    [[ -z "$row_name" || "$row_name" =~ ^[[:space:]]*# ]] && continue
    row_name="${row_name//[[:space:]]/}"
    p2_val="${p2_val# }"
    # <spaces> placeholder — literal trailing whitespace in a heredoc is fragile.
    [ "$p2_val" = "<spaces>" ] && p2_val="   "
    run_bridge "$NONGIT_CWD" "CLAUDE_CODE_SESSION_ID=$p2_val" "CLAUDE_SESSION_ID=fallback-sid-b34"
    if [ "$BRIDGE_RC" -eq 0 ] && [ "$BRIDGE_OUT" = "fallback-sid-b34" ]; then
        pass "B-34/$row_name: invalid P2 value falls through to P4 (fallback-sid-b34)"
    else
        fail "B-34/$row_name: rc=$BRIDGE_RC out='$BRIDGE_OUT' expected='fallback-sid-b34' (P2 value must not leak)"
    fi
done <<'TABLE'
empty           |
whitespace-only | <spaces>
charset-invalid | bad/sid-b34
TABLE
teardown
