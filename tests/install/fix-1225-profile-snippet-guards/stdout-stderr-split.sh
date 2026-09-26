# Tests: profile-snippet.sh, bin/lib/session-sync-markers.sh
# Tags: installer, profile-snippet, stdout-stderr, session-sync, scope:issue-specific
# Part of tests/fix-1225-profile-snippet-guards.sh — sourced by that dispatcher,
# not run alone; uses its make_mirror_sandbox helper. Issue #2160: every startup
# progress line must land on stderr, because Claude Code captures a login shell's
# stdout into the shell snapshot and any stray line there corrupts its PATH.
_SSS_REPAIR_MARKER='Repairing agents symlink(s)...'
_SSS_FETCH_MARKER='git fetch Claude session sync ...'
_SSS_LINK_STUB_LINE='Symlinks created in ~/.claude/'

# run_mirror_driver_split — run_mirror_driver with stdout and stderr captured to
# separate files instead of merged, so the stream each line lands on is testable.
# CLAUDECODE defaults to DROPPED from the child env: the suite itself runs inside
# Claude Code (CLAUDECODE=1) with stdout redirected to a file, which is exactly
# the snippet's own "skip the session-sync block" condition — inheriting it would
# silently vacate every fetch-path assertion. TC-SPLIT4 passes `cc-set` to opt
# back INTO that state deliberately, so the condition is covered on purpose
# rather than by accident. GIT_SSH_COMMAND/GIT_TERMINAL_PROMPT are always dropped.
# Args: <shell> <sandbox> <driver> [SESSION_SYNC|UNSET] [with-node|no-node] [cc-unset|cc-set]
run_mirror_driver_split() {
    local shell="$1" sb="$2" driver="$3" ss="${4:-UNSET}" node_mode="${5:-with-node}" cc_mode="${6:-cc-unset}"
    local path_val="$sb/bin:$PATH"
    [ "$node_mode" = "no-node" ] && path_val="$sb/nonode:$sb/bin:$PATH"
    # `env` stops parsing options at the first NAME=VALUE, so every -u must be
    # collected ahead of every assignment.
    local -a unsets=(-u GIT_SSH_COMMAND -u GIT_TERMINAL_PROMPT)
    local -a assigns=()
    if [ "$ss" = "UNSET" ]; then unsets+=(-u SESSION_SYNC); else assigns+=("SESSION_SYNC=$ss"); fi
    if [ "$cc_mode" = "cc-set" ]; then assigns+=("CLAUDECODE=1"); else unsets+=(-u CLAUDECODE); fi
    env "${unsets[@]}" ${assigns[@]+"${assigns[@]}"} \
        HOME="$sb/home" PATH="$path_val" \
        SNIPPET="$sb/agents/profile-snippet.sh" \
        bash "$RUN_TIMEOUT" 30 "$shell" "$driver" >"$sb/stdout.out" 2>"$sb/stderr.out"
}

# _sss_run <sandbox> — fires both the symlink-repair path and the fetch path in
# one source, then leaves stdout.out / stderr.out behind for the caller.
_sss_run() {
    local sb="$1"
    rm -f "$sb/real_CLAUDE.md"
    local drv="$sb/drv_split.sh"
    cat > "$drv" <<'EOF'
. "$SNIPPET"
echo "DONE"
EOF
    run_mirror_driver_split bash "$sb" "$drv" on
}

# _sss_assert <label> <sandbox> — stdout carries none of the three progress
# lines, stderr carries all three (proving redirection, not suppression), and —
# the assertion that actually protects the shell snapshot — stdout carries
# NOTHING beyond the driver's own DONE line. Naming the three known lines only
# would stay green against a fourth stray echo added later; the snapshot is
# corrupted by any stdout line, known or not, so the allowlist is the contract.
_sss_assert() {
    local label="$1" sb="$2" m
    local out_clean=1 err_complete=1 out_exact=1
    for m in "$_SSS_REPAIR_MARKER" "$_SSS_FETCH_MARKER" "$_SSS_LINK_STUB_LINE"; do
        grep -qF "$m" "$sb/stdout.out" 2>/dev/null && out_clean=0
        grep -qF "$m" "$sb/stderr.out" 2>/dev/null || err_complete=0
    done
    local stdout_body; stdout_body="$(cat "$sb/stdout.out" 2>/dev/null)"
    [ "$stdout_body" = "DONE" ] || out_exact=0
    if [ "$out_clean" = "1" ] && [ "$err_complete" = "1" ] && [ "$out_exact" = "1" ]; then
        pass "$label: stdout is the driver's DONE line alone; all three progress lines on stderr"
    else
        fail "$label: out_clean=$out_clean err_complete=$err_complete out_exact=$out_exact (stdout must be exactly 'DONE'). stdout=[$stdout_body] stderr=[$(cat "$sb/stderr.out" 2>/dev/null)]"
    fi
}

