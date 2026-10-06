# Tests: bin/lib/test-embed-cases/select.sh, bin/lib/test-embed-cases/retry-record.sh, bin/audit-tests-common.sh
# Tags: TL2, scope:common, audit-tests, embed-cases, skip-reasons
# Sourced by tests/bin/bin-audit-tests-embed-cases.sh — every tec_skip_reason
# token in its documented order, the helper-lib non-skip, the retry-capped hash
# key and its invalidation, the no-embed-rules registry fixture, malformed /
# uncertain marker states as candidates, and the discovery exclusions.

SR_REPO="$(ec_make_repo)"
ec_write_embedded "$SR_REPO/tests/bin/s-conforming.sh" "bin/alpha.sh" bin/alpha.sh
ec_add_test "$SR_REPO" tests/bin/s-narrow.sh "bin/alpha.sh"
sed -i 's|^source "\$ROOT/tests/lib/harness.sh"$|source "$ROOT/tests/lib/clearance-hook-harness.sh"|' "$SR_REPO/tests/bin/s-narrow.sh"
ec_add_test "$SR_REPO" tests/bin/s-capped.sh "bin/bravo.sh"
ec_add_test "$SR_REPO" tests/bin/s-noheader.sh "bin/alpha.sh"
sed -i '/^# Tests:/d' "$SR_REPO/tests/bin/s-noheader.sh"
ec_add_test "$SR_REPO" tests/bin/s-multiparen.sh "bin/alpha.sh (a) (b)"
ec_add_test "$SR_REPO" tests/bin/s-hasac.sh "bin/gone.sh (annotation)"
ec_add_test "$SR_REPO" tests/bin/s-sectionrunner.sh "bin/charlie.sh"
sed -i 's|^source "\$ROOT/tests/lib/harness.sh"$|&\nsource "$ROOT/tests/lib/section-runner.sh"|' "$SR_REPO/tests/bin/s-sectionrunner.sh"
ec_add_test "$SR_REPO" tests/bin/s-plain.sh "bin/delta.sh"
ec_commit "$SR_REPO" init
ec_retry_record "$SR_REPO" tests/bin/s-capped.sh

ec_run "$SR_REPO" "$AUDIT" --embed-cases --dry-run --band-size 50
SR_OUT="$OUT"
SR_DIAG="rc=$RC err=${ERR:0:200}"

case_begin "skip-already-conforming" "bin/lib/test-embed-cases/select.sh"
check_eq "SR1 a marker-conforming file is skipped as already-conforming ($SR_DIAG)" "already-conforming" "$(ec_skip_reason tests/bin/s-conforming.sh)"
case_end

case_begin "skip-lang-narrow-harness" "bin/lib/test-embed-cases/select.sh"
check_eq "SR2 a file sourcing tests/lib/clearance-hook-harness.sh is lang-skip:narrow-harness ($SR_DIAG)" "lang-skip:narrow-harness" "$(ec_skip_reason tests/bin/s-narrow.sh)"
case_end

case_begin "skip-retry-capped" "bin/lib/test-embed-cases/retry-record.sh"
check_eq "SR3 a file whose hash-object is in embed-retry.tsv is retry-capped ($SR_DIAG)" "retry-capped" "$(ec_skip_reason tests/bin/s-capped.sh)"
case_end

case_begin "skip-no-tests-header" "bin/lib/test-embed-cases/select.sh"
check_eq "SR4 a header-less file is no-tests-header ($SR_DIAG)" "no-tests-header" "$(ec_skip_reason tests/bin/s-noheader.sh)"
case_end

case_begin "skip-header-unfixable-multi-paren" "bin/lib/test-embed-cases/select.sh"
check_eq "SR5 a multi-paren token is header-unfixable:multi-paren ($SR_DIAG)" "header-unfixable:multi-paren" "$(ec_skip_reason tests/bin/s-multiparen.sh)"
case_end

case_begin "skip-header-unfixable-has-ac" "bin/lib/test-embed-cases/select.sh"
check_eq "SR6 an annotated missing-path token is header-unfixable:has-ac ($SR_DIAG)" "header-unfixable:has-ac" "$(ec_skip_reason tests/bin/s-hasac.sh)"
case_end

case_begin "skip-candidates-stay-in-band" "bin/lib/test-embed-cases/select.sh"
OUT="$SR_OUT"
_sr_band="$(ec_band_paths | sort)"
check_eq "SR7 only the plain file and the section-runner (non-harness helper lib) file form the band ($SR_DIAG)" \
  "$(printf '%s\n' tests/bin/s-plain.sh tests/bin/s-sectionrunner.sh)" "$_sr_band"
