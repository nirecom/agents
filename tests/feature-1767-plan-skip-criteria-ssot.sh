#!/usr/bin/env bash
# Tests: skills/_shared/judge-plan-skip.md, skills/workflow-init/SKILL.md, skills/clarify-intent/SKILL.md, skills/make-outline-plan/SKILL.md
# Tags: tl1, static, roundtrip-reduction, skill-orchestration, scope:issue-specific, pwsh-not-required
#
# #1767 — SSOT for the outline-skip (so_c1/so_c2) and detail-skip
# (sd_c1/sd_c2/sd_c3) criteria. Before this change the criteria text was
# re-stated inline at 4 call sites; this pins that (a) the new SSOT file
# exists with a real rubric (not a one-liner), and (b) each of the 4 call
# sites references it by path instead of restating the criteria prose.
set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$AGENTS_DIR" || exit 1

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

SSOT="skills/_shared/judge-plan-skip.md"
REF_TOKEN="skills/_shared/judge-plan-skip.md"

echo "--- A: SSOT file exists and documents all 5 criteria ---"

if [ -f "$SSOT" ]; then
  pass "A1 $SSOT exists"
else
  fail "A1 $SSOT missing"
fi

if [ -f "$SSOT" ]; then
  for id in so_c1 so_c2 sd_c1 sd_c2 sd_c3; do
    if grep -q -- "$id" "$SSOT"; then
      pass "A2 $SSOT documents $id"
    else
      fail "A2 $SSOT missing $id"
    fi
  done

  # Not just one-line definitions: the file must carry pass/fail examples.
  if grep -qi "pass example\|Pass example" "$SSOT" && grep -qi "fail example\|Fail example" "$SSOT"; then
    pass "A3 $SSOT includes pass/fail examples (not one-line definitions only)"
  else
    fail "A3 $SSOT missing pass/fail example content"
  fi

  LINES=$(wc -l < "$SSOT")
  if [ "$LINES" -le 200 ]; then
    pass "A4 $SSOT stays within Pattern B HARD limit (200 lines): $LINES"
  else
    fail "A4 $SSOT exceeds Pattern B HARD limit (200 lines): $LINES"
  fi
fi

echo ""
echo "--- B: the 4 call sites reference the SSOT instead of restating criteria ---"

check_site() {
  local file="$1" label="$2"
  [ -f "$file" ] || { fail "B $file missing"; return; }

  if grep -q -- "$REF_TOKEN" "$file"; then
    pass "B $file ($label) references $REF_TOKEN"
  else
    fail "B $file ($label) does not reference $REF_TOKEN"
  fi
}

check_site "skills/workflow-init/SKILL.md" "A3a"
check_site "skills/clarify-intent/SKILL.md" "CI-C1b"
check_site "skills/make-outline-plan/SKILL.md" "MOP-1d + MOP-C1"

# make-outline-plan must reference the SSOT at least twice (MOP-1d for so_*,
# MOP-C1 for sd_*) — a single reference would mean one of the two sites was
# missed.
if [ -f "skills/make-outline-plan/SKILL.md" ]; then
  COUNT=$(grep -c -- "$REF_TOKEN" "skills/make-outline-plan/SKILL.md")
  if [ "$COUNT" -ge 2 ]; then
    pass "B make-outline-plan/SKILL.md references $REF_TOKEN at both MOP-1d and MOP-C1 ($COUNT occurrences)"
  else
    fail "B make-outline-plan/SKILL.md references $REF_TOKEN fewer than 2 times ($COUNT occurrences) — MOP-1d or MOP-C1 was not migrated"
  fi
fi

echo ""
echo "--- C: call sites no longer restate the criteria prose inline ---"

# The old inline restatement paired the criterion ID with its parenthetical
# definition on the same line, e.g. "so_c1 (single obvious approach exists)"
# or "so_c1: a single obvious approach exists". After migration, that pairing
# must be gone from the call sites (it may legitimately live in the SSOT file
# itself, which is excluded from this check).
OLD_PHRASES=(
  "so_c1 (single obvious approach exists)"
  "so_c1: a single obvious approach exists"
  "sd_c1: all changed files are listed by path"
)

for file in "skills/workflow-init/SKILL.md" "skills/clarify-intent/SKILL.md" "skills/make-outline-plan/SKILL.md"; do
  [ -f "$file" ] || continue
  for phrase in "${OLD_PHRASES[@]}"; do
    if grep -qF -- "$phrase" "$file"; then
      fail "C $file still restates inline: '$phrase'"
    else
      pass "C $file does not restate inline: '$phrase'"
    fi
  done
done

echo ""
echo "=== feature-1767-plan-skip-criteria-ssot: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
