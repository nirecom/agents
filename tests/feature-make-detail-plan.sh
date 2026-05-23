#!/usr/bin/env bash
# Contract tests for make-detail-plan skill (issue #462 class enumeration carry-forward)
# Target files (expected to FAIL until implementation is complete):
#   skills/make-detail-plan/SKILL.md (worktree-local)
# Exit 0 always — this is a contract test, not a CI gate yet.

# Timeout guard: if running without the sentinel, re-exec under timeout
if [ -z "$_TIMEOUT_WRAPPED" ]; then
    export _TIMEOUT_WRAPPED=1
    if command -v timeout >/dev/null 2>&1; then
        exec timeout 120 bash "$0" "$@"
    else
        exec perl -e 'alarm 120; exec @ARGV' -- bash "$0" "$@"
    fi
fi

AGENTS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL_MD="$AGENTS_ROOT/skills/make-detail-plan/SKILL.md"

PASS=0
FAIL=0

pass() {
    echo "PASS: $1"
    PASS=$((PASS + 1))
}

fail() {
    echo "FAIL: $1"
    FAIL=$((FAIL + 1))
}

# assert_contains FILE PATTERN DESCRIPTION
assert_contains() {
    local file="$1"
    local pattern="$2"
    local desc="$3"

    if [ ! -f "$file" ]; then
        fail "$desc (file not found: $file)"
        return 1
    fi

    if grep -qE "$pattern" "$file"; then
        pass "$desc"
        return 0
    else
        fail "$desc (pattern not found: $pattern)"
        return 1
    fi
}

# assert_absent FILE PATTERN DESCRIPTION
assert_absent() {
    local file="$1"
    local pattern="$2"
    local desc="$3"

    if [ ! -f "$file" ]; then
        fail "$desc (file not found: $file)"
        return 1
    fi

    if grep -qE "$pattern" "$file"; then
        fail "$desc (pattern unexpectedly found: $pattern)"
        return 1
    else
        pass "$desc"
        return 0
    fi
}

echo "=== make-detail-plan contract tests (issue #462) ==="
echo ""

echo "--- Issue #462: make-detail-plan assemble-mandatory ---"

# D10: assemble-mandatory.sh call in make-detail-plan/SKILL.md
if grep -q "assemble-mandatory" "$SKILL_MD" 2>/dev/null; then
    pass "D10: assemble-mandatory.sh referenced in make-detail-plan/SKILL.md"
else
    fail "D10: assemble-mandatory.sh NOT referenced in make-detail-plan/SKILL.md"
fi

# D11: outline.md referenced as carry-forward source for mandatory sections
if grep -qE "outline\.md|outline_md" "$SKILL_MD" 2>/dev/null; then
    pass "D11: outline.md referenced as carry-forward source in make-detail-plan/SKILL.md"
else
    fail "D11: outline.md carry-forward source reference missing from SKILL.md"
fi

echo ""
echo "=== Summary ==="
echo "PASS: $PASS  FAIL: $FAIL"

exit 0
