# Check 4: header tokens H against case targets T, both directions, and the narrow
# MERGED_TARGET exception reported as EXEMPT lines. Sourced by the dispatcher.

echo ""
echo "=== check 4: header tokens vs case targets ==="

case_begin "check4-header-vs-targets" "bin/verify-case-embed/checks.sh"
# name|fixture|want CHECK4 — a deleted target's token stays in H (it must be a target),
# and T must not reach outside H.
while IFS='|' read -r cname cfile cwant; do
  [ -n "$cname" ] || continue
  vce_static "$VCO" "$WD/$cfile"
  expect_check "$cname" 4 "$cwant"
done <<'ROWS'
every-token-a-target|good.sh|PASS
deleted-token-is-a-target|deleted-is-target.sh|PASS
deleted-token-not-a-target|deleted-not-target.sh|FAIL
target-outside-header|target-not-in-header.sh|FAIL
merged-without-report|merged-abc.sh|FAIL
ROWS
vce_static "$VCO" "$WD/merged-abc.sh" --merged-report "$WD/report-empty.txt"
expect_check "empty report" 4 FAIL
case_end

case_begin "check4-merged-target-exemption" "bin/verify-case-embed/checks.sh"
# Only dropped tokens of a qualifying line are exempt, and each one is reported.
vce_static "$VCO" "$WD/merged-abc.sh" --merged-report "$WD/report-ok.txt"
expect_check "single dropped" 4 PASS
assert_eq "single dropped rc=$V_RC" "single dropped rc=0"
ex="$(printf '%s\n' "$V_OUT" | grep "^EXEMPT$T" | sort | tr '\n' ' ')"
assert_eq "single dropped: $ex" "single dropped: EXEMPT${T}bin/b.sh${T}ab "
vce_static "$VCO" "$WD/merged-csv.sh" --merged-report "$WD/report-csv.txt"
expect_check "csv dropped" 4 PASS
ex="$(printf '%s\n' "$V_OUT" | grep "^EXEMPT$T" | sort | tr '\n' ' ')"
assert_eq "csv dropped: $ex" "csv dropped: EXEMPT${T}bin/b.sh${T}abc EXEMPT${T}bin/c.sh${T}abc "
# A qualifying line does not excuse a token it does not drop: bin/c.sh is still missing.
vce_static "$VCO" "$WD/merged-missing.sh" --merged-report "$WD/report-ok.txt"
expect_check "other token still missing" 4 FAIL
got="$(check_of 4)"
case "$got" in
  *bad-merge-report*) fail "other token still missing: not a bad report" "line=[$got]" ;;
  *) pass "other token still missing: not a bad report" ;;
esac
case_end

case_begin "check4-bad-merge-report" "bin/verify-case-embed/checks.sh"
# report|reason — each line breaks one of the four conditions, and is itself the FAIL.
while IFS='|' read -r rname _reason; do
  [ -n "$rname" ] || continue
  vce_static "$VCO" "$WD/merged-abc.sh" --merged-report "$WD/report-$rname.txt"
  expect_check "$rname" 4 FAIL
  detail_has "$rname" 4 "bad-merge-report"
  assert_eq "$rname rc=$V_RC" "$rname rc=1"
done <<'ROWS'
kept-not-target|kept is in H but is not the named case's target
unknown-case|the case name does not exist
dropped-not-in-header|the dropped token is not in H
dropped-is-target|the dropped token is in T
ROWS
case_end
