# shellcheck shell=bash
# Tests: bin/codegraph-lifecycle.js, bin/codegraph-lifecycle/process-identity.js
# Tags: codegraph, lifecycle, daemon, pidfile, scope:issue-specific
# ST-18 L20-L23: what `stop` does with a pidfile it cannot trust, and with an
# identity query it cannot complete. A rejected pid must never reach the kill
# call nor the external query — that query is the injection surface.

echo "--- L20: the safe-integer gate, straddled from both sides ---"
# The accepted row uses 2^32+1, not MAX_SAFE_INTEGER: Node narrows a pid to
# int32, and MAX_SAFE_INTEGER narrows to -1, which on POSIX means "signal every
# process I own". The suite refuses to place that value on a live syscall path,
# so the boundary is proved from just above it instead — including the value
# JSON silently rounds down into MAX_SAFE_INTEGER+1.
while IFS='|' read -r case_id pid_json verdict; do
    [ -n "$case_id" ] || continue
    pid_json="$(trim_field "$pid_json")"
    verdict="$(trim_field "$verdict")"
    reset_env
    CG_PATH_MODE=query
    root_name="$(printf '%s' "$case_id" | tr 'A-Z' 'a-z')"
    root="$(mkroot "$root_name")"
    decoy_pid="$(spawn_helper codegraph.js serve --mcp --path "$root")"
    write_pidfile "$root" "$pid_json"
    run_cli stop "$root"
    if [ "$verdict" = "reject" ]; then
        assert_warned "$case_id ($pid_json)"
        assert_no_query "$case_id ($pid_json)"
    else
        assert_eq "$case_id ($pid_json) — exit 0" "0" "$RC"
        assert_eq "$case_id ($pid_json) — stdout is 0 bytes" "0" "$(out_bytes)"
        assert_query_happened "$case_id ($pid_json)"
    fi
    if [ -n "$decoy_pid" ]; then
        assert_eq "$case_id ($pid_json) — no process was killed" "yes" "$(is_alive "$decoy_pid")"
        kill_helper "$decoy_pid"
    else
        fail "$case_id — the daemon stand-in did not start"
    fi
done <<'TABLE'
L20-missing        | {"version":"1"}           | reject
L20-null           | {"pid":null}              | reject
L20-zero           | {"pid":0}                 | reject
L20-negative       | {"pid":-1}                | reject
L20-string         | {"pid":"12345"}           | reject
L20-float          | {"pid":1.5}               | reject
L20-huge           | {"pid":1e308}             | reject
L20-bool           | {"pid":true}              | reject
L20-above-max-safe | {"pid":9007199254740992}  | reject
L20-precision-loss | {"pid":9007199254740993}  | reject
L20-negative-max   | {"pid":-9007199254740991} | reject
L20-wide-safe      | {"pid":4294967297}        | accept
TABLE

echo "--- L21: a stale pidfile is cleaned up silently ---"
reset_env
root="$(mkroot "l21")"
rp="$(root_sh l21)"
l21_pid="$(spawn_helper codegraph.js serve --mcp --path "$root")"
if [ -z "$l21_pid" ]; then
    fail "L21 — the daemon stand-in did not start"
else
    kill_helper "$l21_pid"
    if [ "$(settled_state "$l21_pid")" != "dead" ]; then
        fail "L21 — could not produce a dead pid to point the pidfile at"
    else
        write_pidfile "$root" "{\"pid\":$l21_pid,\"version\":\"1\"}"
        run_cli stop "$root"
        assert_silent "L21"
        if [ -e "$rp/.codegraph/daemon.pid" ]; then
            fail "L21 — the stale daemon.pid was not removed"
        else
            pass "L21 — the stale daemon.pid was removed"
        fi
    fi
fi

