# shellcheck shell=bash
# Tests: bin/codegraph-lifecycle.js, bin/codegraph-lifecycle/index-health.js
# Tags: codegraph, lifecycle, sync-gate, sqlite, scope:issue-specific
# ST-18 L12-L14b, L27: `sync` refuses to run against an index it cannot vouch for.
# C6 regression — a valid SQLite header is not a CodeGraph index, and syncing
# into one silently produces a wrong graph.

echo "--- L12-L14: sync stays its hand on an unusable index ---"
while IFS='|' read -r case_id kind; do
    [ -n "$case_id" ] || continue
    reset_env
    root="$(mkroot "syncgate-$case_id")"
    make_db "$root" "$kind" || continue
    run_cli sync "$root"
    assert_eq "$case_id ($kind) — exit 0" "0" "$RC"
    assert_no_spawn "$case_id ($kind)"
done <<'TABLE'
L12|zero
L13|fake-schema
L13c|state-indexing
L14|empty-dir
TABLE

echo "--- L13: a foreign-schema DB warns once, and only when not quiet ---"
reset_env
root="$(mkroot "l13-loud")"
if make_db "$root" fake-schema; then
    run_cli sync "$root"
    assert_warned "L13 (no --quiet)"
    reset_logs
    run_cli sync "$root" --quiet
    assert_silent "L13 (--quiet)"
    assert_no_spawn "L13 (--quiet)"
fi

echo "--- L14: an index directory holding only .gitignore is silent ---"
reset_env
root="$(mkroot "l14-silent")"
make_db "$root" empty-dir
run_cli sync "$root"
assert_silent "L14"

echo "--- L13b: the healthy control case does sync ---"
reset_env
root="$(mkroot "l13b")"
if make_db "$root" healthy; then
    run_cli sync "$root"
    assert_eq "L13b — sync called exactly once" "1" "$(verb_count sync)"
    assert_eq "L13b — sync carries the quiet flag" "sync -q" \
        "$(printf '%s' "$(verb_line sync)" | cut -d' ' -f1-2)"
    assert_eq "L13b — sync targets the root" "yes" \
        "$(same_path "$root" "$(printf '%s' "$(verb_line sync)" | cut -d' ' -f3-)")"
fi

echo "--- L14b: an unverifiable index blocks sync and sends init to status ---"
reset_env
export CG_LIFECYCLE_FORCE_UNVERIFIABLE=1
export CG_STUB_STATUS_JSON='{"initialized":true}'
root="$(mkroot "l14b")"
if make_db "$root" healthy; then
    run_cli sync "$root" --quiet
    assert_silent "L14b/sync"
    assert_no_spawn "L14b/sync"
    reset_logs
    run_cli init "$root"
    assert_eq "L14b/init — status --json called exactly once" "1" "$(verb_count status)"
    assert_eq "L14b/init — status carries the json flag" "status --json" \
        "$(printf '%s' "$(verb_line status)" | cut -d' ' -f1-2)"
fi

echo "--- L27: a DB that cannot be read is not a DB that can be synced (POSIX) ---"
# Every other gate case is about content; this one is about access. The probe
# runs first so a host where chmod does not deny (root, win32) skips loudly
# instead of asserting against a file it can still read.
if [ "$IS_WIN32" -eq 1 ]; then
    skip "L27 — chmod does not deny reads on win32"
elif [ "$(id -u)" = "0" ]; then
    skip "L27 — running as root, chmod denies nothing"
else
    reset_env
    root="$(mkroot "l27")"
    root_p="$(root_sh l27)"
    if make_db "$root" healthy; then
        l27_db="$root_p/.codegraph/codegraph.db"
        chmod a-r "$l27_db"
        l27_state="$(file_read_state "$(to_native "$l27_db")")"
        if [ "$l27_state" != "denied:EACCES" ]; then
            skip "L27 — this host still reads a chmod a-r file (probe said $l27_state)"
        else
            run_cli sync "$root" --quiet
            assert_silent "L27/sync --quiet"
            assert_no_spawn "L27/sync --quiet"
            reset_logs
            run_cli sync "$root"
            assert_eq "L27/sync — exit 0" "0" "$RC"
            assert_eq "L27/sync — stdout is 0 bytes" "0" "$(out_bytes)"
            assert_no_spawn "L27/sync"
            if [ -f "$l27_db" ]; then
                pass "L27 — the unreadable DB was left where it was"
            else
                fail "L27 — the unreadable DB was deleted or quarantined"
            fi
        fi
        chmod u+r "$l27_db" 2>/dev/null || true
    fi
fi
