# Tests: profile-snippet.sh
# Tags: installer, profile-snippet, session-sync, frequency-guard, scope:issue-specific
# Part of tests/fix-1225-profile-snippet-guards.sh — sourced by that dispatcher,
# not run alone; uses make_mirror_sandbox / run_mirror_driver. Issue #2160: the
# startup fetch runs at most every 30 minutes, gated by the mtime of the stamp
# file ~/.claude/projects/.git/agents-last-fetch (inside .git so session-sync's
# `git add .` can never pick it up).
_ffg_mtime() {
    stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0
}

# _ffg_stamp <sandbox> — echoes the stamp path, creating its parent directory.
_ffg_stamp() {
    mkdir -p "$1/home/.claude/projects/.git"
    printf '%s' "$1/home/.claude/projects/.git/agents-last-fetch"
}

# _ffg_backdate_minutes <file> <minutes> — exact relative backdating for the
# boundary pair (TC-FREQ4/TC-FREQ5). Returns 1 when neither GNU `touch -d` nor
# BSD `date -v` is available, so those cases skip rather than assert against an
# un-backdated stamp. Same fallback shape as feature-sweep-shell-snapshots.sh.
_ffg_backdate_minutes() {
    local f="$1" m="$2" ts
    touch -d "$m minutes ago" "$f" 2>/dev/null && return 0
    ts="$(date -v-"${m}"M +%Y%m%d%H%M 2>/dev/null)" || ts=""
    if [ -n "$ts" ]; then
        touch -t "$ts" "$f" 2>/dev/null && return 0
    fi
    return 1
}

# _ffg_break_fetch <sandbox> — repoints the fake git so `fetch` exits 1 while
# still recording gtp.out (per-run proof the fetch was attempted). Same
# failure-injection convention as TC12 in the parent file.
_ffg_break_fetch() {
    local sb="$1"
    cat > "$sb/bin/git" <<EOF
#!/bin/bash
cmd=""
for a in "\$@"; do case "\$a" in fetch|merge|config) cmd="\$a"; break ;; esac; done
case "\$cmd" in
    fetch) printf '%s' "\${GIT_TERMINAL_PROMPT-UNSET}" > "$sb/gtp.out"; exit 1 ;;
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

# TC-FREQ1 — a stamp younger than the interval suppresses the fetch entirely,
# and with it the downstream ff-only merge: the guard sits above both, so a guard
# wired around the fetch alone would still mutate the working tree every startup.
tc_freq_fresh_stamp_skips_fetch() {
    local sb; sb="$(make_mirror_sandbox 1)"
    local stamp; stamp="$(_ffg_stamp "$sb")"
    touch "$stamp"
    local drv="$sb/drv_freq_fresh.sh"
    cat > "$drv" <<'EOF'
. "$SNIPPET"
echo "DONE"
EOF
    local out; out="$(run_mirror_driver bash "$sb" "$drv" on)"
    if echo "$out" | grep -q "DONE" \
        && [ ! -f "$sb/gtp.out" ] \
        && [ ! -f "$sb/merged.out" ] \
        && ! echo "$out" | grep -q "git fetch Claude session sync"; then
        pass "TC-FREQ1: fresh stamp → startup fetch AND ff-only merge both skipped"
    else
        fail "TC-FREQ1: fetch/merge ran despite a fresh stamp (gtp=$([ -f "$sb/gtp.out" ] && echo yes || echo no) merged=$([ -f "$sb/merged.out" ] && echo yes || echo no)). Output: $out"
    fi
    rm -rf "$sb"
}

# TC-FREQ2 — a stale stamp lets the fetch run and is refreshed by that run.
# Backdating uses the same GNU/BSD touch pair as tests/feature-sweep-plans.sh.
tc_freq_stale_stamp_runs_and_refreshes() {
    local sb; sb="$(make_mirror_sandbox 1)"
    local stamp; stamp="$(_ffg_stamp "$sb")"
    touch "$stamp"
    touch -d "2 hours ago" "$stamp" 2>/dev/null || touch -t 202401010000 "$stamp" 2>/dev/null || true
    local before; before="$(_ffg_mtime "$stamp")"
    local drv="$sb/drv_freq_stale.sh"
    cat > "$drv" <<'EOF'
. "$SNIPPET"
echo "DONE"
EOF
    local out; out="$(run_mirror_driver bash "$sb" "$drv" on)"
    local after; after="$(_ffg_mtime "$stamp")"
    if [ -f "$sb/gtp.out" ] && [ "${after:-0}" -gt "${before:-0}" ] 2>/dev/null; then
        pass "TC-FREQ2: stale stamp → fetch ran and the stamp mtime was refreshed"
    else
        fail "TC-FREQ2: gtp=$([ -f "$sb/gtp.out" ] && echo yes || echo no) mtime before=$before after=$after. Output: $out"
    fi
    rm -rf "$sb"
}

# TC-FREQ3 — no stamp at all (first shell after install) must not suppress the
# fetch: the guard has to fail open, not fail closed.
tc_freq_absent_stamp_runs() {
    local sb; sb="$(make_mirror_sandbox 1)"
    local stamp="$sb/home/.claude/projects/.git/agents-last-fetch"
    local drv="$sb/drv_freq_absent.sh"
    cat > "$drv" <<'EOF'
. "$SNIPPET"
echo "DONE"
EOF
    local out; out="$(run_mirror_driver bash "$sb" "$drv" on)"
    if [ -f "$sb/gtp.out" ] && [ -f "$stamp" ]; then
        pass "TC-FREQ3: absent stamp → fetch ran and the stamp was created"
    else
        fail "TC-FREQ3: gtp=$([ -f "$sb/gtp.out" ] && echo yes || echo no) stamp=$([ -f "$stamp" ] && echo yes || echo no). Output: $out"
    fi
    rm -rf "$sb"
}

