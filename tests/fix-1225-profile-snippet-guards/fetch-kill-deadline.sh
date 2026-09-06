# Tests: profile-snippet.sh
# Tags: installer, profile-snippet, session-sync, fetch-deadline, timeout, set-e, scope:issue-specific
# Part of tests/fix-1225-profile-snippet-guards.sh — sourced by that dispatcher, not run alone; uses make_mirror_sandbox / run_mirror_driver / pass / fail.
# Issue #2160: _session_sync_fetch() kills the backgrounded fetch once a 3s deadline passes, so a hung remote cannot hold the login shell open.
# Every other case in this suite has git succeed or fail INSTANTLY, leaving the deadline unexercised — deleting it keeps them all green.
# These cases hang the fetch far past the deadline and assert on wall-clock time.

# Seconds the faked fetch hangs: far enough past the 3s deadline to separate
# "killed" from "finished" on a seconds clock, yet inside run_mirror_driver's own
# 30s outer timeout so a broken deadline reports a number instead of hanging.
_FKD_HANG_SECS=20
# Upper bound on the source call: 3s deadline plus overhead fits, a fetch left to
# run to completion cannot.
_FKD_MAX_ELAPSED=10
# Lower bound: proves the fixture really hung. An instantly-exiting fake git
# would satisfy the upper bound vacuously, never reaching the deadline.
_FKD_MIN_ELAPSED=2

# _fkd_hang_fetch <sandbox> — repoints the fake git so `fetch` records its own
# PID then sleeps past the deadline. `fetch-completed.out` appears only if the
# sleep ran to term, i.e. only if nothing killed it. Same failure-injection
# convention as _ffg_break_fetch in fetch-frequency-guard.sh.
_fkd_hang_fetch() {
    local sb="$1"
    cat > "$sb/bin/git" <<EOF
#!/bin/bash
cmd=""
for a in "\$@"; do case "\$a" in fetch|merge|config) cmd="\$a"; break ;; esac; done
case "\$cmd" in
    fetch)
        printf '%s' "\${GIT_TERMINAL_PROMPT-UNSET}" > "$sb/gtp.out"
        printf '%s' "\$\$" > "$sb/fetchpid.out"
        sleep $_FKD_HANG_SECS
        printf 'completed' > "$sb/fetch-completed.out"
        exit 0
        ;;
    merge) printf 'merged' > "$sb/merged.out"; printf 'Updating abc1234..def5678\nFast-forward\n'; exit 0 ;;
    config)
        case "\$*" in
            *"--get core.sshCommand"*) exit 1 ;;
        esac
        exit 0
        ;;
    *) exit 0 ;;
esac
EOF
    chmod +x "$sb/bin/git"
}

# _fkd_write_driver <path> [<prologue>] — times the source itself, so the
# measurement excludes sandbox construction and shell start-up.
_fkd_write_driver() {
    local path="$1" prologue="${2:-}"
    cat > "$path" <<EOF
$prologue
_t0=\$(date +%s)
. "\$SNIPPET"
_t1=\$(date +%s)
echo "ELAPSED=\$(( _t1 - _t0 ))"
echo "DONE"
EOF
}

# _fkd_elapsed <output> — the driver's ELAPSED value, empty when the driver never
# got that far (outer timeout killed it).
_fkd_elapsed() {
    echo "$1" | grep -o 'ELAPSED=[0-9][0-9]*' | head -1 | cut -d= -f2
}

