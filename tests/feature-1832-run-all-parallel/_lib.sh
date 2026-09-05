#!/usr/bin/env bash
# tests/feature-1832-run-all-parallel/_lib.sh — shared fixture builder (SOURCE ONLY).
# Tests: tests/run-all.sh, bin/calibrate-test-parallelism.sh, bin/lib/run-all-parallelism.sh, bin/lib/run-all-durations.sh, bin/worker-dispatch/workers/test-runner.js
# Tags: tests, bin, parallel, ledger, scope:issue-specific

# Builds a throwaway repo-shaped tree for tests/run-all.sh (dummies at <root>/tests/, runner copy outside it — #1836).

# Public API: fx_init, fx_new_root/fx_new_git_root, fx_runner/fx_tests_dir/fx_log, fx_add_dummy, fx_add_archive_sentinel,
# fx_doctor_runner, fx_exec/fx_exec_bg (bg sets FX_BG_PID); fx_contract_line/fx_contract_field/fx_count_contract,
# fx_recorded_pids/fx_pid_alive/fx_wait_gone/fx_child_pids/fx_kill_tree, fx_wait_file, fx_now_ms/fx_children_user_cs,
# fx_mask/fx_show_tail, fx_pass/fx_fail/fx_note/fx_check/fx_finish, fx_peak_log/fx_peak_of/fx_peak_starts (--peak dummies),
# fx_ledger_dir/fx_ledger_clear/fx_ledger_snapshot/fx_ledger_restore/fx_ledger_segments/fx_ledger_lines/fx_ledger_cat

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    echo "SKIP: _lib.sh is a sourceable library, not a test" >&2
    exit 77
fi

FX_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FX_ERRORS=0

# One fx_exec == one run from an EMPTY duration ledger. The runner grows a ledger under
# $FX_CACHE_DIR/durations and re-orders the work list from it, so a second run would
# otherwise stop being byte-comparable with the first. Accumulation is opt-in.
FX_LEDGER_KEEP="${FX_LEDGER_KEEP:-0}"

# One-line shim to the canonical portable wrapper (rules/test/macos-timeout.md).
run_with_timeout() { "$FX_REPO_ROOT/bin/run-with-timeout.sh" "$@"; }

fx_pass() { echo "PASS: $1"; }
fx_fail() { echo "FAIL: $1"; FX_ERRORS=$((FX_ERRORS + 1)); }
fx_note() { echo "NOTE: $1"; }

# fx_check <rc> <message> — fx_pass when rc is 0, fx_fail otherwise.
fx_check() {
    if [ "$1" -eq 0 ]; then fx_pass "$2"; else fx_fail "$2"; fi
}

fx_finish() {
    echo ""
    if [ "$FX_ERRORS" -eq 0 ]; then
        echo "=== $FX_CASE_NAME: all assertions passed ==="
        exit 0
    fi
    echo "=== $FX_CASE_NAME: $FX_ERRORS assertion(s) failed ==="
    exit 1
}

# Git Bash's ps rejects -o; falls back to the plain columnar form (PID PPID ...).
FX_PS_POSIX=0
ps -eo pid=,ppid= >/dev/null 2>&1 && FX_PS_POSIX=1

fx_child_pids() {
    if [ "$FX_PS_POSIX" = "1" ]; then
        ps -eo pid=,ppid= 2>/dev/null | awk -v p="$1" '$2 == p { print $1 }'
    else
        ps 2>/dev/null | awk -v p="$1" 'NR > 1 && $2 == p { print $1 }'
    fi
    return 0
}

# Kills a pid and all descendants, deepest first — killing only the recorded pid leaks the dummy's own sleep child.
fx_kill_tree() {
    local pid="$1" kid
    case "$pid" in ''|*[!0-9]*) return 0 ;; esac
    [ "$pid" = "$$" ] && return 0
    [ "$pid" -le 1 ] 2>/dev/null && return 0
    for kid in $(fx_child_pids "$pid"); do
        [ "$kid" = "$pid" ] || fx_kill_tree "$kid"
    done
    kill -KILL "-$pid" 2>/dev/null || true
    kill -KILL "$pid" 2>/dev/null || true
    return 0
}