# TC-SPLIT1 — the shipped shape: bin/lib/session-sync-markers.sh present, so the
# markers come from the SSOT lib.
tc_split_markers_on_stderr_only() {
    local sb; sb="$(make_mirror_sandbox 1)"
    _sss_run "$sb"
    _sss_assert "TC-SPLIT1" "$sb"
    rm -rf "$sb"
}

# TC-SPLIT1b — mutation probe. TC-SPLIT1 (lib present) and TC-SPLIT2 (lib absent)
# are indistinguishable at runtime: the inline fallback silently covers a `source`
# line that points at the wrong path, or that never runs at all. Replacing the
# mirror's lib with one whose marker values carry a unique suffix breaks that tie
# — the suffix can only reach stderr through this specific file being sourced.
_SSS_PROBE_SUFFIX='-probe-a7f3'
tc_split_lib_source_is_live() {
    local sb; sb="$(make_mirror_sandbox 1)"
    local lib="$sb/agents/bin/lib/session-sync-markers.sh"
    mkdir -p "$sb/agents/bin/lib"
    # Marker values keep the shipped prefix so this case stays readable next to
    # TC-SSOT; only the suffix distinguishes lib-sourced from fallback-assigned.
    printf "AGENTS_SESSION_SYNC_FETCH_MARKER='%s%s'\nAGENTS_SYMLINK_REPAIR_MARKER='%s%s'\n" \
        "$_SSS_FETCH_MARKER" "$_SSS_PROBE_SUFFIX" \
        "$_SSS_REPAIR_MARKER" "$_SSS_PROBE_SUFFIX" > "$lib"
    _sss_run "$sb"
    local err; err="$(cat "$sb/stderr.out" 2>/dev/null)"
    local fetch_live=0 repair_live=0
    printf '%s\n' "$err" | grep -qF "$_SSS_FETCH_MARKER$_SSS_PROBE_SUFFIX" && fetch_live=1
    printf '%s\n' "$err" | grep -qF "$_SSS_REPAIR_MARKER$_SSS_PROBE_SUFFIX" && repair_live=1
    if [ "$fetch_live" = "1" ] && [ "$repair_live" = "1" ]; then
        pass "TC-SPLIT1b: the sourced lib's own marker values reach stderr (source line is live, not shadowed by the fallback)"
    else
        fail "TC-SPLIT1b: fetch_live=$fetch_live repair_live=$repair_live — markers did not carry the probe suffix, so profile-snippet.sh is not reading bin/lib/session-sync-markers.sh. stderr=[$err]"
    fi
    rm -rf "$sb"
}

# TC-SPLIT2 — the lib is missing (damaged checkout), so profile-snippet.sh must
# take its inline fallback assignments. Runtime coverage for the branch that
# tc_marker_fallback_matches_lib only checks statically.
tc_split_fallback_branch_executes() {
    local sb; sb="$(make_mirror_sandbox 1)"
    rm -f "$sb/agents/bin/lib/session-sync-markers.sh"
    _sss_run "$sb"
    _sss_assert "TC-SPLIT2 (lib absent, inline fallback)" "$sb"
    rm -rf "$sb"
}

