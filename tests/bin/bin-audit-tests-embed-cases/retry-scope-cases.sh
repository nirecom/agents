# Tests: bin/lib/test-embed-cases/retry-record.sh
# Tags: TL2, scope:common, audit-tests, embed-cases, retry
# Sourced by tests/bin/bin-audit-tests-embed-cases.sh — the narrowing of an
# embed-retry.tsv row beyond its hash: the relpath must match, and a reason
# ending in " (repo <toplevel>)" scopes the row to that repo only. Also pins
# that the apply path writes that suffix. Reuses s3_plan / s3_hash from
# stage3-apply-cases.sh.

# rs_toplevel <root> — the repo root as tec_main sees it after its cd.
rs_toplevel() { (cd "$1" && cd "$(git rev-parse --show-toplevel)" && pwd); }

# Distinct assertion counts keep each fixture's hash unique.
RS_REPO="$(ec_make_repo)"
ec_add_test "$RS_REPO" tests/bin/rs-relpath.sh "bin/alpha.sh" 5
ec_add_test "$RS_REPO" tests/bin/rs-otherrepo.sh "bin/bravo.sh" 6
ec_add_test "$RS_REPO" tests/bin/rs-thisrepo.sh "bin/charlie.sh" 7
ec_commit "$RS_REPO" init
RS_TOP="$(rs_toplevel "$RS_REPO")"
RS_TSV="$SWEEP_TESTS_STATE_DIR/embed-retry.tsv"
mkdir -p "$SWEEP_TESTS_STATE_DIR"
# Same hash, another relpath, no repo suffix (matches any repo): only the relpath can reject it.
printf '%s\t%s\t2\t%s\n' "$(git -C "$RS_REPO" hash-object tests/bin/rs-relpath.sh)" tests/bin/rs-renamed.sh verify-failed >>"$RS_TSV"
ec_retry_record "$RS_REPO" tests/bin/rs-otherrepo.sh "verify-failed (repo /other)"
ec_retry_record "$RS_REPO" tests/bin/rs-thisrepo.sh "verify-failed (repo $RS_TOP)"
ec_run "$RS_REPO" "$AUDIT" --embed-cases --dry-run --band-size 50
RS_DIAG="rc=$RC top=$RS_TOP err=${ERR:0:200}"

case_begin "retry-row-other-relpath-not-capped" "bin/lib/test-embed-cases/retry-record.sh"
check_eq "RS1 a row with the same hash but another relpath does not cap the file ($RS_DIAG)" "" "$(ec_skip_reason tests/bin/rs-relpath.sh)"
if ec_band_paths | grep -qxF tests/bin/rs-relpath.sh; then pass "RS1 the file stays a band candidate"; else fail "RS1 the file stays a band candidate" "out=${OUT:0:300}"; fi
case_end

case_begin "retry-row-other-repo-not-capped" "bin/lib/test-embed-cases/retry-record.sh"
check_eq "RS2 a row scoped to (repo /other) does not cap the file in this repo ($RS_DIAG)" "" "$(ec_skip_reason tests/bin/rs-otherrepo.sh)"
if ec_band_paths | grep -qxF tests/bin/rs-otherrepo.sh; then pass "RS2 the file stays a band candidate"; else fail "RS2 the file stays a band candidate" "out=${OUT:0:300}"; fi
case_end

case_begin "retry-row-this-repo-capped" "bin/lib/test-embed-cases/retry-record.sh"
check_eq "RS3 a row scoped to this repo's toplevel caps the file ($RS_DIAG)" "retry-capped" "$(ec_skip_reason tests/bin/rs-thisrepo.sh)"
case_end

case_begin "retry-record-reason-carries-repo" "bin/lib/test-embed-cases/retry-record.sh"
# Two NG applies on one workdir cap the item, as in R2.
s3_plan alpha
_rs_hash="$(s3_hash alpha)"
cp "$S3_REPO/tests/bin/t-alpha.sh" "$(ec_item_output tests/bin/t-alpha.sh)"
ec_codex_says "CASE_BOUNDARY: tests/bin/t-alpha.sh: OK"
ec_apply "$S3_REPO"
ec_apply "$S3_REPO"
check_eq "RS4 the second NG caps the item (rc=$RC err=${ERR:0:200})" "capped" "$(ec_wl_field tests/bin/t-alpha.sh 8)"
_rs_reason="$(awk -F'\t' -v h="$_rs_hash" -v p=tests/bin/t-alpha.sh '$1 == h && $2 == p { r = $4 } END { print r }' "$RS_TSV" 2>/dev/null)"
_rs_top="$(rs_toplevel "$S3_REPO")"
check_eq "RS4 the recorded reason ends with (repo <toplevel>)" " (repo $_rs_top)" "${_rs_reason: -$((${#_rs_top} + 8))}"
case_end

grp_done retry-scope-cases.sh
