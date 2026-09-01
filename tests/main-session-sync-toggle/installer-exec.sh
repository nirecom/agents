# Tests: install.sh, install.ps1, install/linux/session-sync-init.sh, install/win/session-sync-init.ps1, bin/get-config-var, bin/get-config-var.ps1
# Tags: install, installer, session-sync, toggle, pwsh-required, scope:common
# Part of tests/main-session-sync-toggle.sh — sourced by that dispatcher; uses its AGENTS_DIR / TMPDIR_BASE / RUN_TIMEOUT / pass / fail.
# Why over the static T17-T19 greps: a correct gate, an inverted gate, a bare
# mention and an unconditional call all share one source signature, so each
# installer is *run* in an all-stub sandbox with the session-sync init stub as
# the observable — the same matrix for both installers (CPR-ORTH).
# TL3 gap: no clean-machine install, no real .env, and each installer refuses the
# other platform. Mitigation: bin/check-verification-gate.sh category: installer.

# _winpath <posix-path> — Windows form when cygpath is available, else unchanged.
_winpath() { cygpath -w "$1" 2>/dev/null || printf '%s' "$1"; }

# Every install/ step the two installers invoke, minus the session-sync init step
# (which is asserted separately) and codex (only reached with --develop/-Develop).
INSTALL_STEPS="dotfileslink claude-code vscode-settings global-gitignore gh jq codegraph"

# ---------------------------------------------------------------------------
# install.sh sandbox. install.sh runs under `set -euo pipefail`, shells out to
# sibling install/linux scripts, edits the shell rc file and probes nvm / npm /
# claude / uname, so everything with a real side effect is replaced:
# install/linux/*.sh -> recording stubs writing <sb>/calls/<name>; HOME ->
# <sb>/home; NVM_DIR -> <sb>/nvm with a no-op nvm.sh; uname / npm / claude ->
# PATH shims (uname must report Linux or install.sh aborts on Git Bash before
# the session-sync step); node stays real except in the no-node rows.
# $1: resolver disposition — "present" (default) or "removed" (get-config-var deleted).
# ---------------------------------------------------------------------------
make_install_sh_sandbox() {
    local resolver="${1:-present}"
    local sb
    sb="$(mktemp -d "$TMPDIR_BASE/inst-sh.XXXXXX")"
    mkdir -p "$sb/agents/install/linux" "$sb/agents/bin" "$sb/agents/hooks" \
             "$sb/bin" "$sb/nonode" "$sb/home" "$sb/calls" "$sb/nvm"

    cp "$AGENTS_DIR/install.sh" "$sb/agents/install.sh"
    cp "$AGENTS_DIR/profile-snippet.sh" "$sb/agents/profile-snippet.sh"
    cp -R "$AGENTS_DIR/hooks/lib" "$sb/agents/hooks/lib"
    if [ "$resolver" = "present" ]; then
        cp "$AGENTS_DIR/bin/get-config-var" "$sb/agents/bin/get-config-var"
        chmod +x "$sb/agents/bin/get-config-var"
    fi

    # Every step install.sh invokes needs a stub: it runs under `set -euo pipefail`,
    # so one unstubbed name aborts the whole run at exit 127.
    local s
    for s in dotfileslink claude-code codex session-sync-init vscode-settings \
             global-gitignore gh jq codegraph; do
        cat > "$sb/agents/install/linux/$s.sh" <<EOF
#!/bin/bash
printf 'was-called %s\n' "\$*" >> "$sb/calls/$s"
exit 0
EOF
        chmod +x "$sb/agents/install/linux/$s.sh"
    done

    printf '#!/bin/bash\necho "Linux"\n'     > "$sb/bin/uname"
    printf '#!/bin/bash\nexit 0\n'           > "$sb/bin/npm"
    printf '#!/bin/bash\nexit 0\n'           > "$sb/bin/claude"
    chmod +x "$sb/bin/uname" "$sb/bin/npm" "$sb/bin/claude"
    printf '# fake nvm for the installer sandbox\n:\n' > "$sb/nvm/nvm.sh"
    printf '#!/bin/bash\necho "node: simulated failure" >&2\nexit 127\n' > "$sb/nonode/node"
    chmod +x "$sb/nonode/node"

    printf '%s' "$sb"
}

