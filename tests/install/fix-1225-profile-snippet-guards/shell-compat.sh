# Tests: profile-snippet.sh
# Tags: installer, profile-snippet, bash-compat, job-control, scope:issue-specific
# Part of tests/fix-1225-profile-snippet-guards.sh — sourced by that dispatcher,
# not run alone; uses its make_sandbox / run_driver helpers and HAVE_ZSH.

# TC8 — bash-compat: the helper's leading `setopt LOCAL_OPTIONS NO_MONITOR` is
# zsh-only, so under bash it must stay behind the ZSH_VERSION guard.
tc_no_setopt_in_bash() {
    local sb; sb="$(make_sandbox 1)"
    local drv="$sb/drv_setopt.sh"
    cat > "$drv" <<'EOF'
. "$SNIPPET"
echo "DONE"
EOF
    local out; out="$(run_driver bash "$sb" "$drv" on)"
    if echo "$out" | grep -q "DONE" && ! echo "$out" | grep -qi "setopt"; then
        pass "bash-compat: no setopt error when sourcing in bash"
    else
        fail "bash-compat: setopt invoked under bash. Output: $out"
    fi
    rm -rf "$sb"
}

# TC9 — sourcing in zsh with a slow fake git must emit no "suspended" / "[N] +"
# job-control notification for the backgrounded fetch (needs NO_MONITOR).
tc_no_job_control_zsh() {
    if [ "$HAVE_ZSH" != "1" ]; then
        echo "SKIP: zsh not available — TC9 (no job control)"
        return
    fi
    local sb; sb="$(make_sandbox 1)"
    local drv="$sb/drv_jobctl.sh"
    cat > "$drv" <<'EOF'
. "$SNIPPET"
echo "DONE"
EOF
    # Absence of a message is only evidence when the run that should have
    # produced it actually happened: a driver that crashes, times out under
    # run-with-timeout, or never reaches the fetch prints no job-control line
    # either. Exit status + DONE + gtp.out (the fake git's per-run proof the
    # fetch was launched at all) are the three non-vacuity preconditions.
    local out rc
    out="$(run_driver zsh "$sb" "$drv" on)"
    rc=$?
    local reached=1
    [ "$rc" -eq 0 ] || reached=0
    echo "$out" | grep -q "DONE" || reached=0
    [ -f "$sb/gtp.out" ] || reached=0
    if [ "$reached" != "1" ]; then
        fail "zsh job control: the case never reached the backgrounded fetch, so 'no suspend output' proves nothing (exit=$rc done=$(echo "$out" | grep -qc DONE) fetched=$([ -f "$sb/gtp.out" ] && echo yes || echo no)). Output: $out"
    elif echo "$out" | grep -Eq "suspended|\[[0-9]+\][[:space:]]*\+"; then
        fail "zsh job control: background suspend output present. Output: $out"
    else
        pass "zsh: no job-control suspend output from backgrounded fetch (exit 0, DONE, fetch launched)"
    fi
    rm -rf "$sb"
}

tc_no_setopt_in_bash               # TC8
tc_no_job_control_zsh              # TC9 (self-skips if no zsh)
