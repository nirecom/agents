#!/usr/bin/env bash
# Tests: skills/write-code/SKILL.md, skills/write-code/scripts/self-check-siblings.sh, skills/write-code/scripts/detect-contract-pins.sh
# Tags: tl1, tl2, static, roundtrip-reduction, skill-orchestration, scope:issue-specific, pwsh-not-required
#
# #1795 (CPR-E2C sibling self-check) / #1796 (contract-pin detection). Both
# land as scripts under skills/write-code/scripts/ with only a 1-line pointer
# each in SKILL.md (rules/coding/file-split.md Pattern B: SKILL.md was 77
# lines, capped at 81 after this change; #2140 grew it to 85). This pins: both scripts exist and
# are shebang-shaped, SKILL.md references both by relative path, SKILL.md
# stays under the size cap, and (TL2) each script runs against a synthetic
# input and produces non-empty, structured stdout without crashing.
set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$AGENTS_DIR" || exit 1

source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

SKILL_MD="skills/write-code/SKILL.md"
SIBLINGS_SCRIPT="skills/write-code/scripts/self-check-siblings.sh"
CONTRACT_SCRIPT="skills/write-code/scripts/detect-contract-pins.sh"

case_begin "scripts-exist-shebang" "skills/write-code/scripts/self-check-siblings.sh"
echo "--- A: both new scripts exist and are shebang-shaped ---"

for f in "$SIBLINGS_SCRIPT" "$CONTRACT_SCRIPT"; do
  if [ -f "$f" ]; then
    pass "A1 $f exists"
  else
    fail "A1 $f missing"
    continue
  fi
  FIRST_LINE="$(head -1 "$f")"
  case "$FIRST_LINE" in
    "#!"*bash*|"#!"*sh*)
      pass "A2 $f has a shebang: $FIRST_LINE"
      ;;
    *)
      fail "A2 $f missing a recognizable shebang, got: $FIRST_LINE"
      ;;
  esac
done

case_end

case_begin "skill-md-structure" "skills/write-code/SKILL.md"
echo ""
echo "--- B: SKILL.md references both scripts by relative path ---"

if [ -f "$SKILL_MD" ]; then
  if grep -qF -- "$SIBLINGS_SCRIPT" "$SKILL_MD"; then
    pass "B1 SKILL.md references $SIBLINGS_SCRIPT"
  else
    fail "B1 SKILL.md missing reference to $SIBLINGS_SCRIPT"
  fi
  if grep -qF -- "$CONTRACT_SCRIPT" "$SKILL_MD"; then
    pass "B2 SKILL.md references $CONTRACT_SCRIPT"
  else
    fail "B2 SKILL.md missing reference to $CONTRACT_SCRIPT"
  fi
else
  fail "B $SKILL_MD missing"
fi

echo ""
echo "--- C: SKILL.md stays within the size cap (<=100 lines; Pattern B WARN=100/HARD=200) ---"

if [ -f "$SKILL_MD" ]; then
  LINES=$(wc -l < "$SKILL_MD")
  if [ "$LINES" -le 100 ]; then
    pass "C1 SKILL.md is $LINES lines (<=100)"
  else
    fail "C1 SKILL.md is $LINES lines, exceeds the 100-line cap"
  fi
  if [ "$LINES" -lt 100 ]; then
    pass "C2 SKILL.md is under the Pattern B WARN threshold (100 lines)"
  else
    fail "C2 SKILL.md is at/over the Pattern B WARN threshold (100 lines)"
  fi
fi

echo ""
echo "--- D: procedure body lives in scripts/, not inlined in SKILL.md ---"

if [ -f "$SKILL_MD" ]; then
  # The checklist/detection procedure text (multi-step body) must not be
  # duplicated into SKILL.md — only a short pointer line is allowed.
  if grep -qF -- "Enumerate every symmetric sibling" "$SKILL_MD"; then
    fail "D1 SKILL.md inlines the self-check-siblings procedure body (should be a pointer only)"
  else
    pass "D1 SKILL.md does not inline the self-check-siblings procedure body"
  fi
  if grep -qF -- "basename string-match" "$SKILL_MD"; then
    fail "D2 SKILL.md inlines the detect-contract-pins procedure body (should be a pointer only)"
  else
    pass "D2 SKILL.md does not inline the detect-contract-pins procedure body"
  fi
