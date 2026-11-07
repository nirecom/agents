#!/usr/bin/env bash
# Tests: skills/workflow-init/SKILL.md
# Tags: workflow-init, github, issues, session-dedup, static-grep, scope:issue-specific, migrate
# Static grep tests — Step 3 initial CLOSED detection for related issues.
#
# F1: Step 3 initial check references ISSUES[@] loop (not just primary)
# F2: workflow-init SKILL.md calls issue-state-check.sh for CLOSED detection
#
# SKIP when patterns are not yet present (pre-implementation).

set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SKILL="$SCRIPT_CHECKOUT_ROOT/skills/workflow-init/SKILL.md"

PASS=0
FAIL=0
SKIP=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

# Existence gate
if [ ! -f "$SKILL" ]; then
    echo "FAIL: skills/workflow-init/SKILL.md not found"
    echo ""
    echo "Results: 0 passed, 1 failed, 0 skipped"
    exit 1
fi

# F1: workflow-init SKILL.md Step 3 initial check references ISSUES[@] loop
if grep -qE '\$\{?ISSUES\[@\]\}?' "$SKILL"; then
    pass "F1: SKILL.md references ISSUES[@] loop (related-issue iteration)"
else
    skip "F1: pattern '\${ISSUES[@]}' not yet in SKILL.md (pre-implementation)"
fi

# F2: workflow-init SKILL.md contains issue-state-check.sh call
if grep -q 'issue-state-check\.sh' "$SKILL"; then
    pass "F2: SKILL.md invokes bin/github-issues/issue-state-check.sh"
else
    skip "F2: 'issue-state-check.sh' not yet in SKILL.md (pre-implementation)"
fi

# #2473 WI-1a: wf-init calls /migrate once, every time, before the driver; only the result is branched on.
WI1A=$(awk '/^### WI-1a/{f=1; print; next} f && /^### /{exit} f{print}' "$SKILL")
L_WI1=$(grep -n '^### WI-1 ' "$SKILL" | head -1 | cut -d: -f1)
L_WI1A=$(grep -n '^### WI-1a' "$SKILL" | head -1 | cut -d: -f1)
L_WI2=$(grep -n '^### WI-2 ' "$SKILL" | head -1 | cut -d: -f1)
if [ -n "$L_WI1" ] && [ -n "$L_WI1A" ] && [ -n "$L_WI2" ] && [ "$L_WI1" -lt "$L_WI1A" ] && [ "$L_WI1A" -lt "$L_WI2" ]; then
    pass "G12-1: WI-1a sits after WI-1 and before the WI-2 driver loop"
else
    fail "G12-1: WI-1a position wi1=$L_WI1 wi1a=$L_WI1A wi2=$L_WI2 (expected WI-1 < WI-1a < WI-2)"
fi

if printf '%s\n' "$WI1A" | grep -Eq '(^|[^-[:alnum:]])/migrate([^-[:alnum:]]|$)'; then
    pass "G12-2: WI-1a invokes /migrate"
else
    fail "G12-2: WI-1a does not invoke /migrate"
fi

if [ -n "$WI1A" ] && ! printf '%s\n' "$WI1A" | grep -Eq 'bin/migrate-needs|AskUserQuestion'; then
    pass "G12-3: WI-1a carries no bin/migrate-needs call and no AskUserQuestion (the judgment lives in /migrate)"
else
    fail "G12-3: WI-1a is missing or names bin/migrate-needs / AskUserQuestion"
fi

g12_missing=""
for v in ok skipped failed; do
    printf '%s\n' "$WI1A" | grep -Eq "MIGRATE_RESULT=?[^[:alnum:]]*$v|$v.*MIGRATE_RESULT|MIGRATE_RESULT.*$v" || g12_missing="$g12_missing $v"
done
if [ -n "$WI1A" ] && [ -z "$g12_missing" ] && printf '%s\n' "$WI1A" | grep -q 'WI-2'; then
    pass "G12-4: WI-1a branches on MIGRATE_RESULT ok / skipped / failed and names WI-2 as the way on"
else
    fail "G12-4: WI-1a result branches missing:${g12_missing:- (WI-2 not named)}"
fi

SKILL_LINES=$(wc -l < "$SKILL" | tr -d ' ')
if [ "$SKILL_LINES" -le 100 ]; then
    pass "G12-5: workflow-init SKILL.md stays at or under 100 lines ($SKILL_LINES)"
else
    fail "G12-5: workflow-init SKILL.md has $SKILL_LINES lines (limit 100)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
exit $((FAIL > 0 ? 1 : 0))