echo "--- L22: an unparsable pidfile warns and kills nothing ---"
reset_env
root="$(mkroot "l22")"
l22_pid="$(spawn_helper codegraph.js serve --mcp --path "$root")"
write_pidfile "$root" '{"pid": 12345, oops this is not json'
run_cli stop "$root"
assert_warned "L22"
if [ -n "$l22_pid" ]; then
    assert_eq "L22 — no process was killed" "yes" "$(is_alive "$l22_pid")"
    kill_helper "$l22_pid"
else
    fail "L22 — the daemon stand-in did not start"
fi

echo "--- L23-control: the query-empty PATH still resolves the codegraph binary ---"
# L23-enoent claims its ENOENT comes from the identity query. That only holds if
# the run got past the ON presence check, and the `--version` probe is invisible
# to the recording stub. A stale pid on the same PATH settles it: reaching the
# pidfile cleanup is downstream of the presence check and upstream of the query.
reset_env
CG_PATH_MODE=query-empty
root="$(mkroot "l23-control")"
rp="$(root_sh l23-control)"
l23c_pid="$(spawn_helper codegraph.js serve --mcp --path "$root")"
if [ -z "$l23c_pid" ]; then
    fail "L23-control — the daemon stand-in did not start"
else
    kill_helper "$l23c_pid"
    if [ "$(settled_state "$l23c_pid")" != "dead" ]; then
        fail "L23-control — could not produce a dead pid to point the pidfile at"
    else
        write_pidfile "$root" "{\"pid\":$l23c_pid,\"version\":\"1\"}"
        run_cli stop "$root"
        assert_silent "L23-control"
        if [ -e "$rp/.codegraph/daemon.pid" ]; then
            fail "L23-control — the run never reached pidfile cleanup, so L23-enoent's ENOENT is unattributed"
        else
            pass "L23-control — the presence check passes on the query-empty PATH"
        fi
    fi
fi

echo "--- L23: an identity query that never answers means no kill ---"
while IFS='|' read -r case_id mode plat; do
    [ -n "$case_id" ] || continue
    if [ "$plat" = "posix" ] && [ "$IS_WIN32" -eq 1 ]; then
        skip "$case_id — no way to hang a native powershell.exe stand-in on $UNAME_S"
        continue
    fi
    reset_env
    export CG_LIFECYCLE_FORCE_CMDLINE_STRING=1
    case "$mode" in
        enoent)  CG_PATH_MODE=query-empty ;;
        nonzero) if [ "$IS_WIN32" -eq 1 ]; then CG_PATH_MODE=query-node; else CG_PATH_MODE=query; export CG_QUERY_EXIT=3; fi ;;
        timeout) CG_PATH_MODE=query; export CG_QUERY_SLEEP=30 ;;
    esac
    root_name="$(printf '%s' "$case_id" | tr 'A-Z' 'a-z')"
    root="$(mkroot "$root_name")"
    l23_pid="$(spawn_helper codegraph.js serve --mcp --path "$root")"
    if [ -z "$l23_pid" ]; then
        fail "$case_id — the daemon stand-in did not start"
        continue
    fi
    write_pidfile "$root" "{\"pid\":$l23_pid,\"version\":\"1\"}"
    run_cli stop "$root"
    assert_warned "$case_id ($mode)"
    assert_eq "$case_id ($mode) — the unidentified process was left running" "yes" "$(is_alive "$l23_pid")"
    kill_helper "$l23_pid"
done <<'TABLE'
L23-enoent|enoent|any
L23-nonzero|nonzero|any
L23-timeout|timeout|posix
TABLE

echo "--- L24: stop with no pidfile at all is a silent no-op ---"
reset_env
root="$(mkroot "l24")"
rp="$(root_sh l24)"
if [ -e "$rp/.codegraph/daemon.pid" ]; then
    fail "L24 — a fresh root already has a daemon.pid, so absence is not what is tested"
else
    pass "L24 — the root really has no daemon.pid"
    run_cli stop "$root"
    assert_silent "L24"
    assert_no_query "L24"
    assert_no_spawn "L24"
fi

