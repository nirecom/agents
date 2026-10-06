# Static mode (no --before): checks 1, 3 and 5, the output format, and exit codes 0/1/2.
# Sourced by the dispatcher.

echo ""
echo "=== static mode, checks 1 / 3 / 5 ==="

# Fixture checkouts: no caseEmbedRules on bash, and no helperLibrary on bash.
fx_table_edit "$REAL_TABLE" "$TMPBASE/noembed.json" \
  't.entries.find((e) => e.id === "bash").caseEmbedRules = null;'
VCO_NOEMBED="$TMPBASE/co-noembed"
vce_checkout "$VCO_NOEMBED" "$TMPBASE/noembed.json"
fx_table_edit "$REAL_TABLE" "$TMPBASE/nohelper.json" \
  't.entries.find((e) => e.id === "bash").helperLibrary = null;'
VCO_NOHELPER="$TMPBASE/co-nohelper"
vce_checkout "$VCO_NOHELPER" "$TMPBASE/nohelper.json"

case_begin "static-mode-good" "bin/verify-case-embed.sh"
# Only checks 1, 3, 4, 5 run; all pass; exit 0; the relpath is put back and the backup gone.
vce_static "$VCO" "$WD/good.sh"
assert_eq "rc=$V_RC" "rc=0"
ids="$(printf '%s\n' "$V_OUT" | awk -F'\t' '$1 ~ /^CHECK/ { print substr($1, 6) }' | tr '\n' ' ')"
assert_eq "checks run: $ids" "checks run: 1 3 4 5 "
for n in 1 3 4 5; do expect_check "good" "$n" PASS; done
intact "static good" "$VCO"
case_end

case_begin "output-line-format" "bin/verify-case-embed.sh"
# Every stdout line is CHECK<n>\t<PASS|FAIL|SKIP>\t<detail> or EXEMPT\t<token>\t<case>.
for args in "good.sh" "leftover.sh" "merged-abc.sh --merged-report $WD/report-ok.txt"; do
  # shellcheck disable=SC2086  # args is a fixed word list built above.
  set -- $args
  vce_static "$VCO" "$WD/$1" "${@:2}"
  bad="$(printf '%s\n' "$V_OUT" | awk -F'\t' 'NF == 0 { next } !(($1 ~ /^CHECK[1-5]$/ && NF == 3 && $2 ~ /^(PASS|FAIL|SKIP)$/) || ($1 == "EXEMPT" && NF == 3 && $2 != "" && $3 != "")) { print NR ":" $0 }')"
  assert_eq "$1: malformed lines [$bad] of [$(printf '%s' "$V_OUT" | head -c 300)]" "$1: malformed lines [] of [$(printf '%s' "$V_OUT" | head -c 300)]"
  if [ -n "$V_OUT" ]; then pass "$1: produced output"; else fail "$1: produced output" "rc=$V_RC"; fi
done
set --
case_end

case_begin "check1-marker-state" "bin/verify-case-embed/checks.sh"
# name|fixture|want CHECK1|want rc — conforming passes; none, malformed and uncertain
# fail whatever the header path count.
while IFS='|' read -r cname cfile cwant crc; do
  [ -n "$cname" ] || continue
  vce_static "$VCO" "$WD/$cfile"
  expect_check "$cname" 1 "$cwant"
  assert_eq "$cname rc=$V_RC" "$cname rc=$crc"
done <<'ROWS'
conforming|good.sh|PASS|0
no-markers|before.sh|FAIL|1
malformed|malformed.sh|FAIL|1
uncertain-two-paths|uncertain2.sh|FAIL|1
uncertain-one-path|uncertain1.sh|FAIL|1
ROWS
case_end

case_begin "check3-leftover-defs" "bin/verify-case-embed/checks.sh"
vce_static "$VCO" "$WD/good.sh"
expect_check "good" 3 PASS
vce_static "$VCO" "$WD/leftover.sh"
expect_check "leftover" 3 FAIL
assert_eq "leftover rc=$V_RC" "leftover rc=1"
detail_has "leftover" 3 "orphan_fn"
# A language with no caseEmbedRules has no leftover-defs op: SKIP, never PASS or FAIL.
vce_static "$VCO_NOEMBED" "$WD/leftover.sh"
expect_check "no embed rules" 3 SKIP
case_end

case_begin "check5-harness-and-self-impl" "bin/verify-case-embed/checks.sh"
vce_static "$VCO" "$WD/good.sh"
expect_check "good" 5 PASS
vce_static "$VCO" "$WD/no-harness.sh"
expect_check "no harness" 5 FAIL
assert_eq "no harness rc=$V_RC" "no harness rc=1"
vce_static "$VCO" "$WD/unguarded.sh"
expect_check "unguarded counter" 5 FAIL
# helperLibrary null: SKIP with detail no-helper-library.
vce_static "$VCO_NOHELPER" "$WD/good.sh"
expect_check "no helper library" 5 SKIP
detail_has "no helper library" 5 "no-helper-library"
# No self-impl op: the sourceRegex match alone decides.
vce_static "$VCO_NOEMBED" "$WD/unguarded.sh"
expect_check "no self-impl op" 5 PASS
vce_static "$VCO_NOEMBED" "$WD/no-harness.sh"
expect_check "no self-impl op, no harness" 5 FAIL
case_end

case_begin "exit-code-usage-errors" "bin/verify-case-embed.sh"
# Exit 2: a usage error or an unusable library; nothing is printed as a CHECK line.
V_BK="$(mktemp -d "$TMPBASE/bk.XXXXXX")"
vce "$VCO" "$WD/good.sh" --backup-dir "$V_BK"
assert_eq "no --relpath rc=$V_RC" "no --relpath rc=2"
vce_static "$VCO" "$WD/no-such-after.sh"
assert_eq "missing after-file rc=$V_RC" "missing after-file rc=2"
VCO_NOLIB="$TMPBASE/co-nolib"
cp -R "$VCO" "$VCO_NOLIB"
rm -f "$VCO_NOLIB/bin/lib/case-record-reader.sh"
vce_static "$VCO_NOLIB" "$WD/good.sh"
assert_eq "library unavailable rc=$V_RC" "library unavailable rc=2"
intact "library unavailable" "$VCO_NOLIB"
case_end