# Roots are discovered by globbing, not tracked in a variable — fx_new_root runs in a subshell.
fx_cleanup() {
    local root pid
    for root in "${FX_TMP_ROOT:-/nonexistent}"/fx*; do
        [ -d "$root/pids" ] || continue
        for pid in $(fx_recorded_pids "$root"); do
            fx_kill_tree "$pid"
        done
    done
    [ -n "${FX_TMP_ROOT:-}" ] && rm -rf "$FX_TMP_ROOT"
    return 0
}

# Fixture isolation (rules/test/fixture-isolation.md): cache/workflow/plans dirs live in
# the temp tree; inherited session ids are dropped so no hook resolves the live session.

# fx_init snapshots and drops ambient control vars (e.g. inherited RUN_ALL_JOBS) so a case's
# own intent isn't silently overridden; anything set AFTER fx_init is caller intent and reaches the child untouched.

FX_CONTROL_VARS="RUN_ALL_JOBS RUN_ALL_DEADLINE RUN_ALL_PROGRESS RUN_ALL_REAP RUN_ALL_WAITN_PROBE FEATURE_644_PHASE RUN_ALL_DURATIONS_LIB"
FX_DROPPED_CONTROLS=""

# Ledger tuning and output variables. These are NOT pinnable intent: the ledger cases source
# bin/lib/run-all-durations.sh into THIS process, so they are set here as a side effect, and a
# leaked RUN_ALL_DUR_REPO_ID or RUN_ALL_DUR_MAX_* would silently retarget or resize the child's
# ledger. They are therefore always `-u`-scrubbed from the child, never forwarded.
FX_SCRUBBED_VARS="RUN_ALL_DUR_SCHEMA RUN_ALL_DUR_DIRNAME RUN_ALL_DUR_KEEP_SEGMENTS RUN_ALL_DUR_MAX_SEGMENTS_READ RUN_ALL_DUR_MAX_RECORDS RUN_ALL_DUR_MAX_LINE_BYTES RUN_ALL_DUR_MAX_KEY_BYTES RUN_ALL_DUR_MAX_SECS_DIGITS RUN_ALL_DUR_TOKEN_WIDTH RUN_ALL_DUR_TIER_UNMEASURED RUN_ALL_DUR_SWEEP_MAX RUN_ALL_DUR_REASON RUN_ALL_DUR_REPO_ID RUN_ALL_DUR_HOST_TOKEN RUN_ALL_DUR_SEGMENT RUN_ALL_DUR_WRITE_OK RUN_ALL_DUR_TIER_OUT RUN_ALL_DUR_SEGMENTS_READ"

fx_drop_ambient_controls() {
    local v cur
    FX_DROPPED_CONTROLS=""
    for v in $FX_CONTROL_VARS; do
        eval "cur=\${$v+set}"
        [ "$cur" = "set" ] || continue
        eval "FX_AMBIENT_$v=\$$v"
        FX_DROPPED_CONTROLS="$FX_DROPPED_CONTROLS $v"
        unset "$v"
    done
    return 0
}

# Builds `env` args pinning each control to caller intent: set vars pass through, unset ones get `-u`.
# FX_SCRUBBED_VARS get `-u` unconditionally. Two passes: env stops parsing options at the first
# NAME=VALUE, so all `-u` must come first.
fx_control_args() {
    local v cur
    for v in $FX_SCRUBBED_VARS; do
        printf -- '-u %s ' "$v"
    done
    for v in $FX_CONTROL_VARS; do
        eval "cur=\${$v+set}"
        [ "$cur" = "set" ] || printf -- '-u %s ' "$v"
    done
    for v in $FX_CONTROL_VARS; do
        eval "cur=\${$v+set}"
        [ "$cur" = "set" ] && eval "printf '%s ' \"$v=\$$v\""
    done
    return 0
}

