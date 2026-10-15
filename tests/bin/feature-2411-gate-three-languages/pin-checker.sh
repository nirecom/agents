# Today's bash verdicts of bin/check-case-markers.sh, whole stdout / stderr / exit code.
# Sourced by tests/bin/feature-2411-gate-three-languages.sh. Green before and after #2411.
# shellcheck shell=bash

echo ""
echo "=== pin: check-case-markers.sh on bash tests ==="

REPO_PIN="$TMPBASE/repo-pin"
mkrepo "$REPO_PIN"
PIN_T="$REPO_PIN/tests/bin"
for _b in missing missing-three missing-loads-helper conforming grammar depth target balance uncertain; do
  put "$REPO_PIN" "tests/bin/$_b.sh" "sh-$_b"
done
PIN_UNCERTAIN_TEXT="multi-line quoted string before the marker; use a heredoc so retire can split cases"

case_begin "pin-checker-missing" "bin/check-case-markers.sh"
ck "$PIN_T/missing.sh"
ck_exact "two paths, no markers" 1 "HIGH: $PIN_T/missing.sh (2 paths in # Tests: header, no case_begin/case_end markers) code=MISSING_CASE_MARKERS" ""
ck "$PIN_T/missing-three.sh"
ck_exact "three paths, no markers" 1 "HIGH: $PIN_T/missing-three.sh (3 paths in # Tests: header, no case_begin/case_end markers) code=MISSING_CASE_MARKERS" ""
case_end

case_begin "pin-checker-conforming" "bin/check-case-markers.sh"
ck "$PIN_T/conforming.sh"
ck_exact "conforming markers print nothing" 0 "" ""
case_end

case_begin "pin-checker-malformed-reasons" "bin/check-case-markers.sh"
while IFS='|' read -r _reason _line; do
  [ -n "$_reason" ] || continue
  ck "$PIN_T/$_reason.sh"
  ck_exact "malformed $_reason" 1 "HIGH: $PIN_T/$_reason.sh line $_line: malformed case marker ($_reason) code=MALFORMED_CASE_MARKER" ""
done <<'ROWS'
grammar|4
depth|5
target|4
balance|5
ROWS
case_end

case_begin "pin-checker-uncertain" "bin/check-case-markers.sh"
ck "$PIN_T/uncertain.sh"
ck_exact "uncertain nesting warns and passes" 0 "WARN: $PIN_T/uncertain.sh line 7: case marker nesting uncertain ($PIN_UNCERTAIN_TEXT) code=UNCERTAIN_CASE_MARKER" ""
case_end

case_begin "pin-checker-ignores-age-and-helper-load" "bin/check-case-markers.sh"
git -C "$REPO_PIN" add -- tests/bin/missing.sh >/dev/null 2>&1
git -C "$REPO_PIN" commit -q -m "missing lands in HEAD" >/dev/null 2>&1
if git -C "$REPO_PIN" cat-file -e HEAD:tests/bin/missing.sh 2>/dev/null; then
  pass "fixture file is in HEAD"
else
  fail "fixture file is in HEAD" "commit did not land"
fi
ck "$PIN_T/missing.sh"
ck_exact "a file already in HEAD gets the same verdict" 1 "HIGH: $PIN_T/missing.sh (2 paths in # Tests: header, no case_begin/case_end markers) code=MISSING_CASE_MARKERS" ""
ck "$PIN_T/missing-loads-helper.sh"
ck_exact "loading the helper library does not change the verdict" 1 "HIGH: $PIN_T/missing-loads-helper.sh (2 paths in # Tests: header, no case_begin/case_end markers) code=MISSING_CASE_MARKERS" ""
case_end

case_begin "pin-checker-several-files-in-argument-order" "bin/check-case-markers.sh"
ck "$PIN_T/target.sh" "$PIN_T/conforming.sh" "$PIN_T/uncertain.sh" "$PIN_T/missing.sh"
ck_exact "one line per offending file, argument order" 1 "HIGH: $PIN_T/target.sh line 4: malformed case marker (target) code=MALFORMED_CASE_MARKER
WARN: $PIN_T/uncertain.sh line 7: case marker nesting uncertain ($PIN_UNCERTAIN_TEXT) code=UNCERTAIN_CASE_MARKER
HIGH: $PIN_T/missing.sh (2 paths in # Tests: header, no case_begin/case_end markers) code=MISSING_CASE_MARKERS" ""
case_end

case_begin "pin-checker-usage-and-missing-file" "bin/check-case-markers.sh"
ck
ck_exact "no arguments" 1 "" "Usage: check-case-markers.sh <file1> [file2 ...]"
ck "$PIN_T/absent.sh"
ck_exact "a path that is not a file" 1 "" "check-case-markers.sh: file not found: $PIN_T/absent.sh"
case_end