fi

case_end

case_begin "scripts-tl2" "skills/write-code/scripts/detect-contract-pins.sh"
echo ""
echo "--- E (TL2): scripts run against synthetic input and produce structured stdout ---"

if [ -f "$SIBLINGS_SCRIPT" ]; then
  OUT_E1="$(bash "$SIBLINGS_SCRIPT" "added a 1-line pointer to skills/write-code/SKILL.md" "keep SKILL.md within the size cap" 2>&1)"
  RC_E1=$?
  if [ "$RC_E1" -eq 0 ] && [ -n "$OUT_E1" ]; then
    pass "E1 $SIBLINGS_SCRIPT exits 0 with non-empty stdout"
  else
    fail "E1 $SIBLINGS_SCRIPT failed or produced empty stdout (rc=$RC_E1)"
  fi
  if echo "$OUT_E1" | grep -qi "sibling"; then
    pass "E2 $SIBLINGS_SCRIPT output mentions siblings"
  else
    fail "E2 $SIBLINGS_SCRIPT output does not mention siblings"
  fi
else
  fail "E $SIBLINGS_SCRIPT missing — cannot invoke"
fi

if [ -f "$CONTRACT_SCRIPT" ]; then
  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "$TMP_DIR"' EXIT
  FAKE_FILE_1="skills/write-code/SKILL.md"
  FAKE_FILE_2="$TMP_DIR/definitely-nonexistent-contract-file-xyz.sh"
  OUT_E3="$(bash "$CONTRACT_SCRIPT" "$FAKE_FILE_1" "$FAKE_FILE_2" 2>&1)"
  RC_E3=$?
  if [ "$RC_E3" -eq 0 ] && [ -n "$OUT_E3" ]; then
    pass "E3 $CONTRACT_SCRIPT exits 0 with non-empty stdout"
  else
    fail "E3 $CONTRACT_SCRIPT failed or produced empty stdout (rc=$RC_E3)"
  fi
  if echo "$OUT_E3" | grep -qi "heuristic"; then
    pass "E4 $CONTRACT_SCRIPT output is phrased as a heuristic, not a proof"
  else
    fail "E4 $CONTRACT_SCRIPT output missing 'heuristic' framing"
  fi
  if echo "$OUT_E3" | grep -qF "$FAKE_FILE_2"; then
    pass "E5 $CONTRACT_SCRIPT flags the synthetic no-test file"
  else
    fail "E5 $CONTRACT_SCRIPT did not flag the synthetic no-test file"
  fi

  # No-args invocation must fail cleanly (usage error), not crash unexpectedly.
  bash "$CONTRACT_SCRIPT" </dev/null >"$TMP_DIR/out_e6" 2>"$TMP_DIR/err_e6"
  RC_E6=$?
  if [ "$RC_E6" -ne 0 ]; then
    pass "E6 $CONTRACT_SCRIPT with no input/args exits non-zero (usage error), not a crash"
  else
    fail "E6 $CONTRACT_SCRIPT with no input/args unexpectedly exited 0"
  fi
else
  fail "E $CONTRACT_SCRIPT missing — cannot invoke"
fi

case_end

case_begin "wcd7-skill-md" "skills/write-code/SKILL.md"
echo ""
echo "--- F: WCD-7 static checks (bin/stage-review-scope-files.js staging step) ---"

# F1: WCD-7 step label exists
if [ -f "$SKILL_MD" ] && grep -qF "WCD-7" "$SKILL_MD"; then
  pass "F1 WCD-7 step label present in SKILL.md"
else
  fail "F1 WCD-7 step label missing from SKILL.md"
fi

# F2: WCD-7 line number is greater than WCD-6 line number
if [ -f "$SKILL_MD" ]; then
  LINE_WCD6=$(grep -n "^WCD-6" "$SKILL_MD" | head -1 | cut -d: -f1)
  LINE_WCD7=$(grep -n "^WCD-7" "$SKILL_MD" | head -1 | cut -d: -f1)
  if [ -n "$LINE_WCD6" ] && [ -n "$LINE_WCD7" ] && [ "$LINE_WCD7" -gt "$LINE_WCD6" ]; then
    pass "F2 WCD-7 appears after WCD-6 (line $LINE_WCD6 -> $LINE_WCD7)"
  else
    fail "F2 WCD-7 not after WCD-6 (WCD-6=${LINE_WCD6:-missing} WCD-7=${LINE_WCD7:-missing})"
  fi