fx_init() {
    FX_CASE_NAME="$1"
    FX_TMP_ROOT="$(mktemp -d)" || { echo "SKIP: mktemp unavailable" >&2; exit 77; }
    FX_CACHE_DIR="$FX_TMP_ROOT/run-all-cache"
    mkdir -p "$FX_CACHE_DIR" "$FX_TMP_ROOT/workflow" "$FX_TMP_ROOT/plans"
    export RUN_ALL_CACHE_DIR="$FX_CACHE_DIR"
    export CLAUDE_WORKFLOW_DIR="$FX_TMP_ROOT/workflow"
    export WORKFLOW_PLANS_DIR="$FX_TMP_ROOT/plans"
    unset CLAUDE_SESSION_ID 2>/dev/null || true
    unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true
    fx_drop_ambient_controls
    trap fx_cleanup EXIT
    echo "=== $FX_CASE_NAME ==="
    [ -n "$FX_DROPPED_CONTROLS" ] && \
        fx_note "ambient control(s) dropped from the environment:$FX_DROPPED_CONTROLS"
    return 0
}

# --- duration ledger (bin/lib/run-all-durations.sh writes here) -------------
# Segment files are $FX_CACHE_DIR/durations/dur.<schema>.<host16>.<stamp>-<pid>.log

fx_ledger_dir() { echo "${FX_CACHE_DIR:-/nonexistent}/durations"; }

fx_ledger_clear() { rm -rf "$(fx_ledger_dir)" 2>/dev/null || true; return 0; }

fx_ledger_snapshot() {
    rm -rf "$1" 2>/dev/null || true
    [ -d "$(fx_ledger_dir)" ] || return 0
    cp -a "$(fx_ledger_dir)" "$1" 2>/dev/null || return 1
    return 0
}

fx_ledger_restore() {
    rm -rf "$(fx_ledger_dir)" 2>/dev/null || true
    [ -d "$1" ] || return 0
    cp -a "$1" "$(fx_ledger_dir)" 2>/dev/null || return 1
    return 0
}

# Counts only files: an entry that is a directory is a deliberate undeletable-segment fixture.
fx_ledger_segments() {
    local f n=0
    for f in "$(fx_ledger_dir)"/dur.*; do
        [ -f "$f" ] && n=$((n + 1))
    done
    printf '%s\n' "$n"
}

fx_ledger_cat() {
    local f
    for f in "$(fx_ledger_dir)"/dur.*; do
        [ -f "$f" ] && cat "$f"
    done 2>/dev/null
    return 0
}

fx_ledger_lines() { fx_ledger_cat | grep -c '' || true; }

# Each call MUST yield a distinct directory even though callers invoke it as
# `root="$(fx_new_root)"` — a counter would only ever advance in the subshell.
fx_new_root() {
    local root
    root="$(mktemp -d "$FX_TMP_ROOT/fxXXXXXX")" || return 1
    mkdir -p "$root/bin/lib" "$root/tests" "$root/pids"
    cp "$FX_REPO_ROOT/tests/run-all.sh" "$root/bin/run-all.sh"
    cp "$FX_REPO_ROOT/bin/lib/run-all-parallelism.sh" "$root/bin/lib/run-all-parallelism.sh"
    # Omitting this silently disables the ledger in EVERY fixture, which would turn
    # the ledger cases green without any of the behaviour under test being present.
    cp "$FX_REPO_ROOT/bin/lib/run-all-durations.sh" "$root/bin/lib/run-all-durations.sh" 2>/dev/null || true
    echo "$root"
}

