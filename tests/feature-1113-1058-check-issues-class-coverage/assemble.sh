#!/usr/bin/env bash
# Tests: skills/_shared/assemble-mandatory.sh
# Tags: scope:issue-specific, TL2
# Assemble-integration tests for assemble-mandatory.sh: the outline coverage
# gate wiring (TC-A*) plus the #2228 changes — mandatory 3->2 (no Class members
# injection), Adopted-approach-first hard check (exit 4), and temp-before-mv so
# a failed verify never overwrites a prior outline.md. TC-C* are RED until those
# land.

# TL3 gap: no live make-outline-plan MOP path with a real PLAN_LANG=japanese
# planner, and no real concurrent writer racing the final mv. Closest
# mitigation: WORKFLOW_USER_VERIFIED preflight (skill-orchestration category).
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

## Adopted approach

Take approach A.

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

# ============================================================================
# TC-C: #2228 mandatory 3->2 + Adopted-approach-first check + temp-before-mv.
# RED until skills/_shared/assemble-mandatory.sh (+ hooks/lib/plan-schema.js
# node bridge) land the phase-3 changes.
# ============================================================================

# Good outline planner: first body H2 is the canonical "## Adopted approach".
C_PLANNER_GOOD="$TMPDIR_BASE/c-planner-good.md"
cat > "$C_PLANNER_GOOD" << 'EOF'
# Outline Plan — C good

## Adopted approach

Take approach A.

## Delivery plan

Do the work.
EOF

# Bad outline planner: first body H2 is NOT "## Adopted approach".
C_PLANNER_BAD="$TMPDIR_BASE/c-planner-bad.md"
cat > "$C_PLANNER_BAD" << 'EOF'
# Outline Plan — C bad

## Delivery plan

Do the work first.

## Adopted approach

Approach A (out of order).
EOF

# TC-C1: valid outline (Adopted approach first) → assemble succeeds and the
# output carries exactly the 2 remaining mandatory sections.
C_OUT_C1="$TMPDIR_BASE/test-c1-outline.md"
EXIT_CODE=0; OUT=$(run_with_timeout bash "$ASSEMBLE" --source-kind outline \
    "$A_SOURCE" "$C_PLANNER_GOOD" "$C_OUT_C1" 2>&1) || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 0 ]] && grep -q "^## Issues$" "$C_OUT_C1" 2>/dev/null \
    && grep -q "^## Accepted Tradeoffs$" "$C_OUT_C1" 2>/dev/null; then
    pass "TC-C1: valid outline (Adopted approach first) → assemble succeeds with Issues + Accepted Tradeoffs"
else
    fail "TC-C1: expected exit 0 with Issues + Accepted Tradeoffs (exit $EXIT_CODE, output: $OUT)"
fi

# TC-C2: mandatory 3→2 — assemble must NOT inject a '## Class members' section
# into the output even though the source still contains one.
if [[ -f "$C_OUT_C1" ]] && ! grep -q "^## Class members$" "$C_OUT_C1" 2>/dev/null; then
    pass "TC-C2: mandatory 3→2 → no '## Class members' injected into outline output"
else
    fail "TC-C2: '## Class members' still present in outline output (injection not removed)"
fi

# TC-C3: Adopted-approach-first hard check — outline whose first body H2 is not
# 'Adopted approach' must fail verify (exit 4).
C_OUT_C3="$TMPDIR_BASE/test-c3-outline.md"
EXIT_CODE=0; OUT=$(run_with_timeout bash "$ASSEMBLE" --source-kind outline \
    "$A_SOURCE" "$C_PLANNER_BAD" "$C_OUT_C3" 2>&1) || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 4 ]]; then
    pass "TC-C3: outline with non-first Adopted approach → verify_fail (exit 4)"
else
    fail "TC-C3: expected exit 4 (Adopted-approach-first check), got $EXIT_CODE (output: $OUT)"
fi

# TC-C4 (C5): temp-before-mv — a failed verify must NOT overwrite a pre-existing
# outline.md; its bytes stay identical.
C_OUT_C4="$TMPDIR_BASE/test-c4-outline.md"
printf 'SENTINEL PRIOR OUTLINE\n' > "$C_OUT_C4"
C4_BEFORE=$(cksum < "$C_OUT_C4")
EXIT_CODE=0; OUT=$(run_with_timeout bash "$ASSEMBLE" --source-kind outline \
    "$A_SOURCE" "$C_PLANNER_BAD" "$C_OUT_C4" 2>&1) || EXIT_CODE=$?
C4_AFTER=$(cksum < "$C_OUT_C4")
if [[ $EXIT_CODE -ne 0 && "$C4_BEFORE" == "$C4_AFTER" ]]; then
    pass "TC-C4: failed verify leaves prior outline.md byte-identical (temp-before-mv)"