fi

# F3: WCD-7 section references WCD-5 as list source, does not reference WCD-6's list
if [ -f "$SKILL_MD" ]; then
  WCD7_BLOCK=$(awk '/^WCD-7/{f=1} f && /^(WCD-[0-9]|## )/ && !/^WCD-7/{exit} f{print}' "$SKILL_MD")
  if echo "$WCD7_BLOCK" | grep -qF "WCD-5"; then
    pass "F3 WCD-7 references WCD-5 as list source"
  else
    fail "F3 WCD-7 does not reference WCD-5 (expected WCD-5 as list source)"
  fi
  if echo "$WCD7_BLOCK" | grep -qF "WCD-6"; then
    fail "F3a WCD-7 incorrectly references WCD-6 list (must use WCD-5)"
  else
    pass "F3a WCD-7 does not reference WCD-6 list"
  fi
fi

# F4: WCD-7 calls bin/stage-review-scope-files.js
if [ -f "$SKILL_MD" ]; then
  WCD7_BLOCK=$(awk '/^WCD-7/{f=1} f && /^(WCD-[0-9]|## )/ && !/^WCD-7/{exit} f{print}' "$SKILL_MD")
  if echo "$WCD7_BLOCK" | grep -qF "stage-review-scope-files"; then
    pass "F4 WCD-7 references bin/stage-review-scope-files.js"
  else
    fail "F4 WCD-7 missing reference to bin/stage-review-scope-files.js"
  fi
fi

# F5: WCD-7 states non-zero → stop + /supervisor-report
if [ -f "$SKILL_MD" ]; then
  WCD7_BLOCK=$(awk '/^WCD-7/{f=1} f && /^(WCD-[0-9]|## )/ && !/^WCD-7/{exit} f{print}' "$SKILL_MD")
  if echo "$WCD7_BLOCK" | grep -qiE "non-zero|non zero|nonzero"; then
    pass "F5a WCD-7 mentions stopping on non-zero exit"
  else
    fail "F5a WCD-7 does not mention non-zero stop condition"
  fi
  if echo "$WCD7_BLOCK" | grep -qF "/supervisor-report"; then
    pass "F5b WCD-7 mentions /supervisor-report"
  else
    fail "F5b WCD-7 does not mention /supervisor-report"
  fi
fi

# F6: Completion references WCD-7; phrase "once WCD-6 passes" removed
if [ -f "$SKILL_MD" ]; then
  COMPLETION_BLOCK=$(awk '/^## Completion/{f=1} f{print}' "$SKILL_MD")
  if echo "$COMPLETION_BLOCK" | grep -qF "WCD-7"; then
    pass "F6a Completion section references WCD-7"
  else
    fail "F6a Completion section does not reference WCD-7"
  fi
  if echo "$COMPLETION_BLOCK" | grep -qF "once WCD-6 passes"; then
    fail "F6b Completion section still contains 'once WCD-6 passes' (must be removed)"
  else
    pass "F6b Completion section does not contain 'once WCD-6 passes'"
  fi
fi

# F7: Completion has next-step line
if [ -f "$SKILL_MD" ]; then
  COMPLETION_BLOCK=$(awk '/^## Completion/{f=1} f{print}' "$SKILL_MD")
  if echo "$COMPLETION_BLOCK" | grep -qF "next-step"; then
    pass "F7 Completion section has next-step line"
  else
    fail "F7 Completion section missing next-step line"
  fi
fi

# F8: SKILL.md <=100 lines
if [ -f "$SKILL_MD" ]; then
  LINES_F8=$(wc -l < "$SKILL_MD")
  if [ "$LINES_F8" -le 100 ]; then
    pass "F8 SKILL.md is $LINES_F8 lines (<=100)"
  else
    fail "F8 SKILL.md is $LINES_F8 lines, exceeds 100-line requirement"
  fi
fi

case_end

echo ""
echo "=== feature-1795-1796-write-code-summary: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
