# tests/install/feature-2119-settings-allow-ssot/cc-running-probe.sh
# Tests: install/lib/wait-cc-exit.sh
# Tags: install, settings, wait-cc-exit, process-probe, scope:issue-specific, pwsh-not-required, TL2
# T57-T58 (#2561 S4-7): with pgrep missing the helper answered "not running", so the installer
# rewrote settings.json under a live session. The probe order is pgrep, then <proc-root>/N/comm,
# then tasklist; with none usable it must say so and exit 1 instead of guessing "absent".
# The helper is run from the checkout read-only, on a PATH holding only this part's stubs.

T57_WAIT_SH="$SCRIPT_CHECKOUT_ROOT/install/lib/wait-cc-exit.sh"
T57_DIR="$TMPROOT/t57"
T57_BASE="$T57_DIR/base-bin"
T57_PRE=""
T57_VERDICTS=""

t57_posix() { if command -v cygpath >/dev/null 2>&1; then cygpath -u "$1"; else printf '%s' "$1"; fi; }

# Wrappers for the real tools the helper may call. pgrep and tasklist are deliberately not here.
t57_mk_base_bin() {
    local t real
    mkdir -p "$T57_BASE"
    for t in sort tr sleep readlink ps cat grep sed awk head tail cut wc basename dirname uname; do
        real="$(command -v "$t" 2>/dev/null)" || continue
        printf '#!%s\nexec "%s" "$@"\n' "$BASH" "$real" > "$T57_BASE/$t"
        chmod +x "$T57_BASE/$t"
    done
}

# A tasklist stand-in: records that it ran, then prints one canned answer line (builtins only).
t57_mk_tasklist() { # <dir> <answer-line>
    mkdir -p "$1"
    printf '%s\n' "$2" > "$1/answer.txt"
    {
        printf '#!%s\n' "$BASH"
        printf 'printf "called\\n" >> "%s"\n' "$(t57_posix "$1")/calls.log"
        printf 'while IFS= read -r l; do printf "%%s\\n" "$l"; done < "%s"\n' "$(t57_posix "$1")/answer.txt"
        printf 'exit 0\n'
    } > "$1/tasklist"
    chmod +x "$1/tasklist"
}

t57_mk_proc() { # <dir> [<pid> <comm>]...
    local d="$1"; shift
    mkdir -p "$d"
    while [ "$#" -ge 2 ]; do
        mkdir -p "$d/$1"
        printf '%s\n' "$2" > "$d/$1/comm"
        shift 2
    done
}

t57_path() { # [tasklist-dir] -> the whole PATH the helper gets
    local p
    p="$(t57_posix "$T57_BASE")"
    [ -n "${1:-}" ] && p="$(t57_posix "$1"):$p"
    printf '%s' "$p"
}

# The stubs must be what the helper will find: checked before any slot runs.
t57_precondition() { # -> "pgrep-state/tasklist-state"
    local path tl="$T57_DIR/tl-alive" pg ts got
    path="$(t57_path "$tl")"
    if ( PATH="$path"; hash -r; command -v pgrep >/dev/null 2>&1 ); then pg="RESOLVES"; else pg="absent"; fi
    got="$( PATH="$path"; hash -r; command -v tasklist 2>/dev/null )" || got=""
    if [ "$got" = "$(t57_posix "$tl")/tasklist" ]; then ts="stub"; else ts="NOT-STUB:$got"; fi
    printf '%s/%s' "$pg" "$ts"
}

# grep exit 2+ (the MSYS grep aborts on -F -i with non-ASCII text) lands in the caller's gfail, never reads as "not found".
t57_has() { # <needle> <file>
    local rc=0
    grep -Fq -- "$1" "$2" || rc=$?
    [ "$rc" -le 1 ] || gfail="<GREP-RC:$rc>"
    return "$rc"
}

t57_case() { # <slot> <proc-root> [tasklist-dir] -> "rc/wait/indet/pid/methods/tasklist-use"
    local slot="$1" root="$2" tl="${3:-}" rc=0 err="$T57_DIR/$1.err" wait indet pid methods used gfail=""
    [ -f "$T57_WAIT_SH" ] || { printf '<MISSING:install/lib/wait-cc-exit.sh>'; return; }
    [ "$T57_PRE" = "absent/stub" ] || { printf '<PRECONDITION:%s>' "$T57_PRE"; return; }
    run_with_timeout 30 env -u WAIT_CC_RESULT -u MOCK_PGREP_MODE -u CLAUDE_CODE_SESSION_ID \
        PATH="$(t57_path "$tl")" WAIT_CC_PROC_ROOT="$(t57_posix "$root")" \
        WAIT_CC_POLL_INTERVAL=0 WAIT_CC_MAX_POLLS=1 \
        "$BASH" "$T57_WAIT_SH" > "$T57_DIR/$slot.out" 2> "$err" || rc=$?
    wait="no-wait"; indet="-"; pid="-"; methods="-"; used="tasklist-not-called"
    t57_has 'Waiting for Claude Code' "$err" && wait="waited"
    t57_has 'cannot determine whether Claude Code is running' "$err" && indet="indeterminate"
    t57_has 'PID 4242' "$err" && pid="pid-shown"
    if t57_has 'pgrep' "$err" && t57_has '/proc' "$err" && t57_has 'tasklist' "$err"; then methods="methods-named"; fi
    [ -n "$tl" ] && [ -f "$tl/calls.log" ] && used="tasklist-called"
    [ -z "$gfail" ] || { printf '%s' "$gfail"; return; }
    printf '%s/%s/%s/%s/%s/%s' "$rc" "$wait" "$indet" "$pid" "$methods" "$used"
}

