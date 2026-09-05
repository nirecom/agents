# shellcheck shell=bash
# Tests: bin/codegraph-lifecycle.js, bin/codegraph-lifecycle/index-health.js, bin/codegraph-lifecycle/process-identity.js
# Tags: codegraph, lifecycle, harness, daemon, scope:issue-specific
# Harness for tests/feature-codegraph-lifecycle.sh: platform axes, the isolated
# temp tree, the guarded CLI invocation and the assertions the ST-18 case files
# share. Sourced first, before any case file.

UNAME_S="$(uname -s 2>/dev/null || echo unknown)"
IS_WIN32=0; IS_LINUX=0
case "$UNAME_S" in MINGW*|MSYS*|CYGWIN*) IS_WIN32=1 ;; Linux) IS_LINUX=1 ;; esac

to_native() {
    if [ "$IS_WIN32" -eq 1 ] && command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"
    else printf '%s' "$1"; fi
}

NODE_EXE="$(command -v node 2>/dev/null || true)"
if [ -z "$NODE_EXE" ]; then
    echo "FAIL: node is not on PATH — this suite cannot run"
    exit 1
fi
NODE_REAL="$("$NODE_EXE" -e 'process.stdout.write(process.execPath)')"
NODE_REAL_SH="$(cygpath -u "$NODE_REAL" 2>/dev/null || printf '%s' "$NODE_REAL")"

RUN_TIMEOUT="$AGENTS_DIR/bin/run-with-timeout.sh"
if [ ! -f "$RUN_TIMEOUT" ]; then
    echo "FAIL: bin/run-with-timeout.sh is missing — no guarded invocation is possible"
    exit 1
fi
CASE_TIMEOUT="${CG_TEST_TIMEOUT:-120}"

TMP_BASE="$(mktemp -d)"
BASE="$(to_native "$TMP_BASE")"
mkdir -p "$TMP_BASE"/{config,bin,bin-empty,bin-broken,bin-broken-nocmd,bin-mismatch,bin-payload,bin-batpayload,bin-exe,query,query-node,query-empty,helpers,roots,log,home}
: > "$TMP_BASE/helper-pids"

cleanup() {
    while read -r p; do
        [ -n "${p:-}" ] || continue
        "$NODE_EXE" -e "try{process.kill(Number(process.argv[1]),'SIGKILL')}catch(e){}" "$p" >/dev/null 2>&1 || true
    done < "$TMP_BASE/helper-pids"
    rm -rf "$TMP_BASE"
}
trap cleanup EXIT

SH_BIN="$TMP_BASE/bin"; SH_BIN_EMPTY="$TMP_BASE/bin-empty"
SH_BIN_BROKEN="$TMP_BASE/bin-broken"; SH_BIN_BROKEN_NOCMD="$TMP_BASE/bin-broken-nocmd"
SH_BIN_MISMATCH="$TMP_BASE/bin-mismatch"
# WS-7/WS-8 (C4): a shim that is a VALID npm batch shim AND carries a DEL+ECHO
# pair against its own marker, so a shell interpreting it destroys the marker.
# WS-9 (C3): the sanctioned direct-launch extension, which has no shim at all.
SH_BIN_PAYLOAD="$TMP_BASE/bin-payload"; SH_BIN_BATPAYLOAD="$TMP_BASE/bin-batpayload"
SH_BIN_EXE="$TMP_BASE/bin-exe"
PAYLOAD_MARKER="$TMP_BASE/payload-marker-cmd.txt"
BATPAYLOAD_MARKER="$TMP_BASE/payload-marker-bat.txt"
SH_QUERY="$TMP_BASE/query"; SH_QUERY_NODE="$TMP_BASE/query-node"; SH_QUERY_EMPTY="$TMP_BASE/query-empty"
CONFIG_N="$BASE/config"; HELPERS_N="$BASE/helpers"
CALL_LOG="$TMP_BASE/log/calls.log"; CALL_LOG_N="$BASE/log/calls.log"
QUERY_LOG="$TMP_BASE/log/query.log"; QUERY_LOG_N="$BASE/log/query.log"
OUT_FILE="$TMP_BASE/log/out.txt"; ERR_FILE="$TMP_BASE/log/err.txt"
RECORDER_N="$BASE/recorder.js"; MKDB_N="$BASE/mkdb.js"; SAMEPATH_N="$BASE/samepath.js"
RECORD_LOGIC_N="$BASE/record-logic.js"
# The PATHEXT every child of this suite runs with (C4). Single definition so a
# case that asserts the pin is load-bearing (WS-6) tests the value run_cli
# really exports, not a copy of it.
PINNED_PATHEXT=".COM;.EXE;.BAT;.CMD"
# A host PATHEXT that omits .CMD — the shape WS-6 uses to show what the pin is
# protecting the suite from.
HOSTILE_PATHEXT=".EXE"
SHIM_REF_N="$(to_native "$AGENTS_DIR/tests/lib/shim-resolve-reference.js")"
LIFECYCLE_N="$(to_native "$LIFECYCLE_SRC")"
IDENTITY_N="$(to_native "$IDENTITY_SRC")"
RC=0