check_eq "SR7 a helper lib without harness in its name is not a skip" "" "$(ec_skip_reason tests/bin/s-sectionrunner.sh)"
case_end

case_begin "skip-order-first-reason-wins" "bin/lib/test-embed-cases/select.sh"
# Conforming AND capped AND narrow: the first token in the documented order wins.
SO_REPO="$(ec_make_repo)"
ec_write_embedded "$SO_REPO/tests/bin/o-conf-capped.sh" "bin/alpha.sh" bin/alpha.sh
ec_add_test "$SO_REPO" tests/bin/o-narrow-capped.sh "bin/alpha.sh (a) (b)"
sed -i 's|^source "\$ROOT/tests/lib/harness.sh"$|source "$ROOT/tests/lib/clearance-hook-harness.sh"|' "$SO_REPO/tests/bin/o-narrow-capped.sh"
ec_add_test "$SO_REPO" tests/bin/o-capped-noheader.sh "bin/alpha.sh"
sed -i '/^# Tests:/d' "$SO_REPO/tests/bin/o-capped-noheader.sh"
ec_add_test "$SO_REPO" tests/bin/o-plain.sh "bin/bravo.sh"
ec_commit "$SO_REPO" init
ec_retry_record "$SO_REPO" tests/bin/o-conf-capped.sh
ec_retry_record "$SO_REPO" tests/bin/o-narrow-capped.sh
ec_retry_record "$SO_REPO" tests/bin/o-capped-noheader.sh
ec_run "$SO_REPO" "$AUDIT" --embed-cases --dry-run --band-size 50
check_eq "SR8 already-conforming precedes retry-capped (rc=$RC)" "already-conforming" "$(ec_skip_reason tests/bin/o-conf-capped.sh)"
check_eq "SR8 lang-skip precedes retry-capped and header-unfixable" "lang-skip:narrow-harness" "$(ec_skip_reason tests/bin/o-narrow-capped.sh)"
check_eq "SR8 retry-capped precedes no-tests-header" "retry-capped" "$(ec_skip_reason tests/bin/o-capped-noheader.sh)"
case_end

case_begin "retry-capped-invalidated-by-content-change" "bin/lib/test-embed-cases/retry-record.sh"
printf '# touched\n' >>"$SR_REPO/tests/bin/s-capped.sh"
ec_commit "$SR_REPO" "change capped file"
ec_run "$SR_REPO" "$AUDIT" --embed-cases --dry-run --band-size 50
check_eq "SR9 a changed file no longer matches its retry row and is not skipped (rc=$RC)" "" "$(ec_skip_reason tests/bin/s-capped.sh)"
if ec_band_paths | grep -qxF tests/bin/s-capped.sh; then
  pass "SR9 the changed file is a candidate again"
else
  fail "SR9 the changed file is a candidate again" "out=${OUT:0:300} err=${ERR:0:200}"
fi
case_end

case_begin "skip-no-embed-rules" "bin/lib/test-embed-cases/select.sh"
# A fixture checkout whose registry sets bash caseEmbedRules to null.
NR_REPO="$(ec_make_repo)"
cp -R "$AGENTS_ROOT/bin/." "$NR_REPO/bin/"
install_test_language_registry "$NR_REPO" "$AGENTS_ROOT"
mkdir -p "$NR_REPO/skills"
[[ -d "$AGENTS_ROOT/skills/sweep-tests" ]] && cp -R "$AGENTS_ROOT/skills/sweep-tests" "$NR_REPO/skills/"
NR_JS='const fs=require("fs"),p=process.argv[1],j=JSON.parse(fs.readFileSync(p,"utf8"));for(const l of j.entries){if(l.id==="bash")l.caseEmbedRules=null;}fs.writeFileSync(p,JSON.stringify(j,null,2));'
node -e "$NR_JS" "$NR_REPO/hooks/lib/test-language-registry.json"
ec_add_test "$NR_REPO" tests/bin/n-plain.sh "bin/alpha.sh"
ec_commit "$NR_REPO" init
ec_run "$NR_REPO" "$NR_REPO/bin/audit-tests.sh" --embed-cases --dry-run --band-size 50
check_eq "SR10 with caseEmbedRules null the file is skipped as no-embed-rules (rc=$RC err=${ERR:0:200})" "no-embed-rules" "$(ec_skip_reason tests/bin/n-plain.sh)"
check_eq "SR10 no band is planned without embed rules" "" "$(ec_band_paths)"
case_end

# Marker states malformed (indented marker) and uncertain (depth violation after an
# open multi-line quote) are candidates, like none (detail Steps 3).
MU_REPO="$(ec_make_repo)"
ec_add_test "$MU_REPO" tests/bin/m-indented.sh "bin/alpha.sh"
cat >>"$MU_REPO/tests/bin/m-indented.sh" <<'FX'
  case_begin "a" "bin/alpha.sh"
