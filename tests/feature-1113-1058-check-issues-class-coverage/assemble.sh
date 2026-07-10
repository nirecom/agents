#!/usr/bin/env bash
# Tests: skills/_shared/assemble-mandatory.sh
# Tags: scope:issue-specific
# Assemble-integration tests: verifies assemble-mandatory.sh invokes the
# bin/check-issues-class-coverage outline gate at the correct call sites.
# TC-A1 and TC-A2 pass immediately; TC-A1 wiring check and TC-A4 fail until
# the gate is wired into assemble-mandatory.sh.
set -uo pipefail

AGENTS_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GATE="$AGENTS_ROOT/bin/check-issues-class-coverage"
ASSEMBLE="$AGENTS_ROOT/skills/_shared/assemble-mandatory.sh"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 120 "$@"
    else
        perl -e 'alarm 120; exec @ARGV' -- "$@"
    fi
}

TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Minimal valid source fixture: 1 issue, 1 class member
A_SOURCE="$TMPDIR_BASE/a-source.md"
cat > "$A_SOURCE" << 'EOF'
## Issues

- #300: test issue

## Class members

- member-A

## Accepted Tradeoffs

- tradeoff A
EOF

A_PLANNER="$TMPDIR_BASE/a-planner.md"
cat > "$A_PLANNER" << 'EOF'
# Outline Plan — assemble test

## Delivery plan

Do the work.
EOF

# Source with 2 issues but only 1 class member (triggers gate block when wired)
A_SOURCE_2ISSUES="$TMPDIR_BASE/a-source-2issues.md"
cat > "$A_SOURCE_2ISSUES" << 'EOF'
## Issues

- #300: issue one
- #301: issue two

## Class members

- member-A

## Accepted Tradeoffs

- tradeoff A
EOF

# Detail planner fixture (valid for TC-A3)
A_DETAIL_PLANNER="$TMPDIR_BASE/a-detail-planner.md"
cat > "$A_DETAIL_PLANNER" << 'EOF'
# Detail Plan — assemble test

## Steps

- step 1

## Files to modify

- bin/foo
EOF

# TC-A1: --source-kind intent, -outline.md output, valid 1:1 coverage → assemble succeeds
A_OUT_A1="$TMPDIR_BASE/test-a1-outline.md"
EXIT_CODE=0; OUT=$(run_with_timeout bash "$ASSEMBLE" --source-kind intent \
    "$A_SOURCE" "$A_PLANNER" "$A_OUT_A1" 2>&1) || EXIT_CODE=$?
[[ $EXIT_CODE -eq 0 ]] \
    && pass "TC-A1: --source-kind intent, -outline.md output → assemble succeeds (gate did not block valid 1:1)" \
    || fail "TC-A1: --source-kind intent, -outline.md → expected exit 0, got $EXIT_CODE (output: $OUT)"

# Structural wiring check: gate must be referenced in assemble-mandatory.sh
grep -q "check-issues-class-coverage" "$ASSEMBLE" \
    && pass "TC-A1: assemble-mandatory.sh references check-issues-class-coverage (integration wired)" \
    || fail "TC-A1: assemble-mandatory.sh does NOT reference check-issues-class-coverage (integration not wired)"

# TC-A2: --source-kind outline, -outline.md output, valid 1:1 coverage → assemble succeeds
A_OUT_A2="$TMPDIR_BASE/test-a2-outline.md"
EXIT_CODE=0; OUT=$(run_with_timeout bash "$ASSEMBLE" --source-kind outline \
    "$A_SOURCE" "$A_PLANNER" "$A_OUT_A2" 2>&1) || EXIT_CODE=$?
[[ $EXIT_CODE -eq 0 ]] \
    && pass "TC-A2: --source-kind outline, -outline.md output → assemble succeeds (gate did not block valid 1:1)" \
    || fail "TC-A2: --source-kind outline, -outline.md → expected exit 0, got $EXIT_CODE (output: $OUT)"

# TC-A3: -detail.md output → gate is NOT invoked
# Use 2-issue / 1-member source so that IF the gate fires, it would block.
A_OUT_A3="$TMPDIR_BASE/test-a3-detail.md"
EXIT_CODE=0; OUT=$(run_with_timeout bash "$ASSEMBLE" --source-kind outline \
    "$A_SOURCE_2ISSUES" "$A_DETAIL_PLANNER" "$A_OUT_A3" 2>&1) || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 0 ]]; then
    pass "TC-A3: -detail.md output → gate NOT invoked (assemble succeeds despite 2 issues / 1 member)"
else
    echo "$OUT" | grep -qi "check-issues-class-coverage\|class.*coverage\|undercoverage" \
        && fail "TC-A3: -detail.md output → gate was invoked and blocked (must NOT fire for detail output)" \
        || fail "TC-A3: -detail.md output → assemble failed for unexpected reason (exit $EXIT_CODE, output: $OUT)"
fi

# TC-A4: Issues=2 > Class members=1, -outline.md → gate blocks assemble
A_OUT_A4="$TMPDIR_BASE/test-a4-outline.md"
EXIT_CODE=0; OUT=$(run_with_timeout bash "$ASSEMBLE" --source-kind intent \
    "$A_SOURCE_2ISSUES" "$A_PLANNER" "$A_OUT_A4" 2>&1) || EXIT_CODE=$?
[[ $EXIT_CODE -ne 0 ]] \
    && pass "TC-A4: Issues=2, members=1, -outline.md → gate blocks assemble (non-zero exit)" \
    || fail "TC-A4: Issues=2, members=1, -outline.md → expected non-zero (gate block), got 0"

TOTAL=$((PASS + FAIL))
echo ""
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