# fx_new_git_root — fx_new_root plus a real one-commit git repository, so a linked
# worktree can be added from it. Returns 1 (prints nothing) when git is unavailable.
fx_new_git_root() {
    local root
    command -v git >/dev/null 2>&1 || return 1
    root="$(fx_new_root)" || return 1
    git -C "$root" init -q >/dev/null 2>&1 || return 1
    git -C "$root" config core.hooksPath /dev/null >/dev/null 2>&1 || return 1
    git -C "$root" config user.name "fx fixture" >/dev/null 2>&1 || return 1
    git -C "$root" config user.email "fx@example.com" >/dev/null 2>&1 || return 1
    git -C "$root" config commit.gpgsign false >/dev/null 2>&1 || true
    git -C "$root" add -A >/dev/null 2>&1 || return 1
    git -C "$root" commit -q -m "fixture" >/dev/null 2>&1 || return 1
    echo "$root"
}

fx_runner()    { echo "$1/bin/run-all.sh"; }
fx_tests_dir() { echo "$1/tests"; }
fx_log()       { echo "$1/overlap.log"; }

# fx_add_dummy <root> <id> [opts] — writes one generated dummy test.
#   --sleep/--exit/--lines/--err-lines/--serial <reason>/--grandchild (spawns sleep 300)/--contract <stdout|stderr|indented>
#   --ignore-term/--ignore-int (trap + bounded loop)/--log (start/end to shared log)/--peak (locked +/-<id>)/--phase <n> (needs FEATURE_644_PHASE>=n)
fx_add_dummy() {
    local root="$1" id="$2"; shift 2
    local sleep_s=0 exit_code=0 lines=0 err_lines=0 serial="" grandchild=0 contract="" ignore_term=0 log=0
    local ignore_int=0 peak=0 phase=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --sleep)       sleep_s="$2"; shift 2 ;;
            --exit)        exit_code="$2"; shift 2 ;;
            --lines)       lines="$2"; shift 2 ;;
            --err-lines)   err_lines="$2"; shift 2 ;;
            --serial)      serial="$2"; shift 2 ;;
            --contract)    contract="$2"; shift 2 ;;
            --phase)       phase="$2"; shift 2 ;;
            --grandchild)  grandchild=1; shift ;;
            --ignore-term) ignore_term=1; shift ;;
            --ignore-int)  ignore_int=1; shift ;;
            --peak)        peak=1; shift ;;
            --log)         log=1; shift ;;
            *) echo "fx_add_dummy: unknown option: $1" >&2; return 2 ;;
        esac
    done
    local f="$root/tests/$id.sh"
    {
        printf '#!/usr/bin/env bash\n'
        printf '# Tests: tests/run-all.sh\n'
        printf '# Tags: fixture, parallel, scope:issue-specific\n'
        [ -n "$serial" ] && printf '# Serial: %s\n' "$serial"
        printf '# generated fixture dummy: %s\n' "$id"
        printf 'ID=%s\n' "$id"
        printf 'ROOT=%s\n' "$root"
        printf 'echo "$$" > "$ROOT/pids/$ID.self"\n'
        if [ -n "$phase" ]; then
            printf 'echo "$ID phase-env FEATURE_644_PHASE=${FEATURE_644_PHASE-(unset)}"\n'
            printf 'if [ "${FEATURE_644_PHASE:-0}" -lt %s ] 2>/dev/null; then\n' "$phase"
            printf '  echo "SKIP: $ID requires FEATURE_644_PHASE>=%s" >&2\n' "$phase"
            printf '  exit 77\n'
            printf 'fi\n'
        fi
        [ "$ignore_term" -eq 1 ] && printf "trap '' TERM\n"
        [ "$ignore_int" -eq 1 ] && printf "trap '' INT\n"
        if [ "$peak" -eq 1 ]; then
            printf '%s\n' "PK_LOG=\"\$ROOT/peak.log\"; PK_LOCK=\"\$ROOT/peak.lock\""
            printf '%s\n' "_pk() { n=0; while ! mkdir \"\$PK_LOCK\" 2>/dev/null; do n=\$((n + 1)); if [ \"\$n\" -gt 200000 ]; then break; fi; done; printf '%s\\n' \"\$1\" >> \"\$PK_LOG\"; rmdir \"\$PK_LOCK\" 2>/dev/null; }"
            printf '%s\n' "_pk \"+\$ID\""
        fi
        [ "$log" -eq 1 ] && printf 'echo "start $ID" >> "$ROOT/overlap.log"\n'
        [ "$grandchild" -eq 1 ] && printf 'sleep 300 & echo "$!" > "$ROOT/pids/$ID.grandchild"\n'
        if [ "$lines" -gt 0 ]; then
            printf 'i=1; while [ "$i" -le %s ]; do echo "$ID line $i"; i=$((i + 1)); done\n' "$lines"
        fi
        if [ "$err_lines" -gt 0 ]; then
            printf 'i=1; while [ "$i" -le %s ]; do echo "$ID err line $i" >&2; i=$((i + 1)); done\n' "$err_lines"
        fi
        case "$contract" in
            stdout)   printf 'echo "RUN_CONTRACT: PASS=9 FAIL=9 SKIP=9 EXECUTED=9"\n' ;;
            stderr)   printf 'echo "RUN_CONTRACT: PASS=9 FAIL=9 SKIP=9 EXECUTED=9" >&2\n' ;;
            indented) printf 'printf "\\t  RUN_CONTRACT: PASS=9 FAIL=9 SKIP=9 EXECUTED=9\\n"\n' ;;
            "")       : ;;
            *) echo "fx_add_dummy: unknown --contract: $contract" >&2; return 2 ;;
        esac
        if [ "$ignore_term" -eq 1 ] || [ "$ignore_int" -eq 1 ]; then
            # Survives the ignored signal; only KILL ends it. Bounded at ~120s.
            printf 'n=0; while [ "$n" -lt 24 ]; do sleep 5; n=$((n + 1)); done\n'
        elif [ "$sleep_s" != "0" ]; then
            printf 'sleep %s\n' "$sleep_s"
        fi
        [ "$peak" -eq 1 ] && printf '%s\n' "_pk \"-\$ID\""
        [ "$log" -eq 1 ] && printf 'echo "end $ID" >> "$ROOT/overlap.log"\n'
        printf 'exit %s\n' "$exit_code"
    } > "$f"
    chmod +x "$f" 2>/dev/null || true
}

