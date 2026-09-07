# Tests: profile-snippet.sh
# Tags: installer, profile-snippet, ssh, scope:issue-specific
# Part of tests/fix-1225-profile-snippet-guards.sh — sourced by that dispatcher,
# not run alone; uses make_mirror_sandbox / run_mirror_driver. Issue #2160: the
# startup fetch must respect a configured core.sshCommand and fall back to
# 'ssh -o BatchMode=yes' only when git has none. The lookup is specified as
# `git -C "$_session_dir" config --get core.sshCommand`, so WHERE the value is
# read from is as much of the contract as WHETHER it is honoured: a CWD-scoped
# lookup silently reads the developer's current repo instead of the session one.

# _ssh_real_git — the real git binary, resolved before any sandbox shadows PATH.
_ssh_real_git() { command -v git 2>/dev/null; }

tc_ssh_fallback_when_core_unset() {
    # No core-sshcommand file under the session dir → the fake git exits 1 for
    # `config --get`, so the BatchMode fallback is the only possible outcome.
    local sb; sb="$(make_mirror_sandbox 1)"
    local drv="$sb/drv_ssh_unset.sh"
    cat > "$drv" <<'EOF'
. "$SNIPPET"
echo "DONE"
EOF
    local out; out="$(run_mirror_driver bash "$sb" "$drv" on)"
    local got; got="$(cat "$sb/sshcmd.out" 2>/dev/null || true)"
    if [ "$got" = "ssh -o BatchMode=yes" ]; then
        pass "TC-SSH1: core.sshCommand unset → GIT_SSH_COMMAND fallback applied"
    else
        fail "TC-SSH1: expected the BatchMode fallback, got '$got'. Output: $out"
    fi
    rm -rf "$sb"
}

# TC-SSH2 — classifier counterpart of TC-SSH1: with core.sshCommand configured,
# GIT_SSH_COMMAND must be absent rather than exported empty (an empty value
# breaks git's ssh launch).
tc_ssh_respects_core_sshcommand() {
    local sb; sb="$(make_mirror_sandbox 1)"
    printf '/custom/ssh -F foo\n' > "$sb/home/.claude/projects/core-sshcommand"
    local drv="$sb/drv_ssh_set.sh"
    cat > "$drv" <<'EOF'
. "$SNIPPET"
echo "DONE"
EOF
    local out; out="$(run_mirror_driver bash "$sb" "$drv" on)"
    local got; got="$(cat "$sb/sshcmd.out" 2>/dev/null || true)"
    if [ "$got" = "UNSET" ]; then
        pass "TC-SSH2: core.sshCommand set → GIT_SSH_COMMAND left unset"
    else
        fail "TC-SSH2: GIT_SSH_COMMAND should stay unset, got '$got'. Output: $out"
    fi
    rm -rf "$sb"
}

# TC-SSH2b — the `-C "$_session_dir"` scope itself. The fake git resolves
# core.sshCommand from `<-C argument>/core-sshcommand`, so a snippet that drops
# `-C` reads the caller's CWD instead. Recording the argument turns "the value
# was honoured" into "the value was read from the session repo".
tc_ssh_config_lookup_is_repo_scoped() {
    local sb; sb="$(make_mirror_sandbox 1)"
    printf '/custom/ssh -F foo\n' > "$sb/home/.claude/projects/core-sshcommand"
    local drv="$sb/drv_ssh_scope.sh"
    cat > "$drv" <<'EOF'
. "$SNIPPET"
echo "DONE"
EOF
    local out; out="$(run_mirror_driver bash "$sb" "$drv" on)"
    local seen; seen="$(cat "$sb/dashc-config.out" 2>/dev/null || true)"
    if [ "$seen" = "$sb/home/.claude/projects" ]; then
        pass "TC-SSH2b: the config lookup is scoped with -C \$_session_dir"
    else
        fail "TC-SSH2b: git was invoked with -C '$seen' (expected '$sb/home/.claude/projects') — the core.sshCommand lookup is not session-repo-scoped. Output: $out"
    fi
    rm -rf "$sb"
}