# shellcheck source=./fixtures.sh
. "$SCRIPT_DIR/fixtures.sh"
# shellcheck source=./probes.sh
. "$SCRIPT_DIR/probes.sh"

reset_logs() { : > "$CALL_LOG"; : > "$QUERY_LOG"; }

reset_env() {
    unset CG_STUB_FAIL CG_STUB_STATUS_JSON CG_STUB_PROBE_PID CG_STUB_MAKEDB 2>/dev/null || true
    unset CG_QUERY_EXIT CG_QUERY_OUT CG_QUERY_SLEEP 2>/dev/null || true
    unset CG_LIFECYCLE_FORCE_UNVERIFIABLE CG_LIFECYCLE_FORCE_CMDLINE_STRING 2>/dev/null || true
    unset CODEGRAPH 2>/dev/null || true
    CG_PATH_MODE=stub
    CG_ENV_OVERRIDE=__unset__
    export CG_QLOG="$QUERY_LOG_N"
    export CG_STUB_LOG="$CALL_LOG_N"
    export CG_MKDB="$MKDB_N"
    write_env on
    reset_logs
}

# Every mode but `empty` keeps $SH_BIN reachable so the ON presence check passes
# and the run reaches the verb under test. `query-empty` removes only the
# identity-query binary, which is what makes L23's ENOENT that query's and not
# the codegraph binary's.
# `missing-sibling` / `missing-cmd` / `mismatched-shim` deliberately omit $PATH:
# their whole point is that no resolvable `codegraph` exists, and a host that
# really has one installed would otherwise satisfy the lookup from the tail of the
# real PATH and turn a fail-closed assertion vacuously green (same reasoning as
# `empty`).
path_for_mode() {
    case "${CG_PATH_MODE:-stub}" in
        empty)            printf '%s' "$SH_BIN_EMPTY" ;;
        query)            printf '%s' "$SH_QUERY:$SH_BIN:$PATH" ;;
        query-node)       printf '%s' "$SH_QUERY_NODE:$SH_BIN:$PATH" ;;
        query-empty)      printf '%s' "$SH_QUERY_EMPTY:$SH_BIN" ;;
        missing-sibling)  printf '%s' "$SH_BIN_BROKEN" ;;
        missing-cmd)      printf '%s' "$SH_BIN_BROKEN_NOCMD" ;;
        mismatched-shim)  printf '%s' "$SH_BIN_MISMATCH" ;;
        payload-cmd)      printf '%s' "$SH_BIN_PAYLOAD" ;;
        payload-bat)      printf '%s' "$SH_BIN_BATPAYLOAD" ;;
        *)                printf '%s' "$SH_BIN:$PATH" ;;
    esac
}

HOME_N="$BASE/home"

