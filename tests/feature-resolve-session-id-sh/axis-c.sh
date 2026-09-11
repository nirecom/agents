# Tests: bin/resolve-session-id, hooks/workflow-state/session-id.js
# Tags: scope:common, session-id
# axis-c.sh — Axis C: Error / fallback / resolution-chain cases (B-23..B-25, B-32, B-34)
# Sourced by feature-resolve-session-id-sh.sh; inherits all globals and helpers.

# B-23: bridge rc=2 + stderr when all SID sources absent, non-git temp CWD, no
# WORKTREE_NOTES.md up-chain. stdout emptiness + "session id unresolvable"
# wording distinguish rc 2 ("no session") from the rc 3 resolver fault (B-23b).
setup
NONGIT_CWD="$TMP/b23-nongit"
mkdir -p "$NONGIT_CWD"
B23_ERR="$TMP/b23.err"
STDOUT_OUT=$(bash -c "
    unset CLAUDE_SESSION_ID CLAUDE_ENV_FILE CLAUDE_CODE_SESSION_ID
    export CLAUDE_TRANSCRIPT_BASE_DIR='$CLAUDE_TRANSCRIPT_BASE_DIR'
    export AGENTS_CONFIG_DIR='$AGENTS_DIR'
    cd '$NONGIT_CWD'
    bash '$BRIDGE'
" 2>"$B23_ERR")
RC=$?
STDERR_OUT=$(cat "$B23_ERR")
if [ "$RC" -eq 2 ] && [ -z "$STDOUT_OUT" ] \
    && echo "$STDERR_OUT" | grep -q "resolve-session-id" \
    && echo "$STDERR_OUT" | grep -q "session id unresolvable"; then
    pass "B-23: bridge rc=2 + empty stdout + 'session id unresolvable' on stderr"
else
    fail "B-23: rc=$RC out='$STDOUT_OUT' stderr='$STDERR_OUT' (expected rc=2, empty stdout, stderr with 'session id unresolvable')"
fi
teardown

# ===========================================================================
# B-23b: resolver throw -> rc=3, empty stdout, stderr names the fault.
# rc 3 is what stops a resolver fault from masquerading as "no session": the
# sweep and off-clearance receivers delete/mint on exactly that distinction.
# The bridge requires hooks/workflow-state relative to its own directory, so a
# copy of the real bridge beside a throwing stub module reaches the catch path
# without touching the real resolver.
# ===========================================================================
setup
B23B="$TMP/b23b"
mkdir -p "$B23B/bin" "$B23B/hooks/workflow-state"
cp "$BRIDGE" "$B23B/bin/resolve-session-id"
printf 'module.exports = { resolveSessionId() { throw new Error("boom"); } };\n' \
    > "$B23B/hooks/workflow-state/index.js"
B23B_ERR="$TMP/b23b.err"
B23B_OUT=$(bash -c "
    unset CLAUDE_SESSION_ID CLAUDE_ENV_FILE CLAUDE_CODE_SESSION_ID
    export CLAUDE_TRANSCRIPT_BASE_DIR='$CLAUDE_TRANSCRIPT_BASE_DIR'
    export AGENTS_CONFIG_DIR='$AGENTS_DIR'
    bash '$B23B/bin/resolve-session-id'
" 2>"$B23B_ERR")
RC=$?
B23B_ERR_TEXT=$(cat "$B23B_ERR")
if [ "$RC" -eq 3 ] && [ -z "$B23B_OUT" ] \
    && echo "$B23B_ERR_TEXT" | grep -q "resolve-session-id: resolver failed: boom"; then
    pass "B-23b: resolver throw -> rc=3, empty stdout, 'resolver failed: boom' on stderr"
else
    fail "B-23b: rc=$RC out='$B23B_OUT' stderr='$B23B_ERR_TEXT' (expected rc=3, empty stdout, 'resolve-session-id: resolver failed: boom')"
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
# B-25: driver wip-check phase graceful degradation when SID is UNRESOLVABLE.
# When all SID sources are absent (no P2/P3/P4 env, empty transcript base,
# non-git CWD), resolve-session-id returns rc=2 → driver falls back to
# spawning resolve-session-id but must not abort. The driver should proceed
# without --session-id in the wip-state.sh call.
# ===========================================================================
DRIVER="$AGENTS_DIR/bin/workflow/workflow-init-driver"
if [ ! -f "$DRIVER" ]; then
    fail "B-25: bin/workflow/workflow-init-driver not found"
else
    B25_TMP="$(mktemp -d 2>/dev/null || mktemp -d -t b25drv)"
    B25_PLANS="$B25_TMP/plans"
    B25_CFG="$B25_TMP/cfg"
    B25_MOCKBIN="$B25_TMP/bin"
    B25_RESP="$B25_TMP/resp"
    B25_WIPD="$B25_TMP/wip"
    B25_CAPTURE="$B25_TMP/wip-capture.txt"
    mkdir -p "$B25_PLANS" "$B25_MOCKBIN" "$B25_RESP" "$B25_WIPD" \
        "$B25_CFG/bin/github-issues" "$B25_CFG/hooks/lib" \
        "$B25_CFG/skills/workflow-init/scripts"
    # gh mock: return issue JSON for #99
    cat > "$B25_MOCKBIN/gh" <<GHEOF
#!/bin/bash
RESP="$B25_RESP"
cmd="\${1:-}"; sub="\${2:-}"
if [ "\$cmd" = "issue" ] && [ "\$sub" = "view" ]; then
    shift 2; N=""
    while [ \$# -gt 0 ]; do
        case "\$1" in
            --repo|--json|--jq) if [ \$# -ge 2 ]; then shift 2; else shift; fi ;;
            -*) shift ;;
            *) [ -z "\$N" ] && N="\$1"; shift ;;
        esac
    done
    N="\${N#\#}"
    if [ -f "\$RESP/issue-view-\$N.json" ]; then cat "\$RESP/issue-view-\$N.json"; exit 0; fi
    exit 1
fi
if [ "\$cmd" = "repo" ] && [ "\$sub" = "view" ]; then echo "mockorg/mockrepo"; exit 0; fi
if [ "\$cmd" = "api" ]; then echo "[]"; exit 0; fi
exit 0
GHEOF
    chmod +x "$B25_MOCKBIN/gh"
    printf '{"number":99,"title":"T","body":"B","labels":[{"name":"type:task"}],"state":"OPEN","createdAt":"2026-01-01T00:00:00Z"}\n' \
        > "$B25_RESP/issue-view-99.json"
    # wip-state.sh mock: capture args, return "same"
    cat > "$B25_CFG/bin/github-issues/wip-state.sh" <<WIPEOF
#!/bin/bash
CMD="\$1"; shift
case "\$CMD" in
    check) printf '%s\n' "\$*" >> '$B25_CAPTURE'; echo "same" ;;
    set)   exit 0 ;;
    *)     exit 0 ;;
