#!/bin/bash
# Tests: skills/workflow-init/SKILL.md, bin/workflow/workflow-init-driver
# Tags: workflow-init, wip-state, all-none, label-check, related-issues
# Tests for issue #589/#798 — workflow-init WI-5 ALL_NONE / FORCE_PATH_B fallback.
#
# WI-5 ALL_NONE previously only checked whether the *primary* issue had the
# `intent:clarified` label; related issues without the label were silently
# routed to Path A (resume) instead of Path B (re-clarify), causing
# clarify-intent to be skipped for issues whose intent was never captured.
#
# The fix (now absorbed into the driver):
#   - ALL_NONE evaluates all N's labels (not just the first).
#   - force_path_b=true is set when WIP is freshly claimed (ALL_NONE case).
#   - WI-8/route-decision enforces FORCE_PATH_B fallback.
#   - wip_error branch routes to ask_user (no silent warn-and-continue).

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW_INIT_SKILL="$AGENTS_DIR/skills/workflow-init/SKILL.md"
DRIVER="$AGENTS_DIR/bin/workflow/workflow-init-driver"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm '"$secs"'; exec @ARGV' -- "$@"; fi
}

# --- Existence gate ---------------------------------------------------------
if [ ! -f "$WORKFLOW_INIT_SKILL" ]; then
    echo "FAIL: precondition missing — skills/workflow-init/SKILL.md"
    echo ""
    echo "Results: 0 passed, 1 failed"
    exit 1
fi

# ============================================================================
# T1: SKILL.md references the driver (not wip-set-resume.sh) for WIP handling
# ============================================================================
if grep -qE "workflow-init-driver" "$WORKFLOW_INIT_SKILL"; then
    pass "T1: SKILL.md references workflow-init-driver (driver handles WIP aggregation)"
elif grep -qE "bin/workflow/workflow-init-driver|workflow.init.driver" "$WORKFLOW_INIT_SKILL"; then
    pass "T1: SKILL.md references workflow-init-driver"
else
    fail "T1: SKILL.md does not reference workflow-init-driver — driver loop not found"
fi

# ============================================================================
# T2: SKILL.md references FORCE_PATH_B or force_path_b behavior
# ============================================================================
if grep -qiE "(FORCE_PATH_B|force.path.b|force path B|PATH_DECISION)" "$WORKFLOW_INIT_SKILL"; then
    pass "T2: SKILL.md references FORCE_PATH_B / PATH_DECISION (routing documented)"
else
    fail "T2: SKILL.md missing FORCE_PATH_B or PATH_DECISION reference"
fi

# ============================================================================
# T3: SKILL.md references ask_user handling for wip errors (no silent continue)
# ============================================================================
if grep -qiE "(ask_user|AskUserQuestion|wip_error|wip_conflict)" "$WORKFLOW_INIT_SKILL"; then
    pass "T3: SKILL.md references ask_user / AskUserQuestion for wip conflict/error handling"
else
    fail "T3: SKILL.md missing ask_user/AskUserQuestion reference for wip error branch"
fi

# ============================================================================
# T4: bin/workflow/workflow-init-driver exists and is accessible
# ============================================================================
if [ -f "$DRIVER" ]; then
    pass "T4: bin/workflow/workflow-init-driver exists"
else
    fail "T4: bin/workflow/workflow-init-driver missing"
fi

# --- helper setup for T5-T7 -------------------------------------------------
# Use cygpath -u (POSIX) so MOCKBIN works in bash PATH entries.
to_native() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -u "$1"; else printf '%s' "$1"; fi
}
ROOT_TMP="$(to_native "$(mktemp -d)")"
trap 'rm -rf "$ROOT_TMP"' EXIT
ORIG_PATH="$PATH"
_CN=0

if [ ! -f "$DRIVER" ]; then
    echo "SKIP: T5-T7 require $DRIVER (not yet built)"
    FAIL=$((FAIL + 3))
else

setup_drv() {
    local sid="$1"
    _CN=$((_CN + 1))
    CASE_DIR="$ROOT_TMP/case-$_CN"
    PLANS="$CASE_DIR/plans"
    CFG="$CASE_DIR/cfg"
    MOCKBIN="$CASE_DIR/bin"
    RESP="$CASE_DIR/resp"
    WIPD="$CASE_DIR/wip"
    mkdir -p "$PLANS" "$MOCKBIN" "$RESP" "$WIPD" \
        "$CFG/bin/github-issues" "$CFG/hooks/lib" "$CFG/skills/workflow-init/scripts"
    cat > "$MOCKBIN/gh" <<GHEOF
#!/bin/bash
echo "\$*" >> "$CASE_DIR/gh.log"
RESP="$RESP"
GHEOF
    cat >> "$MOCKBIN/gh" <<'GHEOF2'
cmd="${1:-}"; sub="${2:-}"
if [ "$cmd" = "issue" ] && [ "$sub" = "view" ]; then
    shift 2; N=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --repo|--json|--jq) if [ $# -ge 2 ]; then shift 2; else shift; fi ;;
            -*) shift ;;
            *) [ -z "$N" ] && N="$1"; shift ;;
        esac
    done
    N="${N#\#}"
    if [ -f "$RESP/issue-view-$N.json" ]; then cat "$RESP/issue-view-$N.json"; exit 0; fi
    echo "mock-gh: no fixture for issue $N" >&2; exit 1
fi
if [ "$cmd" = "repo" ] && [ "$sub" = "view" ]; then echo "mockorg/mockrepo"; exit 0; fi
if [ "$cmd" = "api" ]; then echo "[]"; exit 0; fi
echo "mock-gh: unhandled: $*" >&2; exit 1
GHEOF2
    chmod +x "$MOCKBIN/gh"
    cat > "$CFG/bin/github-issues/wip-state.sh" <<WIPEOF