# run_cli <verb> <root-native> [extra CLI args...] — always under a timeout.
# The guard resolves its own timeout binary from the parent PATH, so stripping
# the child PATH cannot disarm it. HOME/USERPROFILE point into the temp tree so
# a child that consults them cannot reach the real profile, and the session ids
# are dropped so no workflow state is attributable to this run.
# CG_ENV_OVERRIDE pins the child's own CODEGRAPH variable; `__unset__` (the
# reset_env default) removes it, so no case inherits an ambient value.
run_cli() {
    local verb="$1" root="$2"; shift 2
    local child_path; child_path="$(path_for_mode)"
    local flag_env=(-u CODEGRAPH)
    [ "${CG_ENV_OVERRIDE:-__unset__}" = "__unset__" ] || flag_env=("CODEGRAPH=$CG_ENV_OVERRIDE")
    NODE_OPTIONS="--require \"$RECORDER_N\"" AGENTS_CONFIG_DIR="$CONFIG_N" \
        bash "$RUN_TIMEOUT" "$CASE_TIMEOUT" \
        env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID "${flag_env[@]}" \
        CG_RECORD_LOGIC_N="$RECORD_LOGIC_N" PATHEXT="$PINNED_PATHEXT" \
        PATH="$child_path" HOME="$HOME_N" USERPROFILE="$HOME_N" \
        "$NODE_EXE" "$LIFECYCLE_N" "$verb" --path "$root" "$@" > "$OUT_FILE" 2> "$ERR_FILE"
    RC=$?
}

out_lines() { wc -l < "$OUT_FILE" | tr -d ' '; }
out_bytes() { wc -c < "$OUT_FILE" | tr -d ' '; }
err_bytes() { wc -c < "$ERR_FILE" | tr -d ' '; }
err_lines() { wc -l < "$ERR_FILE" | tr -d ' '; }
query_bytes() { wc -c < "$QUERY_LOG" | tr -d ' '; }
total_calls() { wc -l < "$CALL_LOG" | tr -d ' '; }
verb_count() { local n; n="$(grep -c "^$1 " "$CALL_LOG" 2>/dev/null || true)"; printf '%s' "${n:-0}"; }
verb_line() { grep -m1 "^$1 " "$CALL_LOG" 2>/dev/null || true; }
same_path() { "$NODE_EXE" "$SAMEPATH_N" "$1" "$2"; }

# The ON preamble probes `codegraph --version` for the presence check, so a raw
# line count is not necessarily the number of verb invocations. Measured on this
# host: `node --version` short-circuits before NODE_OPTIONS `--require`, so the
# probe records nothing and the two counts coincide. The subtraction is kept so
# the counts stay right on a node that does honor the preload, and
# VERSION_PROBE_RECORDS reports which regime is in force rather than leaving
# "no verb ran" resting on an unexamined assumption.
version_probes() { grep -c '^--version' "$CALL_LOG" 2>/dev/null || true; }
stub_db_failures() { grep -c '^STUB-MAKEDB-FAILED' "$CALL_LOG" 2>/dev/null || true; }
verb_calls() { printf '%s' "$(( $(total_calls) - $(version_probes) - $(stub_db_failures) ))"; }
assert_no_spawn() { assert_eq "$1 — codegraph was never launched for a verb" "0" "$(verb_calls)"; }

# assert_payload_intact <label> <marker> <ran-count> — the C4 measurement. An
# untouched marker only counts as evidence when the shim was actually reached:
# a run that never resolved anything leaves it untouched for the wrong reason.
assert_payload_intact() {
    if [ "${3:-0}" -lt 1 ]; then
        fail "$1 — the marker survived only because the shim was never reached (no evidence)"
    else
        assert_eq "$1 — the planted shim body was never shell-executed" \
            "pristine" "$(cat "$2" 2>/dev/null || echo "<destroyed-or-missing>")"
    fi
}

VERSION_PROBE_RECORDS=0
prove_version_probe() {
    : > "$CALL_LOG"
    CG_STUB_LOG="$CALL_LOG_N" NODE_OPTIONS="--require \"$RECORDER_N\"" \
        env CG_RECORD_LOGIC_N="$RECORD_LOGIC_N" PATHEXT="$PINNED_PATHEXT" \
        PATH="$SH_BIN:$PATH" "$NODE_EXE" \
        -e "require('node:child_process').spawnSync('codegraph',['--version'],{stdio:'ignore'})" \
        >/dev/null 2>&1 || true
    [ -s "$CALL_LOG" ] && VERSION_PROBE_RECORDS=1
    : > "$CALL_LOG"
    return 0
}

