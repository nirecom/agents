#!/usr/bin/env bash
# Static + integration tests for fail-loud pattern in SKILL.md (issue #558).
# Ensures review-plan-codex non-zero exit is propagated correctly.
# Will FAIL until SKILL.md changes land (test-first).
set -uo pipefail

AGENTS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export AGENTS_CONFIG_DIR="$AGENTS_ROOT"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

OUTLINE_SKILL="$AGENTS_ROOT/skills/make-outline-plan/SKILL.md"
DETAIL_SKILL="$AGENTS_ROOT/skills/make-detail-plan/SKILL.md"

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
    else
        fail "$desc (pattern not found: $pattern)"
    fi
}

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
    else
        pass "$desc"
    fi
}

echo "=== feature-558 codex caller fail-loud tests ==="
echo ""

echo "--- Anti-pattern absence ---"

# F1: make-outline-plan SKILL.md does NOT use "if ! review-plan-codex"
assert_absent "$OUTLINE_SKILL" 'if !.*review-plan-codex' \
    "F1: make-outline-plan/SKILL.md does NOT use 'if ! review-plan-codex' anti-pattern"

# F2: make-detail-plan SKILL.md does NOT use "if ! review-plan-codex"
assert_absent "$DETAIL_SKILL" 'if !.*review-plan-codex' \
    "F2: make-detail-plan/SKILL.md does NOT use 'if ! review-plan-codex' anti-pattern"

echo ""
echo "--- Correct rc=\$? capture pattern ---"

# F3: make-outline-plan SKILL.md contains rc=$? following review-plan-codex
assert_contains "$OUTLINE_SKILL" 'rc=\$\?' \
    'F3: make-outline-plan/SKILL.md contains rc=$? (correct fail-loud capture)'

# F4: make-detail-plan SKILL.md contains rc=$?
assert_contains "$DETAIL_SKILL" 'rc=\$\?' \
    'F4: make-detail-plan/SKILL.md contains rc=$? (correct fail-loud capture)'

echo ""
echo "--- exit \$rc propagation ---"

# F5: make-outline-plan SKILL.md propagates non-zero via exit "$rc" or exit $rc
assert_contains "$OUTLINE_SKILL" 'exit "\$rc"|exit \$rc' \
    'F5: make-outline-plan/SKILL.md propagates non-zero exit via exit $rc'

# F6: make-detail-plan SKILL.md propagates non-zero
assert_contains "$DETAIL_SKILL" 'exit "\$rc"|exit \$rc' \
    'F6: make-detail-plan/SKILL.md propagates non-zero exit via exit $rc'

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
if [[ $ERRORS -eq 0 ]]; then
    echo "All tests passed."
    exit 0
else
    echo "$ERRORS test(s) failed."
    exit 1
fi
