# Tests: bin/lib/test-embed-cases/stage-apply.sh, bin/lib/test-embed-cases/retry-record.sh
# Tags: TL2, scope:common, audit-tests, embed-cases, stage-protocol, retry
# Sourced by tests/bin/bin-audit-tests-embed-cases.sh — the 2-try retry rule
# (RETRY gate row + failure.txt, then CAPPED + embed-retry.tsv), APPLIED never
# turning STALE on a re-run, STALE on a changed original, the leftover-backup
# recovery, and the MERGED_TARGET / EXEMPT report passthrough.
# Reuses s3_plan / s3_good / s3_hash / s3_untouched from stage3-apply-cases.sh.

case_begin "retry-first-ng-emits-retry-row" "bin/lib/test-embed-cases/stage-apply.sh"
s3_plan alpha
R_HASH="$(s3_hash alpha)"
cp "$S3_REPO/tests/bin/t-alpha.sh" "$(ec_item_output tests/bin/t-alpha.sh)"
ec_codex_says "CASE_BOUNDARY: tests/bin/t-alpha.sh: OK"
ec_apply "$S3_REPO"
check_eq "R1 attempts becomes 1 after the first NG (rc=$RC err=${ERR:0:200})" "1" "$(ec_wl_field tests/bin/t-alpha.sh 9)"
check_eq "R1 state becomes reverted" "reverted" "$(ec_wl_field tests/bin/t-alpha.sh 8)"
_idx="$(ec_wl_field tests/bin/t-alpha.sh 1)"
_retry="$(printf '%s\n' "$OUT" | awk -F'\t' -v i="$_idx" '$1 == "RETRY" && $2 == i')"
check_eq "R1 one RETRY row with 7 fields for the item" "7" "$(printf '%s' "$_retry" | awk -F'\t' '{ print NF }')"
_failure="$(ec_abs "$(printf '%s' "$_retry" | cut -f7)")"
check_eq "R1 the RETRY row names items/<idx>/failure.txt" "$EC_WORKDIR/items/$_idx/failure.txt" "$_failure"
if [[ -s "$EC_WORKDIR/items/$_idx/failure.txt" ]]; then pass "R1 failure.txt holds the verifier / codex output"; else fail "R1 failure.txt holds the verifier / codex output" "idx='$_idx'"; fi
if [[ ! -s "$SWEEP_TESTS_STATE_DIR/embed-retry.tsv" ]] || ! grep -qF "$R_HASH" "$SWEEP_TESTS_STATE_DIR/embed-retry.tsv"; then
  pass "R1 the first NG is not recorded in embed-retry.tsv"
else
  fail "R1 the first NG is not recorded in embed-retry.tsv" "$(cat "$SWEEP_TESTS_STATE_DIR/embed-retry.tsv")"
fi
case_end

case_begin "retry-second-ng-caps-and-records" "bin/lib/test-embed-cases/retry-record.sh"
ec_apply "$S3_REPO"
s3_untouched "R2 (second NG; rc=$RC err=${ERR:0:200})" alpha "$R_HASH"
if ec_has_line "$OUT" "$(printf 'CAPPED\ttests/bin/t-alpha.sh')"; then pass "R2 the second NG is CAPPED"; else fail "R2 the second NG is CAPPED" "out=${OUT:0:300}"; fi
check_eq "R2 state becomes capped" "capped" "$(ec_wl_field tests/bin/t-alpha.sh 8)"
check_eq "R2 attempts becomes 2" "2" "$(ec_wl_field tests/bin/t-alpha.sh 9)"
if printf '%s\n' "$OUT" | grep -q '^RETRY'; then fail "R2 no second RETRY row" "out=${OUT:0:300}"; else pass "R2 no second RETRY row"; fi
_row="$(awk -F'\t' -v h="$R_HASH" '$1 == h' "$SWEEP_TESTS_STATE_DIR/embed-retry.tsv" 2>/dev/null)"
check_eq "R2 embed-retry.tsv row is <orig_hash> <relpath> <attempts> <reason>" \
  "$R_HASH|tests/bin/t-alpha.sh|2|4" \
  "$(printf '%s' "$_row" | awk -F'\t' '{ print $1 "|" $2 "|" $3 "|" NF }')"
ec_run "$S3_REPO" "$AUDIT" --embed-cases --dry-run --band-size 5
check_eq "R2 the capped file is skipped as retry-capped by the next stage 1" "retry-capped" "$(ec_skip_reason tests/bin/t-alpha.sh)"
case_end

case_begin "retry-applied-not-stale-on-rerun" "bin/lib/test-embed-cases/stage-apply.sh"
s3_plan alpha
s3_good alpha
ec_codex_says "CASE_BOUNDARY: tests/bin/t-alpha.sh: OK"
ec_apply "$S3_REPO"
_after="$(s3_hash alpha)"
ec_apply "$S3_REPO"
if printf '%s\n' "$OUT" | grep -q '^STALE'; then fail "R3 a second apply does not report the APPLIED item STALE" "out=${OUT:0:300}"; else pass "R3 a second apply does not report the APPLIED item STALE"; fi
if ec_has_line "$OUT" "$(printf 'APPLIED\ttests/bin/t-alpha.sh')"; then pass "R3 the second apply re-reports APPLIED (rc=$RC)"; else fail "R3 the second apply re-reports APPLIED" "out=${OUT:0:300} err=${ERR:0:200}"; fi
check_eq "R3 state stays applied" "applied" "$(ec_wl_field tests/bin/t-alpha.sh 8)"
check_eq "R3 the applied file is not rewritten again" "$_after" "$(s3_hash alpha)"
case_end

