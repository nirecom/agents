#!/bin/bash
# Tests for issue #325 — skills/issue-close/SKILL.md deprecation alias.
#
# After splitting /issue-close into /issue-close-stage + /issue-close-finalize,
# the original skills/issue-close/ directory is renamed; a NEW SKILL.md is
# placed back at skills/issue-close/SKILL.md as a deprecation alias that
# instructs the model to non-zero exit and route to the new skills.
#
# This is a pure static content test — no implementation needed beyond the
# new SKILL.md file content.
#
# RED: fails clean while the deprecation alias file is missing or lacks the
# required content (the old skills/issue-close/SKILL.md fails these checks).

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ALIAS_FILE="$AGENTS_DIR/skills/issue-close/SKILL.md"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# --- Existence gate ---------------------------------------------------------
if [ ! -f "$ALIAS_FILE" ]; then
    echo "FAIL: precondition missing — skills/issue-close/SKILL.md"
    echo ""
    echo "Results: 0 passed, 1 failed"
    exit 1
fi

# Pre-check: is the file the deprecation alias (not the original skill)?
# The original skill does not contain "DEPRECATED". If it's still the
# original, fail clean — RED phase.
if ! grep -qi "DEPRECATED" "$ALIAS_FILE"; then
    echo "FAIL: precondition missing — skills/issue-close/SKILL.md is not yet the deprecation alias (no DEPRECATED marker)"
    echo ""
    echo "Results: 0 passed, 1 failed"
    exit 1
fi

# ============================================================================
# DA-series — deprecation alias static content
# ============================================================================

# --- DA1: frontmatter contains `name: issue-close`
if grep -qE '^name: issue-close$' "$ALIAS_FILE"; then
    pass "DA1: frontmatter name: issue-close"
else
    fail "DA1: frontmatter name missing"
fi

# --- DA2: file contains "DEPRECATED" (case-insensitive)
if grep -qi "DEPRECATED" "$ALIAS_FILE"; then
    pass "DA2: contains DEPRECATED"
else
    fail "DA2: DEPRECATED missing"
fi

# --- DA3: file mentions /issue-close-stage AND /issue-close-finalize
if grep -q "issue-close-stage" "$ALIAS_FILE" && grep -q "issue-close-finalize" "$ALIAS_FILE"; then
    pass "DA3: mentions both new skills"
else
    fail "DA3: missing skill references"
fi

# --- DA4: file instructs non-zero exit (code 1)
if grep -qiE "exit.*code 1|code 1|exit with code 1|exits non-zero|Exit with code 1" "$ALIAS_FILE"; then
    pass "DA4: instructs non-zero exit"
else
    fail "DA4: non-zero exit instruction missing"
fi

# --- DA5: file does NOT contain `## Step D` or `## Step E` (old steps removed)
if ! grep -qE '^## Step [DE]' "$ALIAS_FILE"; then
    pass "DA5: no old step headers"
else
    fail "DA5: old step headers found (D or E still present)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