fx_add_archive_sentinel() {
    mkdir -p "$1/tests/_archive"
    printf '#!/usr/bin/env bash\necho "FX_ARCHIVE_LEAKED"\nexit 0\n' \
        > "$1/tests/_archive/archive-sentinel.sh"
}

# Rewrites `neutralize_stream <file>` calls to `cat <file>`; returns 1 if the runner has
# no such call site (itself the W-NEUTRALIZE-absent finding).
fx_doctor_runner() {
    local root="$1" dest="$2"
    sed 's/^\([[:blank:]]*\)neutralize_stream \(.*\)$/\1cat \2/' "$(fx_runner "$root")" > "$dest"
    cmp -s "$(fx_runner "$root")" "$dest" && return 1
    return 0
}

# fx_exec <root> <timeout> <out> <err> [runner-args...]
# The unquoted fx_control_args expansion is deliberate: it must word-split into
# `-u NAME` / `NAME=value` argv items for env.
fx_exec() {
    local root="$1" to="$2" out="$3" err="$4"; shift 4
    local rc=0
    [ "${FX_LEDGER_KEEP:-0}" -eq 1 ] || fx_ledger_clear
    run_with_timeout "$to" env $(fx_control_args) \
        "TESTS_DIR=$(fx_tests_dir "$root")" "RUN_ALL_CACHE_DIR=$FX_CACHE_DIR" \
        bash "$(fx_runner "$root")" "$@" >"$out" 2>"$err" || rc=$?
    return "$rc"
}

# fx_exec_bg <root> <out> <err> [runner-args...] — sets FX_BG_PID.
fx_exec_bg() {
    local root="$1" out="$2" err="$3"; shift 3
    [ "${FX_LEDGER_KEEP:-0}" -eq 1 ] || fx_ledger_clear
    set -m
    env $(fx_control_args) \
        "TESTS_DIR=$(fx_tests_dir "$root")" "RUN_ALL_CACHE_DIR=$FX_CACHE_DIR" \
        bash "$(fx_runner "$root")" "$@" >"$out" 2>"$err" &
    FX_BG_PID=$!
    set +m
}