# --- Real-git repository fixtures (TC-SSH3 / TC-SSH4) ------------------------
# The fake git's own -C handling is test code, so TC-SSH2b can only prove the
# snippet passes -C, not that real git's repo scoping is what the snippet relies
# on. These two cases hand `config` to the REAL git binary against real `git
# init` repositories and put a DIFFERENT core.sshCommand in the process CWD's
# repo — the value a CWD-scoped lookup would find. fetch/merge stay faked, so
# nothing touches a network.

# _ssh_realgit_sandbox <session-value|-> <cwd-value|-> — echoes a sandbox whose
# git stub delegates `config` to real git; seeds the session repo and a separate
# CWD repo, each with its own core.sshCommand (`-` = leave unset).
_ssh_realgit_sandbox() {
    local session_val="$1" cwd_val="$2" rg
    rg="$(_ssh_real_git)"
    [ -n "$rg" ] || { printf ''; return; }
    local sb; sb="$(make_mirror_sandbox 1)"
    local sess="$sb/home/.claude/projects"
    rm -rf "$sess/.git"
    "$rg" init -q "$sess" >/dev/null 2>&1 || { rm -rf "$sb"; printf ''; return; }
    "$rg" -C "$sess" config core.hooksPath /dev/null
    [ "$session_val" = "-" ] || "$rg" -C "$sess" config core.sshCommand "$session_val"
    mkdir -p "$sb/cwdrepo"
    "$rg" init -q "$sb/cwdrepo" >/dev/null 2>&1 || { rm -rf "$sb"; printf ''; return; }
    "$rg" -C "$sb/cwdrepo" config core.hooksPath /dev/null
    [ "$cwd_val" = "-" ] || "$rg" -C "$sb/cwdrepo" config core.sshCommand "$cwd_val"

    cat > "$sb/bin/git" <<EOF
#!/bin/bash
# fake git with real \`config\` delegation (TC-SSH3/TC-SSH4)
repo=""; prev=""; cmd=""
for a in "\$@"; do
    if [ "\$prev" = "-C" ]; then repo="\$a"; fi
    case "\$a" in
        fetch|merge|config) if [ -z "\$cmd" ]; then cmd="\$a"; fi ;;
    esac
    prev="\$a"
done
if [ -n "\$cmd" ]; then printf '%s' "\$repo" > "$sb/dashc-\$cmd.out"; fi
case "\$cmd" in
    fetch)
        printf '%s' "\${GIT_TERMINAL_PROMPT-UNSET}" > "$sb/gtp.out"
        printf '%s' "\${GIT_SSH_COMMAND-UNSET}" > "$sb/sshcmd.out"
        exit 0
        ;;
    merge) printf 'merged' > "$sb/merged.out"; exit 0 ;;
    config) exec "$rg" "\$@" ;;
    *) exit 0 ;;
esac
EOF
    chmod +x "$sb/bin/git"
    printf '%s' "$sb"
}

# _ssh_run_in_cwdrepo <sandbox> <driver> [ambient GIT_SSH_COMMAND] — like
# run_mirror_driver, but the child runs INSIDE $sb/cwdrepo so a CWD-scoped
# config lookup has a repository to find, and an ambient GIT_SSH_COMMAND can be
# handed through instead of stripped.
_ssh_run_in_cwdrepo() {
    local sb="$1" drv="$2" ambient="${3-}"
    (
        cd "$sb/cwdrepo" || exit 1
        if [ -n "$ambient" ]; then
            env -u CLAUDECODE -u GIT_TERMINAL_PROMPT \
                GIT_SSH_COMMAND="$ambient" SESSION_SYNC=on HOME="$sb/home" \
                PATH="$sb/bin:$PATH" SNIPPET="$sb/agents/profile-snippet.sh" \
                bash "$RUN_TIMEOUT" 30 bash "$drv" 2>&1
        else
            env -u CLAUDECODE -u GIT_SSH_COMMAND -u GIT_TERMINAL_PROMPT \
                SESSION_SYNC=on HOME="$sb/home" \
                PATH="$sb/bin:$PATH" SNIPPET="$sb/agents/profile-snippet.sh" \
                bash "$RUN_TIMEOUT" 30 bash "$drv" 2>&1
        fi
    )
}