else
    fail "TC-C4: prior outline.md changed on failed verify (exit $EXIT_CODE, before='$C4_BEFORE' after='$C4_AFTER')"
fi

# TC-C5: the Adopted-approach-first check is outline-only — a detail output with
# no 'Adopted approach' first body H2 must still succeed (both-verdict guard).
C_OUT_C5="$TMPDIR_BASE/test-c5-detail.md"
EXIT_CODE=0; OUT=$(run_with_timeout bash "$ASSEMBLE" --source-kind outline \
    "$A_SOURCE" "$C_PLANNER_BAD" "$C_OUT_C5" 2>&1) || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 0 ]]; then
    pass "TC-C5: detail output → Adopted-approach-first check NOT applied (assemble succeeds)"
else
    fail "TC-C5: detail output failed though Adopted-approach check must not fire (exit $EXIT_CODE, output: $OUT)"
fi

# TC-C7 (C5): a PLANNER DRAFT that itself carries a '## Class members' section
# must have it stripped from the assembled outline — under #2228 the mandatory
# set is 3→2 (no Class members injection) AND the planner-side duplicate is
# stripped, so neither the heading nor the planner's member text survives.
# RED until #2228: today Step 2 still injects '## Class members' from the source.
C_PLANNER_WITH_CM="$TMPDIR_BASE/c-planner-with-cm.md"
cat > "$C_PLANNER_WITH_CM" << 'EOF'
# Outline Plan — planner carries Class members

## Adopted approach

Take approach A.

## Class members

- planner-injected-member: MUST NOT survive assembly

## Delivery plan

Do the work.
EOF
C_OUT_C7="$TMPDIR_BASE/test-c7-outline.md"
EXIT_CODE=0; OUT=$(run_with_timeout bash "$ASSEMBLE" --source-kind outline \
    "$A_SOURCE" "$C_PLANNER_WITH_CM" "$C_OUT_C7" 2>&1) || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 0 ]] && [[ -f "$C_OUT_C7" ]] \
    && ! grep -q "^## Class members$" "$C_OUT_C7" 2>/dev/null \
    && ! grep -qF "planner-injected-member" "$C_OUT_C7" 2>/dev/null; then
    pass "TC-C7 (C5): planner-draft '## Class members' section is stripped from the assembled outline (heading + body gone)"
else
    fail "TC-C7 (C5): planner '## Class members' survived assembly (exit $EXIT_CODE, output: $OUT)"
fi

# TC-C9 (C5, detail draft): a DETAIL planner draft that itself carries a
# '## Class members' section must have it stripped from the assembled DETAIL
# output. Class members is an intent-only section (SSOT: intent.md), so a detail
# draft that duplicates it must not have the heading or its member text survive.
# The detail path never injects Class members either, so neither can reappear.
# RED until #2228 lands the planner-side strip.
C_DETAIL_WITH_CM="$TMPDIR_BASE/c-detail-planner-with-cm.md"
cat > "$C_DETAIL_WITH_CM" << 'EOF'
# Detail Plan — planner carries Class members

## Steps

- step 1

## Class members

- detail-planner-injected-member: MUST NOT survive assembly

## Files to modify

- bin/foo
EOF
C_OUT_C9="$TMPDIR_BASE/test-c9-detail.md"
EXIT_CODE=0; OUT=$(run_with_timeout bash "$ASSEMBLE" --source-kind outline \
    "$A_SOURCE" "$C_DETAIL_WITH_CM" "$C_OUT_C9" 2>&1) || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 0 ]] && [[ -f "$C_OUT_C9" ]] \
    && ! grep -q "^## Class members$" "$C_OUT_C9" 2>/dev/null \
    && ! grep -qF "detail-planner-injected-member" "$C_OUT_C9" 2>/dev/null; then
    pass "TC-C9 (C5): detail-planner-draft '## Class members' section is stripped from the assembled detail (heading + body gone)"
else
    fail "TC-C9 (C5): detail planner '## Class members' survived assembly (exit $EXIT_CODE, output: $OUT)"
fi

# TC-C6 (executable bridge assertion): the first body section of a successfully
# assembled outline must equal the stdout of the plan-schema CLI bridge
# `node hooks/lib/plan-schema.js --first-body-section outline`. The expected value
# is taken from the CLI stdout (the same bridge assemble-mandatory.sh calls), and
# compared by ACTUAL STRING EQUALITY against the first non-mandatory H2 extracted
# from the assembled file — not a grep-presence check. RED until the CLI exists.
PLAN_SCHEMA_BIN="$AGENTS_ROOT/hooks/lib/plan-schema.js"
C_OUT_C6="$TMPDIR_BASE/test-c6-outline.md"
if command -v cygpath >/dev/null 2>&1; then
    PLAN_SCHEMA_BIN_NODE="$(cygpath -m "$PLAN_SCHEMA_BIN")"
    C_OUT_C6_NODE="$(cygpath -m "$C_OUT_C6")"