# TC-SPLIT3 — the snippet leaves no scratch variables behind. Mirrors TC7's
# static+runtime pair for the two marker variables and GIT_SSH_COMMAND: "absent
# after source" alone cannot tell "never assigned" from "assigned then cleaned",
# so the static half checks the trailing `unset` line names both markers.
# GIT_SSH_COMMAND has no static half — the design never exports it into the
# sourcing shell at all (it is a per-command prefix on the fetch subshell), so
# its runtime absence IS the whole contract. The child env drops all three, so
# a SET verdict can only have come from the snippet.
tc_split_no_variable_leak() {
    local sb; sb="$(make_mirror_sandbox 1)"
    rm -f "$sb/real_CLAUDE.md"
    local drv="$sb/drv_leak.sh"
    cat > "$drv" <<'EOF'
. "$SNIPPET"
printf 'FETCHVAR=%s\n' "${AGENTS_SESSION_SYNC_FETCH_MARKER+SET}"
printf 'REPAIRVAR=%s\n' "${AGENTS_SYMLINK_REPAIR_MARKER+SET}"
printf 'SSHVAR=%s\n' "${GIT_SSH_COMMAND+SET}"
EOF
    run_mirror_driver_split bash "$sb" "$drv" on
    local out; out="$(cat "$sb/stdout.out" 2>/dev/null)"
    local runtime_clean=1
    echo "$out" | grep -q 'FETCHVAR=SET' && runtime_clean=0
    echo "$out" | grep -q 'REPAIRVAR=SET' && runtime_clean=0
    echo "$out" | grep -q 'SSHVAR=SET' && runtime_clean=0

    local static_ok=0
    if grep -Eq '^[[:space:]]*unset[[:space:]].*AGENTS_SESSION_SYNC_FETCH_MARKER' "$SNIPPET" \
        && grep -Eq '^[[:space:]]*unset[[:space:]].*AGENTS_SYMLINK_REPAIR_MARKER' "$SNIPPET"; then
        static_ok=1
    fi

    if [ "$runtime_clean" = "1" ] && [ "$static_ok" = "1" ]; then
        pass "TC-SPLIT3: marker vars and GIT_SSH_COMMAND unset after source (not merely empty)"
    else
        fail "TC-SPLIT3: variable leak (runtime_clean=$runtime_clean static_ok=$static_ok). stdout=[$out]"
    fi
    rm -rf "$sb"
}

# TC-SPLIT4 — the literal #2160 reproduction condition. Claude Code's own shell-
# snapshot capture sources this file with CLAUDECODE set AND stdout redirected
# into the snapshot file (non-TTY). That exact pair is the snippet's session-sync
# skip gate (profile-snippet.sh:48) — but the symlink-repair block above it sits
# OUTSIDE that gate and still runs, so the corrupting `echo` is reachable in
# precisely the state the issue reports. Every other case in this suite unsets
# CLAUDECODE to keep the fetch-path assertions non-vacuous, which left the state
# the bug actually occurs in untested.
tc_split_claudecode_snapshot_capture() {
    local sb; sb="$(make_mirror_sandbox 1)"
    rm -f "$sb/real_CLAUDE.md"
    local drv="$sb/drv_split_cc.sh"
    cat > "$drv" <<'EOF'
. "$SNIPPET"
echo "DONE"
EOF
    run_mirror_driver_split bash "$sb" "$drv" on with-node cc-set
    local stdout_body; stdout_body="$(cat "$sb/stdout.out" 2>/dev/null)"
    local err; err="$(cat "$sb/stderr.out" 2>/dev/null)"
    local out_exact=1 repair_on_err=1 gate_held=1
    [ "$stdout_body" = "DONE" ] || out_exact=0
    printf '%s\n' "$err" | grep -qF "$_SSS_REPAIR_MARKER" || repair_on_err=0
    printf '%s\n' "$err" | grep -qF "$_SSS_LINK_STUB_LINE" || repair_on_err=0
    # Naming the fetch marker's absence keeps the case honest about WHICH block
    # produced the stderr lines: under this gate the session-sync block is skipped
    # wholesale, so its marker must reach neither stream and no fetch may run.
    grep -qF "$_SSS_FETCH_MARKER" "$sb/stdout.out" 2>/dev/null && gate_held=0
    grep -qF "$_SSS_FETCH_MARKER" "$sb/stderr.out" 2>/dev/null && gate_held=0
    [ -f "$sb/gtp.out" ] && gate_held=0
    if [ "$out_exact" = "1" ] && [ "$repair_on_err" = "1" ] && [ "$gate_held" = "1" ]; then
        pass "TC-SPLIT4: CLAUDECODE set + non-TTY stdout (snapshot capture) — repair output on stderr, stdout is DONE alone, session-sync block skipped"
    else
        fail "TC-SPLIT4: out_exact=$out_exact repair_on_err=$repair_on_err gate_held=$gate_held — a stray stdout line here is the literal #2160 shell-snapshot corruption. stdout=[$stdout_body] stderr=[$err]"
    fi
    rm -rf "$sb"
}