# assert_only <label> <verb> — that verb ran exactly once and no other did, so
# a success path cannot quietly fan out into a second repair attempt.
assert_only() {
    local v
    for v in init index sync status; do
        if [ "$v" = "$2" ]; then
            assert_eq "$1 — $v ran exactly once" "1" "$(verb_count "$v")"
        else
            assert_eq "$1 — $v never ran" "0" "$(verb_count "$v")"
        fi
    done
}

assert_silent() {
    assert_eq "$1 — exit 0" "0" "$RC"
    assert_eq "$1 — stdout is 0 bytes" "0" "$(out_bytes)"
    assert_eq "$1 — stderr is 0 bytes" "0" "$(err_bytes)"
}

assert_warned() {
    assert_eq "$1 — exit 0" "0" "$RC"
    assert_eq "$1 — stdout is 0 bytes" "0" "$(out_bytes)"
    assert_eq "$1 — exactly 1 stderr warning line" "1" "$(err_lines)"
}

# assert_reported_n <name> <want_stdout_lines> — the success shape: N stdout
# lines, nothing on stderr. C4 grows runInit's success report to a second
# line (the index-resync notice); the daemon-stop success paths in
# stop-identity.sh / stop-pid.sh still report exactly one line, so the line
# count is a parameter rather than baked into the helper.
assert_reported_n() {
    assert_eq "$1 — exit 0" "0" "$RC"
    assert_eq "$1 — exactly $2 stdout line(s)" "$2" "$(out_lines)"
    assert_eq "$1 — stderr is 0 bytes" "0" "$(err_bytes)"
}

# assert_reported <name> — the success shape: one stdout line, nothing on stderr.
assert_reported() { assert_reported_n "$1" 1; }

# assert_no_secret <name> <sentinel> — the sentinel reached no channel a user or
# a log ever sees. Counted, not grepped for absence, so a broken path is visible.
assert_no_secret() {
    local n; n="$(cat "$OUT_FILE" "$ERR_FILE" "$CALL_LOG" "$QUERY_LOG" 2>/dev/null | grep -cF "$2" || true)"
    assert_eq "$1 — sentinel absent from stdout/stderr/stub logs" "0" "${n:-0}"
}

# assert_secret_confined <name> <sentinel> <dir> <expected-file-count> — the
# sentinel is still only in the fixture that planted it; nothing copied it.
assert_secret_confined() {
    local n; n="$(grep -rlF "$2" "$3" 2>/dev/null | wc -l | tr -d ' ')"
    assert_eq "$1 — sentinel confined to its own fixture file" "$4" "${n:-0}"
}

# trim_field <value> — strips the padding a readable table puts around a field.
trim_field() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    printf '%s' "${s%"${s##*[![:space:]]}"}"
}

spawn_helper() {
    local script="$1"; shift
    local pidfile="$TMP_BASE/helpers/pid.$RANDOM.$RANDOM"
    rm -f "$pidfile"
    CG_HELPER_PIDFILE="$(to_native "$pidfile")" "$NODE_EXE" "$HELPERS_N/$script" "$@" >/dev/null 2>&1 &
    local i=0 pid=""
    while [ "$i" -lt 200 ]; do
        if [ -s "$pidfile" ]; then pid="$(cat "$pidfile" 2>/dev/null || true)"; [ -n "$pid" ] && break; fi
        sleep 0.05; i=$((i + 1))
    done
    [ -n "$pid" ] && printf '%s\n' "$pid" >> "$TMP_BASE/helper-pids"
    printf '%s' "$pid"
}

is_alive() {
    "$NODE_EXE" -e "try{process.kill(Number(process.argv[1]),0);process.stdout.write('yes')}catch(e){process.stdout.write('no')}" "$1"
}

kill_helper() {
    [ -n "${1:-}" ] || return 0
    "$NODE_EXE" -e "try{process.kill(Number(process.argv[1]),'SIGKILL')}catch(e){}" "$1" >/dev/null 2>&1 || true
}

