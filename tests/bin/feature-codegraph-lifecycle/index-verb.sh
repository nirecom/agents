# shellcheck shell=bash
# Tests: bin/codegraph-lifecycle.js, bin/codegraph-lifecycle/index-health.js
# Tags: codegraph, lifecycle, index-health, sqlite, scope:issue-specific
# ST-18 L7-L10f: which verb `init` selects from the index health verdict.
# C5 regression — the upstream isInitialized() only checks that the DB file
# exists, so `init -y` would never rebuild a present-but-unusable index.

# assert_rebuilds <label> <root-native> — the repair shape shared by every
# unusable-index case: exactly one `index -q <root>` and no `init -y`.
assert_rebuilds() {
    assert_eq "$1 — index called exactly once" "1" "$(verb_count index)"
    assert_eq "$1 — index carries the quiet flag" "index -q" \
        "$(printf '%s' "$(verb_line index)" | cut -d' ' -f1-2)"
    assert_eq "$1 — index targets the root" "yes" \
        "$(same_path "$2" "$(printf '%s' "$(verb_line index)" | cut -d' ' -f3-)")"
    assert_eq "$1 — init -y was NOT called" "0" "$(verb_count init)"
}

echo "--- L7: nothing indexed yet ---"
reset_env
root="$(mkroot "l7")"
make_db "$root" absent
run_cli init "$root"
assert_eq "L7 — init -y called exactly once" "1" "$(verb_count init)"
assert_eq "L7 — init carries the assume-yes flag" "init -y" "$(printf '%s' "$(verb_line init)" | cut -d' ' -f1-2)"
assert_eq "L7 — init targets the root" "yes" "$(same_path "$root" "$(printf '%s' "$(verb_line init)" | cut -d' ' -f3-)")"
assert_eq "L7 — index was not called" "0" "$(verb_count index)"

echo "--- L8: healthy index is idempotent ---"
reset_env
root="$(mkroot "l8")"
if make_db "$root" healthy; then
    run_cli init "$root"
    assert_silent "L8"
    assert_no_spawn "L8"
fi

echo "--- L9c precondition: the corrupt fixture must fail at DB open ---"
# Without this the case would only prove the cheap bad-header branch, and a
# fixture whose 16th byte drifted off 0x00 would still pass (review C7).
reset_env
root="$(mkroot "l9c-pre")"
if make_db "$root" corrupt; then
    assert_eq "L9c precondition — header is the exact 16-byte SQLite magic" "ok" "$(db_field "$root" header)"
    assert_eq "L9c precondition — the database cannot be opened" "fail" "$(db_field "$root" open)"
    assert_eq "L9c precondition — open failed with 'file is not a database'" "not-a-database" "$(db_field "$root" openerr)"
fi

echo "--- L9-L10e: an unusable index is rebuilt, never re-inited ---"
while IFS='|' read -r case_id kind; do
    [ -n "$case_id" ] || continue
    reset_env
    root="$(mkroot "rebuild-$case_id")"
    make_db "$root" "$kind" || continue
    run_cli init "$root"
    assert_rebuilds "$case_id ($kind)" "$root"
done <<'TABLE'
L9|zero
L9b|fake-schema
L9c|corrupt
L10|state-partial
L10b|state-failed
L10c|no-nodes
L10e|no-schema-versions
TABLE

echo "--- L9d: each required table, dropped on its own, forces the rebuild ---"
# One fixture per omitted table (review C6): deleting any single table check in
# the implementation now has a case that fails, which one all-tables-missing
# fixture could never provide. The last row is the must-not-repair control.
while IFS='|' read -r case_id kind expect; do
    [ -n "$case_id" ] || continue
    expect="$(trim_field "$expect")"
    reset_env
    root="$(mkroot "schema-$case_id")"
    make_db "$root" "$(trim_field "$kind")" || continue
    run_cli init "$root"
    if [ "$expect" = "rebuild" ]; then
        assert_rebuilds "$case_id ($kind)" "$root"
    else
        assert_silent "$case_id ($kind)"
        assert_no_spawn "$case_id ($kind)"
    fi
done <<'TABLE'
L9d-nodes         | no-table-nodes            | rebuild
L9d-edges         | no-table-edges            | rebuild
L9d-files         | no-table-files            | rebuild
L9d-metadata      | no-table-project_metadata | rebuild
L9d-versions      | no-table-schema_versions  | rebuild
L9d-state-missing | state-missing             | rebuild
L9d-control       | healthy                   | none
TABLE

echo "--- L10d: a running index is left alone ---"
reset_env
root="$(mkroot "l10d")"
if make_db "$root" state-indexing; then
    run_cli init "$root"
    assert_warned "L10d"
    assert_no_spawn "L10d"
fi

echo "--- L10f: the daemon is stopped before the rebuild ---"
reset_env
root="$(mkroot "l10f")"
make_db "$root" zero
l10f_pid="$(spawn_helper codegraph.js serve --mcp --path "$root")"
if [ -z "$l10f_pid" ]; then
    fail "L10f — the daemon stand-in did not start"
else
    write_pidfile "$root" "{\"pid\":$l10f_pid,\"version\":\"1\"}"
    export CG_STUB_PROBE_PID="$l10f_pid"
    run_cli init "$root"
    assert_eq "L10f — index called exactly once" "1" "$(verb_count index)"
    l10f_line="$(verb_line index)"
    l10f_probe="unrecorded"
    case "$l10f_line" in
        *probe_alive=no*) l10f_probe="gone" ;;
        *probe_alive=yes*) l10f_probe="still-running" ;;
    esac
    assert_eq "L10f — the daemon was already gone when index ran [$l10f_line]" "gone" "$l10f_probe"
    assert_eq "L10f — the daemon did not survive the run" "dead" "$(settled_state "$l10f_pid")"
    kill_helper "$l10f_pid"
fi