_ssh_write_driver() {
    cat > "$1" <<'EOF'
. "$SNIPPET"
echo "DONE"
EOF
}

# TC-SSH3 — real git, value only in the SESSION repo. A CWD-scoped lookup finds
# nothing there and applies the fallback; the specified -C lookup finds it and
# leaves GIT_SSH_COMMAND alone.
tc_ssh_realgit_session_scope_wins() {
    local sb; sb="$(_ssh_realgit_sandbox '/session/ssh -F sess' '-')"
    if [ -z "$sb" ]; then
        echo "SKIP: TC-SSH3 — real git unavailable for the repo-scoped fixture"
        return
    fi
    local drv="$sb/drv_ssh_real_sess.sh"; _ssh_write_driver "$drv"
    local out; out="$(_ssh_run_in_cwdrepo "$sb" "$drv")"
    local got; got="$(cat "$sb/sshcmd.out" 2>/dev/null || true)"
    if [ "$got" = "UNSET" ]; then
        pass "TC-SSH3: real git — core.sshCommand in the session repo is found via -C (no fallback)"
    else
        fail "TC-SSH3: expected UNSET (session repo configures core.sshCommand), got '$got' — the lookup is not reading the session repository. Output: $out"
    fi
    rm -rf "$sb"
}

# TC-SSH4 — the mirror image: the value lives ONLY in the process CWD's repo.
# The specified lookup must not see it, so the BatchMode fallback still applies.
# TC-SSH3 alone would stay green against a CWD-scoped lookup whenever both repos
# happen to carry a value; this case is what separates the two scopes.
tc_ssh_realgit_cwd_scope_ignored() {
    local sb; sb="$(_ssh_realgit_sandbox '-' '/cwd/ssh -F cwd')"
    if [ -z "$sb" ]; then
        echo "SKIP: TC-SSH4 — real git unavailable for the repo-scoped fixture"
        return
    fi
    local drv="$sb/drv_ssh_real_cwd.sh"; _ssh_write_driver "$drv"
    local out; out="$(_ssh_run_in_cwdrepo "$sb" "$drv")"
    local got; got="$(cat "$sb/sshcmd.out" 2>/dev/null || true)"
    if [ "$got" = "ssh -o BatchMode=yes" ]; then
        pass "TC-SSH4: real git — a core.sshCommand in the CWD repo is ignored, fallback applied"
    else
        fail "TC-SSH4: expected the BatchMode fallback (only the CWD repo configures core.sshCommand), got '$got' — the lookup is CWD-scoped. Output: $out"
    fi
    rm -rf "$sb"
}

# TC-SSH5 / TC-SSH6 — every other runner strips an ambient GIT_SSH_COMMAND, so
# nothing yet says what happens on a machine that exports one. Git's own
# precedence puts the environment variable above core.sshCommand: with the
# config present the snippet must not touch the variable (TC-SSH5, the operator
# keeps their own transport), and with it absent the fallback must still take
# effect for the fetch (TC-SSH6, no passphrase prompt at login).
tc_ssh_ambient_preserved_when_core_set() {
    local sb; sb="$(_ssh_realgit_sandbox '/session/ssh -F sess' '-')"
    if [ -z "$sb" ]; then
        echo "SKIP: TC-SSH5 — real git unavailable for the repo-scoped fixture"
        return
    fi
    local drv="$sb/drv_ssh_ambient_set.sh"; _ssh_write_driver "$drv"
    local out; out="$(_ssh_run_in_cwdrepo "$sb" "$drv" '/ambient/ssh -F amb')"
    local got; got="$(cat "$sb/sshcmd.out" 2>/dev/null || true)"
    if [ "$got" = "/ambient/ssh -F amb" ]; then
        pass "TC-SSH5: ambient GIT_SSH_COMMAND survives when core.sshCommand is configured"
    else
        fail "TC-SSH5: the fetch saw '$got' (expected the ambient '/ambient/ssh -F amb') — the snippet overwrote the operator's own transport. Output: $out"
    fi
    rm -rf "$sb"
}

