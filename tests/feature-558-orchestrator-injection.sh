#!/usr/bin/env bash
# Static and integration tests for triage-split.sh orchestrator injection (issue #558).
# Static tests check SKILL.md files; integration test runs triage-split.sh against a fixture.
# Will FAIL until source changes land (test-first).
set -uo pipefail

AGENTS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export AGENTS_CONFIG_DIR="$AGENTS_ROOT"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

OUTLINE_SKILL="$AGENTS_ROOT/skills/make-outline-plan/SKILL.md"
DETAIL_SKILL="$AGENTS_ROOT/skills/make-detail-plan/SKILL.md"
TRIAGE_SPLIT="$AGENTS_ROOT/skills/_shared/triage-split.sh"

TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 120 "$@"
    else
        perl -e 'alarm 120; exec @ARGV' -- "$@"
    fi
}

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

echo "=== feature-558 orchestrator injection tests ==="
echo ""

# ---------------------------------------------------------------------------
# Static tests
# ---------------------------------------------------------------------------
echo "--- Static: SKILL.md references ---"

# S1: make-outline-plan/SKILL.md contains triage-split.sh
assert_contains "$OUTLINE_SKILL" "triage-split\.sh" \
    "S1: make-outline-plan/SKILL.md references triage-split.sh"

# S2: make-detail-plan/SKILL.md contains triage-split.sh
assert_contains "$DETAIL_SKILL" "triage-split\.sh" \
    "S2: make-detail-plan/SKILL.md references triage-split.sh"

# S3: make-outline-plan/SKILL.md contains TRIAGE_BLOCK
assert_contains "$OUTLINE_SKILL" "TRIAGE_BLOCK" \
    "S3: make-outline-plan/SKILL.md contains TRIAGE_BLOCK variable"

# S4: make-detail-plan/SKILL.md contains TRIAGE_BLOCK
assert_contains "$DETAIL_SKILL" "TRIAGE_BLOCK" \
    "S4: make-detail-plan/SKILL.md contains TRIAGE_BLOCK variable"

# S5: make-outline-plan/SKILL.md: rc=$? pattern (correct fail-loud)
assert_contains "$OUTLINE_SKILL" 'rc=\$\?' \
    "S5: make-outline-plan/SKILL.md uses rc=\$? after review-plan-codex (correct fail-loud)"

# S6: make-detail-plan/SKILL.md: rc=$? pattern
assert_contains "$DETAIL_SKILL" 'rc=\$\?' \
    "S6: make-detail-plan/SKILL.md uses rc=\$? after review-plan-codex (correct fail-loud)"

# S7: make-outline-plan/SKILL.md does NOT use bash anti-pattern "if ! review-plan-codex"
assert_absent "$OUTLINE_SKILL" 'if !.*review-plan-codex' \
    "S7: make-outline-plan/SKILL.md does NOT use 'if ! review-plan-codex' anti-pattern"

# S8: make-detail-plan/SKILL.md does NOT use bash anti-pattern "if ! review-plan-codex"
assert_absent "$DETAIL_SKILL" 'if !.*review-plan-codex' \
    "S8: make-detail-plan/SKILL.md does NOT use 'if ! review-plan-codex' anti-pattern"

echo ""
echo "--- Integration: triage-split.sh output ---"

# I1: Run triage-split.sh against a fixture with 3-value dispositions.
#     Output must contain all 3 section headers.
FIXTURE_I1="$TMPDIR_BASE/fixture-i1.md"
cat > "$FIXTURE_I1" << 'FIXTURE_EOF'
# Intent

## Issue

Issue body.

## Class members

- alpha: a must-fix item — disposition: MUST
- beta: an optional item — disposition: OPTIONAL
- gamma: out of scope — disposition: NA

## Accepted Tradeoffs

- none
FIXTURE_EOF

EC=0
OUT=$(run_with_timeout bash "$TRIAGE_SPLIT" "$FIXTURE_I1" 2>&1) || EC=$?
if [[ "$EC" == "0" ]]; then
    HEADER_MUST=0
    HEADER_OPT=0
    HEADER_NA=0
    echo "$OUT" | grep -q '^### MUST (fix in scope required)$' && HEADER_MUST=1
    echo "$OUT" | grep -q '^### OPTIONAL (planner judgment, justify in plan)$' && HEADER_OPT=1
    echo "$OUT" | grep -q '^### NA (out of scope, do not address)$' && HEADER_NA=1
    if [[ "$HEADER_MUST" == "1" && "$HEADER_OPT" == "1" && "$HEADER_NA" == "1" ]]; then
        pass "I1: triage-split.sh 3-value fixture: all 3 section headers present"
    else
        fail "I1: triage-split.sh output missing headers (MUST=$HEADER_MUST OPT=$HEADER_OPT NA=$HEADER_NA). Output:
$OUT"
    fi
else
    fail "I1: triage-split.sh exited $EC. Output: $OUT"
fi

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
