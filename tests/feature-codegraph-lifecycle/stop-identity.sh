# shellcheck shell=bash
# Tests: bin/codegraph-lifecycle.js, bin/codegraph-lifecycle/process-identity.js
# Tags: codegraph, lifecycle, daemon, process-identity, scope:issue-specific
# ST-18 L15-L19f: `stop` kills only a process it has positively identified as
# this root's daemon. C2 regression — substring matching on the command line
# used to hit a sibling worktree whose path shares a prefix.

# stop_token_path <token> <root-native> <root-posix> — the --path value baked
# into the stand-in daemon's argv. Creates any directory the token implies.
stop_token_path() {
    case "$1" in
        ROOT)        printf '%s' "$2" ;;
        ROOT_TRAIL)  printf '%s/' "$2" ;;
        ROOT_OLD)    mkdir -p "$3-old"; printf '%s-old' "$2" ;;
        ROOT_SUB)    mkdir -p "$3/sub"; printf '%s/sub' "$2" ;;
        ROOT_PARENT) dirname "$2" | tr -d '\n' ;;
        OTHER)       mkdir -p "$3-other"; printf '%s-other' "$2" ;;
        ROOT_BS)     printf '%s' "$2" | tr '/' '\\' ;;
        ROOT_DRIVE)  printf '%s' "$2" | sed 's/^\(.\)/\l\1/' ;;
        ROOT_CASE)   printf '%s' "$2" | sed 's/\([^/]*\)$/\U\1/' ;;
        NONE)        printf '' ;;
        *)           printf 'UNKNOWN-TOKEN-%s' "$1" ;;
    esac
}

echo "--- L15-L19d: daemon identity matching ---"
while IFS='|' read -r case_id script argv token expect expect_out plat; do
    [ -n "$case_id" ] || continue
    case "$plat" in
        win32) if [ "$IS_WIN32" -ne 1 ]; then skip "$case_id — win32-only case, host is $UNAME_S"; continue; fi ;;
        posix) if [ "$IS_WIN32" -eq 1 ]; then skip "$case_id — POSIX-only case, host is $UNAME_S"; continue; fi ;;
    esac
    reset_env
    root_name="$(printf 'stop-%s' "$case_id" | tr 'A-Z' 'a-z')"
    root="$(mkroot "$root_name")"
    rp="$(root_sh "$root_name")"
    tokpath="$(stop_token_path "$token" "$root" "$rp")"
    argv_expanded="${argv//%P%/$tokpath}"
    # shellcheck disable=SC2086
    helper_pid="$(spawn_helper "$script" $argv_expanded)"
    if [ -z "$helper_pid" ]; then
        fail "$case_id — the daemon stand-in did not start"
        continue
    fi
    write_pidfile "$root" "{\"pid\":$helper_pid,\"version\":\"1\"}"
    run_cli stop "$root"
    assert_eq "$case_id — exit 0" "0" "$RC"
    if [ "$expect" = "kill" ]; then
        assert_kill_or_skip "$case_id — the matching daemon was stopped" "$helper_pid"
        if [ "$LIVE_CMDLINE_OBSERVABLE" -eq 1 ]; then
            if [ -e "$rp/.codegraph/daemon.pid" ]; then
                fail "$case_id — daemon.pid survived a successful stop"
            else
                pass "$case_id — daemon.pid was removed"
            fi
        else
            skip "$case_id — daemon.pid removal is unobservable on this host (see LIVE_CMDLINE_OBSERVABLE)"
        fi
    else
        assert_eq "$case_id — the unrelated process was left running" "yes" "$(is_alive "$helper_pid")"
    fi
    [ "$expect_out" = "warn" ] && assert_eq "$case_id — exactly 1 stderr warning line" "1" "$(err_lines)"
    kill_helper "$helper_pid"
