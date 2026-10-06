# Tests: bin/lib/test-embed-cases/order.sh
# Tags: TL2, scope:common, audit-tests, embed-cases, ordering
# Sourced by tests/bin/bin-audit-tests-embed-cases.sh — --order frequency
# (ledger count desc, churn desc, path asc), the no-ledger fallback, the default
# order, and --order priority (deleted-target, single-token, rest; path tiebreak).

# Five marker-less candidates; bin/echo.sh gets two extra commits (churn), the
# ledger counts t-bravo in 3 segments and t-alpha in 1 (each segment < 50% of 5).
OR_REPO="$(ec_make_repo)"
for _n in alpha bravo charlie delta echo; do
  ec_add_test "$OR_REPO" "tests/bin/t-$_n.sh" "bin/$_n.sh"
done
ec_commit "$OR_REPO" init
printf 'echo e2\n' >>"$OR_REPO/bin/echo.sh"
ec_commit "$OR_REPO" "echo churn 1"
printf 'echo e3\n' >>"$OR_REPO/bin/echo.sh"
ec_commit "$OR_REPO" "echo churn 2"

OR_WANT_LEDGER="$(printf '%s\n' tests/bin/t-bravo.sh tests/bin/t-alpha.sh tests/bin/t-echo.sh tests/bin/t-charlie.sh tests/bin/t-delta.sh)"
OR_WANT_NO_LEDGER="$(printf '%s\n' tests/bin/t-echo.sh tests/bin/t-alpha.sh tests/bin/t-bravo.sh tests/bin/t-charlie.sh tests/bin/t-delta.sh)"

case_begin "order-frequency-ledger-churn-path" "bin/lib/test-embed-cases/order.sh"
export RUN_ALL_CACHE_DIR="$EC_TMP/cache-order-ledger"
ec_ledger_segment "$OR_REPO" 20260101T000001 tests/bin/t-bravo.sh tests/bin/t-alpha.sh
ec_ledger_segment "$OR_REPO" 20260101T000002 tests/bin/t-bravo.sh
ec_ledger_segment "$OR_REPO" 20260101T000003 tests/bin/t-bravo.sh
ec_run "$OR_REPO" "$AUDIT" --embed-cases --dry-run --band-size 5 --order frequency
check_eq "OF1 frequency order: ledger count desc, then churn desc, then path asc (rc=$RC err=${ERR:0:200})" "$OR_WANT_LEDGER" "$(ec_band_paths)"
case_end

case_begin "order-frequency-no-ledger" "bin/lib/test-embed-cases/order.sh"
export RUN_ALL_CACHE_DIR="$EC_TMP/cache-order-empty"
ec_run "$OR_REPO" "$AUDIT" --embed-cases --dry-run --band-size 5 --order frequency
check_eq "OF2 no ledger: every count is 0, so churn desc then path asc decides (rc=$RC err=${ERR:0:200})" "$OR_WANT_NO_LEDGER" "$(ec_band_paths)"
case_end

case_begin "order-default-is-frequency" "bin/lib/test-embed-cases/order.sh"
export RUN_ALL_CACHE_DIR="$EC_TMP/cache-order-ledger"
ec_run "$OR_REPO" "$AUDIT" --embed-cases --dry-run --band-size 5
check_eq "OF3 omitting --order yields the frequency order (rc=$RC err=${ERR:0:200})" "$OR_WANT_LEDGER" "$(ec_band_paths)"
case_end
export RUN_ALL_CACHE_DIR="$EC_TMP/run-all-cache"

# Priority: bin/gone.sh never existed (CHR_HAS_C=1) -> 1; one token -> 2; rest -> 3.
OP_REPO="$(ec_make_repo)"
ec_add_test "$OP_REPO" tests/bin/a-multi.sh "bin/alpha.sh, bin/bravo.sh" 2
ec_add_test "$OP_REPO" tests/bin/z-deleted.sh "bin/gone.sh, bin/alpha.sh" 2
ec_add_test "$OP_REPO" tests/bin/m-single.sh "bin/charlie.sh"
ec_add_test "$OP_REPO" tests/bin/b-single.sh "bin/delta.sh"
ec_commit "$OP_REPO" init

case_begin "order-priority" "bin/lib/test-embed-cases/order.sh"
ec_run "$OP_REPO" "$AUDIT" --embed-cases --dry-run --band-size 5 --order priority
check_eq "OP1 priority order: deleted-target header, single token, the rest; path breaks ties (rc=$RC err=${ERR:0:200})" \
  "$(printf '%s\n' tests/bin/z-deleted.sh tests/bin/b-single.sh tests/bin/m-single.sh tests/bin/a-multi.sh)" \
  "$(ec_band_paths)"
case_end

grp_done order-cases.sh
