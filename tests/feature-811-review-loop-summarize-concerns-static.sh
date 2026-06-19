#!/usr/bin/env bash
# tests/feature-811-review-loop-summarize-concerns-static.sh
# Tests: skills/_shared/cap-menu-dispatch.md, skills/make-outline-plan/SKILL.md, skills/make-detail-plan/SKILL.md
# Tags: feature, cap-menu, static-protocol, scope:issue-specific, pwsh-not-required
#
# Static grep-based checks for #811 protocol wiring:
#   - cap-menu-dispatch.md step c.5 invokes the summarize-concerns helper
#   - Parameters table carries LEDGER_FILE and RAW_FILE with ROUND_NUMBER-1 semantics
#   - MOP-6 / MDP-6 cap-menu Step Parameters carry LEDGER_FILE + RAW_FILE
#   - MOP-6 / MDP-6 chat-output Rules carry a (d) bullet exempting the concern summary
#   - cap-menu-dispatch.md does NOT introduce a new 3+ line fenced code block
#
# L3 gap (what this test does NOT catch):
# - The helper invocation actually fires from cap-menu-dispatch.md step c.5 in a real review loop
# - The stdout actually reaches the main conversation rendered as Markdown
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: skill-orchestration.
set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

# grep wrapper: fixed-string match, returns 0/1
has_fixed() {
    grep -F -- "$1" "$2" >/dev/null 2>&1
}

# grep wrapper: extended regex match, returns 0/1
has() {
    grep -E -- "$1" "$2" >/dev/null 2>&1
}

require_file() {
    if [ ! -f "$1" ]; then
        fail "missing required file: $1"
        return 1
    fi
    return 0
}

CAP_DISPATCH="$REPO_ROOT/skills/_shared/cap-menu-dispatch.md"
OUTLINE_SKILL="$REPO_ROOT/skills/make-outline-plan/SKILL.md"
DETAIL_SKILL="$REPO_ROOT/skills/make-detail-plan/SKILL.md"

# ---------------------------------------------------------------------------
# 1. cap-menu-dispatch.md step c.5 invocation exists
# ---------------------------------------------------------------------------
echo "=== 1. cap-menu-dispatch.md: step c.5 invokes review-loop-summarize-concerns ==="
if require_file "$CAP_DISPATCH"; then
    if has_fixed "review-loop-summarize-concerns" "$CAP_DISPATCH"; then
        pass "cap-menu-dispatch.md references review-loop-summarize-concerns"
    else
        fail "cap-menu-dispatch.md missing review-loop-summarize-concerns reference"
    fi
    if has_fixed "c.5" "$CAP_DISPATCH"; then
        pass "cap-menu-dispatch.md references step c.5"
    else
        fail "cap-menu-dispatch.md missing step c.5 anchor"
    fi
fi

# ---------------------------------------------------------------------------
# 2. cap-menu-dispatch.md Parameters table includes LEDGER_FILE row
# ---------------------------------------------------------------------------
echo "=== 2. cap-menu-dispatch.md: Parameters table LEDGER_FILE row ==="
if require_file "$CAP_DISPATCH"; then
    if has_fixed "LEDGER_FILE" "$CAP_DISPATCH"; then
        pass "cap-menu-dispatch.md contains LEDGER_FILE"
    else
        fail "cap-menu-dispatch.md missing LEDGER_FILE"
    fi
    if has_fixed "concern-ledger" "$CAP_DISPATCH"; then
        pass "cap-menu-dispatch.md contains 'concern-ledger' token"
    else
        fail "cap-menu-dispatch.md missing 'concern-ledger' token"
    fi
fi

# ---------------------------------------------------------------------------
# 3. cap-menu-dispatch.md Parameters-table RAW_FILE row carries
#    "most recently persisted" / ROUND_NUMBER-1 semantics
# ---------------------------------------------------------------------------
echo "=== 3. cap-menu-dispatch.md: RAW_FILE row carries ROUND_NUMBER-1 semantics ==="
if require_file "$CAP_DISPATCH"; then
    if has 'RAW_FILE.*(most recently persisted|ROUND_NUMBER-1)' "$CAP_DISPATCH"; then
        pass "cap-menu-dispatch.md RAW_FILE row carries ROUND_NUMBER-1 / most-recently-persisted semantics"
    else
        fail "RAW_FILE row must specify ROUND_NUMBER-1 (most recently persisted); see detail-plan §RAW_FILE state at cap-reach"
    fi
fi

# ---------------------------------------------------------------------------
# 4. MOP-6 carries LEDGER_FILE within 5 lines after the MOP-6 anchor
# ---------------------------------------------------------------------------
echo "=== 4. make-outline-plan/SKILL.md: MOP-6 carries LEDGER_FILE ==="
if require_file "$OUTLINE_SKILL"; then
    # awk window: 5 lines after first MOP-6 occurrence
    WIN=$(awk '/MOP-6/{found=1; count=0} found && count<=5 {print; count++}' "$OUTLINE_SKILL")
    if echo "$WIN" | grep -F -q -- "LEDGER_FILE" && echo "$WIN" | grep -F -q -- "outline-plan-concern-ledger"; then
        pass "MOP-6 carries LEDGER_FILE + outline-plan-concern-ledger within 5 lines"
    else
        fail "MOP-6 missing LEDGER_FILE or outline-plan-concern-ledger within 5-line window"
    fi
fi