tc_ssh_ambient_overridden_when_core_unset() {
    local sb; sb="$(_ssh_realgit_sandbox '-' '-')"
    if [ -z "$sb" ]; then
        echo "SKIP: TC-SSH6 — real git unavailable for the repo-scoped fixture"
        return
    fi
    local drv="$sb/drv_ssh_ambient_unset.sh"; _ssh_write_driver "$drv"
    local out; out="$(_ssh_run_in_cwdrepo "$sb" "$drv" '/ambient/ssh -F amb')"
    local got; got="$(cat "$sb/sshcmd.out" 2>/dev/null || true)"
    if [ "$got" = "ssh -o BatchMode=yes" ]; then
        pass "TC-SSH6: no core.sshCommand → the BatchMode fallback overrides an ambient GIT_SSH_COMMAND"
    else
        fail "TC-SSH6: the fetch saw '$got' (expected 'ssh -o BatchMode=yes') — an ambient value without BatchMode can hang the login shell on a passphrase prompt. Output: $out"
    fi
    rm -rf "$sb"
}

# TC-SSH7 — core.sshCommand present but EMPTY. Real git answers `config --get`
# with exit 0 and an empty line, so the two plausible implementations part here:
# `[ -z "$cfg" ]` treats empty as unset and applies the fallback, while
# `if git config --get core.sshCommand >/dev/null 2>&1` reads exit 0 as
# "configured", exports nothing, and a passphrase-protected key then hangs the
# login shell on a prompt — the exact hang this guard exists to prevent. Every
# other case is satisfied by both, since none has an empty-but-present value.
tc_ssh_empty_core_sshcommand_is_unset() {
    local sb; sb="$(_ssh_realgit_sandbox '' '-')"
    if [ -z "$sb" ]; then
        echo "SKIP: TC-SSH7 — real git unavailable for the repo-scoped fixture"
        return
    fi
    local drv="$sb/drv_ssh_empty.sh"; _ssh_write_driver "$drv"
    local out; out="$(_ssh_run_in_cwdrepo "$sb" "$drv")"
    local got; got="$(cat "$sb/sshcmd.out" 2>/dev/null || true)"
    if [ "$got" = "ssh -o BatchMode=yes" ]; then
        pass "TC-SSH7: core.sshCommand set to the empty string behaves as unset (BatchMode fallback applied)"
    else
        fail "TC-SSH7: the fetch saw '$got' (expected 'ssh -o BatchMode=yes') — an empty core.sshCommand is being treated as configured, so no BatchMode guard reaches git and a passphrase prompt can hang the login shell. Output: $out"
    fi
    rm -rf "$sb"
}

tc_ssh_fallback_when_core_unset       # TC-SSH1
tc_ssh_respects_core_sshcommand       # TC-SSH2
tc_ssh_config_lookup_is_repo_scoped   # TC-SSH2b
tc_ssh_realgit_session_scope_wins     # TC-SSH3
tc_ssh_realgit_cwd_scope_ignored      # TC-SSH4
tc_ssh_ambient_preserved_when_core_set     # TC-SSH5
tc_ssh_ambient_overridden_when_core_unset  # TC-SSH6
tc_ssh_empty_core_sshcommand_is_unset      # TC-SSH7