fx_peak_log() { echo "$1/peak.log"; }

# fx_peak_of <log> — highest number of --peak dummies simultaneously inside
# their body, reconstructed from the +/- transition log.
fx_peak_of() {
    [ -f "$1" ] || { printf '0'; return 0; }
    awk '{ c = substr($0, 1, 1)
           if (c == "+") { n = n + 1; if (n > m) m = n }
           else if (c == "-") { n = n - 1 } }
         END { printf "%d", m + 0 }' "$1" 2>/dev/null
    return 0
}

# fx_peak_starts <log> — how many dummies entered at all. Guards the peak
# assertion against a run that executed nothing.
fx_peak_starts() {
    [ -f "$1" ] || { printf '0'; return 0; }
    grep -c '^+' "$1" 2>/dev/null
    return 0
}

FX_CONTRACT_RE='^[[:blank:]]*RUN_CONTRACT: PASS=[0-9]+ FAIL=[0-9]+ SKIP=[0-9]+ EXECUTED=[0-9]+'

fx_count_contract() { cat "$@" 2>/dev/null | grep -cE "$FX_CONTRACT_RE" || true; }

fx_contract_line() { grep -E "$FX_CONTRACT_RE" "$1" 2>/dev/null | head -n 1 || true; }

fx_contract_field() {
    fx_contract_line "$1" | sed -n "s/.*[[:blank:]]$2=\([0-9]*\).*/\1/p" | head -n 1
}

fx_recorded_pids() {
    local f
    for f in "$1"/pids/*; do
        [ -f "$f" ] && cat "$f"
    done 2>/dev/null
    return 0
}

fx_pid_alive() { kill -0 "$1" 2>/dev/null; }

# fx_wait_gone <timeout-secs> <pid>... — 0 when all pids are gone in time.
fx_wait_gone() {
    local timeout="$1"; shift
    local waited=0 pid alive
    while [ "$waited" -lt "$timeout" ]; do
        alive=0
        for pid in "$@"; do fx_pid_alive "$pid" && alive=1; done
        [ "$alive" -eq 0 ] && return 0
        sleep 1
        waited=$((waited + 1))
    done
    return 1
}

# fx_wait_file <timeout-secs> <path> — 0 when the path appears in time.
fx_wait_file() {
    local timeout="$1" path="$2" waited=0
    while [ "$waited" -lt "$timeout" ]; do
        [ -e "$path" ] && return 0
        sleep 1
        waited=$((waited + 1))
    done
    return 1
}

fx_now_ms() {
    local n
    n="$(date +%s%N 2>/dev/null)"
    case "$n" in
        ''|*[!0-9]*) echo $(( $(date +%s) * 1000 )) ;;
        *)           echo $(( n / 1000000 )) ;;
    esac
}

# Children user CPU in centiseconds. `times` is a builtin: redirecting it does
# NOT fork, so the accounting is the current shell's own children total.
fx_children_user_cs() {
    local f="$FX_TMP_ROOT/times.$$"
    times > "$f" 2>/dev/null || { echo 0; return 0; }
    sed -n 2p "$f" | awk '{ split($1, a, "m"); sub("s", "", a[2]); printf "%d", (a[1] * 60 + a[2]) * 100 }'
}

# Diagnostic printing: a captured contract line must never reach THIS file's
# stdout unmasked — the hook applies an exactly-one-contract-line rule to it.
fx_mask() { sed 's/^\([[:blank:]]*\)RUN_CONTRACT:/\1[masked] RUN_CONTRACT:/'; }

fx_show_tail() {
    local f="$1" n="${2:-20}"
    echo "    --- last $n line(s) of $(basename "$f") (contract masked) ---"
    tail -n "$n" "$f" 2>/dev/null | fx_mask | sed 's/^/    | /'
}
