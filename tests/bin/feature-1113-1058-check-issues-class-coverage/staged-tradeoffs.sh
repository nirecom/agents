#!/usr/bin/env bash
# Tests: skills/_shared/assemble-mandatory.sh
# Tags: scope:issue-specific, TL2, accepted-tradeoffs, staged-heading, assemble
# lang-check: ignore — the assertions match plan-language marker values and plan text the code under test emits (functional data).
# #2924: assemble-mandatory.sh injects only `## Issues`. Each stage's planner writes its own
# `## Accepted Tradeoffs (<stage>)` (intent→outline, outline→detail by --source-kind), which
# must appear exactly once; the legacy heading and other stages' sections are stripped.

# TL3 gap: no live make-outline-plan / make-detail-plan run that re-prompts the planner on
# the exit-4 path; the retry loop lives in the skills.
set -uo pipefail

# isolation (#2512): pin state and plans dirs once for this file
_ISOLATION_TMP_ROOT="$(mktemp -d)"; readonly _ISOLATION_TMP_ROOT
mkdir -p "$_ISOLATION_TMP_ROOT/workflow-state" "$_ISOLATION_TMP_ROOT/plans"
export WORKFLOW_STATE_DIR="$_ISOLATION_TMP_ROOT/workflow-state" WORKFLOW_PLANS_DIR="$_ISOLATION_TMP_ROOT/plans"
unset CLAUDE_CODE_SESSION_ID
trap 'rm -rf "$_ISOLATION_TMP_ROOT"' EXIT

AGENTS_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
ASSEMBLE="$AGENTS_ROOT/skills/_shared/assemble-mandatory.sh"
EXTRACT="$AGENTS_ROOT/bin/extract-mandatory-sections"
T="$_ISOLATION_TMP_ROOT/t"
mkdir -p "$T"
cd "$_ISOLATION_TMP_ROOT" || exit 1

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then timeout 120 "$@"; else perl -e 'alarm 120; exec @ARGV' -- "$@"; fi
}
# assemble <out-name> <args...> — sets RC and ERR; OUTF is the output path.
assemble() {
    OUTF="$T/$1"; shift
    RC=0; ERR=$(run_with_timeout bash "$ASSEMBLE" "$@" "$OUTF" 2>&1) || RC=$?
}
count_h2() { grep -c "^## $2\$" "$1" 2>/dev/null || true; }

# Intent source: legacy heading (the transition form) plus a staged one, both must stay out.
INTENT="$T/intent.md"
cat > "$INTENT" << 'EOF'
## Issues

- #2924: chain copy

## Glossary

## Class members

- member-A

## Accepted Tradeoffs

- intent-legacy-tradeoff

## Accepted Tradeoffs (intent)

- intent-staged-tradeoff
EOF

# Outline source for the detail stage: carries its own `(outline)` section.
OUTLINE_SRC="$T/source-outline.md"
cat > "$OUTLINE_SRC" << 'EOF'
# Outline

## Issues

- #2924: chain copy

## Adopted approach

Approach.

## Accepted Tradeoffs (outline)

- outline-stage-tradeoff
EOF

# Outline planner draft that copied every upstream section on top of its own one.
OUTLINE_COPYING="$T/outline-copying.md"
cat > "$OUTLINE_COPYING" << 'EOF'
# Outline Plan

## Issues

- planner-written-issue: MUST NOT survive

## Adopted approach

Take approach A.

## Accepted Tradeoffs

- copied-legacy: MUST NOT survive

## Accepted Tradeoffs (intent)

- copied-intent: MUST NOT survive

## Delivery plan

Do the work.

## Accepted Tradeoffs (outline)

- own-outline-decision

## Accepted Tradeoffs (detail)

- premature-detail: MUST NOT survive
EOF

