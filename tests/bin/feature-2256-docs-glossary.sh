#!/usr/bin/env bash
# tests/feature-2256-docs-glossary.sh
# Tests: docs/glossary.md, skills/update-docs/SKILL.md, agents/supervisor-audit.md
# Tags: docs, glossary, terminology, static, TL1, scope:issue-specific

# #2256 delivery items 9 and 10 — update-docs must treat docs/glossary.md as a
# mandatory target, every term the outline fixed must have an entry there, and the
# hyphenated `recurrence-patterns` spelling must be gone from the three audit-side
# sites while the unrelated security-side "three axes" wording stays put.

set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GLOSSARY="$AGENTS_DIR/docs/glossary.md"
UPDATE_DOCS="$AGENTS_DIR/skills/update-docs/SKILL.md"
SUP_AUDIT="$AGENTS_DIR/agents/supervisor-audit.md"
CC_DOC="$AGENTS_DIR/docs/architecture/claude-code.md"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1${2:+ — $2}"; FAIL=$((FAIL + 1)); }
assert_file() { if [ -f "$1" ]; then pass "$2"; else fail "$2" "missing file: $1"; fi; }
assert_grep() {
    if [ -f "$2" ] && grep -Eqi "$3" "$2"; then pass "$1"; else fail "$1" "/$3/ not found in $2"; fi
}
assert_nogrep() {
    if [ -f "$2" ] && grep -Eqi "$3" "$2"; then
        fail "$1" "/$3/ is still present in $2"
    else
        pass "$1"
    fi
}

# --- 1-3: update-docs owns docs/glossary.md as a mandatory target ---
assert_file "$UPDATE_DOCS" "1: skills/update-docs/SKILL.md exists"
assert_grep "2: update-docs names docs/glossary.md" "$UPDATE_DOCS" 'docs/glossary\.md'
if [ -f "$UPDATE_DOCS" ] && grep -Ei 'docs/glossary\.md' "$UPDATE_DOCS" | grep -Eqi 'optional|任意|skip'; then
    fail "3: the glossary entry is mandatory, not optional" "the glossary line is qualified as optional"
else
    pass "3: the glossary entry is mandatory, not optional"
fi

# --- 4: the glossary itself exists ---
assert_file "$GLOSSARY" "4: docs/glossary.md exists"

# --- 5-12: every term the outline Glossary fixed has an entry ---
assert_grep "5: 'audit ledger' has a glossary entry" "$GLOSSARY" 'audit ledger'
assert_grep "6: 'audit run identity' has a glossary entry" "$GLOSSARY" 'audit run identity'
assert_grep "7: 'freshness backstop' has a glossary entry" "$GLOSSARY" 'freshness backstop'
assert_grep "8: 'audit checklist' has a glossary entry" "$GLOSSARY" 'audit checklist'
assert_grep "9: 'review round' has a glossary entry" "$GLOSSARY" 'review round'
assert_grep "10: CAP and MAX_EXTENSIONS have glossary entries" "$GLOSSARY" 'MAX_EXTENSIONS'
assert_grep "11: 'step' has its own glossary entry row" "$GLOSSARY" '^(\| *)?(\*\*)?step(\*\*)? *[|:—-]'
assert_grep "12: 'trigger' has its own glossary entry row" "$GLOSSARY" '^(\| *)?(\*\*)?trigger(\*\*)? *[|:—-]'
assert_grep "13: the arm / surface / clear lifecycle has a glossary entry" "$GLOSSARY" 'arm */ *surface */ *clear'

# --- 14-16: the hyphenated identifier-like spelling is gone from the audit sites ---
assert_nogrep "14: agents/supervisor-audit.md no longer writes recurrence-patterns" \
    "$SUP_AUDIT" 'recurrence-patterns'
assert_nogrep "15: docs/architecture/claude-code.md no longer writes recurrence-patterns" \
    "$CC_DOC" 'recurrence-patterns'
assert_grep "16: the space-separated 'recurrence patterns' wording is used instead" \
    "$SUP_AUDIT" 'recurrence patterns'

# --- 17: the audit checklist is no longer described as three axes ---
assert_nogrep "17: agents/supervisor-audit.md no longer calls the checklist three axes" \
    "$SUP_AUDIT" 'three axes'

# --- 18-21: the unrelated security-side "three axes" wording is untouched ---
assert_grep "18: agents/security-scanner.md keeps its three axes wording" \
    "$AGENTS_DIR/agents/security-scanner.md" 'three axes'
assert_grep "19: agents/plan-security-reviewer.md keeps its three axes wording" \
    "$AGENTS_DIR/agents/plan-security-reviewer.md" 'three axes'
assert_grep "20: bin/review-plan-codex keeps its three axes wording" \
    "$AGENTS_DIR/bin/review-plan-codex" 'three axes'
assert_grep "21: skills/review-code-security/SKILL.md keeps its three axes wording" \
    "$AGENTS_DIR/skills/review-code-security/SKILL.md" 'three axes'

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -eq 0 ]; then
    echo "All tests passed."
    exit 0
fi
exit 1
