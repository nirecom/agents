# Tests: profile-snippet.sh
# Tags: installer, profile-snippet, session-sync, frequency-guard, boundary, scope:issue-specific
# Part of tests/fix-1225-profile-snippet-guards.sh — sourced by that dispatcher.
# Semantics SSOT: the plan's frequency-guard section (elapsed < 1800 suppresses).

# Relative backdating cannot pin 1800: it is host-dependent AND the wall clock
# moves between the backdate and the snippet's own `date +%s`, so a 1799s stamp
# can read as 1801s. These cases freeze the clock instead — a `date` shim ahead
# of the sandbox PATH answers `+%s` from a fixed epoch — making the observed age
# exactly the number each case names, on every host, with no SKIP path.

# _fgc_set_mtime <file> <epoch> — absolute mtime, exact to the second.
_fgc_set_mtime() {
    perl -e 'utime $ARGV[0], $ARGV[0], $ARGV[1] or exit 1' "$2" "$1" 2>/dev/null && return 0
    touch -d "@$2" "$1" 2>/dev/null && return 0
    return 1
}

# _fgc_freeze_clock <sandbox> <epoch> — frozen `date` that also records every
# call, so a case can prove the guard consulted it rather than passing by luck.
_fgc_freeze_clock() {
    local sb="$1" epoch="$2" real_date
    real_date="$(command -v date)"
    cat > "$sb/bin/date" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$sb/date.calls"
if [ "\$1" = "+%s" ]; then printf '%s\n' "$epoch"; exit 0; fi
exec "$real_date" "\$@"
EOF
    chmod +x "$sb/bin/date"
}

# _fgc_boundary_case <label> <age-seconds> <expect-fetch 0|1> <why>
_fgc_boundary_case() {
    local label="$1" age="$2" expect="$3" why="$4"
    local sb; sb="$(make_mirror_sandbox 1)"
    local now; now="$(date +%s)"
    local stamp; stamp="$(_ffg_stamp "$sb")"
    touch "$stamp"
    if ! _fgc_set_mtime "$stamp" "$(( now - age ))"; then
        fail "$label: no absolute-mtime primitive here (neither perl utime nor 'touch -d @epoch'), so the 1800s constant cannot be pinned"
        rm -rf "$sb"
        return
    fi
    _fgc_freeze_clock "$sb" "$now"
    local drv="$sb/drv_fgc_$age.sh"
    cat > "$drv" <<'EOF'
. "$SNIPPET"
echo "DONE"
EOF
    local out; out="$(run_mirror_driver bash "$sb" "$drv" on)"
    local ran=0 clock_used=0
    [ -f "$sb/gtp.out" ] && ran=1
    [ -s "$sb/date.calls" ] && clock_used=1
    if [ "$clock_used" != "1" ]; then
        fail "$label: the frozen clock was never consulted, so the ${age}s age is not what the guard measured — the interval check does not read 'date +%s'. Output: $out"
    elif [ "$ran" = "$expect" ]; then
        pass "$label: stamp exactly ${age}s old → fetch $([ "$expect" = "1" ] && echo runs || echo suppressed) ($why)"
    else
        fail "$label: stamp exactly ${age}s old → fetch ran=$ran expected=$expect ($why — the interval constant is not 1800 with '<' semantics). Output: $out"
    fi
    rm -rf "$sb"
}

# TC-FREQ8/9/10 — 1799 vs 1800 pins the number; 1800 vs 1801 pins that the
# comparison is `-lt`, so an age of exactly 1800 fetches. An implementation
# written with `-le` passes TC-FREQ8 and TC-FREQ10 and is caught only by 9.
_fgc_boundary_case "TC-FREQ8"  1799 0 "1799 < 1800 → still inside the window"
_fgc_boundary_case "TC-FREQ9"  1800 1 "1800 is NOT less than 1800 → window elapsed"
_fgc_boundary_case "TC-FREQ10" 1801 1 "1801 > 1800 → window elapsed"

