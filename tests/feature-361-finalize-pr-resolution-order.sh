#!/bin/bash
# Tests: skills/issue-close-finalize/SKILL.md
# Tags: issue-close, finalize, workflow, pr, marker
# Static contract test for #361 ordering fix.
# This is a static contract test, not a runtime behavioral test.
# No skill-level execution harness exists for SKILL.md prose.
# Catches the specific class of regression #361 represents (ordering + guard).
# Brittle by design: refactors removing the ordering-contract comment or *,J,* guard must update this test.
set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL="$AGENTS_DIR/skills/issue-close-finalize/SKILL.md"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

if [ ! -f "$SKILL" ]; then
    fail "precondition missing — $SKILL"
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

# --- ST1: ordering — find-pr-by-marker.sh EXECUTABLE invocation MUST appear AFTER triage eval
# Match only lines where find-pr-by-marker.sh is called as a bash subprocess (inside eval/if),
# not prose mentions like "resolved via find-pr-by-marker.sh".
TRIAGE_LINE=$(grep -n 'issue-close-finalize-triage.sh' "$SKILL" | head -1 | cut -d: -f1)
PR_LINE=$(grep -n 'bash.*find-pr-by-marker\.sh' "$SKILL" | head -1 | cut -d: -f1)
if [ -n "$TRIAGE_LINE" ] && [ -n "$PR_LINE" ] && [ "$PR_LINE" -gt "$TRIAGE_LINE" ]; then
    pass "ST1: find-pr-by-marker.sh (line $PR_LINE) appears after triage (line $TRIAGE_LINE)"
else
    fail "ST1: ordering wrong — triage=$TRIAGE_LINE pr=$PR_LINE (PR invocation must be > triage line)"
fi

# --- ST2: guard present — *,J,* appears within 5 lines before or 20 lines after find-pr-by-marker.sh
if [ -n "$PR_LINE" ]; then
    WINDOW_START=$((PR_LINE > 5 ? PR_LINE - 5 : 1))
    WINDOW_END=$((PR_LINE + 20))
    if sed -n "${WINDOW_START},${WINDOW_END}p" "$SKILL" | grep -qF '*,J,*'; then
        pass "ST2: *,J,* guard present within window of find-pr-by-marker.sh"
    else
        fail "ST2: *,J,* guard NOT found within lines ${WINDOW_START}-${WINDOW_END}"
    fi
else
    fail "ST2: cannot check guard — find-pr-by-marker.sh line not found"
fi

# --- ST3: contract anchor — the ordering-contract comment exists somewhere
if grep -qF 'ordering-contract: PR/SHA resolution MUST run after triage' "$SKILL"; then
    pass "ST3: ordering-contract anchor comment present"
else
    fail "ST3: ordering-contract anchor comment missing"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
