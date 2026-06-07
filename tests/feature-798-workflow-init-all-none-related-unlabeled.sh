#!/bin/bash
# Tests: skills/workflow-init/SKILL.md
# Tags: workflow-init, wip-state, all-none, label-check, related-issues
# Tests for issue #589/#798 — workflow-init WI-5 ALL_NONE / WI-8 FORCE_PATH_B fallback.
#
# WI-5 ALL_NONE previously only checked whether the *primary* issue had the
# `intent:clarified` label; related issues without the label were silently
# routed to Path A (resume) instead of Path B (re-clarify), causing
# clarify-intent to be skipped for issues whose intent was never captured.
#
# The fix:
#   - WI-5 ALL_NONE evaluates all N's labels (not just primary).
#   - WI-8 introduces a FORCE_PATH_B fallback when any related N is unlabeled.
#   - WI-5 ERROR branch routes to AskUserQuestion (no silent warn-and-continue).
#
# RED before /write-code runs — these grep assertions match prose that
# /write-code will add to skills/workflow-init/SKILL.md.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW_INIT_SKILL="$AGENTS_DIR/skills/workflow-init/SKILL.md"
WIP_RESUME_SCRIPT="$AGENTS_DIR/skills/workflow-init/scripts/wip-set-resume.sh"

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
# T1: WI-5 ALL_NONE condition covers all N (not just primary)
# ============================================================================
# The fixed SKILL.md must NOT contain prose limiting the ALL_NONE label check
# to the primary issue. Pre-fix text reads:
#   "ALL_NONE → if `intent:clarified` ∈ labels of primary: ..."
# Post-fix text must replace `primary` with all-N phrasing
# (e.g. "labels of all N", "every N", "each N in ISSUES").
ALL_NONE_LINE=$(grep -nE '^- `ALL_NONE`' "$WORKFLOW_INIT_SKILL" | head -1 || true)
if [ -z "$ALL_NONE_LINE" ]; then
    fail "T1: WI-5 ALL_NONE bullet not found in SKILL.md"
elif echo "$ALL_NONE_LINE" | grep -qiE "labels of primary[^a-zA-Z_]"; then
    fail "T1: WI-5 ALL_NONE still checks only 'labels of primary' — must cover all N"
elif echo "$ALL_NONE_LINE" | grep -q "wip-set-resume.sh"; then
    pass "T1: WI-5 ALL_NONE references wip-set-resume.sh (all-N handling delegated)"
elif echo "$ALL_NONE_LINE" | grep -qiE "(labels of all N|labels of every N|labels of each N|all N have|every N has|each N has|for all N|ALL_CLARIFIED)"; then
    pass "T1: WI-5 ALL_NONE condition covers all N (not just primary)"
else
    fail "T1: WI-5 ALL_NONE does not reference wip-set-resume.sh or all-N prose; line: $ALL_NONE_LINE"
fi

# ============================================================================
# T2: WI-8 references FORCE_PATH_B fallback for related N without intent:clarified
# ============================================================================
if grep -qiE "(FORCE_PATH_B|force.path.b|force path B)" "$WORKFLOW_INIT_SKILL" && grep -q "NEEDS_CLARIFY" "$WORKFLOW_INIT_SKILL"; then
    pass "T2: WI-8 references FORCE_PATH_B + NEEDS_CLARIFY (related N without intent:clarified handled)"
else
    fail "T2: WI-8 missing FORCE_PATH_B or NEEDS_CLARIFY reference"
fi

# ============================================================================
# T3: WI-5 ERROR branch references AskUserQuestion (no silent warn-and-continue)
# ============================================================================
# The pre-fix behavior was to warn-and-continue when wip-state detection
# failed. The fix (rc=2 escalation, #589) routes to AskUserQuestion so the
# user is forced to resolve ambiguity before the workflow proceeds.
ERROR_LINE=$(grep -nE '^- `ERROR' "$WORKFLOW_INIT_SKILL" | head -1 || true)
if [ -z "$ERROR_LINE" ]; then
    fail "T3: WI-5 ERROR bullet not found in SKILL.md"
elif echo "$ERROR_LINE" | grep -qiE "(AskUserQuestion|ask.*user.*question)"; then
    pass "T3: WI-5 ERROR branch references AskUserQuestion"
else
    fail "T3: WI-5 ERROR branch does not reference AskUserQuestion — may still silently warn; line: $ERROR_LINE"
fi