echo "indented"
case_end
FX
ec_add_test "$MU_REPO" tests/bin/u-quote.sh "bin/bravo.sh"
cat >>"$MU_REPO/tests/bin/u-quote.sh" <<'FX'
echo "multi
line"
if true; then
case_begin "b" "bin/bravo.sh"
echo "inside if"
case_end
fi
FX
ec_commit "$MU_REPO" init

case_begin "candidate-malformed-and-uncertain-states" "bin/lib/test-embed-cases/select.sh"
for _mu in m-indented.sh:malformed u-quote.sh:uncertain; do
  _mu_f="${_mu%%:*}"
  _mu_st="$(bash -c '. "$1/bin/lib/test-retire-predicate.sh" || exit 95; trp_marker_conformance "$2"; printf "%s" "$TRP_MARKER_STATE"' _ "$AGENTS_ROOT" "$MU_REPO/tests/bin/$_mu_f" 2>/dev/null)"
  check_eq "SR11 fixture $_mu_f parses as ${_mu#*:}" "${_mu#*:}" "$_mu_st"
done
ec_run "$MU_REPO" "$AUDIT" --embed-cases --dry-run --band-size 50
check_eq "SR11 dry run exits 0 (err=${ERR:0:200})" "0" "$RC"
check_eq "SR11 both the malformed and the uncertain file form the band" \
  "$(printf '%s\n' tests/bin/m-indented.sh tests/bin/u-quote.sh)" "$(ec_band_paths | sort)"
check_eq "SR11 the malformed file has no SKIP line" "" "$(ec_skip_reason tests/bin/m-indented.sh)"
check_eq "SR11 the uncertain file has no SKIP line" "" "$(ec_skip_reason tests/bin/u-quote.sh)"
case_end

# Discovery exclusions: an archived test, a suite part file sourced by a dispatcher,
# and tests in languages without a case-marker reader never reach BAND or SKIP.
EX_REPO="$(ec_make_repo)"
ec_add_test "$EX_REPO" tests/bin/t-plain.sh "bin/alpha.sh"
ec_add_test "$EX_REPO" tests/_archive/old-archived.sh "bin/bravo.sh"
ec_add_test "$EX_REPO" tests/bin/suite-x/part.sh "bin/charlie.sh"
ec_add_test "$EX_REPO" tests/bin/suite-x.sh "bin/charlie.sh"
sed -i 's|^source "\$ROOT/tests/lib/harness.sh"$|&\n. "$ROOT/tests/bin/suite-x/part.sh"|' "$EX_REPO/tests/bin/suite-x.sh"
printf '%s\n' '# Tests: bin/delta.sh' '# Tags: TL2, scope:common' 'def test_x():' '    assert True' >"$EX_REPO/tests/bin/test_noreader.py"
printf '%s\n' '# Tests: bin/echo.sh' '# Tags: TL2, scope:common' 'Describe "x" { It "y" { $true | Should -Be $true } }' >"$EX_REPO/tests/bin/noreader.Tests.ps1"
ec_commit "$EX_REPO" init
EX_EXCLUDED="tests/_archive/old-archived.sh tests/bin/suite-x/part.sh tests/bin/test_noreader.py tests/bin/noreader.Tests.ps1"

# ex_assert_excluded <label> — none of EX_EXCLUDED is on a BAND or SKIP line of $OUT.
ex_assert_excluded() {
  local p hit
  if ec_band_paths | grep -qxF tests/bin/t-plain.sh; then pass "$1 the plain candidate is planned (non-vacuous)"; else fail "$1 the plain candidate is planned (non-vacuous)" "rc=$RC out=${OUT:0:300} err=${ERR:0:200}"; fi
  for p in $EX_EXCLUDED; do
    hit="$(printf '%s\n' "$OUT" | awk -F'\t' -v p="$p" '($1 == "BAND" && $3 == p) || ($1 == "SKIP" && $2 == p)')"
    check_eq "$1 $p is on no BAND or SKIP line" "" "$hit"
  done
}

case_begin "exclusions-absent-audit-tests" "bin/lib/test-embed-cases/select.sh"
ec_run "$EX_REPO" "$AUDIT" --embed-cases --dry-run --band-size 50
ex_assert_excluded "SR12 (audit-tests.sh)"
case_end

case_begin "exclusions-absent-audit-tests-common" "bin/audit-tests-common.sh"
ec_run "$EX_REPO" "$AUDIT_COMMON" --embed-cases --dry-run --band-size 50
ex_assert_excluded "SR13 (audit-tests-common.sh)"
case_end

grp_done skip-reason-cases.sh
