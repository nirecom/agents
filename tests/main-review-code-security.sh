#!/usr/bin/env bash
# Structural tests for claude-global/skills/review-code-security/SKILL.md
set -euo pipefail

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

DOTFILES_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$DOTFILES_DIR/claude-global/skills/review-code-security/SKILL.md"
PRIVATE_INFO_DOC="$DOTFILES_DIR/docs/scan-outbound.md"

echo "=== review-code-security skill structural tests ==="

# --- Normal case 1: SKILL.md exists ---
if [ -f "$SKILL" ]; then
    pass "SKILL.md exists"
else
    fail "SKILL.md does not exist"
fi

# --- Normal case 2: frontmatter has required fields ---
for field in name description model effort; do
    if [ -f "$SKILL" ] && grep -qE "^${field}:" "$SKILL" 2>/dev/null; then
        pass "frontmatter has '$field'"
    else
        fail "frontmatter missing '$field'"
    fi
done

# --- Normal case 3: name field is review-code-security ---
if [ -f "$SKILL" ] && grep -qE '^name: review-code-security$' "$SKILL" 2>/dev/null; then
    pass "name is 'review-code-security'"
else
    fail "name is not 'review-code-security'"
fi

# --- Normal case 4: has ## Procedure, ## Rules, ## Patterns by Axis sections ---
for section in "Procedure" "Rules" "Patterns by Axis"; do
    if [ -f "$SKILL" ] && grep -qE "^## ${section}" "$SKILL" 2>/dev/null; then
        pass "has ## $section section"
    else
        fail "missing ## $section section"
    fi
done

# --- Normal case 5: has the 3 axis headers ---
for axis in "Axis 1: Information Leakage" "Axis 2: Third-Party Access" "Axis 3: External Access"; do
    if [ -f "$SKILL" ] && grep -qF "### $axis" "$SKILL" 2>/dev/null; then
        pass "has '### $axis' header"
    else
        fail "missing '### $axis' header"
    fi
done

# --- Normal case 6: contains OWASP or CWE- citations ---
if [ -f "$SKILL" ] && grep -qE '(OWASP|CWE-)' "$SKILL" 2>/dev/null; then
    pass "contains OWASP/CWE citations"
else
    fail "missing OWASP/CWE citations"
fi

# --- Normal case 8: cross-references /review-plan-security ---
if [ -f "$SKILL" ] && grep -qF '/review-plan-security' "$SKILL" 2>/dev/null; then
    pass "cross-references /review-plan-security"
else
    fail "does not cross-reference /review-plan-security"
fi

# --- Normal case 9: references docs/scan-outbound.md ---
if [ -f "$SKILL" ] && grep -qF 'docs/scan-outbound.md' "$SKILL" 2>/dev/null; then
    pass "references docs/scan-outbound.md"
else
    fail "does not reference docs/scan-outbound.md"
fi

# --- Normal case 10: contains 'Automated coverage' phrase ---
if [ -f "$SKILL" ] && perl -lne 'if (/Automated coverage/i) { $found=1 } END { exit($found ? 0 : 1) }' "$SKILL" 2>/dev/null; then
    pass "SKILL.md contains 'Automated coverage' phrase"
else
    fail "SKILL.md does not contain 'Automated coverage' phrase"
fi

# --- Edge case 11: no absolute paths (public repo leak check) ---
if [ -f "$SKILL" ] && grep -qiE '(^|[^a-zA-Z])(c:/|/home/|/Users/)' "$SKILL" 2>/dev/null; then
    fail "absolute path found in SKILL.md (public repo leak)"
else
    pass "no absolute paths in SKILL.md"
fi

# --- Edge case 12: no references to dotfiles-private/ ---
if [ -f "$SKILL" ] && grep -qF 'dotfiles-private/' "$SKILL" 2>/dev/null; then
    fail "SKILL.md references dotfiles-private/ (private repo leak)"
else
    pass "no references to dotfiles-private/ in SKILL.md"
fi

# --- Security case 13: AWS key pattern appears only inside backticks/code blocks ---
# Strategy: strip fenced code blocks (``` ... ```) and inline backtick spans, then search.
if [ -f "$SKILL" ]; then
    stripped=$(perl -0777 -pe 's/```.*?```//gs; s/`[^`]*`//g' "$SKILL" 2>/dev/null || true)
    if echo "$stripped" | grep -qE 'AKIA[0-9A-Z]{16}'; then
        fail "AWS key pattern AKIA[0-9A-Z]{16} appears outside code blocks/backticks in SKILL.md"
    else
        pass "AWS key pattern only appears inside code blocks/backticks (or not at all)"
    fi
else
    pass "SKILL.md absent — security pattern check skipped (file-existence failure already recorded)"
fi

# --- Idempotency case 14: docs/scan-outbound.md mentions review-code-security exactly once ---
if [ -f "$PRIVATE_INFO_DOC" ]; then
    count=$(grep -c 'review-code-security' "$PRIVATE_INFO_DOC" 2>/dev/null || true)
    : "${count:=0}"
    if [ "$count" -eq 1 ]; then
        pass "docs/scan-outbound.md mentions review-code-security exactly once"
    else
        fail "docs/scan-outbound.md mentions review-code-security $count times (expected exactly 1)"
    fi
else
    fail "docs/scan-outbound.md does not exist"
fi

# --- Normal case 15: SKILL.md has a ## Completion section ---
if [ -f "$SKILL" ] && grep -qE '^## Completion' "$SKILL" 2>/dev/null; then
    pass "SKILL.md has ## Completion section"
else
    fail "SKILL.md missing ## Completion section"
fi

# --- Normal case 16: Completion section contains review_security_complete sentinel ---
if [ -f "$SKILL" ] && grep -qF 'WORKFLOW_MARK_STEP_review_security_complete' "$SKILL" 2>/dev/null; then
    pass "Completion section contains review_security_complete sentinel"
else
    fail "Completion section missing review_security_complete sentinel"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
