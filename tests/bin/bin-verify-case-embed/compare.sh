# Check 2 (--before): run before and after at the relpath and compare result class and
# counts; restore the relpath and drop the backup afterwards. Sourced by the dispatcher.

echo ""
echo "=== check 2: before/after run comparison ==="

# vce_compare <checkout> <after-file> <before> — compare mode against tests/bin/sample.sh.
vce_compare() {
  V_BK="$(mktemp -d "$TMPBASE/bk.XXXXXX")"
  vce "$1" "$2" --relpath tests/bin/sample.sh --before "$3" --backup-dir "$V_BK"
}

case_begin "check2-same-result" "bin/verify-case-embed/run-compare.sh"
# Before is the relpath itself (the stage-3 form): same class, same counts.
vce_compare "$VCO" "$WD/good.sh" tests/bin/sample.sh
expect_check "same result" 2 PASS
assert_eq "rc=$V_RC" "rc=0"
ids="$(printf '%s\n' "$V_OUT" | awk -F'\t' '$1 ~ /^CHECK/ { print substr($1, 6) }' | tr '\n' ' ')"
assert_eq "checks run: $ids" "checks run: 1 2 3 4 5 "
intact "same result" "$VCO"
case_end

case_begin "check2-different-result" "bin/verify-case-embed/run-compare.sh"
# name|after fixture — a class change and a count change both fail.
while IFS='|' read -r cname cfile; do
  [ -n "$cname" ] || continue
  vce_compare "$VCO" "$WD/$cfile" tests/bin/sample.sh
  expect_check "$cname" 2 FAIL
  assert_eq "$cname rc=$V_RC" "$cname rc=1"
  intact "$cname" "$VCO"
done <<'ROWS'
class-pass-to-fail|good-fails.sh
count-differs|good-three.sh
ROWS
case_end

case_begin "check2-count-unavailable" "bin/verify-case-embed/run-compare.sh"
# Before has no Results line: class alone decides, detail says count-unavailable. The
# before file differs from the relpath, so it is placed there and the original restored.
vce_compare "$VCO" "$WD/good.sh" "$WD/before-nores.sh"
expect_check "count unavailable" 2 PASS
detail_has "count unavailable" 2 "count-unavailable"
intact "before differs from relpath" "$VCO"
case_end

fx_table_edit "$REAL_TABLE" "$TMPBASE/timeout.json" \
  't.entries.find((e) => e.id === "bash").launch.timeoutSeconds = 2;'
VCO_TIMEOUT="$TMPBASE/co-timeout"
vce_checkout "$VCO_TIMEOUT" "$TMPBASE/timeout.json"

case_begin "check2-both-timeout-inconclusive" "bin/verify-case-embed/run-compare.sh"
# Both runs hit launch.timeoutSeconds: the same "class" is never a PASS.
vce_compare "$VCO_TIMEOUT" "$WD/slow.sh" "$WD/slow.sh"
expect_check "both timeout" 2 FAIL
detail_has "both timeout" 2 "inconclusive"
assert_eq "rc=$V_RC" "rc=1"
intact "both timeout" "$VCO_TIMEOUT"
case_end