# ============================================================================
# T4: wip-set-resume.sh exists and is executable
# ============================================================================
if [ -x "$WIP_RESUME_SCRIPT" ]; then
    pass "T4: wip-set-resume.sh exists and is executable"
else
    fail "T4: wip-set-resume.sh missing or not executable: $WIP_RESUME_SCRIPT"
fi

# --- mock setup for T5-T7 ----------------------------------------------------
setup_mock() {
    TMP="$(mktemp -d 2>/dev/null || mktemp -d -t wipresume)"
    mkdir -p "$TMP/mock-bin" "$TMP/bin/github-issues"

    # Mock gh: reads GH_MOCK_LABELS_<N> per issue.
    # Invocation: gh issue view <N> --json labels --jq ...
    cat > "$TMP/mock-bin/gh" <<'MOCKGH'
#!/bin/bash
# args: issue view <N> --json labels --jq '[.labels[].name]'
N=""
prev=""
for a in "$@"; do
    if [ "$prev" = "view" ]; then
        N="$a"
        break
    fi
    prev="$a"
done
VARNAME="GH_MOCK_LABELS_${N}"
VAL="${!VARNAME:-}"
if [ "$VAL" = "fail" ]; then
    exit 1
fi
if [ -z "$VAL" ]; then
    echo "[]"
    exit 0
fi
echo "$VAL"
exit 0
MOCKGH
    chmod +x "$TMP/mock-bin/gh"

    # Mock wip-state.sh: exits GH_MOCK_WIP_RC (default 0).
    cat > "$TMP/bin/github-issues/wip-state.sh" <<'MOCKWIP'
#!/bin/bash
exit "${GH_MOCK_WIP_RC:-0}"
MOCKWIP
    chmod +x "$TMP/bin/github-issues/wip-state.sh"

    export AGENTS_CONFIG_DIR="$TMP"
    export PATH="$TMP/mock-bin:$PATH"
}

teardown_mock() {
    rm -rf "$TMP" 2>/dev/null
    # unset any GH_MOCK_LABELS_* vars and rc var
    for v in $(env | grep -oE '^GH_MOCK_LABELS_[0-9]+' || true); do
        unset "$v"
    done
    unset GH_MOCK_WIP_RC
    PATH="${PATH#$TMP/mock-bin:}"
    export PATH
}

# ============================================================================
# T5: all-clarified + no-meta → exit 0 + ALL_SET
# ============================================================================
setup_mock
export GH_MOCK_LABELS_101='["intent:clarified","type:task"]'
export GH_MOCK_LABELS_102='["intent:clarified","type:task"]'
export GH_MOCK_WIP_RC=0
OUT=$(run_with_timeout 10 bash "$WIP_RESUME_SCRIPT" 101 102 2>/dev/null)
RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | grep -q "^ALL_SET$"; then
    pass "T5: all-clarified + no-meta → ALL_SET, exit 0"
else
    fail "T5: expected (ALL_SET,0); got rc=$RC out=$OUT"
fi
teardown_mock

# ============================================================================
# T6: one N lacking intent:clarified → exit 1 + NEEDS_CLARIFY
# ============================================================================
setup_mock
export GH_MOCK_LABELS_201='["intent:clarified","type:task"]'
export GH_MOCK_LABELS_202='["type:task"]'
export GH_MOCK_WIP_RC=0
OUT=$(run_with_timeout 10 bash "$WIP_RESUME_SCRIPT" 201 202 2>/dev/null)
RC=$?
if [ "$RC" -eq 1 ] && echo "$OUT" | grep -q "^NEEDS_CLARIFY"; then
    pass "T6: one N unlabeled → NEEDS_CLARIFY, exit 1"
else
    fail "T6: expected (NEEDS_CLARIFY,1); got rc=$RC out=$OUT"
fi
teardown_mock

# ============================================================================
# T7: meta N → META_SKIP in stdout, still ALL_SET, exit 0
# ============================================================================
setup_mock
export GH_MOCK_LABELS_301='["intent:clarified","meta"]'
export GH_MOCK_LABELS_302='["intent:clarified","type:task"]'
export GH_MOCK_WIP_RC=0
OUT=$(run_with_timeout 10 bash "$WIP_RESUME_SCRIPT" 301 302 2>/dev/null)
RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | grep -q "^META_SKIP 301$" && echo "$OUT" | grep -q "^ALL_SET$"; then
    pass "T7: meta N → META_SKIP + ALL_SET, exit 0"
else
    fail "T7: expected META_SKIP 301 + ALL_SET, rc=0; got rc=$RC out=$OUT"
fi
teardown_mock

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
