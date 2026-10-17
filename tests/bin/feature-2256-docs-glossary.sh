#!/usr/bin/env bash
# tests/bin/feature-2256-docs-glossary.sh
# Tests: docs/glossary-user.md, docs/glossary-internal.md, skills/update-docs/SKILL.md, agents/supervisor-audit.md, docs/architecture/claude-code/supervisor-audit-ledger.md
# Tags: docs, glossary, terminology, static, TL1, scope:issue-specific

# #2256 delivery items 9 and 10 — the hyphenated `recurrence-patterns` spelling must be
# gone from the three audit-side sites while the unrelated security-side "three axes"
# wording stays put. #2529 replaced the "every term gets a glossary entry" duty with the
# entry criteria in rules/docs/glossary.md: update-docs promotes terms through bin/glossary-promote,
# the glossary splits into glossary-user.md / glossary-internal.md, and single-subsystem
# audit terms are defined once in their owning documents instead.

set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

GL_USER="$SCRIPT_CHECKOUT_ROOT/docs/glossary-user.md"
GL_INTERNAL="$SCRIPT_CHECKOUT_ROOT/docs/glossary-internal.md"
UPDATE_DOCS="$SCRIPT_CHECKOUT_ROOT/skills/update-docs/SKILL.md"
SUP_AUDIT="$SCRIPT_CHECKOUT_ROOT/agents/supervisor-audit.md"
AUDIT_LEDGER="$SCRIPT_CHECKOUT_ROOT/docs/architecture/claude-code/supervisor-audit-ledger.md"
CC_DOC="$SCRIPT_CHECKOUT_ROOT/docs/architecture/claude-code.md"

assert_file() { if [ -f "$1" ]; then pass "$2"; else fail "$2" "missing file: $1"; fi; }
assert_grep() {
    if [ -f "$2" ] && grep -Eqi "$3" "$2"; then pass "$1"; else fail "$1" "/$3/ not found in $2"; fi
}
# An absence over a missing or empty file proves nothing, so the file must have content.
assert_nogrep() {
    if [ ! -s "$2" ]; then
        fail "$1" "$2 missing or empty; absence not provable"
    elif grep -Eqi "$3" "$2"; then
        fail "$1" "/$3/ is still present in $2"
    else
        pass "$1"
    fi
}

# entry <file> <term> — the body of one "### <term>" glossary entry.
entry() { awk -v h="### $2" '{ sub(/\r$/, "") } $0 == h { on = 1; next } /^##+ / { on = 0 } on' "$1" 2>/dev/null; }

# assert_no_heading <name> <term-regex> — no "### " heading in either glossary file names
# the term; both files must exist for the absence to count.
assert_no_heading() {
    if [ ! -s "$GL_USER" ] || [ ! -s "$GL_INTERNAL" ]; then
        fail "$1" "glossary-user.md / glossary-internal.md missing or empty; absence not provable"
    elif grep -Eqi "^### .*($2)" "$GL_USER" "$GL_INTERNAL"; then
        fail "$1" "a glossary heading still names /$2/"
    else
        pass "$1"
    fi
}

# --- 1-3: update-docs promotes glossary terms through the rule and glossary-promote ---
case_begin "update-docs-uses-rule-and-promote" "skills/update-docs/SKILL.md"
assert_grep "1: update-docs points to rules/docs/glossary.md" "$UPDATE_DOCS" 'rules/docs/glossary\.md'
assert_grep "2: update-docs points to bin/glossary-promote" "$UPDATE_DOCS" 'glossary-promote'
assert_nogrep "3: update-docs no longer demands an entry for every term" "$UPDATE_DOCS" 'every term'
case_end

# --- 4: both glossary files exist ---
case_begin "glossary-split-files-exist" "docs/glossary-internal.md"
assert_file "$GL_USER" "4a: docs/glossary-user.md exists"
assert_file "$GL_INTERNAL" "4b: docs/glossary-internal.md exists"
case_end

# --- 5-7, 12: the removed ledger terms live in supervisor-audit-ledger.md ---
case_begin "ledger-terms-live-in-owner" "docs/architecture/claude-code/supervisor-audit-ledger.md"
assert_no_heading "5a: 'audit ledger' has no glossary entry" 'audit ledger'
assert_grep "5b: 'audit ledger' is defined in supervisor-audit-ledger.md" "$AUDIT_LEDGER" 'audit ledger'
assert_no_heading "6a: 'audit run identity' has no glossary entry" 'audit run identity'
assert_grep "6b: 'audit run identity' is defined in supervisor-audit-ledger.md" "$AUDIT_LEDGER" 'audit run identity'
assert_no_heading "7a: 'freshness backstop' has no glossary entry" 'freshness backstop'
assert_grep "7b: 'freshness backstop' is defined in supervisor-audit-ledger.md" "$AUDIT_LEDGER" 'freshness backstop'
assert_no_heading "12a: 'trigger' has no glossary entry" 'trigger'
assert_grep "12b: 'trigger' is defined in supervisor-audit-ledger.md" "$AUDIT_LEDGER" 'trigger'
case_end