echo "--- L25: stopping an already-stopped daemon is idempotent ---"
# The second call is the one that matters: an implementation that reports on
# every invocation, or that errors when the pidfile is gone, fails here while
# passing every single-shot case above.
reset_env
root="$(mkroot "l25")"
rp="$(root_sh l25)"
l25_pid="$(spawn_helper codegraph.js serve --mcp --path "$root")"
if [ -z "$l25_pid" ]; then
    fail "L25 — the daemon stand-in did not start"
else
    write_pidfile "$root" "{\"pid\":$l25_pid,\"version\":\"1\"}"
    run_cli stop "$root"
    if [ "$LIVE_CMDLINE_OBSERVABLE" -eq 1 ]; then
        assert_reported "L25/first"
        assert_eq "L25/first — the daemon was stopped" "dead" "$(settled_state "$l25_pid")"
        if [ -e "$rp/.codegraph/daemon.pid" ]; then
            fail "L25/first — daemon.pid survived a successful stop"
        else
            pass "L25/first — daemon.pid was removed"
        fi
        reset_logs
        run_cli stop "$root"
        assert_silent "L25/second"
        assert_no_query "L25/second"
    else
        # If the first stop never identified/killed the daemon, daemon.pid
        # still exists pointing at a still-live process, so the second call
        # would repeat the same warning rather than being silent — both
        # calls' outcomes depend on the first stop's kill succeeding.
        skip "L25/first — kill outcome unobservable on this host (see LIVE_CMDLINE_OBSERVABLE)"
        skip "L25/second — idempotency is unobservable when the first stop never killed anything (see LIVE_CMDLINE_OBSERVABLE)"
    fi
    kill_helper "$l25_pid"
fi

echo "--- L26: a successful stop clears the socket, not just the pidfile ---"
reset_env
root="$(mkroot "l26")"
rp="$(root_sh l26)"
l26_pid="$(spawn_helper codegraph.js serve --mcp --path "$root")"
if [ -z "$l26_pid" ]; then
    fail "L26 — the daemon stand-in did not start"
else
    write_pidfile "$root" "{\"pid\":$l26_pid,\"version\":\"1\"}"
    printf 'stale-socket\n' > "$rp/.codegraph/daemon.sock"
    if [ ! -f "$rp/.codegraph/daemon.sock" ]; then
        fail "L26 — the daemon.sock fixture was not created, so its removal proves nothing"
    else
        run_cli stop "$root"
        if [ "$LIVE_CMDLINE_OBSERVABLE" -eq 1 ]; then
            assert_reported "L26"
            assert_eq "L26 — the daemon was stopped" "dead" "$(settled_state "$l26_pid")"
            if [ -e "$rp/.codegraph/daemon.sock" ]; then
                fail "L26 — .codegraph/daemon.sock was left behind"
            else
                pass "L26 — .codegraph/daemon.sock was removed"
            fi
        else
            skip "L26 — kill outcome unobservable on this host (see LIVE_CMDLINE_OBSERVABLE)"
        fi
    fi
    kill_helper "$l26_pid"
fi

echo "--- L29: a pid this user may not signal is unidentifiable, not killable ---"
# EPERM is the one liveness answer that means "it exists and is not yours".
# The probe runs first because a privileged host answers `ok` instead, and
# asserting against that would be a pass with no EPERM anywhere in it.
l29_pid=1
[ "$IS_WIN32" -eq 1 ] && l29_pid=4
l29_probe="$(kill_probe "$l29_pid")"
if [ "$l29_probe" != "EPERM" ]; then
    skip "L29 — pid $l29_pid does not answer EPERM on this host (probe said $l29_probe)"
else
    reset_env
    CG_PATH_MODE=query
    root="$(mkroot "l29")"
    write_pidfile "$root" "{\"pid\":$l29_pid,\"version\":\"1\"}"
    run_cli stop "$root"
    assert_warned "L29"
    assert_no_query "L29"
    assert_eq "L29 — the foreign process was neither signalled nor reaped" "EPERM" "$(kill_probe "$l29_pid")"
fi
