#!/bin/bash
# Tests: skills/clarify-intent/SKILL.md, skills/_shared/complexity-and-outline-skip.md
# Tags: skill, static, complexity-evaluation, scope:issue-specific
#
# Issue #1350/#1427, rewritten for #2460 — clarify-intent's CI-C1b is a one-line reference
# to skills/_shared/complexity-and-outline-skip.md, and that file (COS) runs the shared
# jev-two-stage-judge procedure twice: COS-1 point=complexity-judge, COS-2 point=outline-skip,
# both at stage complexity; COS-3 proceeds on SKIP=true (outline already settled by
# jev-judge finalize) and runs outline otherwise. The record-complexity-and-skip wrapper, the
# background skip-verifier and check-complexity-skip.sh are gone. Assertions never abort.
set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

has_fixed() { grep -F -- "$1" "$2" >/dev/null 2>&1; }
has_re() { grep -E -- "$1" "$2" >/dev/null 2>&1; }
# label_line <file> <label> — first line number whose line starts with the step label.
label_line() { grep -nE -- "^[-*#[:space:]]*$2[^0-9]" "$1" 2>/dev/null | head -1 | cut -d: -f1; }
# label_block <file> <label> — the step's text: its label line up to the next COS-<n> label.
label_block() {
  awk -v re="^[-*#[:space:]]*$2[^0-9]" '
    on && /^[-*#[:space:]]*COS-[0-9]/ { exit }
    !on && $0 ~ re { on = 1 }
    on { print }' "$1" 2>/dev/null
}

CI_SKILL="$REPO_ROOT/skills/clarify-intent/SKILL.md"
COS_REL="skills/_shared/complexity-and-outline-skip.md"
COS="$REPO_ROOT/$COS_REL"
JJ_REL="skills/_shared/jev-two-stage-judge.md"

echo "=== CI-COMP-0: CI-C1b delegates to the shared COS procedure ==="
if [ ! -f "$CI_SKILL" ] || [ ! -f "$COS" ]; then
  fail "CI-COMP-0. clarify-intent/SKILL.md or $COS_REL is missing"
elif has_re "CI-C1b.*$COS_REL" "$CI_SKILL"; then
  pass "CI-COMP-0. CI-C1b references $COS_REL"
else
  fail "CI-COMP-0. CI-C1b does not reference $COS_REL"
fi

echo "=== CI-COMP-1: COS-1 / COS-2 run the shared procedure at the right point and stage ==="
if has_fixed "$JJ_REL" "$COS"; then pass "CI-COMP-1a. $COS_REL references $JJ_REL"
else fail "CI-COMP-1a. $COS_REL does not reference $JJ_REL"; fi
STAGE_RE='stage[ =:`"]*complexity([^-_a-z]|$)'
cos1="$(label_block "$COS" COS-1)"
if printf '%s\n' "$cos1" | grep -qF 'complexity-judge' && printf '%s\n' "$cos1" | grep -qE "$STAGE_RE"; then
  pass "CI-COMP-1b. COS-1 runs point complexity-judge at stage complexity"
else
  fail "CI-COMP-1b. COS-1 lacks point complexity-judge / stage complexity: [$(printf '%s' "$cos1" | head -1)]"
fi
cos2="$(label_block "$COS" COS-2)"
if printf '%s\n' "$cos2" | grep -qF 'outline-skip' && printf '%s\n' "$cos2" | grep -qE "$STAGE_RE"; then
  pass "CI-COMP-1c. COS-2 runs point outline-skip at stage complexity"
else
  fail "CI-COMP-1c. COS-2 lacks point outline-skip / stage complexity: [$(printf '%s' "$cos2" | head -1)]"
fi

echo "=== CI-COMP-2: COS-3 branches on SKIP after COS-1 and COS-2 ==="
l1="$(label_line "$COS" COS-1)"; l2="$(label_line "$COS" COS-2)"; l3="$(label_line "$COS" COS-3)"
if [ -n "$l1" ] && [ -n "$l2" ] && [ -n "$l3" ] && [ "$l1" -lt "$l2" ] && [ "$l2" -lt "$l3" ]; then
  pass "CI-COMP-2a. COS-1 (L$l1) < COS-2 (L$l2) < COS-3 (L$l3)"
else
  fail "CI-COMP-2a. COS-1/2/3 labels missing or out of order (L${l1:-?}/L${l2:-?}/L${l3:-?})"
fi
cos3_block="$(label_block "$COS" COS-3)"
if printf '%s\n' "$cos3_block" | grep -qF 'SKIP=true' && printf '%s\n' "$cos3_block" | grep -qiE 'false'; then
  pass "CI-COMP-2b. COS-3 handles SKIP=true and the false branch"
else
  fail "CI-COMP-2b. COS-3 does not branch on SKIP=true / false"
fi
if [ -z "$(label_line "$COS" COS-4)" ]; then pass "CI-COMP-2c. the old COS-4 step is gone"
else fail "CI-COMP-2c. $COS_REL still has a COS-4 step"; fi

echo "=== CI-COMP-3: retired parts are no longer referenced ==="
for f in "$COS" "$CI_SKILL"; do
  label="${f#"$REPO_ROOT"/}"
  for t in record-complexity-and-skip skip-verifier check-complexity-skip.sh normalize-judge-signals record-skip-judgment; do
    if has_fixed "$t" "$f"; then fail "CI-COMP-3. $label still references $t"
    else pass "CI-COMP-3. $label does not reference $t"; fi
  done
done

echo "=== CI-COMP-4: the skip is settled by jev-judge finalize, not by a sentinel here ==="
if has_fixed "WORKFLOW_OUTLINE_NOT_NEEDED" "$COS"; then
  fail "CI-COMP-4. $COS_REL still emits WORKFLOW_OUTLINE_NOT_NEEDED (outline is settled by finalize)"
else
  pass "CI-COMP-4. $COS_REL emits no WORKFLOW_OUTLINE_NOT_NEEDED sentinel"
fi
if has_fixed "SKIP_DISPATCH" "$CI_SKILL"; then
  fail "CI-COMP-4b. CI-C1b still restates the SKIP_DISPATCH procedure inline"
else
  pass "CI-COMP-4b. CI-C1b carries no inline SKIP_DISPATCH procedure"
fi

echo
if [ "$ERRORS" -eq 0 ]; then
  echo "All static checks passed."
  exit 0
else
  echo "$ERRORS check(s) failed."
  exit 1
fi
