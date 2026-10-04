#!/usr/bin/env bash
# tests/bin/feature-2455-test-load-control/registry-fail-closed-cases.sh — RF1-RF2 (#2500).
# The helper's test-language registry is broken or missing => exit 3 (environment error),
# no TSV row, and the ERROR line last on stderr; a valid table is the control. The loader
# reads the table of its own checkout, so each case runs a fixture checkout's copy.

case_begin "registry-fail-closed" "bin/find-tests-for-source.sh"

# shellcheck source=../test-language-registry/slash-header-fixture.sh
. "$AGENTS_ROOT/tests/bin/test-language-registry/slash-header-fixture.sh"

RF_REPO="$TMPDIR_BASE/rf-repo"
mkdir -p "$RF_REPO/src" "$RF_REPO/tests/bin"
printf '%s\n' 'module.exports = {};' >"$RF_REPO/src/x.js"
git init -q "$RF_REPO"
git -C "$RF_REPO" config core.hooksPath /dev/null

# rf_run <mode:valid|invalid-json|missing> — sets RC / OUT / ERR.
rf_run() {
    local co="$TMPDIR_BASE/rf-co-$1"
    slash_fx_checkout "$co" "$AGENTS_ROOT" bin/find-tests-for-source.sh bin/run-with-timeout.sh
    install_test_language_registry "$co" "$AGENTS_ROOT"
    case "$1" in
        invalid-json) printf '%s\n' '{ "schema": 1, "entries": [' >"$co/hooks/lib/test-language-registry.json" ;;
        missing) rm -f "$co/hooks/lib/test-language-registry.json" ;;
    esac
    RC=0
    OUT="$(cd "$NEUTRAL_DIR" && env TEST_LANES=off FIND_TESTS_CORPUS_CACHE=off \
        "RUN_ALL_CACHE_DIR=$TMPDIR_BASE/rf-cache-$1" \
        bash "$RUN_TIMEOUT" 120 bash "$co/bin/find-tests-for-source.sh" --root "$RF_REPO" --sources src/x.js \
        2>"$TMPDIR_BASE/rf-err-$1")" || RC=$?
    ERR="$(cat "$TMPDIR_BASE/rf-err-$1")"
}

# ── RF1 control: a valid table answers the query ────────────────────────────
rf_run valid
assert_eq "RF1 valid table: exit 0" "0" "$RC"
assert_eq "RF1 valid table: one TSV row for the query" "1" "$(printf '%s\n' "$OUT" | awk -F'\t' '$1 == "src/x.js"' | grep -c .)"
case_ran RF1

# ── RF2 broken / missing table: fail closed ─────────────────────────────────
for _rf_mode in invalid-json missing; do
    rf_run "$_rf_mode"
    assert_eq "RF2 $_rf_mode: exit 3 (environment error)" "3" "$RC"
    assert_eq "RF2 $_rf_mode: no TSV row on stdout" "" "$OUT"
    assert_eq "RF2 $_rf_mode: ERROR line last on stderr" "ERROR: test language registry not readable" "${ERR##*$'\n'}"
done
case_ran RF2

case_end
grp_done registry-fail-closed-cases.sh