# run_install_sh <sandbox> <SESSION_SYNC|UNSET> <with-node|no-node>
run_install_sh() {
    local sb="$1" ss="$2" node_mode="$3"
    local path="$sb/bin:$PATH"
    [ "$node_mode" = "no-node" ] && path="$sb/nonode:$sb/bin:$PATH"
    if [ "$ss" = "UNSET" ]; then
        env -u SESSION_SYNC HOME="$sb/home" SHELL=/bin/bash NVM_DIR="$sb/nvm" \
            AGENTS_CONFIG_DIR="$sb/agents" PATH="$path" \
            bash "$RUN_TIMEOUT" 120 bash "$sb/agents/install.sh" 2>&1
    else
        env SESSION_SYNC="$ss" HOME="$sb/home" SHELL=/bin/bash NVM_DIR="$sb/nvm" \
            AGENTS_CONFIG_DIR="$sb/agents" PATH="$path" \
            bash "$RUN_TIMEOUT" 120 bash "$sb/agents/install.sh" 2>&1
    fi
}

# tc_install_sh_gate <label> <SESSION_SYNC|UNSET> <with-node|no-node> <present|removed> <expect> <why>
tc_install_sh_gate() {
    local label="$1" ss="$2" node_mode="$3" resolver="$4" expect="$5" why="$6"
    local sb; sb="$(make_install_sh_sandbox "$resolver")"
    local out rc=0
    out="$(run_install_sh "$sb" "$ss" "$node_mode")" || rc=$?

    local ran=0
    [ -f "$sb/calls/session-sync-init" ] && ran=1
    if [ "$ran" = "$expect" ]; then
        pass "$label: install.sh session-sync init $([ "$expect" = "1" ] && echo runs || echo is skipped) ($why)"
    else
        fail "$label: install.sh session-sync init ran=$ran expected=$expect ($why). exit=$rc. Output tail: $(printf '%s' "$out" | tail -6 | tr '\n' ' ')"
    fi

    # Orthogonality: gating one step must not short-circuit the installer. Every
    # other step — including the profile-sourcing edit and the five steps that
    # come AFTER the session-sync block, codegraph last — must still have happened.
    local missing="" step
    for step in $INSTALL_STEPS; do
        [ -f "$sb/calls/$step" ] || missing="$missing $step"
    done
    grep -qF "BEGIN agents profile sourcing" "$sb/home/.bashrc" 2>/dev/null \
        || missing="$missing profile-sourcing"
    if [ -z "$missing" ] && [ "$rc" -eq 0 ]; then
        pass "$label: install.sh completes and its unrelated steps still run"
    else
        fail "$label: install.sh short-circuited — exit=$rc missing:${missing:- none}. Output tail: $(printf '%s' "$out" | tail -6 | tr '\n' ' ')"
    fi
    rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# install.ps1 sandbox — same shape, Windows members of the class.
#
# install.ps1 writes to $PROFILE, so the driver overrides that variable before
# dot-invoking the installer; PowerShell child scopes read it from the caller.
# ---------------------------------------------------------------------------
make_install_ps1_sandbox() {
    local resolver="${1:-present}"
    local sb
    sb="$(mktemp -d "$TMPDIR_BASE/inst-ps.XXXXXX")"
    mkdir -p "$sb/agents/install/win" "$sb/agents/bin" "$sb/agents/hooks" \
             "$sb/winbin" "$sb/nonode" "$sb/calls" "$sb/profile"

    cp "$AGENTS_DIR/install.ps1" "$sb/agents/install.ps1"
    cp "$AGENTS_DIR/profile-snippet.ps1" "$sb/agents/profile-snippet.ps1"
    cp -R "$AGENTS_DIR/hooks/lib" "$sb/agents/hooks/lib"
    if [ "$resolver" = "present" ]; then
        cp "$AGENTS_DIR/bin/get-config-var.ps1" "$sb/agents/bin/get-config-var.ps1"
        cp "$AGENTS_DIR/bin/get-config-var" "$sb/agents/bin/get-config-var"
        chmod +x "$sb/agents/bin/get-config-var"
    fi

    local calls_win; calls_win="$(_winpath "$sb/calls")"
    # Same step list as the Linux sandbox (CPR-ORTH): install.ps1 invokes the
    # same nine steps, so an unstubbed name short-circuits it the same way.
    local s
    for s in dotfileslink claude-code codex session-sync-init vscode-settings \
             global-gitignore gh jq codegraph; do
        printf 'Add-Content -Path "%s\\%s" -Value ("was-called " + ($args -join " "))\n' \
            "$calls_win" "$s" > "$sb/agents/install/win/$s.ps1"
    done

    printf '@echo off\r\nexit /b 0\r\n' > "$sb/winbin/fnm.cmd"
    printf '@echo off\r\nexit /b 0\r\n' > "$sb/winbin/claude.cmd"
    printf '@echo off\r\necho node: simulated failure 1>&2\r\nexit /b 127\r\n' > "$sb/nonode/node.cmd"

    printf '$ErrorActionPreference = "Continue"\n$PROFILE = "%s\\Microsoft.PowerShell_profile.ps1"\n& "%s\\install.ps1"\n' \
        "$(_winpath "$sb/profile")" "$(_winpath "$sb/agents")" > "$sb/driver.ps1"

    printf '%s' "$sb"
}

# run_install_ps1 <sandbox> <SESSION_SYNC|UNSET> <with-node|no-node>
run_install_ps1() {
    local sb="$1" ss="$2" node_mode="$3"
    local path="$sb/winbin:$PATH"
    [ "$node_mode" = "no-node" ] && path="$sb/nonode:$sb/winbin:$PATH"
    local drv; drv="$(_winpath "$sb/driver.ps1")"
    local cfg; cfg="$(_winpath "$sb/agents")"
    if [ "$ss" = "UNSET" ]; then
        env -u SESSION_SYNC AGENTS_CONFIG_DIR="$cfg" PATH="$path" \
            bash "$RUN_TIMEOUT" 180 pwsh -NoProfile -NonInteractive -File "$drv" 2>&1
    else
        env SESSION_SYNC="$ss" AGENTS_CONFIG_DIR="$cfg" PATH="$path" \
            bash "$RUN_TIMEOUT" 180 pwsh -NoProfile -NonInteractive -File "$drv" 2>&1
    fi
}

# tc_install_ps1_gate <label> <SESSION_SYNC|UNSET> <with-node|no-node> <present|removed> <expect> <why>
tc_install_ps1_gate() {
    local label="$1" ss="$2" node_mode="$3" resolver="$4" expect="$5" why="$6"
    local sb; sb="$(make_install_ps1_sandbox "$resolver")"
    local out rc=0
    out="$(run_install_ps1 "$sb" "$ss" "$node_mode")" || rc=$?

    local ran=0
    [ -f "$sb/calls/session-sync-init" ] && ran=1
    if [ "$ran" = "$expect" ]; then
        pass "$label: install.ps1 session-sync init $([ "$expect" = "1" ] && echo runs || echo is skipped) ($why)"
    else
        fail "$label: install.ps1 session-sync init ran=$ran expected=$expect ($why). exit=$rc. Output tail: $(printf '%s' "$out" | tail -6 | tr '\n' ' ')"
    fi

    local missing="" step
    for step in $INSTALL_STEPS; do
        [ -f "$sb/calls/$step" ] || missing="$missing $step"
    done
    grep -qF "BEGIN agents profile sourcing" \
        "$sb/profile/Microsoft.PowerShell_profile.ps1" 2>/dev/null \
        || missing="$missing profile-sourcing"
    if [ -z "$missing" ] && [ "$rc" -eq 0 ]; then
        pass "$label: install.ps1 completes and its unrelated steps still run"
    else
        fail "$label: install.ps1 short-circuited — exit=$rc missing:${missing:- none}. Output tail: $(printf '%s' "$out" | tail -6 | tr '\n' ' ')"
    fi
    rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# The matrix. Columns: label | SESSION_SYNC | node | resolver | expect-init | why
# expect-init: 1 = the session-sync init step must run, 0 = it must be skipped.
# Every row is 1: the init step is unconditional bootstrap — it must run whatever
# SESSION_SYNC says, with or without node or the resolver, because the manual
# sync subcommands need the repo/remote/attributes set up on any machine first.
# The matrix still walks the full environment-permutation space (missing node,
# missing resolver, invalid value, unset) to prove that unconditional call is
# robust to those conditions rather than to prove a gate.
# ---------------------------------------------------------------------------
INSTALLER_MATRIX=$(cat <<'TABLE'
on-explicit       | on    | with-node | present | 1 | explicit on
on-case-variant   | ON    | with-node | present | 1 | value match is case-insensitive
off-explicit      | off   | with-node | present | 1 | manual sync needs the repo bootstrapped even with the automatic toggle off
unset-default     | UNSET | with-node | present | 1 | unset — bootstrap runs before any toggle value is even considered
invalid-value     | maybe | with-node | present | 1 | unrecognized value — bootstrap does not depend on the toggle being readable
resolver-no-node  | on    | no-node   | present | 1 | node absent — bootstrap does not depend on the resolver running at all
resolver-absent   | on    | with-node | removed | 1 | resolver script missing — bootstrap does not depend on the resolver existing
TABLE
)

echo ""
echo "--- installer gate: install.sh executed in a stubbed sandbox ---"
while IFS='|' read -r m_label m_ss m_node m_res m_expect m_why; do
    m_label="${m_label//[[:space:]]/}"
    case "$m_label" in ''|'#'*) continue ;; esac
    m_ss="${m_ss//[[:space:]]/}"
    m_node="${m_node//[[:space:]]/}"
    m_res="${m_res//[[:space:]]/}"
    m_expect="${m_expect//[[:space:]]/}"
    m_why="$(printf '%s' "$m_why" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    tc_install_sh_gate "T20/$m_label" "$m_ss" "$m_node" "$m_res" "$m_expect" "$m_why"
done <<TABLE
$INSTALLER_MATRIX
TABLE

echo ""
echo "--- installer gate: install.ps1 executed in a stubbed sandbox ---"
# install.ps1 exits immediately when $IsWindows is false, so the pwsh half of the
# class is only decidable on Windows. Announce the skip rather than pass silently.
_ps1_runnable=1
command -v pwsh >/dev/null 2>&1 || _ps1_runnable=0
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) ;; *) _ps1_runnable=0 ;; esac
if [ "$_ps1_runnable" = "1" ]; then
    while IFS='|' read -r m_label m_ss m_node m_res m_expect m_why; do
        m_label="${m_label//[[:space:]]/}"
        case "$m_label" in ''|'#'*) continue ;; esac
        m_ss="${m_ss//[[:space:]]/}"
        m_node="${m_node//[[:space:]]/}"
        m_res="${m_res//[[:space:]]/}"
        m_expect="${m_expect//[[:space:]]/}"
        m_why="$(printf '%s' "$m_why" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        tc_install_ps1_gate "T21/$m_label" "$m_ss" "$m_node" "$m_res" "$m_expect" "$m_why"
    done <<TABLE
$INSTALLER_MATRIX
TABLE
else
    echo "SKIP: install.ps1 execution matrix — needs pwsh on a Windows host"
fi
