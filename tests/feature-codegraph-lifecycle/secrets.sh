# shellcheck shell=bash
# Tests: bin/codegraph-lifecycle.js, hooks/lib/load-env.js
# Tags: codegraph, lifecycle, security, secret-leakage, scope:issue-specific
# ST-18 L28: the malformed fixtures this suite feeds the CLI are files that in
# real use sit beside secrets, so a diagnostic quoting the offending bytes turns
# a parse failure into a disclosure. Each fixture carries a sentinel and every
# channel a person or a log can see is counted for it (review C16).

# assert_planted <name> <sentinel> <file> <want-lines> — the fixture really does
# carry the sentinel, so a clean channel means confinement and not absence.
assert_planted() {
    local n; n="$(grep -acF "$2" "$3" 2>/dev/null || true)"
    assert_eq "$1 — the sentinel is present in the fixture that plants it" "$4" "${n:-0}"
}

SEC_ENV="CGSECRET-ENV-4f1a2b"; SEC_PID="CGSECRET-PID-7c3d9e"; SEC_DB="CGSECRET-DB-1b8e55"

echo "--- L28a: a token sitting in .env never reaches a diagnostic ---"
reset_env
write_env on "CODEGRAPH_API_TOKEN=$SEC_ENV"
root="$(mkroot "l28a")"
if make_db "$root" fake-schema; then
    assert_planted "L28a" "$SEC_ENV" "$TMP_BASE/config/.env" 1
    run_cli sync "$root"
    assert_warned "L28a"
    assert_no_secret "L28a (.env token)" "$SEC_ENV"
fi

echo "--- L28b: an unparsable daemon.pid is not quoted back at the user ---"
reset_env
root="$(mkroot "l28b")"
root_p="$(root_sh l28b)"
write_pidfile "$root" "{\"pid\": 12345, \"socketToken\": \"$SEC_PID\" oops not json"
assert_planted "L28b" "$SEC_PID" "$root_p/.codegraph/daemon.pid" 1
run_cli stop "$root"
assert_warned "L28b"
assert_no_secret "L28b (daemon.pid body)" "$SEC_PID"
assert_no_query "L28b"

echo "--- L28c: bytes from a corrupt DB stay inside the DB ---"
reset_env
export CG_STUB_FAIL=index
root="$(mkroot "l28c")"
root_p="$(root_sh l28c)"
if make_db "$root" corrupt "$SEC_DB not-a-real-database"; then
    assert_planted "L28c" "$SEC_DB" "$root_p/.codegraph/codegraph.db" 1
    run_cli init "$root"
    assert_warned "L28c"
    assert_no_secret "L28c (corrupt DB bytes)" "$SEC_DB"
    assert_secret_confined "L28c (corrupt DB bytes)" "$SEC_DB" "$root_p" 1
fi

echo "--- L28d: the OFF path reads the same fixtures and leaks nothing ---"
# The gated verbs assert 0 bytes on both channels, so a leak cannot hide there.
# `stop` is exempt from the gate (#2150 review) and DOES run, which makes it the
# stricter row: it parses the sentinel-bearing daemon.pid and must still keep the
# body out of its warning. `shape` names the expected verdict per row so a verb
# that silently changed sides is a failure rather than a quietly relaxed assert.
while IFS='|' read -r case_id verb shape; do
    [ -n "$case_id" ] || continue
    case_id="$(trim_field "$case_id")"
    verb="$(trim_field "$verb")"
    shape="$(trim_field "$shape")"
    reset_env
    write_env off "CODEGRAPH_API_TOKEN=$SEC_ENV"
    root="$(mkroot "l28d-$case_id")"
    root_p="$(root_sh "l28d-$case_id")"
    make_db "$root" corrupt "$SEC_DB not-a-real-database" || continue
    write_pidfile "$root" "{\"pid\": 12345, \"socketToken\": \"$SEC_PID\" oops not json"
    assert_planted "L28d/$case_id" "$SEC_ENV" "$TMP_BASE/config/.env" 1
    assert_planted "L28d/$case_id" "$SEC_PID" "$root_p/.codegraph/daemon.pid" 1
    run_cli "$verb" "$root"
    if [ "$shape" = "silent" ]; then
        assert_silent "L28d/$case_id ($verb)"
    else
        assert_warned "L28d/$case_id ($verb)"
    fi
    assert_no_secret "L28d/$case_id ($verb, .env token)" "$SEC_ENV"
    assert_no_secret "L28d/$case_id ($verb, daemon.pid body)" "$SEC_PID"
    assert_no_secret "L28d/$case_id ($verb, corrupt DB bytes)" "$SEC_DB"
done <<'TABLE'
init | init | silent
sync | sync | silent
stop | stop | warned
TABLE