# settled_state <pid> — "dead" as soon as the process is gone, "alive" after a
# grace window that covers the CLI's SIGTERM / poll / SIGKILL ladder.
settled_state() {
    local i=0
    while [ "$i" -lt 80 ]; do
        [ "$(is_alive "$1")" = "no" ] && { printf 'dead'; return; }
        sleep 0.1; i=$((i + 1))
    done
    printf 'alive'
}

# Positive control for the identity-query stub. On win32 a PATH-visible script
# cannot run as powershell.exe, so "the query never happened" is reported as a
# skip instead of passing vacuously.
QUERY_STUB_RECORDS=0
prove_query_stub() {
    : > "$QUERY_LOG"
    local probe_cmd="ps"
    [ "$IS_WIN32" -eq 1 ] && probe_cmd="powershell.exe"
    CG_QLOG="$QUERY_LOG_N" CG_QUERY_EXIT=1 env PATH="$SH_QUERY:$PATH" \
        "$NODE_EXE" -e "require('node:child_process').spawnSync(process.argv[1],['-probe'],{timeout:10000})" \
        "$probe_cmd" >/dev/null 2>&1 || true
    if [ -s "$QUERY_LOG" ]; then QUERY_STUB_RECORDS=1; fi
    : > "$QUERY_LOG"
}
prove_query_stub
prove_version_probe
echo "--- harness: identity-query stub records=$QUERY_STUB_RECORDS, --version probe records=$VERSION_PROBE_RECORDS ---"

assert_no_query() {
    if [ "$QUERY_STUB_RECORDS" -eq 1 ]; then
        assert_eq "$1 — identity query was never invoked" "0" "$(query_bytes)"
    else
        skip "$1 — identity-query stub is not executable on $UNAME_S (non-invocation unprovable)"
    fi
}

# The accepting half of assert_no_query: an accepted pid must reach the argv
# lookup, which is what separates "validated and looked up" from "rejected".
assert_query_happened() {
    if [ "$QUERY_STUB_RECORDS" -ne 1 ]; then
        skip "$1 — identity-query stub is not executable on $UNAME_S (invocation unobservable)"
    elif [ "$(query_bytes)" -gt 0 ]; then
        pass "$1 — the accepted pid reached the identity query"
    else
        fail "$1 — the identity query never ran, so the pid was rejected before it"
    fi
}

# Positive control for the REAL, unmocked identify-and-kill path (default
# CG_PATH_MODE=stub — no interception of the identity query at all). Some
# hosts' Get-CimInstance/WMI query cannot see a live, freshly-spawned process
# at all, which is a host limitation, not a defect in the code under test: it
# is exactly the "fail closed on an unreadable argv" behavior the security fix
# requires. Distinct from QUERY_STUB_RECORDS, which only proves whether this
# suite's own fake stub script can execute — this probes whether the real OS
# query can observe a real process.
LIVE_CMDLINE_OBSERVABLE=0
prove_live_cmdline_query() {
    reset_env
    local probe_root; probe_root="$(mkroot "cmdline-probe")"
    local probe_pid; probe_pid="$(spawn_helper codegraph.js serve --mcp --path "$probe_root")"
    [ -n "$probe_pid" ] || return
    write_pidfile "$probe_root" "{\"pid\":$probe_pid,\"version\":\"1\"}"
    run_cli stop "$probe_root"
    if [ "$(settled_state "$probe_pid")" = "dead" ]; then LIVE_CMDLINE_OBSERVABLE=1; fi
    kill_helper "$probe_pid"
    reset_logs
}
prove_live_cmdline_query
echo "--- harness: live command-line query observable=$LIVE_CMDLINE_OBSERVABLE ---"

# assert_kill_or_skip <label> <pid> — the kill-path counterpart of
# assert_no_query: skip (not fail) the kill-outcome assertion when this host's
# real identity query cannot observe a live process's command line at all.
assert_kill_or_skip() {
    if [ "$LIVE_CMDLINE_OBSERVABLE" -eq 1 ]; then
        assert_eq "$1" "dead" "$(settled_state "$2")"
    else
        skip "$1 — this host's identity query cannot observe a live process's command line (WMI/Win32_Process returns no match here), so the kill outcome is unobservable"
    fi
}