done <<'TABLE'
L15|codegraph.js|serve --mcp --path %P%|ROOT|kill|ignore|any
L16|impostor.js|serve --mcp --path %P%|ROOT|alive|warn|any
L17|codegraph.js|serve --mcp --path %P%|OTHER|alive|warn|any
L17b|codegraph.js|serve --mcp --path %P%|ROOT_OLD|alive|warn|any
L17c|codegraph.js|serve --mcp --path %P%|ROOT_SUB|alive|ignore|any
L17d|codegraph.js|serve --mcp --path %P%|ROOT_PARENT|alive|ignore|any
L18|codegraph.js|index --path %P%|ROOT|alive|ignore|any
L18b|codegraph.js|serve --foo --mcp --path %P%|ROOT|alive|ignore|any
L18c|codegraph.js|serve --mcp --path-prefix %P%|ROOT|alive|ignore|any
L18d|codegraph.js|serve --mcp --path|NONE|alive|ignore|any
L19|codegraph.js|serve --mcp --path %P%|ROOT_TRAIL|kill|ignore|any
L19b|codegraph.js|serve --mcp --path %P%|ROOT_BS|kill|ignore|win32
L19c|codegraph.js|serve --mcp --path %P%|ROOT_DRIVE|kill|ignore|win32
L19d-win32|codegraph.js|serve --mcp --path %P%|ROOT_CASE|kill|ignore|win32
L19d-posix|codegraph.js|serve --mcp --path %P%|ROOT_CASE|alive|ignore|posix
TABLE

echo "--- L19e: a quoted root containing a space is tokenized correctly ---"
reset_env
export CG_LIFECYCLE_FORCE_CMDLINE_STRING=1
root="$(mkroot "stop space root")"
rp="$(root_sh "stop space root")"
l19e_pid="$(spawn_helper codegraph.js serve --mcp --path "$root")"
if [ -z "$l19e_pid" ]; then
    fail "L19e — the daemon stand-in did not start"
else
    write_pidfile "$root" "{\"pid\":$l19e_pid,\"version\":\"1\"}"
    if [ "$IS_WIN32" -ne 1 ]; then
        # POSIX `ps -o args=` prints the argv unquoted, which cannot exercise the
        # tokenizer, so feed the quoted form the real Windows command line has.
        printf '%s %s serve --mcp --path "%s"\n' "$NODE_REAL" "$HELPERS_N/codegraph.js" "$root" \
            > "$TMP_BASE/query-out.txt"
        export CG_QUERY_OUT="$BASE/query-out.txt"
        CG_PATH_MODE=query
    fi
    run_cli stop "$root"
    assert_eq "L19e — exit 0" "0" "$RC"
    if [ "$IS_WIN32" -eq 1 ]; then
        # win32 sets no query mock above — CG_PATH_MODE stays the default
        # `stub`, so this exercises the real, unmocked WMI query, gated the
        # same way as the main L15-L19d table.
        assert_kill_or_skip "L19e — the daemon behind a quoted spaced path was stopped" "$l19e_pid"
    else
        # non-win32 feeds a synthetic command line through the mocked query
        # stub (CG_QUERY_OUT / CG_PATH_MODE=query), which is unaffected by
        # this host's real WMI visibility, so no gate applies here.
        assert_eq "L19e — the daemon behind a quoted spaced path was stopped" "dead" "$(settled_state "$l19e_pid")"
    fi
    kill_helper "$l19e_pid"
fi

echo "--- L19i: a root literally named 'codegraph' does not let an unrelated script pass as the daemon ---"
reset_env
root="$(mkroot "codegraph")"
rp="$(root_sh "codegraph")"
l19i_pid="$(spawn_helper impostor.js serve --mcp --path "$root")"
if [ -z "$l19i_pid" ]; then
    fail "L19i — the impostor stand-in did not start"
else
    write_pidfile "$root" "{\"pid\":$l19i_pid,\"version\":\"1\"}"
    run_cli stop "$root"
    assert_eq "L19i — exit 0" "0" "$RC"
    assert_eq "L19i — the unrelated process was left running" "yes" "$(is_alive "$l19i_pid")"
    assert_eq "L19i — exactly 1 stderr warning line" "1" "$(err_lines)"
    kill_helper "$l19i_pid"
fi

echo "--- L19j: a --path that is not the LAST one on the daemon's command line does not authorize a kill ---"
reset_env
root="$(mkroot "l19j")"
rp="$(root_sh "l19j")"
l19j_pid="$(spawn_helper codegraph.js serve --mcp --path "$root" --path "$rp-decoy")"
if [ -z "$l19j_pid" ]; then
    fail "L19j — the daemon stand-in did not start"
