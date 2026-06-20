#!/usr/bin/env bash
# Tests: skills/workflow-init/SKILL.md, skills/workflow-init/scripts/path-a-label-and-board.sh
# Tags: workflow-init, refactor, file-split, static-grep
# Static checks for the A2 extraction (Pattern B file-split):
#   H1: script file exists and is non-empty
#   H2: script declares set -uo pipefail and validates argc >= 1
#   H3: SKILL.md references the script
#   H4: SKILL.md no longer contains the inline `for N in "${ISSUES[@]}"` loop body
#   H5: SKILL.md still under HARD 200-line limit

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL="$AGENTS_DIR/skills/workflow-init/SKILL.md"
SCRIPT="$AGENTS_DIR/skills/workflow-init/scripts/path-a-label-and-board.sh"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# H1
if [ -s "$SCRIPT" ]; then
    pass "H1: scripts/path-a-label-and-board.sh exists and is non-empty"
else
    fail "H1: scripts/path-a-label-and-board.sh missing or empty"
fi

# H2
if grep -q 'set -uo pipefail' "$SCRIPT" 2>/dev/null \
   && grep -qE 'if \[ "\$#" -lt 1 \]' "$SCRIPT" 2>/dev/null; then
    pass "H2: script declares 'set -uo pipefail' and validates argc >= 1"
else
    fail "H2: script missing 'set -uo pipefail' or argc validation"
fi

# H3
if grep -q 'scripts/path-a-label-and-board.sh' "$SKILL" 2>/dev/null; then
    pass "H3: SKILL.md references scripts/path-a-label-and-board.sh"
else
    fail "H3: SKILL.md does not reference scripts/path-a-label-and-board.sh"
fi

# H4 — inline loop body removed (the for-loop header is the canonical token).
if grep -qE 'for N in "\$\{ISSUES\[@\]\}"; do' "$SKILL" 2>/dev/null; then
    fail "H4: SKILL.md still contains the inline 'for N in \${ISSUES[@]}' loop body (extraction incomplete)"
else
    pass "H4: SKILL.md no longer contains the inline A2 loop body"
fi

# H5
LINES=$(awk 'END{print NR}' "$SKILL" 2>/dev/null || echo 0)
if [ "$LINES" -lt 200 ]; then
    pass "H5: SKILL.md is $LINES lines (under HARD 200-line limit)"
else
    fail "H5: SKILL.md is $LINES lines (exceeds HARD 200-line limit)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0 ? 1 : 0))