# TC-SPLIT5 — steady state: symlinks healthy (repair block a no-op) and the fetch
# stamp fresh (frequency guard suppresses the fetch), i.e. the shape of nearly
# every real shell startup. TC-SPLIT1/2/4 all force something to happen, so none
# of them can catch an unconditional line printed on the do-nothing path.
# The "emits nothing at all" half is conditional: on hosts where `ln -s` degrades
# to a copy (git-bash without winsymlinks) the sandbox's four slots are regular
# files, so the repair block legitimately fires and stderr is legitimately
# non-empty. The stdout-purity half is host-independent and always asserted.
tc_split_steady_state_stdout_silent() {
    local sb; sb="$(make_mirror_sandbox 1)"
    local stamp; stamp="$(_ffg_stamp "$sb")"
    touch "$stamp"
    local links_ok=1 f
    for f in CLAUDE.md skills rules agents; do
        { [ -L "$sb/home/.claude/$f" ] && [ -e "$sb/home/.claude/$f" ]; } || links_ok=0
    done
    local drv="$sb/drv_split_steady.sh"
    cat > "$drv" <<'EOF'
. "$SNIPPET"
echo "DONE"
EOF
    run_mirror_driver_split bash "$sb" "$drv" on
    local stdout_body; stdout_body="$(cat "$sb/stdout.out" 2>/dev/null)"
    local err; err="$(cat "$sb/stderr.out" 2>/dev/null)"
    local out_exact=1 nothing_ran=1 m
    [ "$stdout_body" = "DONE" ] || out_exact=0
    if [ "$links_ok" = "1" ]; then
        for m in "$_SSS_REPAIR_MARKER" "$_SSS_FETCH_MARKER" "$_SSS_LINK_STUB_LINE"; do
            printf '%s\n' "$err" | grep -qF "$m" && nothing_ran=0
        done
    fi
    if [ "$out_exact" = "1" ] && [ "$nothing_ran" = "1" ]; then
        pass "TC-SPLIT5: steady state (fresh stamp, links_ok=$links_ok) — stdout is DONE alone"
    else
        fail "TC-SPLIT5: out_exact=$out_exact nothing_ran=$nothing_ran links_ok=$links_ok (a do-nothing startup must not print on stdout). stdout=[$stdout_body] stderr=[$err]"
    fi
    rm -rf "$sb"
}

# TC-SPLIT6 — branch-selection anchor for core.sshCommand CONFIGURED: the fetch
# must take the line-107 branch and honour the value by leaving GIT_SSH_COMMAND
# unset (TC-SSH2 pins the same behaviour from the ssh angle).
# It does NOT pin the fetch branch's stream contract: its probe
# `_ss_sshcmd="$(git config --get ...)"` is a command substitution, which
# captures that stdout by construction, so no mutation turns out_exact red for a
# stream reason. TC-SPLIT8 owns that claim via the leaky-fetch fixture below.
_SSS_CORE_SSHCOMMAND='/custom/ssh -F /dev/null'
tc_split_stdout_pure_with_core_sshcommand() {
    local sb; sb="$(make_mirror_sandbox 1)"
    printf '%s\n' "$_SSS_CORE_SSHCOMMAND" > "$sb/home/.claude/projects/core-sshcommand"
    _sss_run "$sb"
    local stdout_body; stdout_body="$(cat "$sb/stdout.out" 2>/dev/null)"
    local err; err="$(cat "$sb/stderr.out" 2>/dev/null)"
    local out_exact=1 branch_taken=1
    [ "$stdout_body" = "DONE" ] || out_exact=0
    # Non-vacuity: the config-reading branch must really have been reached, i.e.
    # the fetch ran and honoured the configured value by leaving GIT_SSH_COMMAND
    # unset. Without this a snippet that never calls `config` would pass too.
    [ -f "$sb/gtp.out" ] || branch_taken=0
    [ "$(cat "$sb/sshcmd.out" 2>/dev/null || true)" = "UNSET" ] || branch_taken=0
    if [ "$out_exact" = "1" ] && [ "$branch_taken" = "1" ]; then
        pass "TC-SPLIT6: core.sshCommand configured — the configured-value branch runs and stdout is still DONE alone"
    else
        fail "TC-SPLIT6: out_exact=$out_exact branch_taken=$branch_taken — the configured core.sshCommand branch must run (fetch attempted, GIT_SSH_COMMAND left unset). stdout=[$stdout_body] stderr=[$err]"
    fi
    rm -rf "$sb"
}