# ---------------------------------------------------------------------------
# 5. MOP-6 RAW_FILE uses <round_number-1> token (or 'previous round' near RAW_FILE)
# ---------------------------------------------------------------------------
echo "=== 5. make-outline-plan/SKILL.md: MOP-6 RAW_FILE uses <round_number-1> ==="
if require_file "$OUTLINE_SKILL"; then
    WIN=$(awk '/MOP-6/{found=1; count=0} found && count<=10 {print; count++}' "$OUTLINE_SKILL")
    if echo "$WIN" | grep -F -q -- "<round_number-1>"; then
        pass "MOP-6 references <round_number-1> token"
    elif echo "$WIN" | grep -E -q 'RAW_FILE.*previous round|previous round.*RAW_FILE'; then
        pass "MOP-6 references 'previous round' adjacent to RAW_FILE"
    else
        fail "MOP-6 missing <round_number-1> token or 'previous round' adjacent to RAW_FILE within 10-line window"
    fi
fi

# ---------------------------------------------------------------------------
# 6. MDP-6 carries LEDGER_FILE within 5 lines after the MDP-6 anchor
# ---------------------------------------------------------------------------
echo "=== 6. make-detail-plan/SKILL.md: MDP-6 carries LEDGER_FILE ==="
if require_file "$DETAIL_SKILL"; then
    WIN=$(awk '/MDP-6/{found=1; count=0} found && count<=5 {print; count++}' "$DETAIL_SKILL")
    if echo "$WIN" | grep -F -q -- "LEDGER_FILE" && echo "$WIN" | grep -F -q -- "detail-plan-concern-ledger"; then
        pass "MDP-6 carries LEDGER_FILE + detail-plan-concern-ledger within 5 lines"
    else
        fail "MDP-6 missing LEDGER_FILE or detail-plan-concern-ledger within 5-line window"
    fi
fi

# ---------------------------------------------------------------------------
# 7. MDP-6 RAW_FILE uses <round_number-1> token (or 'previous round' near RAW_FILE)
# ---------------------------------------------------------------------------
echo "=== 7. make-detail-plan/SKILL.md: MDP-6 RAW_FILE uses <round_number-1> ==="
if require_file "$DETAIL_SKILL"; then
    WIN=$(awk '/MDP-6/{found=1; count=0} found && count<=10 {print; count++}' "$DETAIL_SKILL")
    if echo "$WIN" | grep -F -q -- "<round_number-1>"; then
        pass "MDP-6 references <round_number-1> token"
    elif echo "$WIN" | grep -E -q 'RAW_FILE.*previous round|previous round.*RAW_FILE'; then
        pass "MDP-6 references 'previous round' adjacent to RAW_FILE"
    else
        fail "MDP-6 missing <round_number-1> token or 'previous round' adjacent to RAW_FILE within 10-line window"
    fi
fi

# ---------------------------------------------------------------------------
# 8. MOP-6 Rules exemption bullet — (d) bullet + 'concern summary' within
#    5 lines after the existing (c) bullet
# ---------------------------------------------------------------------------
echo "=== 8. make-outline-plan/SKILL.md: MOP-6 Rules (d) exemption bullet ==="
if require_file "$OUTLINE_SKILL"; then
    # 5-line window after the first '(c)' occurrence in the file
    WIN=$(awk '/\(c\)/{found=1; count=0} found && count<=5 {print; count++}' "$OUTLINE_SKILL")
    if echo "$WIN" | grep -F -q -- "(d)" && echo "$WIN" | grep -F -q -- "concern summary"; then
        pass "MOP-6 Rules contains (d) bullet + 'concern summary' within 5 lines after (c)"
    else
        fail "MOP-6 Rules missing (d) bullet or 'concern summary' within 5-line window after (c)"
    fi
fi

# ---------------------------------------------------------------------------
# 9. MDP-6 Rules exemption bullet — (d) bullet + 'concern summary' within
#    5 lines after the existing (c) bullet
# ---------------------------------------------------------------------------
echo "=== 9. make-detail-plan/SKILL.md: MDP-6 Rules (d) exemption bullet ==="
if require_file "$DETAIL_SKILL"; then
    WIN=$(awk '/\(c\)/{found=1; count=0} found && count<=5 {print; count++}' "$DETAIL_SKILL")
    if echo "$WIN" | grep -F -q -- "(d)" && echo "$WIN" | grep -F -q -- "concern summary"; then
        pass "MDP-6 Rules contains (d) bullet + 'concern summary' within 5 lines after (c)"
    else
        fail "MDP-6 Rules missing (d) bullet or 'concern summary' within 5-line window after (c)"
    fi
fi

# ---------------------------------------------------------------------------
# 10. No new 3+ line fenced code block introduced in cap-menu-dispatch.md
#     (count of lines starting with ``` must be <= 2; i.e. <= 1 fence pair)
# ---------------------------------------------------------------------------
echo "=== 10. cap-menu-dispatch.md: no new 3+ line fenced code block ==="
if require_file "$CAP_DISPATCH"; then
    FENCE_COUNT=$(grep -c '^```' "$CAP_DISPATCH" || true)
    if [ "$FENCE_COUNT" -le 2 ]; then
        pass "cap-menu-dispatch.md has $FENCE_COUNT fence line(s) (<= 2)"
    else
        fail "cap-menu-dispatch.md has $FENCE_COUNT fence lines (> 2 — new 3+ line code block introduced)"
    fi
fi

# ---------------------------------------------------------------------------
echo
if [ "$ERRORS" -eq 0 ]; then
    echo "All static checks passed."
    exit 0
else
    echo "$ERRORS check(s) failed."
    exit 1
fi