# TC-FREQ6 — the stamp belongs to the fetch, not to shell startup: with
# SESSION_SYNC off the whole block is skipped, so the stamp must never be created
# or touched. A stamp written ahead of the gate would silently suppress the first
# fetch after the toggle is turned on.
tc_freq_no_stamp_when_session_sync_off() {
    local sb; sb="$(make_mirror_sandbox 1)"
    local stamp="$sb/home/.claude/projects/.git/agents-last-fetch"
    local drv="$sb/drv_freq_off.sh"
    cat > "$drv" <<'EOF'
. "$SNIPPET"
echo "DONE"
EOF
    local out; out="$(run_mirror_driver bash "$sb" "$drv" off)"
    if echo "$out" | grep -q "DONE" && [ ! -f "$stamp" ] && [ ! -f "$sb/gtp.out" ]; then
        pass "TC-FREQ6: SESSION_SYNC=off → no fetch and no stamp file created"
    else
        fail "TC-FREQ6: stamp=$([ -f "$stamp" ] && echo created || echo absent) gtp=$([ -f "$sb/gtp.out" ] && echo yes || echo no). Output: $out"
    fi
    rm -rf "$sb"
}

# TC-FREQ7 — the stamp is written for the ATTEMPT, not for the success. TC-FREQ2
# only proves refreshing after a fetch that exits 0, which a "touch on success"
# implementation satisfies too — and that implementation reproduces the literal
# #2160 symptom: a fetch that keeps failing is retried on every single shell
# startup. With fetch pinned to exit 1, the stamp must still be written and the
# very next startup must be suppressed by the same guard TC-FREQ1/TC-FREQ4 pin.
tc_freq_stamp_written_despite_fetch_failure() {
    local sb; sb="$(make_mirror_sandbox 1)"
    local stamp="$sb/home/.claude/projects/.git/agents-last-fetch"
    _ffg_break_fetch "$sb"
    local drv="$sb/drv_freq_fetchfail.sh"
    cat > "$drv" <<'EOF'
. "$SNIPPET"
echo "DONE"
EOF
    local out1; out1="$(run_mirror_driver bash "$sb" "$drv" on)"
    local ran1=0 stamped=0
    [ -f "$sb/gtp.out" ] && ran1=1
    [ -f "$stamp" ] && stamped=1
    rm -f "$sb/gtp.out"
    local out2; out2="$(run_mirror_driver bash "$sb" "$drv" on)"
    local ran2=0
    [ -f "$sb/gtp.out" ] && ran2=1
    if [ "$ran1" = "1" ] && [ "$stamped" = "1" ] && [ "$ran2" = "0" ]; then
        pass "TC-FREQ7: failing fetch still writes the stamp, and the next startup is suppressed"
    else
        fail "TC-FREQ7: ran1=$ran1 stamped=$stamped ran2=$ran2 (expected 1/1/0 — a stamp written only on fetch success makes every startup retry). Run1: $out1 Run2: $out2"
    fi
    rm -rf "$sb"
}

# TC-FREQ4 / TC-FREQ5 — the interval really is 1800s (30 min). TC-FREQ1 touches
# "now" and TC-FREQ2 backdates two hours, so any interval from a second to two
# hours satisfies both; only a boundary-straddling pair can tell 1800 from 600 or
# 3600. No override is passed — the default constant is what is under test.
# _ffg_boundary_case <label> <minutes> <expect-fetch 0|1> <why>
_ffg_boundary_case() {
    local label="$1" minutes="$2" expect="$3" why="$4"
    local sb; sb="$(make_mirror_sandbox 1)"
    local stamp; stamp="$(_ffg_stamp "$sb")"
    touch "$stamp"
    if ! _ffg_backdate_minutes "$stamp" "$minutes"; then
        echo "SKIP: $label — host cannot backdate by exact minutes"
        rm -rf "$sb"
        return
    fi
    local drv="$sb/drv_freq_boundary_$minutes.sh"
    cat > "$drv" <<'EOF'
. "$SNIPPET"
echo "DONE"
EOF
    local out; out="$(run_mirror_driver bash "$sb" "$drv" on)"
    local ran=0
    if [ -f "$sb/gtp.out" ]; then ran=1; fi
    if [ "$ran" = "$expect" ]; then
        pass "$label: stamp ${minutes}min old → fetch $([ "$expect" = "1" ] && echo runs || echo suppressed) ($why)"
    else
        fail "$label: stamp ${minutes}min old → fetch ran=$ran expected=$expect ($why — the 1800s interval is not what the code uses). Output: $out"
    fi
    rm -rf "$sb"
}

tc_freq_fresh_stamp_skips_fetch          # TC-FREQ1
tc_freq_stale_stamp_runs_and_refreshes   # TC-FREQ2
tc_freq_absent_stamp_runs                # TC-FREQ3
_ffg_boundary_case "TC-FREQ4" 20 0 "20min < 30min interval"   # inside the window
_ffg_boundary_case "TC-FREQ5" 40 1 "40min > 30min interval"   # past the window
tc_freq_no_stamp_when_session_sync_off   # TC-FREQ6
tc_freq_stamp_written_despite_fetch_failure  # TC-FREQ7