# --- Leaky-fetch fixture (TC-SPLIT7 / TC-SPLIT8) -----------------------------
# The shipped fake `git fetch` writes nothing to real stdout, so reverting
# either fetch branch's `>/dev/null 2>&1` back to `2>/dev/null` leaves every
# purity case green. This variant prints a real progress line on real stdout as
# its FIRST statement — the same deliberate noisiness make_sandbox gives `merge`
# — so the redirect on profile-snippet.sh:108 / :110 becomes observable.
_SSS_FETCH_LEAK_LINE='remote: Enumerating objects: 12, done.'
_sss_leaky_fetch_git() {
    local sb="$1"
    cat > "$sb/bin/git" <<EOF
#!/bin/bash
# fake git with a stdout-leaking fetch (TC-SPLIT7 / TC-SPLIT8)
cmd=""; repo="\$PWD"; prev=""
for a in "\$@"; do
    if [ "\$prev" = "-C" ]; then repo="\$a"; fi
    case "\$a" in
        fetch|merge|config) if [ -z "\$cmd" ]; then cmd="\$a"; fi ;;
    esac
    prev="\$a"
done
case "\$cmd" in
    fetch)
        printf '%s\n' '$_SSS_FETCH_LEAK_LINE'
        printf '%s' "\${GIT_TERMINAL_PROMPT-UNSET}" > "$sb/gtp.out"
        printf '%s' "\${GIT_SSH_COMMAND-UNSET}" > "$sb/sshcmd.out"
        exit 0
        ;;
    merge)
        printf 'merged' > "$sb/merged.out"
        printf 'Updating abc1234..def5678\nFast-forward\n'
        exit 0
        ;;
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

# _sss_leaky_case <label> <core.sshCommand value|-> <expected GIT_SSH_COMMAND> <why>
# One body for the two symmetric fetch branches: seed (or omit) core.sshCommand,
# run the leaky fetch, and require stdout to be the driver's DONE line alone.
# expected_sshcmd is the non-vacuity half — it names WHICH branch ran, so a case
# cannot go green because the other branch happened to be taken.
_sss_leaky_case() {
    local label="$1" core_val="$2" expected_sshcmd="$3" why="$4"
    local sb; sb="$(make_mirror_sandbox 1)"
    _sss_leaky_fetch_git "$sb"
    [ "$core_val" = "-" ] || printf '%s\n' "$core_val" > "$sb/home/.claude/projects/core-sshcommand"
    _sss_run "$sb"
    local stdout_body; stdout_body="$(cat "$sb/stdout.out" 2>/dev/null)"
    local err; err="$(cat "$sb/stderr.out" 2>/dev/null)"
    local got; got="$(cat "$sb/sshcmd.out" 2>/dev/null || true)"
    local out_exact=1 branch_taken=1 leak_absent=1
    [ "$stdout_body" = "DONE" ] || out_exact=0
    [ -f "$sb/gtp.out" ] || branch_taken=0
    [ "$got" = "$expected_sshcmd" ] || branch_taken=0
    grep -qF "$_SSS_FETCH_LEAK_LINE" "$sb/stdout.out" 2>/dev/null && leak_absent=0
    if [ "$out_exact" = "1" ] && [ "$branch_taken" = "1" ] && [ "$leak_absent" = "1" ]; then
        pass "$label: $why — the fetch's own stdout is discarded; stdout is the driver's DONE line alone"
    else
        fail "$label: out_exact=$out_exact branch_taken=$branch_taken leak_absent=$leak_absent (GIT_SSH_COMMAND='$got', expected '$expected_sshcmd') — $why: a fetch redirect of 2>/dev/null alone lets git's stdout into the shell snapshot. stdout=[$stdout_body] stderr=[$err]"
    fi
    rm -rf "$sb"
}

tc_split_markers_on_stderr_only     # TC-SPLIT1
tc_split_lib_source_is_live         # TC-SPLIT1b
tc_split_fallback_branch_executes   # TC-SPLIT2
tc_split_no_variable_leak           # TC-SPLIT3
tc_split_claudecode_snapshot_capture  # TC-SPLIT4
tc_split_steady_state_stdout_silent   # TC-SPLIT5
tc_split_stdout_pure_with_core_sshcommand  # TC-SPLIT6
# TC-SPLIT7 / TC-SPLIT8 — the two fetch branches are symmetric, so both carry the
# same stream contract; a fix applied to one only is what this pair catches.
_sss_leaky_case "TC-SPLIT7" "-" "ssh -o BatchMode=yes" \
    "core.sshCommand unset (profile-snippet.sh:110, BatchMode fallback branch)"
_sss_leaky_case "TC-SPLIT8" "$_SSS_CORE_SSHCOMMAND" "UNSET" \
    "core.sshCommand configured (profile-snippet.sh:108, configured-value branch)"