else
    write_pidfile "$root" "{\"pid\":$l19j_pid,\"version\":\"1\"}"
    run_cli stop "$root"
    assert_eq "L19j — exit 0" "0" "$RC"
    assert_eq "L19j — the process whose LAST --path names a different root was left running" "yes" "$(is_alive "$l19j_pid")"
    kill_helper "$l19j_pid"
fi

echo "--- L19k: a 'codegraph.js' token that isn't at the script position doesn't authorize a kill ---"
# spawn_helper always places the script at argv[1]; passing "codegraph.js" as an
# extra positional argument before serve puts it at argv[2] instead — the exact
# decoy shape a process forwarding unrelated arguments could carry.
reset_env
root="$(mkroot "l19k")"
rp="$(root_sh "l19k")"
l19k_pid="$(spawn_helper impostor.js codegraph.js serve --mcp --path "$root")"
if [ -z "$l19k_pid" ]; then
    fail "L19k — the impostor stand-in did not start"
else
    write_pidfile "$root" "{\"pid\":$l19k_pid,\"version\":\"1\"}"
    run_cli stop "$root"
    assert_eq "L19k — exit 0" "0" "$RC"
    assert_eq "L19k — the process carrying a decoy 'codegraph.js' token was left running" "yes" "$(is_alive "$l19k_pid")"
    kill_helper "$l19k_pid"
fi

echo "--- L30: a daemon that ignores SIGTERM is escalated to SIGKILL ---"
# The stand-in installs a no-op SIGTERM handler, so a stop that only ever sends
# SIGTERM leaves it running. The control below proves the handler is actually in
# force on this host — on win32 SIGTERM is not catchable and the case would
# otherwise "pass" while testing nothing.
if [ "$IS_WIN32" -eq 1 ]; then
    skip "L30 — SIGTERM cannot be caught on win32, so escalation is unobservable"
else
    reset_env
    root="$(mkroot "stop-l30")"
    rp="$(root_sh "stop-l30")"
    l30_pid="$(spawn_helper sigterm/codegraph.js serve --mcp --path "$root")"
    if [ -z "$l30_pid" ]; then
        fail "L30 — the SIGTERM-deaf stand-in did not start"
    else
        "$NODE_EXE" -e "try{process.kill(Number(process.argv[1]),'SIGTERM')}catch(e){}" "$l30_pid" >/dev/null 2>&1 || true
        sleep 1
        if [ "$(is_alive "$l30_pid")" != "yes" ]; then
            skip "L30 — the stand-in died on SIGTERM, so escalation cannot be observed"
        else
            pass "L30 — the stand-in survives SIGTERM, so only SIGKILL can end it"
            write_pidfile "$root" "{\"pid\":$l30_pid,\"version\":\"1\"}"
            run_cli stop "$root"
            assert_reported "L30"
            assert_eq "L30 — the SIGTERM-deaf daemon was escalated to SIGKILL" "dead" "$(settled_state "$l30_pid")"
            if [ -e "$rp/.codegraph/daemon.pid" ]; then
                fail "L30 — daemon.pid survived a successful stop"
            else
                pass "L30 — daemon.pid was removed after the escalation"
            fi
        fi
        kill_helper "$l30_pid"
    fi
fi

echo "--- L19f: /proc makes the external query unnecessary (Linux) ---"
if [ "$IS_LINUX" -ne 1 ]; then
    skip "L19f — /proc argv acquisition is Linux-only, host is $UNAME_S"
elif [ ! -r "/proc/$$/cmdline" ]; then
    skip "L19f — /proc/<pid>/cmdline is not readable on this host"
else
    reset_env
    root="$(mkroot "stop-l19f")"
    l19f_pid="$(spawn_helper codegraph.js serve --mcp --path "$root")"
    if [ -z "$l19f_pid" ]; then
        fail "L19f — the daemon stand-in did not start"
    else
        write_pidfile "$root" "{\"pid\":$l19f_pid,\"version\":\"1\"}"
        CG_PATH_MODE=query
        run_cli stop "$root"
        assert_eq "L19f — exit 0" "0" "$RC"
        assert_eq "L19f — the daemon was stopped from /proc data alone" "dead" "$(settled_state "$l19f_pid")"
        assert_no_query "L19f"
        kill_helper "$l19f_pid"
    fi
fi