# Each proc slot also carries a tasklist that says the OPPOSITE, so only "first usable means decides" passes.
t57_setup() {
    local d="$T57_DIR"
    mkdir -p "$d"
    t57_mk_base_bin
    t57_mk_proc "$d/proc-empty"
    t57_mk_proc "$d/proc-alive" 1 bash 4242 claude
    t57_mk_proc "$d/proc-absent" 1 bash 77 node
    t57_mk_proc "$d/proc-near" 1 bash 4242 claudex
    t57_mk_tasklist "$d/tl-alive" '"claude.exe","4242","Console","1","123,456 K"'
    t57_mk_tasklist "$d/tl-absent" 'INFO: No tasks are running which match the specified criteria.'
    t57_mk_tasklist "$d/tl-contra-absent" 'INFO: No tasks are running which match the specified criteria.'
    t57_mk_tasklist "$d/tl-contra-alive" '"claude.exe","4242","Console","1","123,456 K"'
    T57_PRE="$(t57_precondition)"
    T57_VERDICTS="pre=$T57_PRE
none=$(t57_case none "$d/proc-empty")
proc-alive=$(t57_case proc-alive "$d/proc-alive" "$d/tl-contra-absent")
proc-absent=$(t57_case proc-absent "$d/proc-absent" "$d/tl-contra-alive")
proc-near-miss=$(t57_case proc-near-miss "$d/proc-near")
tasklist-alive=$(t57_case tasklist-alive "$d/proc-empty" "$d/tl-alive")
tasklist-absent=$(t57_case tasklist-absent "$d/proc-empty" "$d/tl-absent")
"
}

t57_slot() { # <slot> -> verdict
    printf '%s\n' "$T57_VERDICTS" | grep "^$1=" | sed "s/^$1=//"
}

t57_run_rows() { # <id>; rows on stdin: slot|field|want|label
    local id="$1" slot field want label
    while IFS='|' read -r slot field want label; do
        [ -n "$slot" ] || continue
        ROWS=$((ROWS + 1))
        assert_eq "$id[$slot/f$field]: $label" "$want" "$(t40_field "$(t57_slot "$slot")" "$field")"
    done
}

t57_setup

case_begin "t57-probe-indeterminate-fails-closed" "install/lib/wait-cc-exit.sh"
t57_run_rows T57 <<'T57_CASES'
pre|1|absent|PRECONDITION: pgrep does not resolve on the PATH the helper is given
pre|2|stub|PRECONDITION: tasklist resolves to this part's stub, not a system binary
none|1|1|no pgrep, an empty proc root and no tasklist: the helper cannot know, so it exits 1 rather than reporting "not running"
none|2|no-wait|without polling -- waiting cannot make an unusable probe usable
none|3|indeterminate|stderr says it cannot determine whether Claude Code is running
none|4|-|and shows no PID, having found none
none|5|methods-named|naming the three means it tried (pgrep, /proc, tasklist) so the operator can supply one
T57_CASES
case_end

case_begin "t58-probe-falls-back-in-order" "install/lib/wait-cc-exit.sh"
t57_run_rows T58 <<'T58_CASES'
proc-alive|1|1|no pgrep, proc root lists a process whose comm is exactly claude: running, so exit 1 after the polls
proc-alive|2|waited|having polled like any other running answer
proc-alive|4|pid-shown|and shown the PID it found
proc-alive|6|tasklist-not-called|the proc root answered, so the later means (which here says "absent") is never consulted
proc-absent|1|0|proc root usable and holding no claude: not running, exit 0 -- although tasklist here would say "running"
proc-absent|3|-|a usable means that finds nothing is an answer, not an indeterminate probe
proc-near-miss|1|0|a comm of claudex is not claude: the match is exact
tasklist-alive|1|1|no pgrep and an empty proc root: tasklist is the next means, and its claude.exe row means running
tasklist-alive|4|pid-shown|with the PID taken from that row
tasklist-alive|6|tasklist-called|and the stub really was the means consulted
tasklist-absent|1|0|tasklist reporting no matching task means not running: exit 0
T58_CASES
case_end