# S1: outline keeps its own `(outline)` section; legacy / intent / detail copies are stripped.
assemble s1-outline.md --source-kind intent "$INTENT" "$OUTLINE_COPYING"
if [[ $RC -eq 0 && -f "$OUTF" ]] && [[ "$(count_h2 "$OUTF" 'Accepted Tradeoffs (outline)')" -eq 1 ]] \
    && grep -qF "own-outline-decision" "$OUTF" && ! grep -q "MUST NOT survive" "$OUTF" \
    && ! grep -qF "intent-legacy-tradeoff" "$OUTF" && ! grep -qF "intent-staged-tradeoff" "$OUTF" \
    && [[ "$(count_h2 "$OUTF" 'Accepted Tradeoffs')" -eq 0 ]] \
    && [[ "$(count_h2 "$OUTF" 'Accepted Tradeoffs (intent)')" -eq 0 ]] \
    && [[ "$(count_h2 "$OUTF" 'Accepted Tradeoffs (detail)')" -eq 0 ]]; then
    pass "S1: outline keeps own '(outline)', strips legacy/(intent)/(detail) copies, copies nothing from intent"
else
    fail "S1: outline staged strip wrong (rc=$RC, err=$ERR)"
fi

# S2: detail keeps its own `(detail)` section and strips the copied legacy / `(intent)` / `(outline)` ones.
DETAIL_COPYING="$T/detail-copying.md"
cat > "$DETAIL_COPYING" << 'EOF'
# Detail Plan

## Delivery plan

- step

## Accepted Tradeoffs

- copied-legacy: MUST NOT survive

## Accepted Tradeoffs (intent)

- copied-intent: MUST NOT survive

## Accepted Tradeoffs (outline)

- copied-outline: MUST NOT survive

## Accepted Tradeoffs (detail)

- own-detail-decision
EOF
assemble s2-detail.md --source-kind outline "$OUTLINE_SRC" "$DETAIL_COPYING"
if [[ $RC -eq 0 && -f "$OUTF" ]] && [[ "$(count_h2 "$OUTF" 'Accepted Tradeoffs (detail)')" -eq 1 ]] \
    && grep -qF "own-detail-decision" "$OUTF" && ! grep -q "MUST NOT survive" "$OUTF" \
    && ! grep -qF "outline-stage-tradeoff" "$OUTF" \
    && [[ "$(count_h2 "$OUTF" 'Accepted Tradeoffs')" -eq 0 ]] \
    && [[ "$(count_h2 "$OUTF" 'Accepted Tradeoffs (intent)')" -eq 0 ]] \
    && [[ "$(count_h2 "$OUTF" 'Accepted Tradeoffs (outline)')" -eq 0 ]]; then
    pass "S2: detail keeps own '(detail)', strips legacy/(intent)/(outline) copies, copies nothing from outline"
else
    fail "S2: detail staged strip wrong (rc=$RC, err=$ERR)"
fi

# S3: zero own-stage sections fail verify (exit 4) and leave no output, for both stages.
printf '%s\n' "# Outline Plan" "" "## Adopted approach" "" "A." "" "## Delivery plan" "" "D." > "$T/outline-none.md"
assemble s3-outline.md --source-kind intent "$INTENT" "$T/outline-none.md"
[[ $RC -eq 4 && ! -f "$OUTF" ]] \
    && pass "S3a: outline without '(outline)' → exit 4, no output" \
    || fail "S3a: outline without '(outline)' expected exit 4 and no output (rc=$RC, err=$ERR)"
printf '%s\n' "# Detail Plan" "" "## Delivery plan" "" "- step" "" "## Accepted Tradeoffs (outline)" "" "- wrong stage" > "$T/detail-none.md"
assemble s3-detail.md --source-kind outline "$OUTLINE_SRC" "$T/detail-none.md"
[[ $RC -eq 4 && ! -f "$OUTF" ]] \
    && pass "S3b: detail with only another stage's section → exit 4, no output" \
    || fail "S3b: detail without '(detail)' expected exit 4 and no output (rc=$RC, err=$ERR)"