#!/bin/bash
WIPD="$WIPD"
WIPEOF
    cat >> "$CFG/bin/github-issues/wip-state.sh" <<'WIPEOF2'
V=""; N=""
while [ $# -gt 0 ]; do
    case "$1" in
        --session-id|--repo) shift 2 ;;
        -*) shift ;;
        *) [ -z "$V" ] && V="$1" || N="$1"; shift ;;
    esac
done
N="${N#\#}"
echo "$V $N" >> "$WIPD/calls.log"
case "$V" in
    check) if [ -f "$WIPD/s-$N" ]; then cat "$WIPD/s-$N"; else echo "none"; fi; exit 0 ;;
    set) echo "same" > "$WIPD/s-$N"; exit 0 ;;
    *) exit 0 ;;
esac
WIPEOF2
    chmod +x "$CFG/bin/github-issues/wip-state.sh"
    printf '#!/bin/bash\necho "${CLAUDE_SESSION_ID:-mock}"\n' > "$CFG/bin/resolve-session-id"
    cp "$AGENTS_DIR/bin/parse-issue-tokens" "$CFG/bin/parse-issue-tokens"
    cp "$AGENTS_DIR/hooks/lib/parse-closes-issues.js" "$CFG/hooks/lib/parse-closes-issues.js"
    cat > "$CFG/skills/workflow-init/scripts/filter-init-candidates.sh" <<'FEOF'
#!/bin/bash
while [ $# -gt 0 ]; do
    case "$1" in --repo-map) shift 2 ;; -*) shift ;; *) echo "#${1#\#}"; shift ;; esac
done
exit 0
FEOF
    chmod +x "$CFG/bin/resolve-session-id" "$CFG/bin/parse-issue-tokens" \
        "$CFG/skills/workflow-init/scripts/filter-init-candidates.sh"
    export WORKFLOW_PLANS_DIR="$PLANS" AGENTS_CONFIG_DIR="$CFG" CLAUDE_SESSION_ID="$sid"
    unset NON_GITHUB CLAUDE_ENV_FILE 2>/dev/null || true
    export PATH="$MOCKBIN:$ORIG_PATH"
}

teardown_drv() {
    export PATH="$ORIG_PATH"
    unset WORKFLOW_PLANS_DIR AGENTS_CONFIG_DIR CLAUDE_SESSION_ID 2>/dev/null || true
}

mock_issue() {
    local n="$1" state="$2" labels_csv="${3:-}" labels="" l
    local IFS=','
    for l in $labels_csv; do labels="$labels{\"name\":\"$l\"},"; done
    labels="[${labels%,}]"
    printf '{"number":%s,"title":"Issue %s","body":"Body","labels":%s,"state":"%s","createdAt":"2026-07-01T00:00:00Z"}\n' \
        "$n" "$n" "$labels" "$state" > "$RESP/issue-view-$n.json"
}

TIMEOUT_WRAP="$AGENTS_DIR/bin/run-with-timeout.sh"

run_drv() {
    DROUT="$(cd "$CASE_DIR" && "$TIMEOUT_WRAP" 30 node "$DRIVER" "$@" 2>/dev/null)"
    DRRC=$?
    return 0
}

kv() {
    local val
    val="$(printf '%s\n' "$DROUT" | grep -m1 "^${1}=")" || { printf ''; return; }
    val="${val#"${1}"=}"
    val="${val%$'\r'}"
    case "$val" in \'*\') val="${val#\'}"; val="${val%\'}" ;; esac
    printf '%s' "$val"
}

# ============================================================================
# T5: all-clarified + wip=none → wip set for all, ACTION=done
# ============================================================================
setup_drv t5-wip798
mock_issue 101 OPEN "intent:clarified,type:task"
mock_issue 102 OPEN "intent:clarified,type:task"
run_drv '#101' '#102'
ACT="$(kv ACTION)"
if [ "$ACT" = "done" ] && grep -q '^set 101$' "$WIPD/calls.log" 2>/dev/null && grep -q '^set 102$' "$WIPD/calls.log" 2>/dev/null; then
    pass "T5: all-clarified + wip=none → wip set for both, ACTION=done"
else
    fail "T5: expected done + set 101 + set 102; got ACT=$ACT calls=$(cat "$WIPD/calls.log" 2>/dev/null | tr '\n' ';')"
fi
teardown_drv

# ============================================================================
# T6: one N lacking intent:clarified → PATH_DECISION=B (force_path_b + label check)
# ============================================================================
setup_drv t6-wip798
mock_issue 201 OPEN "intent:clarified,type:task"
mock_issue 202 OPEN "type:task"
run_drv '#201' '#202'
ACT="$(kv ACTION)"
PD="$(kv PATH_DECISION)"
if [ "$ACT" = "done" ] && [ "$PD" = "B" ]; then
    pass "T6: one N unlabeled → PATH_DECISION=B"
else
    fail "T6: expected done PATH_DECISION=B; got ACT=$ACT PD=$PD"
fi
teardown_drv

# ============================================================================
# T7: meta N + intent:clarified → PATH_DECISION=META (meta handled separately)
# ============================================================================
setup_drv t7-wip798
mock_issue 301 OPEN "intent:clarified,meta"
run_drv '#301'
ACT="$(kv ACTION)"
PD="$(kv PATH_DECISION)"
if [ "$ACT" = "done" ] && [ "$PD" = "META" ]; then
    pass "T7: meta N with intent:clarified → PATH_DECISION=META"
else
    fail "T7: expected done PATH_DECISION=META; got ACT=$ACT PD=$PD"
fi
teardown_drv

fi  # end of driver-present block

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