esac
WIPEOF
    chmod +x "$B25_CFG/bin/github-issues/wip-state.sh"
    # resolve-session-id: fail (simulate unresolvable SID)
    printf '#!/bin/bash\necho "SID unresolvable" >&2\nexit 2\n' > "$B25_CFG/bin/resolve-session-id"
    chmod +x "$B25_CFG/bin/resolve-session-id"
    # parse-issue-tokens
    cp "$AGENTS_DIR/bin/parse-issue-tokens" "$B25_CFG/bin/parse-issue-tokens"
    cp "$AGENTS_DIR/hooks/lib/parse-closes-issues.js" "$B25_CFG/hooks/lib/parse-closes-issues.js"
    # filter-init-candidates passthrough
    cat > "$B25_CFG/skills/workflow-init/scripts/filter-init-candidates.sh" <<'FEOF'
#!/bin/bash
while [ $# -gt 0 ]; do
    case "$1" in --repo-map) shift 2 ;; -*) shift ;; *) echo "#${1#\#}"; shift ;; esac
done
exit 0
FEOF
    chmod +x "$B25_CFG/bin/parse-issue-tokens" \
        "$B25_CFG/skills/workflow-init/scripts/filter-init-candidates.sh"

    : > "$B25_CAPTURE"
    B25_NONGIT="$B25_TMP/nongit"
    mkdir -p "$B25_NONGIT"
    ORIG_PATH_B25="$PATH"
    export PATH="$B25_MOCKBIN:$PATH"
    B25_OUT=$(bash -c "
        unset CLAUDE_SESSION_ID CLAUDE_ENV_FILE CLAUDE_CODE_SESSION_ID 2>/dev/null || true
        export WORKFLOW_PLANS_DIR='$B25_PLANS'
        export AGENTS_CONFIG_DIR='$B25_CFG'
        export CLAUDE_TRANSCRIPT_BASE_DIR='$B25_TMP/transcripts'
        mkdir -p '$B25_TMP/transcripts'
        cd '$B25_NONGIT'
        node '$DRIVER' '#99'
    " 2>/dev/null)
    B25_RC=$?
    export PATH="$ORIG_PATH_B25"
    B25_CAPTURE_CONTENT=$(cat "$B25_CAPTURE" 2>/dev/null || echo "")
    # Driver must not abort (ACTION=done or ask_user is acceptable); must not pass --session-id
    if [ "$B25_RC" -eq 0 ] && ! echo "$B25_CAPTURE_CONTENT" | grep -q "\-\-session-id"; then
        pass "B-25: driver wip-check degrades gracefully (no --session-id, no abort) when SID unresolvable"
    else
        fail "B-25: rc=$B25_RC capture='$B25_CAPTURE_CONTENT' (expected rc=0, no --session-id in wip-state call)"
    fi
    rm -rf "$B25_TMP" 2>/dev/null || true
fi

# ===========================================================================
# B-32: P3 — CLAUDE_SESSION_ID env var when P1 and P2 are unset.
# ===========================================================================
setup
NONGIT_CWD="$TMP/b32-nongit"
mkdir -p "$NONGIT_CWD"
run_bridge "$NONGIT_CWD" "CLAUDE_SESSION_ID=envvar-sid-b32"
if [ "$BRIDGE_RC" -eq 0 ] && [ "$BRIDGE_OUT" = "envvar-sid-b32" ]; then
    pass "B-32: bridge P3 falls back to CLAUDE_SESSION_ID env var"
else
    fail "B-32: rc=$BRIDGE_RC out='$BRIDGE_OUT' expected='envvar-sid-b32'"
fi
teardown

# ===========================================================================
# B-34: invalid CLAUDE_CODE_SESSION_ID falls through to P3 (table-driven).
# P2 gate: value must be non-empty and match ^[A-Za-z0-9_-]+$ after trim.
# Empty / whitespace-only / charset-invalid values must NOT be returned —
# the chain falls to CLAUDE_SESSION_ID (P3) which holds a valid fallback.
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
        pass "B-34/$row_name: invalid P2 value falls through to P3 (fallback-sid-b34)"
    else
        fail "B-34/$row_name: rc=$BRIDGE_RC out='$BRIDGE_OUT' expected='fallback-sid-b34' (P2 value must not leak)"
    fi
done <<'TABLE'
empty           |
whitespace-only | <spaces>
charset-invalid | bad/sid-b34
TABLE
teardown
