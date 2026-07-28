#!/bin/bash
# tests/fix-1501-icf-f-meta-fastpath.sh
# Tests: skills/issue-close-finalize/SKILL.md
# Tags: issue-close, meta, skill-doc, scope:issue-specific
#
# Issue #1501: the ICF-F meta-label fast path used to gate on crude body parsing
# (no unchecked `- [ ]` checkboxes). The fix re-gates it on the authoritative
# parent-all-closed-check.sh exit code (RC=0 = all sub-issues closed). These are
# static text assertions against the POST-fix SKILL.md — they legitimately FAIL
# until the #1501 fix is applied (tests-first TDD stage).
#
# TL1 (pure text): no hook/process needed. This is a documentation/static-assertion
# test by design — ICF-F is a main-conversation step (LLM judge + AskUserQuestion,
# per skills/issue-close-finalize/SKILL.md), not delegated to the
# issue-close-finalize-worker subagent code. No TL2/TL3 headless worker-chain
# harness can drive this gating logic, so no live coverage exists or is claimed
# elsewhere for it.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL_MD="${AGENTS_DIR}/skills/issue-close-finalize/SKILL.md"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

if [ ! -f "$SKILL_MD" ]; then
    echo "FAIL: precondition missing — skills/issue-close-finalize/SKILL.md"
    echo ""
    echo "Total: PASS=0 FAIL=1"
    exit 1
fi

# Extract the ICF-F meta fast-path line/section (the paragraph that contains the
# "Meta-label fast path" marker). It is authored as a single line in SKILL.md.
FASTPATH_LINE="$(grep -n "Meta-label fast path" "$SKILL_MD" 2>/dev/null | head -1)"

# ============================================================================
# 1. Fast path references parent-all-closed-check.sh
# ============================================================================
test_fastpath_references_check_script() {
    if [ -z "$FASTPATH_LINE" ]; then
        fail "1_references_check_script: 'Meta-label fast path' marker not found in SKILL.md"
        return
    fi
    if printf '%s' "$FASTPATH_LINE" | grep -qF "parent-all-closed-check.sh"; then
        pass "1_references_check_script: ICF-F meta fast path references parent-all-closed-check.sh"
    else
        fail "1_references_check_script: ICF-F meta fast path does NOT reference parent-all-closed-check.sh (still crude body parse)"
    fi
}

# ============================================================================
# 2. Fast path no longer contains `- [ ]` checkbox-body-parsing language
# ============================================================================
test_fastpath_no_checkbox_parse() {
    if [ -z "$FASTPATH_LINE" ]; then
        fail "2_no_checkbox_parse: 'Meta-label fast path' marker not found in SKILL.md"
        return
    fi
    if printf '%s' "$FASTPATH_LINE" | grep -qF -- "- [ ]"; then
        fail "2_no_checkbox_parse: ICF-F meta fast path still contains '- [ ]' checkbox-body parsing"
    else
        pass "2_no_checkbox_parse: ICF-F meta fast path no longer parses '- [ ]' checkboxes"
    fi
}

# ============================================================================
# 3. RC=0 semantics documented (fast path gates on exit code 0)
# ============================================================================
test_fastpath_documents_rc0() {
    if [ -z "$FASTPATH_LINE" ]; then
        fail "3_documents_rc0: 'Meta-label fast path' marker not found in SKILL.md"
        return
    fi
    # Accept either explicit RC=0 / exit code 0 phrasing, or an "all sub-issues
    # closed" restatement of the exit-0 semantics, on the fast-path line.
    if printf '%s' "$FASTPATH_LINE" | grep -qiE "RC=0|exit(\s+code)?\s+0|all sub-issues closed"; then
        pass "3_documents_rc0: ICF-F meta fast path documents RC=0 / all-sub-issues-closed gating"
    else
        fail "3_documents_rc0: ICF-F meta fast path does NOT document RC=0 gating semantics"
    fi
}

test_fastpath_references_check_script
test_fastpath_no_checkbox_parse
test_fastpath_documents_rc0

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $FAIL