case_begin "retry-stale-original" "bin/lib/test-embed-cases/stage-apply.sh"
s3_plan alpha
s3_good alpha
printf '# edited after stage 1\n' >>"$S3_REPO/tests/bin/t-alpha.sh"
_h="$(s3_hash alpha)"
ec_codex_says "CASE_BOUNDARY: tests/bin/t-alpha.sh: OK"
ec_apply "$S3_REPO"
if ec_has_line "$OUT" "$(printf 'STALE\ttests/bin/t-alpha.sh')"; then pass "R4 a changed original is STALE (rc=$RC)"; else fail "R4 a changed original is STALE" "out=${OUT:0:300} err=${ERR:0:200}"; fi
s3_untouched "R4 (stale)" alpha "$_h"
check_eq "R4 state becomes stale" "stale" "$(ec_wl_field tests/bin/t-alpha.sh 8)"
check_eq "R4 a stale item is not counted as a try" "0" "$(ec_wl_field tests/bin/t-alpha.sh 9)"
case_end

case_begin "retry-leftover-backup-restored" "bin/lib/test-embed-cases/stage-apply.sh"
s3_plan alpha
_h="$(s3_hash alpha)"
_idx="$(ec_wl_field tests/bin/t-alpha.sh 1)"
# Simulates a verifier killed mid-check: original in backup/, a foreign file in place.
mkdir -p "$EC_WORKDIR/items/$_idx/backup"
cp "$S3_REPO/tests/bin/t-alpha.sh" "$EC_WORKDIR/items/$_idx/backup/t-alpha.sh"
printf 'interrupted\n' >"$S3_REPO/tests/bin/t-alpha.sh"
s3_good alpha
ec_codex_says "CASE_BOUNDARY: tests/bin/t-alpha.sh: OK"
ec_apply "$S3_REPO"
if printf '%s\n' "$OUT" | grep -q '^STALE'; then fail "R5 the restored original is not STALE" "out=${OUT:0:300}"; else pass "R5 the restored original is not STALE"; fi
if ec_has_line "$OUT" "$(printf 'APPLIED\ttests/bin/t-alpha.sh')"; then pass "R5 after the restore the item applies (rc=$RC)"; else fail "R5 after the restore the item applies" "out=${OUT:0:300} err=${ERR:0:200}"; fi
if [[ -e "$EC_WORKDIR/items/$_idx/backup/t-alpha.sh" ]]; then fail "R5 the leftover backup is removed" "still present"; else pass "R5 the leftover backup is removed"; fi
if grep -qx 'interrupted' "$S3_REPO/tests/bin/t-alpha.sh"; then fail "R5 the foreign content is gone" "file still holds the interrupted content"; else pass "R5 the foreign content is gone"; fi
case_end

case_begin "retry-leftover-backup-restored-on-ng" "bin/lib/test-embed-cases/stage-apply.sh"
s3_plan alpha
_h="$(s3_hash alpha)"
_idx="$(ec_wl_field tests/bin/t-alpha.sh 1)"
mkdir -p "$EC_WORKDIR/items/$_idx/backup"
cp "$S3_REPO/tests/bin/t-alpha.sh" "$EC_WORKDIR/items/$_idx/backup/t-alpha.sh"
printf 'interrupted\n' >"$S3_REPO/tests/bin/t-alpha.sh"
ec_codex_says "CASE_BOUNDARY: tests/bin/t-alpha.sh: OK"
ec_apply "$S3_REPO"
s3_untouched "R6 (restored, then no output; rc=$RC err=${ERR:0:200})" alpha "$_h"
case_end

case_begin "retry-merged-target-report-passthrough" "bin/lib/test-embed-cases/stage-apply.sh"
S3_REPO="$(ec_make_repo)"
ec_add_test "$S3_REPO" tests/bin/t-merged.sh "bin/alpha.sh, bin/bravo.sh"
ec_commit "$S3_REPO" init
ec_stage1 "$S3_REPO" "$AUDIT" --band-size 5
ec_write_embedded "$(ec_item_output tests/bin/t-merged.sh)" "bin/alpha.sh, bin/bravo.sh" bin/alpha.sh
printf 'MERGED_TARGET\tblock-1\tbin/alpha.sh\tbin/bravo.sh\n' >"$(ec_item_report tests/bin/t-merged.sh)"
ec_codex_says "CASE_BOUNDARY: tests/bin/t-merged.sh: OK"
ec_apply "$S3_REPO"
if ec_has_line "$OUT" "$(printf 'APPLIED\ttests/bin/t-merged.sh')"; then pass "R7 a valid merged block applies (rc=$RC)"; else fail "R7 a valid merged block applies" "out=${OUT:0:300} err=${ERR:0:200}"; fi
if printf '%s\n' "$OUT" | awk -F'\t' '$1 == "MERGED_TARGET" && $2 == "tests/bin/t-merged.sh"' | grep -q .; then pass "R7 MERGED_TARGET<TAB>relpath is carried into the report"; else fail "R7 MERGED_TARGET<TAB>relpath is carried into the report" "out=${OUT:0:300}"; fi
if ec_has_line "$OUT" "$(printf 'EXEMPT\ttests/bin/t-merged.sh\tbin/bravo.sh')"; then pass "R7 the dropped token is reported EXEMPT"; else fail "R7 the dropped token is reported EXEMPT" "out=${OUT:0:300}"; fi
case_end

grp_done stage3-retry-cases.sh
