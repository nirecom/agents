# Tests: profile-snippet.sh
# Tags: installer, profile-snippet, set-e, session-sync, frequency-guard, scope:issue-specific
# Part of tests/fix-1225-profile-snippet-guards.sh — sourced by that dispatcher;
# uses make_mirror_sandbox / run_mirror_driver / _ffg_stamp / HAVE_ZSH.
# Every other case here sources with `set -e` INACTIVE; profile-snippet.sh's own
# `_ss_rc` comment is the SSOT for why that hides a killed login shell. The three
# #2160 commands that exit non-zero on the COMMON path are pinned below.

_sete_write_driver() {
    cat > "$1" <<'EOF'
set -eu
. "$SNIPPET"
echo "DONE"
EOF
}

# Surviving means exit 0 AND DONE reached: _sete_assert <label> <out> <rc> <why>
_sete_assert() {
    local label="$1" out="$2" rc="$3" why="$4"
    if [ "$rc" -eq 0 ] && echo "$out" | grep -q "DONE"; then
        pass "$label: shell survives sourcing under 'set -eu' ($why)"
    else
        fail "$label: exit=$rc done=$(echo "$out" | grep -c DONE) — sourcing aborted under 'set -eu'. $why must be guarded (|| true, an if, or a conditional) or it kills the login shell before the rest of the profile runs. Output: $out"
    fi
}

# TC-SETE1 — core.sshCommand unset and no stamp: the DEFAULT state of every
# machine right after install, and the state in which `git config --get` exits 1.
tc_sete_config_probe_unset() {
    local sb; sb="$(make_mirror_sandbox 1)"
    local drv="$sb/drv_sete_cfg.sh"; _sete_write_driver "$drv"
    local out rc
    out="$(run_mirror_driver bash "$sb" "$drv" on)"
    rc=$?
    _sete_assert "TC-SETE1" "$out" "$rc" "the 'git config --get core.sshCommand' probe exiting 1 on an unset key"
    rm -rf "$sb"
}

# TC-SETE2 — a stamp older than the window, so `[ elapsed -lt 1800 ]` evaluates
# FALSE. TC-SETE1's sandbox has no stamp and never reaches that comparison.
tc_sete_interval_test_false() {
    local shell="$1" label="$2"
    local sb; sb="$(make_mirror_sandbox 1)"
    local stamp; stamp="$(_ffg_stamp "$sb")"
    touch "$stamp"
    touch -d "2 hours ago" "$stamp" 2>/dev/null || touch -t 202401010000 "$stamp" 2>/dev/null || true
    local drv="$sb/drv_sete_interval.sh"; _sete_write_driver "$drv"
    local out rc
    out="$(run_mirror_driver "$shell" "$sb" "$drv" on)"
    rc=$?
    _sete_assert "$label" "$out" "$rc" "the interval test '[ \$elapsed -lt 1800 ]' evaluating false on an elapsed window"
    rm -rf "$sb"
}

# TC-SETE3 — TC-FREQ12's failure injection re-run under `set -eu`: TC-FREQ12's
# driver has no `set -e`, so it cannot prove a failing `touch` spares the shell.
tc_sete_touch_failure() {
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
    local drv="$sb/drv_sete_touch.sh"; _sete_write_driver "$drv"
    local out rc
    out="$(run_mirror_driver bash "$sb" "$drv" on)"
    rc=$?
    _sete_assert "TC-SETE3" "$out" "$rc" "'touch \$stamp' exiting 1 on an unwritable stamp"
    rm -rf "$sb"
}

tc_sete_config_probe_unset                     # TC-SETE1
tc_sete_interval_test_false bash "TC-SETE2"    # TC-SETE2
tc_sete_touch_failure                          # TC-SETE3
# zsh's ERR_EXIT differs from bash's inside function bodies and && chains, so one
# configuration is re-run there rather than trusting bash to speak for both.
if [ "$HAVE_ZSH" = "1" ]; then
    tc_sete_interval_test_false zsh "TC-SETE4"
else
    echo "SKIP: zsh not available — TC-SETE4 (set -eu under zsh)"
fi
