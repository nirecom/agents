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

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$AGENTS_DIR" || exit 1

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

SKILL_MD="skills/write-code/SKILL.md"
SIBLINGS_SCRIPT="skills/write-code/scripts/self-check-siblings.sh"
CONTRACT_SCRIPT="skills/write-code/scripts/detect-contract-pins.sh"

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
echo "--- C: SKILL.md stays within the size cap (<=85 lines; Pattern B WARN=100/HARD=200) ---"

if [ -f "$SKILL_MD" ]; then
  LINES=$(wc -l < "$SKILL_MD")
  if [ "$LINES" -le 85 ]; then
    pass "C1 SKILL.md is $LINES lines (<=85)"
  else
    fail "C1 SKILL.md is $LINES lines, exceeds the 85-line cap"
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

echo ""
echo "=== feature-1795-1796-write-code-summary: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