else
    PLAN_SCHEMA_BIN_NODE="$PLAN_SCHEMA_BIN"
    C_OUT_C6_NODE="$C_OUT_C6"
fi
EXIT_CODE=0; OUT=$(run_with_timeout bash "$ASSEMBLE" --source-kind outline \
    "$A_SOURCE" "$C_PLANNER_GOOD" "$C_OUT_C6" 2>&1) || EXIT_CODE=$?
# Bridge stdout — the authoritative expected value (trim trailing newline only).
C6_EXPECTED="$(node "$PLAN_SCHEMA_BIN_NODE" --first-body-section outline 2>/dev/null)"
C6_EXPECTED="${C6_EXPECTED%$'\n'}"
# First non-mandatory H2 from the assembled file (printed raw for string compare).
C6_ACTUAL="$(node -e "
const fs = require('fs');
const text = fs.readFileSync('$C_OUT_C6_NODE', 'utf8');
const mandatory = new Set(['Issues', 'Issue', 'Class members', 'Accepted Tradeoffs']);
const h2 = text.split(/\r?\n/).filter(function (l) { return /^## /.test(l); }).map(function (l) { return l.replace(/^## /, '').trim(); });
const body = h2.filter(function (h) { return !mandatory.has(h); });
process.stdout.write(body.length ? body[0] : '');
" 2>/dev/null)"
if [[ $EXIT_CODE -eq 0 && -n "$C6_EXPECTED" && -n "$C6_ACTUAL" && "$C6_ACTUAL" == "$C6_EXPECTED" ]]; then
    pass "TC-C6: assembled outline first body section '$C6_ACTUAL' == CLI --first-body-section outline stdout '$C6_EXPECTED' (string-equal, bridge proven)"
else
    fail "TC-C6: first body section did not string-match the plan-schema CLI bridge (assemble exit $EXIT_CODE, cli-expected='$C6_EXPECTED', assembled-actual='$C6_ACTUAL')"
fi

# TC-C10: source (intent.md) has Issues but NO '## Class members' section at all
# (not even a placeholder). The coverage gate must fire and block assembly for an
# outline output. This proves that the gate is wired to the SOURCE argument (the
# intent.md file), not to the planner draft, and that an entirely absent Class
# members section (not just under-coverage) is detected.
C_SOURCE_NO_CM="$TMPDIR_BASE/c-source-no-classmembers.md"
cat > "$C_SOURCE_NO_CM" << 'EOF'
## Issues

- #400: issue requiring class members

## Accepted Tradeoffs

- tradeoff B
EOF
C_OUT_C10="$TMPDIR_BASE/test-c10-outline.md"
EXIT_CODE=0; OUT=$(run_with_timeout bash "$ASSEMBLE" --source-kind intent \
    "$C_SOURCE_NO_CM" "$C_PLANNER_GOOD" "$C_OUT_C10" 2>&1) || EXIT_CODE=$?
[[ $EXIT_CODE -ne 0 ]] \
    && pass "TC-C10: source has Issues but no '## Class members' section → gate blocks (non-zero exit)" \
    || fail "TC-C10: expected non-zero (gate block for absent Class members section), got 0 (output: $OUT)"

# TC-C11: --source-kind intent produces output with exactly the two mandatory
# sections (Issues + Accepted Tradeoffs) but NOT Class members. This verifies that
# the 3→2 reduction applies to the intent path symmetrically with the outline path
# (TC-C2 covers --source-kind outline already).
C_OUT_C11="$TMPDIR_BASE/test-c11-intent-outline.md"
EXIT_CODE=0; OUT=$(run_with_timeout bash "$ASSEMBLE" --source-kind intent \
    "$A_SOURCE" "$C_PLANNER_GOOD" "$C_OUT_C11" 2>&1) || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 0 ]] && [[ -f "$C_OUT_C11" ]] \
    && grep -q "^## Issues$" "$C_OUT_C11" 2>/dev/null \
    && grep -q "^## Accepted Tradeoffs$" "$C_OUT_C11" 2>/dev/null \
    && ! grep -q "^## Class members$" "$C_OUT_C11" 2>/dev/null; then
    pass "TC-C11: --source-kind intent output has Issues + Accepted Tradeoffs, no Class members (3→2 parity with TC-C2)"
else
    fail "TC-C11: --source-kind intent output structure wrong (exit $EXIT_CODE, output: $OUT)"
fi

TOTAL=$((PASS + FAIL))
echo ""
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
