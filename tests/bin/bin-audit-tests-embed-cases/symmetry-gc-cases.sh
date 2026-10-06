# Tests: bin/audit-tests-common.sh, bin/audit-tests.sh, bin/lib/test-embed-cases/stage-apply.sh
# Tags: TL2, scope:common, audit-tests, embed-cases, entrypoint-symmetry, gc
# Sourced by tests/bin/bin-audit-tests-embed-cases.sh — both entrypoints print
# byte-identical embed plans, --fix-headers without --embed-cases is unchanged
# (golden), and an embedded file hands the GC a per-case verdict
# (partial-orphan once one of its two targets is deleted).

SY_REPO="$(ec_make_repo)"
ec_add_test "$SY_REPO" tests/bin/t-alpha.sh "bin/alpha.sh"
ec_add_test "$SY_REPO" tests/bin/feature-1-t-bravo.sh "bin/bravo.sh"
ec_add_test "$SY_REPO" tests/bin/t-fix.sh "bin/charlie.sh (annotation)"
ec_add_test "$SY_REPO" tests/bin/feature-2-t-fix.sh "bin/delta.sh (annotation)"
ec_add_test "$SY_REPO" tests/bin/s-noheader.sh "bin/alpha.sh"
sed -i '/^# Tests:/d' "$SY_REPO/tests/bin/s-noheader.sh"
ec_commit "$SY_REPO" init

case_begin "symmetry-dry-run-byte-identical" "bin/audit-tests-common.sh"
ec_run "$SY_REPO" "$AUDIT" --embed-cases --dry-run --band-size 3
SY_A_OUT="$OUT"
SY_A_RC="$RC"
ec_run "$SY_REPO" "$AUDIT_COMMON" --embed-cases --dry-run --band-size 3
check_eq "SY1 both entrypoints exit alike" "$SY_A_RC" "$RC"
check_eq "SY1 both entrypoints print byte-identical dry-run plans" "$SY_A_OUT" "$OUT"
if printf '%s\n' "$OUT" | grep -q '^BAND'; then pass "SY1 the shared plan is non-empty"; else fail "SY1 the shared plan is non-empty" "rc=$RC err=${ERR:0:200}"; fi
_sy_band="$(ec_band_paths | sort)"
check_eq "SY1 the corpus spans feature-NNN and common files alike (not entrypoint-scoped)" \
  "$(printf '%s\n' tests/bin/feature-1-t-bravo.sh tests/bin/feature-2-t-fix.sh tests/bin/t-alpha.sh | sort)" "$_sy_band"
case_end

case_begin "symmetry-fix-headers-unchanged-audit-tests" "bin/audit-tests.sh"
ec_run "$SY_REPO" "$AUDIT" --fix-headers --dry-run --offline
check_eq "SY2 audit-tests.sh --fix-headers output is the golden (rc=$RC)" \
  "FIX_A: tests/bin/feature-2-t-fix.sh: bin/delta.sh" \
  "$(printf '%s\n' "$OUT" | grep -E '^(FIX_|C:|MANUAL_REVIEW_REQUIRED|SKIP_APPLY|APPLIED)')"
case_end

case_begin "symmetry-fix-headers-unchanged-audit-tests-common" "bin/audit-tests-common.sh"
ec_run "$SY_REPO" "$AUDIT_COMMON" --fix-headers --dry-run --offline
check_eq "SY3 audit-tests-common.sh --fix-headers output is the golden (rc=$RC)" \
  "FIX_A: tests/bin/t-fix.sh: bin/charlie.sh" \
  "$(printf '%s\n' "$OUT" | grep -E '^(FIX_|C:|MANUAL_REVIEW_REQUIRED|SKIP_APPLY|APPLIED)')"
case_end

case_begin "gc-partial-orphan-after-embed" "bin/lib/test-embed-cases/stage-apply.sh"
GC_REPO="$(ec_make_repo)"
ec_add_test "$GC_REPO" tests/bin/t-gc.sh "bin/alpha.sh, bin/bravo.sh" 2
ec_commit "$GC_REPO" init
ec_stage1 "$GC_REPO" "$AUDIT" --band-size 5
EC_GC_OUT="$(ec_item_output tests/bin/t-gc.sh)"
ec_write_embedded "$EC_GC_OUT" "bin/alpha.sh, bin/bravo.sh" bin/alpha.sh bin/bravo.sh
ec_codex_says "CASE_BOUNDARY: tests/bin/t-gc.sh: OK"
ec_apply "$GC_REPO"
if ec_has_line "$OUT" "$(printf 'APPLIED\ttests/bin/t-gc.sh')"; then pass "GC1 the two-target file is embedded (rc=$RC)"; else fail "GC1 the two-target file is embedded" "out=${OUT:0:300} err=${ERR:0:200}"; fi
ec_commit "$GC_REPO" "embed cases"
git -C "$GC_REPO" rm -q bin/bravo.sh
ec_commit "$GC_REPO" "delete bravo"
_verdict="$(cd "$GC_REPO" && . "$AGENTS_ROOT/bin/lib/test-retire-predicate.sh" && trp_case_refcount_verdict "$GC_REPO" tests/bin/t-gc.sh 2>/dev/null)"
check_eq "GC1 deleting one target makes the embedded file partial-orphan" "partial-orphan" "$_verdict"
case_end

grp_done symmetry-gc-cases.sh