# ---------------------------------------------------------------------------
# TC-DEADLINE1 — a fetch that never returns on its own is killed at the deadline:
#   sourcing returns promptly, the fetch PID is gone afterwards, it never reached
#   its own completion marker, and the ff-only merge is skipped because a killed
#   fetch's status is non-zero.
# ---------------------------------------------------------------------------
tc_deadline_kills_hung_fetch() {
    local sb; sb="$(make_mirror_sandbox 1)"
    _fkd_hang_fetch "$sb"
    local drv="$sb/drv_deadline_kill.sh"; _fkd_write_driver "$drv"
    local out; out="$(run_mirror_driver bash "$sb" "$drv" on)"
    local elapsed; elapsed="$(_fkd_elapsed "$out")"
    local fetchpid; fetchpid="$(cat "$sb/fetchpid.out" 2>/dev/null || true)"
    # Give the kill a beat to be reaped before asking whether the PID is alive.
    sleep 1
    local alive=unknown
    if [ -n "$fetchpid" ]; then
        if kill -0 "$fetchpid" 2>/dev/null; then alive=yes; else alive=no; fi
    fi
    if [ -f "$sb/gtp.out" ] \
        && [ -n "$elapsed" ] && [ "$elapsed" -le "$_FKD_MAX_ELAPSED" ] \
        && [ "$alive" = "no" ] \
        && [ ! -f "$sb/fetch-completed.out" ] \
        && [ ! -f "$sb/merged.out" ]; then
        pass "TC-DEADLINE1: hung fetch killed at the deadline (source ${elapsed}s, fetch PID $fetchpid dead, merge skipped)"
    else
        fail "TC-DEADLINE1: elapsed='$elapsed' (max $_FKD_MAX_ELAPSED) attempted=$([ -f "$sb/gtp.out" ] && echo yes || echo no) fetch-alive=$alive completed=$([ -f "$sb/fetch-completed.out" ] && echo yes || echo no) merged=$([ -f "$sb/merged.out" ] && echo yes || echo no) — a fetch hanging ${_FKD_HANG_SECS}s must be killed by the 3s deadline in _session_sync_fetch. Output: $out"
    fi
    rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# TC-DEADLINE2 — the kill path must not abort a login shell under `set -eu`:
#   `wait` on a TERM-killed child reports 143, and the surrounding `|| true` /
#   `|| _rc_ss=$?` guards are what keep that from being the shell's last word.
#   Same idiom as TC-SETE1/2/3, which never reach the kill (instant fetch).
# ---------------------------------------------------------------------------
tc_deadline_kill_survives_set_e() {
    local sb; sb="$(make_mirror_sandbox 1)"
    _fkd_hang_fetch "$sb"
    local drv="$sb/drv_deadline_sete.sh"; _fkd_write_driver "$drv" 'set -eu'
    local out rc
    out="$(run_mirror_driver bash "$sb" "$drv" on)"
    rc=$?
    local elapsed; elapsed="$(_fkd_elapsed "$out")"
    if [ "$rc" -eq 0 ] && echo "$out" | grep -q "DONE" \
        && [ -f "$sb/gtp.out" ] \
        && [ -n "$elapsed" ] && [ "$elapsed" -le "$_FKD_MAX_ELAPSED" ]; then
        pass "TC-DEADLINE2: shell survives sourcing under 'set -eu' when the deadline kills the fetch (${elapsed}s)"
    else
        fail "TC-DEADLINE2: exit=$rc done=$(echo "$out" | grep -c DONE) elapsed='$elapsed' attempted=$([ -f "$sb/gtp.out" ] && echo yes || echo no) — the deadline kill (wait returning 143) must not abort a login shell under 'set -eu'. Output: $out"
    fi
    rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# TC-DEADLINE3 — mutation guard. TC-DEADLINE1/2 could be read as "the shell did
#   not crash"; this case pins the NUMBER, from both sides. Upper: sourcing must
#   finish far inside the fixture's hang, so 3 → 60 or a dropped `kill` goes RED.
#   Lower: sourcing must take seconds, so a fixture that stopped hanging (which
#   would vacate the upper bound) goes RED instead of passing for a wrong reason.
# ---------------------------------------------------------------------------
tc_deadline_bounds_source_wall_clock() {
    local sb; sb="$(make_mirror_sandbox 1)"
    _fkd_hang_fetch "$sb"
    local drv="$sb/drv_deadline_bounds.sh"; _fkd_write_driver "$drv"
    local out; out="$(run_mirror_driver bash "$sb" "$drv" on)"
    local elapsed; elapsed="$(_fkd_elapsed "$out")"
    if [ -z "$elapsed" ]; then
        fail "TC-DEADLINE3: sourcing never returned inside run_mirror_driver's outer timeout — the ${_FKD_HANG_SECS}s fetch is holding the shell, so the 3s deadline is not killing it. Output: $out"
    elif [ ! -f "$sb/gtp.out" ]; then
        fail "TC-DEADLINE3: the fetch never ran, so the deadline was never exercised and the timing bound is vacuous. Output: $out"
    elif [ "$elapsed" -gt "$_FKD_MAX_ELAPSED" ]; then
        fail "TC-DEADLINE3: sourcing took ${elapsed}s against a ${_FKD_HANG_SECS}s hung fetch (max $_FKD_MAX_ELAPSED) — the deadline in _session_sync_fetch is longer than 3s or its kill is gone. Output: $out"
    elif [ "$elapsed" -lt "$_FKD_MIN_ELAPSED" ]; then
        fail "TC-DEADLINE3: sourcing took only ${elapsed}s (min $_FKD_MIN_ELAPSED) — the fixture's fetch is not hanging, so the upper bound proves nothing about the deadline. Output: $out"
    else
        pass "TC-DEADLINE3: sourcing bounded to ${elapsed}s ($_FKD_MIN_ELAPSED..$_FKD_MAX_ELAPSED) against a ${_FKD_HANG_SECS}s hung fetch"
    fi
    rm -rf "$sb"
}

tc_deadline_kills_hung_fetch          # TC-DEADLINE1
tc_deadline_kill_survives_set_e       # TC-DEADLINE2
tc_deadline_bounds_source_wall_clock  # TC-DEADLINE3
