#!/usr/bin/env bash
# tests/feature-811-review-loop-summarize-concerns-static.sh
# Tests: skills/_shared/cap-menu-dispatch.md, skills/make-outline-plan/SKILL.md, skills/make-detail-plan/SKILL.md
# Tags: feature, cap-menu, static-protocol, scope:issue-specific, pwsh-not-required
#
# Static grep checks for #811 protocol wiring: the summarize-concerns helper is
# invoked, LEDGER_FILE / RAW_FILE reach the cap-menu steps, the concern summary
# is exempted from the chat-output rules, and no new fenced block appears.
# L3 gap: whether the helper really fires in a live loop and its stdout reaches
# the conversation — checked at the WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh, category skill-orchestration.
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
# 3. The RAW_FILE round is read, not computed. "ROUND_NUMBER minus one" was an
#    inference about a counter the reader does not own; the loop that owns it
#    now states the answer — last-round.txt at a terminal, round-number.txt
#    while the loop continues (#2068).
# ---------------------------------------------------------------------------
echo "=== 3. cap-menu-dispatch.md: RAW_FILE row names the file that holds the round ==="
if require_file "$CAP_DISPATCH"; then
    if has 'RAW_FILE.*(last-round|round-number)' "$CAP_DISPATCH"; then
        pass "cap-menu-dispatch.md RAW_FILE row reads the round from last-round/round-number"
    else
        fail "RAW_FILE row must read the round from last-round.txt / round-number.txt"
    fi
    if has_fixed "round_number-1" "$CAP_DISPATCH"; then
        fail "cap-menu-dispatch.md still computes round_number-1 — a second opinion on the round"
    else
        pass "cap-menu-dispatch.md no longer computes round_number-1"
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
# 5. Same contract at the outline skill's own copy of the instruction: name the
#    file that holds the round instead of subtracting one from a live counter,
#    which pointed at the wrong raw file whenever the counter had moved on.
# ---------------------------------------------------------------------------
echo "=== 5. make-outline-plan/SKILL.md: MOP-6 RAW_FILE reads the recorded round ==="
if require_file "$OUTLINE_SKILL"; then
    WIN=$(awk '/MOP-6/{found=1; count=0} found && count<=10 {print; count++}' "$OUTLINE_SKILL")
    if echo "$WIN" | grep -E -q -- 'last-round|round-number'; then
        pass "MOP-6 reads the RAW_FILE round from last-round/round-number"
    else
        fail "MOP-6 missing a last-round.txt / round-number.txt reference within its 10-line window"
    fi
    if echo "$WIN" | grep -F -q -- "round_number-1"; then
        fail "MOP-6 still computes round_number-1 — the reader must not second-guess the counter"
    else
        pass "MOP-6 no longer computes round_number-1"
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
# 7. The detail skill is the symmetric case (CPR-ORTH): one skill left on the
#    subtraction is one skill still reading the wrong round's raw file.
# ---------------------------------------------------------------------------
echo "=== 7. make-detail-plan/SKILL.md: MDP-6 RAW_FILE reads the recorded round ==="
if require_file "$DETAIL_SKILL"; then
    WIN=$(awk '/MDP-6/{found=1; count=0} found && count<=10 {print; count++}' "$DETAIL_SKILL")
    if echo "$WIN" | grep -E -q -- 'last-round|round-number'; then
        pass "MDP-6 reads the RAW_FILE round from last-round/round-number"
    else
        fail "MDP-6 missing a last-round.txt / round-number.txt reference within its 10-line window"
    fi
    if echo "$WIN" | grep -F -q -- "round_number-1"; then
        fail "MDP-6 still computes round_number-1 — the reader must not second-guess the counter"
    else
        pass "MDP-6 no longer computes round_number-1"
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