# S4: two own-stage sections fail verify (exit 4).
printf '%s\n' "# Outline Plan" "" "## Adopted approach" "" "A." "" "## Accepted Tradeoffs (outline)" "" "- one" \
    "" "## Delivery plan" "" "D." "" "## Accepted Tradeoffs (outline)" "" "- two" > "$T/outline-two.md"
assemble s4-outline.md --source-kind intent "$INTENT" "$T/outline-two.md"
[[ $RC -eq 4 && ! -f "$OUTF" ]] \
    && pass "S4: outline with two '(outline)' sections → exit 4, no output" \
    || fail "S4: two own-stage sections expected exit 4 (rc=$RC, err=$ERR)"

# S5 + S6: the MOP-3 minimal outline (H1, approach, Delivery plan, `(outline)` = なし) passes,
# and its 「なし」 body is kept as written.
printf '%s\n' "# Outline Plan" "" "## Adopted approach" "" "A." "" "## Delivery plan" "" "D." "" \
    "## Accepted Tradeoffs (outline)" "" "なし" > "$T/outline-minimal.md"
assemble s5-outline.md --source-kind intent "$INTENT" "$T/outline-minimal.md"
if [[ $RC -eq 0 && -f "$OUTF" ]] && [[ "$(count_h2 "$OUTF" 'Accepted Tradeoffs (outline)')" -eq 1 ]] \
    && [[ "$("$EXTRACT" "$OUTF" --section "Accepted Tradeoffs (outline)" 2>/dev/null | sed '/^[[:space:]]*$/d')" == "なし" ]]; then
    pass "S5: MOP-3 minimal outline with '(outline)' = なし assembles and keeps なし"
else
    fail "S5: minimal outline with なし expected exit 0 (rc=$RC, err=$ERR)"
fi
printf '%s\n' "# Detail Plan" "" "## Delivery plan" "" "- step" "" "## Accepted Tradeoffs (detail)" "" "なし" > "$T/detail-minimal.md"
assemble s5-detail.md --source-kind outline "$OUTLINE_SRC" "$T/detail-minimal.md"
[[ $RC -eq 0 && -f "$OUTF" ]] \
    && pass "S6: detail with '(detail)' = なし and a source without a legacy heading assembles" \
    || fail "S6: detail with なし expected exit 0 (rc=$RC, err=$ERR)"

# S7: Issues injection and verbatim match still work — the source body replaces the planner's.
assemble s7-outline.md --source-kind intent "$INTENT" "$OUTLINE_COPYING"
SRC_ISSUES="$("$EXTRACT" "$INTENT" --section Issues 2>/dev/null)"
OUT_ISSUES="$("$EXTRACT" "$OUTF" --section Issues 2>/dev/null)"
if [[ $RC -eq 0 && -n "$SRC_ISSUES" && "$SRC_ISSUES" == "$OUT_ISSUES" ]] && [[ "$(count_h2 "$OUTF" Issues)" -eq 1 ]]; then
    pass "S7: ## Issues is injected verbatim from the source, planner Issues stripped"
else
    fail "S7: Issues injection/verbatim broken (rc=$RC, out-issues='$OUT_ISSUES')"
fi
# Issues stays first: it comes right after the H1, before the planner's own section.
FIRST_H2="$(grep -m1 '^## ' "$OUTF" 2>/dev/null)"
[[ "$FIRST_H2" == "## Issues" ]] \
    && pass "S7b: ## Issues is the first H2 of the assembled outline" \
    || fail "S7b: first H2 is '$FIRST_H2', expected '## Issues'"

# S8: --source-kind is required now (it decides the own stage).
assemble s8-outline.md "$INTENT" "$T/outline-minimal.md"
[[ $RC -ne 0 && ! -f "$OUTF" ]] \
    && pass "S8: missing --source-kind → non-zero exit, no output" \
    || fail "S8: missing --source-kind expected a failure (rc=$RC)"

TOTAL=$((PASS + FAIL))
echo ""
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
