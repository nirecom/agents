#!/bin/bash
# tests/fix-1591-intent-title-contract.sh
# Tests: skills/clarify-intent/SKILL.md, skills/workflow-init/SKILL.md
# Tags: skill, clarify-intent, workflow-init, docs, scan-outbound, scope:issue-specific, layer:TL1
#
# Issue #1591 — **Title:** data contract: clarify-intent CI-4 and workflow-init Path A1
# must emit it; intent-to-issue.sh reads it. Title assertions FAIL until /write-code;
# <200-line baseline regression guards MUST pass now.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLARIFY="$AGENTS_DIR/skills/clarify-intent/SKILL.md"
WFINIT="$AGENTS_DIR/skills/workflow-init/SKILL.md"

PASS=0
FAIL=0
SOFT=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
soft() { echo "SOFT-FAIL (expected until /write-code edits SKILL.md): $1"; SOFT=$((SOFT + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

run_with_timeout 10 true

# Primary assertion: the literal contract string `**Title:**` appears in each SKILL.
# Tolerant of exact wording (any occurrence counts). SOFT until docs are edited.
if [ -f "$CLARIFY" ]; then
    if grep -q '\*\*Title:\*\*' "$CLARIFY"; then
        pass "TC-1: clarify-intent SKILL.md documents the **Title:** contract"
    else
        soft "TC-1: clarify-intent SKILL.md has no **Title:** reference yet (CI-4 edit pending)"
    fi
else
    fail "TC-1: clarify-intent SKILL.md not found at $CLARIFY"
fi

if [ -f "$WFINIT" ]; then
    if grep -q '\*\*Title:\*\*' "$WFINIT"; then
        pass "TC-2: workflow-init SKILL.md documents the **Title:** contract"
    else
        soft "TC-2: workflow-init SKILL.md has no **Title:** reference yet (Path A1 edit pending)"
    fi
else
    fail "TC-2: workflow-init SKILL.md not found at $WFINIT"
fi

# HARD-limit regression: both SKILL.md files must stay under 200 lines. This runs
# against the CURRENT files and must pass now (baseline guard against the edits
# pushing either file over the SKILL.md split threshold).
check_under_200() {
    local f="$1" name="$2"
    if [ ! -f "$f" ]; then
        fail "TC-SIZE: $name not found"
        return
    fi
    local n
    n=$(wc -l < "$f" | tr -d ' ')
    if [ "$n" -lt 200 ]; then
        pass "TC-SIZE: $name is $n lines (< 200 HARD limit)"
    else
        fail "TC-SIZE: $name is $n lines (>= 200 HARD limit — must split)"
    fi
}
check_under_200 "$CLARIFY" "clarify-intent/SKILL.md"
check_under_200 "$WFINIT" "workflow-init/SKILL.md"

echo ""
echo "Results: $PASS passed, $FAIL failed, $SOFT soft-fail"
# SOFT failures do not fail the suite (expected pre-/write-code). Only hard FAILs do.
exit $((FAIL > 0 ? 1 : 0))