# --- 8, 13: the removed audit-agent terms live in agents/supervisor-audit.md ---
case_begin "audit-agent-terms-live-in-owner" "agents/supervisor-audit.md"
assert_no_heading "8a: 'audit checklist' has no glossary entry" 'audit checklist'
assert_grep "8b: 'audit checklist' is defined in agents/supervisor-audit.md" "$SUP_AUDIT" 'audit checklist'
assert_no_heading "13a: the arm / surface / clear lifecycle has no glossary entry" 'arm */ *surface */ *clear'
assert_grep "13b: arm / surface / clear is defined in agents/supervisor-audit.md" "$SUP_AUDIT" 'arm */ *surface */ *clear'
case_end

# --- 9-10: review round stays, in glossary-internal.md, expanding CAP and MAX_EXTENSIONS ---
case_begin "review-round-entry-in-internal" "docs/glossary-internal.md"
RR="$(entry "$GL_INTERNAL" 'review round')"
if [ -n "$RR" ]; then pass "9: 'review round' has an entry in glossary-internal.md"
else fail "9: 'review round' has an entry in glossary-internal.md" "no '### review round' entry"; fi
if printf '%s\n' "$RR" | grep -q 'CAP' && printf '%s\n' "$RR" | grep -q 'MAX_EXTENSIONS'; then
    pass "10: the review round entry expands CAP and MAX_EXTENSIONS"
else
    fail "10: the review round entry expands CAP and MAX_EXTENSIONS" "CAP / MAX_EXTENSIONS absent from the entry"
fi
case_end

# --- 11: bare "step" is folded into the workflow step definition ---
case_begin "workflow-step-entry-names-short-form" "docs/glossary-user.md"
WS="$(entry "$GL_USER" 'workflow step')"
WS_BARE="$(printf '%s\n' "$WS" | sed -E 's/(workflow|in-skill) steps?//Ig')"
if [ -n "$WS" ] && printf '%s\n' "$WS_BARE" | grep -Eqiw 'step'; then
    pass "11: the workflow step definition names the short form 'step'"
else
    fail "11: the workflow step definition names the short form 'step'" "no bare 'step' in the '### workflow step' entry"
fi
case_end

# --- 14-17: the hyphenated spelling and "three axes" are gone from the audit sites ---
case_begin "audit-sites-drop-hyphenated-spelling" "agents/supervisor-audit.md"
assert_nogrep "14: agents/supervisor-audit.md no longer writes recurrence-patterns" \
    "$SUP_AUDIT" 'recurrence-patterns'
assert_nogrep "15: docs/architecture/claude-code.md no longer writes recurrence-patterns" \
    "$CC_DOC" 'recurrence-patterns'
assert_grep "16: the space-separated 'recurrence patterns' wording is used instead" \
    "$SUP_AUDIT" 'recurrence patterns'
assert_nogrep "17: agents/supervisor-audit.md no longer calls the checklist three axes" \
    "$SUP_AUDIT" 'three axes'
case_end

# --- 18-21: the unrelated security-side "three axes" wording is untouched ---
# Out-of-header targets: the case attributes to the audit agent whose rewording must not leak.
case_begin "security-side-keeps-three-axes" "agents/supervisor-audit.md"
assert_grep "18: agents/security-scanner.md keeps its three axes wording" \
    "$SCRIPT_CHECKOUT_ROOT/agents/security-scanner.md" 'three axes'
assert_grep "19: agents/plan-security-reviewer.md keeps its three axes wording" \
    "$SCRIPT_CHECKOUT_ROOT/agents/plan-security-reviewer.md" 'three axes'
assert_grep "20: bin/review-plan-codex keeps its three axes wording" \
    "$SCRIPT_CHECKOUT_ROOT/bin/review-plan-codex" 'three axes'
assert_grep "21: skills/review-code-security/SKILL.md keeps its three axes wording" \
    "$SCRIPT_CHECKOUT_ROOT/skills/review-code-security/SKILL.md" 'three axes'
case_end

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -eq 0 ]; then
    echo "All tests passed."
    exit 0
fi
exit 1
