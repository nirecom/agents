# Tests: bin/lib/test-embed-cases.sh
# Tags: TL2, scope:common, audit-tests, embed-cases, band, dry-run
# Sourced by tests/bin/bin-audit-tests-embed-cases.sh — --band-size validation and
# default, the BAND / SKIP line formats, and the dry-run no-write guarantee.

BD_REPO="$(ec_make_repo)"
for _n in 1 2 3 4 5 6 7; do
  ec_add_test "$BD_REPO" "tests/bin/t-band$_n.sh" "bin/alpha.sh"
done
ec_add_test "$BD_REPO" tests/bin/t-noheader.sh "bin/alpha.sh"
sed -i '/^# Tests:/d' "$BD_REPO/tests/bin/t-noheader.sh"
ec_commit "$BD_REPO" init

case_begin "band-size-invalid-values" "bin/lib/test-embed-cases.sh"
for _bad in 0 abc -1; do
  ec_run "$BD_REPO" "$AUDIT" --embed-cases --dry-run --band-size "$_bad"
  if [[ "$RC" -eq 2 ]] && ec_not_unknown_arg; then
    pass "BD1 --band-size $_bad is rejected with exit 2 by the embed parser"
  else
    fail "BD1 --band-size $_bad is rejected with exit 2 by the embed parser" "rc=$RC err=${ERR:0:200}"
  fi
done
case_end

case_begin "band-size-default-five" "bin/lib/test-embed-cases.sh"
ec_run "$BD_REPO" "$AUDIT" --embed-cases --dry-run
check_eq "BD2 the default band holds 5 of 7 candidates (rc=$RC err=${ERR:0:200})" "5" "$(ec_band_paths | grep -c .)"
case_end

case_begin "band-size-explicit" "bin/lib/test-embed-cases.sh"
ec_run "$BD_REPO" "$AUDIT" --embed-cases --dry-run --band-size 2
check_eq "BD3 --band-size 2 emits exactly 2 BAND lines (rc=$RC err=${ERR:0:200})" "2" "$(ec_band_paths | grep -c .)"
case_end

case_begin "dry-run-line-formats" "bin/lib/test-embed-cases.sh"
ec_run "$BD_REPO" "$AUDIT" --embed-cases --dry-run --band-size 3
_bad_band="$(printf '%s\n' "$OUT" | awk -F'\t' '$1 == "BAND" && (NF != 4 || $2 !~ /^[0-9]+$/ || $3 !~ /^tests\//) { print }')"
check_eq "BD4 every BAND line is BAND<TAB>idx<TAB>relpath<TAB>metric (rc=$RC)" "" "$_bad_band"
if [[ "$(ec_band_paths | grep -c .)" -gt 0 ]]; then pass "BD4 dry run emitted BAND lines"; else fail "BD4 dry run emitted BAND lines" "out=${OUT:0:200} err=${ERR:0:200}"; fi
check_eq "BD5 a header-less test is reported as SKIP<TAB>relpath<TAB>no-tests-header" "no-tests-header" "$(ec_skip_reason tests/bin/t-noheader.sh)"
_bad_skip="$(printf '%s\n' "$OUT" | awk -F'\t' '$1 == "SKIP" && NF != 3 { print }')"
check_eq "BD5 every SKIP line has 3 fields" "" "$_bad_skip"
check_eq "BD6 dry run exits 0" "0" "$RC"
case_end

case_begin "dry-run-writes-nothing" "bin/lib/test-embed-cases.sh"
_before_status="$(git -C "$BD_REPO" status --porcelain)"
_before_hash="$(cat "$BD_REPO"/tests/bin/*.sh | git hash-object --stdin)"
_before_plans="$(ls -1A "$WORKFLOW_PLANS_DIR" 2>/dev/null)"
_before_state="$(ls -1A "$SWEEP_TESTS_STATE_DIR" 2>/dev/null)"
ec_run "$BD_REPO" "$AUDIT" --embed-cases --dry-run --fix-headers
check_eq "BD7 dry run leaves git status unchanged" "$_before_status" "$(git -C "$BD_REPO" status --porcelain)"
check_eq "BD7 dry run leaves every test file byte-identical" "$_before_hash" "$(cat "$BD_REPO"/tests/bin/*.sh | git hash-object --stdin)"
check_eq "BD7 dry run creates nothing under the plans dir" "$_before_plans" "$(ls -1A "$WORKFLOW_PLANS_DIR" 2>/dev/null)"
check_eq "BD7 dry run writes no retry state" "$_before_state" "$(ls -1A "$SWEEP_TESTS_STATE_DIR" 2>/dev/null)"
if [[ -d "$WORKFLOW_PLANS_DIR/sweep-tests-embed" ]]; then
  fail "BD7 dry run creates no sweep-tests-embed workdir" "found $WORKFLOW_PLANS_DIR/sweep-tests-embed"
else
  pass "BD7 dry run creates no sweep-tests-embed workdir"
fi
if printf '%s\n' "$OUT" | grep -q '^EMBED_WORKDIR: '; then fail "BD7 dry run prints no EMBED_WORKDIR" "${OUT:0:200}"; else pass "BD7 dry run prints no EMBED_WORKDIR"; fi
if [[ "$(ec_band_paths | grep -c .)" -gt 0 ]]; then pass "BD7 dry run still plans a band"; else fail "BD7 dry run still plans a band" "rc=$RC err=${ERR:0:200}"; fi
case_end

grp_done band-dryrun-cases.sh