# TC-FREQ11 — overlapping startups. The guard's only defence against a second
# shell duplicating the fetch is statement ORDER: the stamp is touched BEFORE
# the fetch is launched. With a 2s fetch and a second shell starting 1s in, a
# stamp written after the fetch leaves shell B looking at an absent stamp.
# TL3 gap: a truly simultaneous pair (both between the stat and the touch) needs
# a lock file, which the approved design does not take; this pins the ordering.
_fgc_counting_git() {
    local sb="$1"
    cat > "$sb/bin/git" <<EOF
#!/bin/bash
cmd=""; repo="\$PWD"; prev=""
for a in "\$@"; do
    if [ "\$prev" = "-C" ]; then repo="\$a"; fi
    case "\$a" in
        fetch|merge|config) if [ -z "\$cmd" ]; then cmd="\$a"; fi ;;
    esac
    prev="\$a"
done
case "\$cmd" in
    fetch) printf 'fetch\n' >> "$sb/fetch.count"; sleep 2; exit 0 ;;
    merge) printf 'merged\n' >> "$sb/merged.out"; exit 0 ;;
    config)
        case "\$*" in
            *"--get core.sshCommand"*)
                if [ -f "\$repo/core-sshcommand" ]; then cat "\$repo/core-sshcommand"; exit 0; fi
                exit 1
                ;;
        esac
        exit 0
        ;;
    *) exit 0 ;;
esac
EOF
    chmod +x "$sb/bin/git"
}

tc_freq_overlapping_startups_fetch_once() {
    local sb; sb="$(make_mirror_sandbox 1)"
    _fgc_counting_git "$sb"
    _ffg_stamp "$sb" >/dev/null
    local drv="$sb/drv_fgc_concurrent.sh"
    cat > "$drv" <<'EOF'
. "$SNIPPET"
echo "DONE"
EOF
    run_mirror_driver bash "$sb" "$drv" on >"$sb/run_a.out" 2>&1 &
    local pid_a=$!
    sleep 1
    local out_b; out_b="$(run_mirror_driver bash "$sb" "$drv" on)"
    wait "$pid_a" 2>/dev/null
    sleep 3
    local n=0
    [ -f "$sb/fetch.count" ] && n="$(grep -c fetch "$sb/fetch.count")"
    if [ "$n" -eq 1 ]; then
        pass "TC-FREQ11: a shell starting during an in-flight fetch does not fetch again (1 fetch total)"
    else
        fail "TC-FREQ11: $n fetches for two overlapping startups (expected 1) — the stamp is written after the fetch instead of before it. RunA: $(cat "$sb/run_a.out" 2>/dev/null) RunB: $out_b"
    fi
    rm -rf "$sb"
}

# TC-FREQ12 — an unwritable stamp must fail OPEN: `touch "$_ss_stamp" || true`
# may cost the suppression but never the fetch and never the login shell. A
# `touch` shim injects the error on every platform; chmod does not, because
# Windows filesystems ignore the read-only bit for the account that owns it.
tc_freq_unwritable_stamp_fails_open() {
    local sb; sb="$(make_mirror_sandbox 1)"
    local stamp; stamp="$(_ffg_stamp "$sb")"
    local real_touch; real_touch="$(command -v touch)"
    cat > "$sb/bin/touch" <<EOF
#!/bin/bash
for a in "\$@"; do
    if [ "\$a" = "$stamp" ]; then
        echo "touch: $stamp: Permission denied" >&2
        exit 1
    fi
done
exec "$real_touch" "\$@"
EOF
    chmod +x "$sb/bin/touch"
    local drv="$sb/drv_fgc_rostamp.sh"
    cat > "$drv" <<'EOF'
. "$SNIPPET"
echo "DONE"
EOF
    local out rc
    out="$(run_mirror_driver bash "$sb" "$drv" on)"
    rc=$?
    if [ "$rc" -eq 0 ] && echo "$out" | grep -q "DONE" && [ -f "$sb/gtp.out" ]; then
        pass "TC-FREQ12: an unwritable stamp fails open — the fetch still runs and the shell still finishes"
    else
        fail "TC-FREQ12: exit=$rc done=$(echo "$out" | grep -c DONE) fetched=$([ -f "$sb/gtp.out" ] && echo yes || echo no) — a failing 'touch' on the stamp must not abort the startup or suppress the fetch. Output: $out"
    fi
    rm -rf "$sb"
}

tc_freq_overlapping_startups_fetch_once   # TC-FREQ11
tc_freq_unwritable_stamp_fails_open       # TC-FREQ12
