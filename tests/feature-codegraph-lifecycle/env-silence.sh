# shellcheck shell=bash
# Tests: bin/codegraph-lifecycle.js, hooks/lib/load-env.js
# Tags: codegraph, lifecycle, env-flag, fail-safe, scope:issue-specific
# ST-18 L1-L6: the CODEGRAPH flag gate. Sourced by tests/feature-codegraph-lifecycle.sh.
# Every fixture below is deliberately "loud when ON" (foreign-schema DB, broken
# daemon.pid) so that silence proves the gate held rather than proving the root
# happened to be uninteresting.

# The gate covers `init` and `sync` only; `stop` is exempt (#2150 review) and is
# pinned by its CPR-ORTH counterpart file stop-flag-exempt.sh.
echo "--- L1-L4: fail-safe OFF is silent on the two gated verbs ---"
while IFS='|' read -r case_id env_value; do
    [ -n "$case_id" ] || continue
    for verb in init sync; do
        reset_env
        write_env "$env_value"
        root="$(mkroot "silence-$case_id-$verb")"
        make_db "$root" fake-schema || continue
        write_pidfile "$root" 'this is not json'
        run_cli "$verb" "$root"
        assert_silent "$case_id/$verb (CODEGRAPH=$env_value)"
        assert_eq "$case_id/$verb — codegraph was never launched" "0" "$(total_calls)"
    done
done <<'TABLE'
L1|__none__
L2|off
L3|
L4|garbage
TABLE

echo "--- L4b: ON + healthy DB leaks no ExperimentalWarning ---"
reset_env
root="$(mkroot "l4b")"
if make_db "$root" healthy; then
    run_cli sync "$root"
    assert_eq "L4b — exit 0" "0" "$RC"
    assert_eq "L4b — stderr is 0 bytes (no node:sqlite ExperimentalWarning)" "0" "$(err_bytes)"
fi

echo "--- L5: ON but codegraph is not on PATH ---"
reset_env
CG_PATH_MODE=empty
root="$(mkroot "l5")"
make_db "$root" absent
run_cli init "$root"
assert_warned "L5"
if [ -e "$(root_sh l5)/.codegraph" ]; then
    fail "L5 — .codegraph/ must not be created when codegraph is unavailable"
else
    pass "L5 — .codegraph/ was not created"
fi

echo "--- L6: ON + healthy DB hands sync the quiet flag and the root ---"
reset_env
root="$(mkroot "l6")"
if make_db "$root" healthy; then
    run_cli sync "$root"
    line="$(verb_line sync)"
    assert_eq "L6 — sync called exactly once" "1" "$(verb_count sync)"
    assert_eq "L6 — sync carries the quiet flag" "sync -q" "$(printf '%s' "$line" | cut -d' ' -f1-2)"
    assert_eq "L6 — sync targets the root" "yes" "$(same_path "$root" "$(printf '%s' "$line" | cut -d' ' -f3-)")"
fi

echo "--- L6c: telemetry env reaches every spawned codegraph subprocess ---"
# spawnCodegraph() (bin/codegraph-lifecycle.js) is the single choke point every
# verb funnels through, so one real invocation reaching it proves the telemetry
# env for all of them (codegraphOnPath's --version probe included).
# Expected values are read from the SSOT (install/codegraph-constants.txt)
# rather than hardcoded, so a future flip of the pair cannot silently drift
# from what this test asserts.
L6C_EXPECTED_TELEMETRY="$(sed -n 's/^CODEGRAPH_TELEMETRY=//p' "$AGENTS_DIR/install/codegraph-constants.txt" | head -1)"
L6C_EXPECTED_DNT="$(sed -n 's/^DO_NOT_TRACK=//p' "$AGENTS_DIR/install/codegraph-constants.txt" | head -1)"
reset_env
root="$(mkroot "l6c")"
if make_db "$root" healthy; then
    env_log="$TMP_BASE/env-log-l6c.txt"
    rm -f "$env_log"
    export CG_STUB_ENV_LOG="$(to_native "$env_log")"
    export CG_STUB_ENV_VARS="CODEGRAPH_TELEMETRY,DO_NOT_TRACK"
    run_cli sync "$root"
    unset CG_STUB_ENV_LOG CG_STUB_ENV_VARS
    assert_eq "L6c — exit 0" "0" "$RC"
    assert_eq "L6c — telemetry env vars reached the subprocess" \
        "CODEGRAPH_TELEMETRY=$L6C_EXPECTED_TELEMETRY DO_NOT_TRACK=$L6C_EXPECTED_DNT" "$(head -n1 "$env_log" 2>/dev/null || true)"
fi

echo "--- L6b: a real environment variable outranks the .env file ---"
# The two sources disagree on purpose in every row, so a reading that ignores
# precedence lands on the wrong verdict instead of coincidentally agreeing.
# An empty CODEGRAPH counts as unset, which is what makes row L6b-empty ON.
while IFS='|' read -r case_id env_var env_file expect; do
    [ -n "$case_id" ] || continue
    reset_env
    write_env "$env_file"
    [ "$env_var" = "__unset__" ] || CG_ENV_OVERRIDE="$env_var"
    root="$(mkroot "envprec-$case_id")"
    make_db "$root" fake-schema || continue
    run_cli sync "$root"
    if [ "$expect" = "on" ]; then
        assert_warned "$case_id (env=$env_var, .env=$env_file)"
        assert_no_spawn "$case_id (env=$env_var, .env=$env_file)"
    else
        assert_silent "$case_id (env=$env_var, .env=$env_file)"
        assert_eq "$case_id (env=$env_var, .env=$env_file) — nothing was recorded at all" "0" "$(total_calls)"
    fi
done <<'TABLE'
L6b-env-on|on|off|on
L6b-env-off|off|on|off
L6b-env-garbage|garbage|on|off
L6b-empty||on|on
L6b-unset|__unset__|on|on
L6b-no-file|on|__none__|on
TABLE
