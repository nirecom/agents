#!/bin/bash
# tests/fix-1225-profile-snippet-guards.sh
# Tests: profile-snippet.sh, bin/lib/session-sync-markers.sh
# Tags: installer, profile-snippet, idempotency, job-control, ssh, stdout-stderr, scope:issue-specific
#
# Issue #1225 guards (idempotency, _session_sync_fetch + NO_MONITOR,
# GIT_TERMINAL_PROMPT=0, unset -f cleanup) and issue #2160 (progress output moved
# to stderr, core.sshCommand-aware GIT_SSH_COMMAND, fetch frequency stamp guard).
# TL2 broad integration: sources the real profile-snippet.sh in real bash and real
# zsh with a stubbed HOME and a fake git on PATH.

set -u

# TL3 gap (what this test does NOT catch):
# - real SSH passphrase prompting on `git fetch` against a passphrase-protected key
# - real iTerm/interactive-shell job-control rendering of "[N] + suspended"
# - real network fetch/merge against the live session-sync remote
# - the snippet running from its real install location (gate cases source a copy)
# - the value actually shipped in the real .env (the mirror has none on purpose)
# - Claude Code's own shell-snapshot capture of a real login shell's stdout
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: installer

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SNIPPET="${AGENTS_DIR}/profile-snippet.sh"
MARKERS_LIB="${AGENTS_DIR}/bin/lib/session-sync-markers.sh"
RUN_TIMEOUT="${AGENTS_DIR}/bin/run-with-timeout.sh"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; }

HAVE_ZSH=0
command -v zsh >/dev/null 2>&1 && HAVE_ZSH=1

# --- Shared sandbox builder -------------------------------------------------
# Builds a temp HOME with valid symlinks (so the repair block is a no-op) and a
# fake git on PATH. Optionally seeds ~/.claude/projects/.git so the fetch block runs.
# Echoes the sandbox root dir. The fake-git GIT_TERMINAL_PROMPT capture file is at
# <sandbox>/gtp.out and the merge-marker file at <sandbox>/merged.out.
make_sandbox() {
    local with_git_repo="$1"   # 1 = seed .claude/projects/.git, 0 = no repo
    local sb
    sb="$(mktemp -d "${TMPDIR:-/tmp}/fix1225.XXXXXX")"

    mkdir -p "$sb/home/.claude"
    # Real targets for the four repair-checked slots, then valid symlinks.
    : > "$sb/real_CLAUDE.md"
    mkdir -p "$sb/real_skills" "$sb/real_rules" "$sb/real_agents"
    ln -s "$sb/real_CLAUDE.md" "$sb/home/.claude/CLAUDE.md"
    ln -s "$sb/real_skills"    "$sb/home/.claude/skills"
    ln -s "$sb/real_rules"     "$sb/home/.claude/rules"
    ln -s "$sb/real_agents"    "$sb/home/.claude/agents"

    if [ "$with_git_repo" = "1" ]; then
        mkdir -p "$sb/home/.claude/projects/.git"
    fi

    # Fake git: `fetch` records GIT_TERMINAL_PROMPT/GIT_SSH_COMMAND; `merge` drops a
    # marker AND prints "Updating ../Fast-forward" as real `merge --ff-only` does —
    # a silent fake would let an unredirected merge pass the TC-SPLIT purity cases;
    # `config --get core.sshCommand` answers from <-C argument>/core-sshcommand
    # (absent = unset, exit 1). `-C` is honoured as real git honours it (config from
    # the named repo, not the CWD) and each subcommand's -C argument is recorded to
    # <sandbox>/dashc-<cmd>.out, so TC-SSH2b reads the `config` probe's own scope
    # and cannot be satisfied by the `fetch` call's -C.
    mkdir -p "$sb/bin"
    cat > "$sb/bin/git" <<EOF
#!/bin/bash
# fake git for fix-1225 test
cmd=""; repo="\$PWD"; prev=""; seen_c=""
for a in "\$@"; do
    if [ "\$prev" = "-C" ]; then repo="\$a"; seen_c="\$a"; fi
    case "\$a" in
        fetch|merge|config) if [ -z "\$cmd" ]; then cmd="\$a"; fi ;;
    esac
    prev="\$a"
done
if [ -n "\$cmd" ]; then printf '%s' "\$seen_c" > "$sb/dashc-\$cmd.out"; fi
case "\$cmd" in
    fetch)
        printf '%s' "\${GIT_TERMINAL_PROMPT-UNSET}" > "$sb/gtp.out"
        printf '%s' "\${GIT_SSH_COMMAND-UNSET}" > "$sb/sshcmd.out"
        sleep 0.1
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
    *)
        exit 0
        ;;
esac
EOF
    chmod +x "$sb/bin/git"
    echo "$sb"
}

# Runs a snippet driver under a given shell with the sandbox HOME + fake git PATH.
# Args: <shell: bash|zsh> <sandbox> <driver> [<SESSION_SYNC value|UNSET>]. Four
# ambient vars are dropped so no assertion reads the developer's environment:
# SESSION_SYNC (off would vacate TC5/TC8-TC12), CLAUDECODE (set whenever this
# suite runs inside Claude Code — with captured stdout that is exactly the
# snippet's own skip condition), GIT_SSH_COMMAND and GIT_TERMINAL_PROMPT.
run_driver() {
    local shell="$1" sb="$2" driver="$3" ss="${4:-UNSET}"
    if [ "$ss" = "UNSET" ]; then
        env -u SESSION_SYNC -u CLAUDECODE -u GIT_SSH_COMMAND -u GIT_TERMINAL_PROMPT \
            HOME="$sb/home" PATH="$sb/bin:$PATH" SNIPPET="$SNIPPET" \
            bash "$RUN_TIMEOUT" 30 "$shell" "$driver" 2>&1
    else
        env -u CLAUDECODE -u GIT_SSH_COMMAND -u GIT_TERMINAL_PROMPT \
            SESSION_SYNC="$ss" HOME="$sb/home" PATH="$sb/bin:$PATH" SNIPPET="$SNIPPET" \
            bash "$RUN_TIMEOUT" 30 "$shell" "$driver" 2>&1
    fi
}

# --- Mirror sandbox (SESSION_SYNC gate cases) -------------------------------
# profile-snippet.sh re-exports AGENTS_CONFIG_DIR / AGENTS_DIR to *its own* parent
# directory, so sourcing it from the real checkout would resolve the real .env and
# the real session-sync CLI — pushing the developer's actual session repo. The
# mirror copies the snippet into a throwaway tree carrying just enough of the repo
# around it (bin/lib/session-sync-markers.sh included) plus recording stubs.
make_mirror_sandbox() {
    local with_git_repo="$1"
    local sb; sb="$(make_sandbox "$with_git_repo")"

    mkdir -p "$sb/agents/bin/lib" "$sb/agents/hooks" "$sb/agents/install/linux"
    cp "$SNIPPET" "$sb/agents/profile-snippet.sh"
    cp "$AGENTS_DIR/bin/get-config-var" "$sb/agents/bin/get-config-var"
    chmod +x "$sb/agents/bin/get-config-var"
    # codes() delegates to bin/codes-launch.sh (re-read from disk on every call,
    # unlike a sourced function) — mirror it too, or codes() would fail to find it.
    # No vscode-cc-repair stub: codes-launch.sh's own -e guard skips the repair
    # call cleanly when the directory is absent, as it is in this mirror.
    cp "$AGENTS_DIR/bin/codes-launch.sh" "$sb/agents/bin/codes-launch.sh"
    chmod +x "$sb/agents/bin/codes-launch.sh"
    # The marker SSOT lib ships beside the snippet; copying it here keeps the
    # mirror on the `source the lib` path rather than the inline fallback.
    if [ -f "$MARKERS_LIB" ]; then
        cp "$MARKERS_LIB" "$sb/agents/bin/lib/session-sync-markers.sh"
    fi
    # get-config-var resolves hooks/lib/load-env.js under AGENTS_CONFIG_DIR.
    cp -R "$AGENTS_DIR/hooks/lib" "$sb/agents/hooks/lib"
    # No .env in the mirror on purpose: loadDefaultEnv short-circuits on
    # AGENTS_CONFIG_DIR and never falls back, so SESSION_SYNC can only come from
    # the process environment. That makes each case decide its own value.

    # Recording stub for the manual sync CLI — never touches a real repo.
    cat > "$sb/agents/bin/session-sync.sh" <<EOF
#!/bin/bash
printf 'was-called %s\n' "\$*" >> "$sb/session-sync.calls"
exit 0
EOF
    chmod +x "$sb/agents/bin/session-sync.sh"
    cat > "$sb/agents/bin/wait-vscode-window.sh" <<'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$sb/agents/bin/wait-vscode-window.sh"
    # Prints on stdout like the real dotfileslink.sh, so the caller-side
    # redirection in profile-snippet.sh is observable (issue #2160).
    cat > "$sb/agents/install/linux/dotfileslink.sh" <<'EOF'
#!/bin/bash
printf 'Symlinks created in ~/.claude/\n'
exit 0
EOF
    chmod +x "$sb/agents/install/linux/dotfileslink.sh"

    # Recording stub for the editor launch, so a case can tell "codes() did
    # nothing" apart from "codes() ran but skipped the push".
    cat > "$sb/bin/code" <<EOF
#!/bin/bash
printf 'was-called %s\n' "\$*" >> "$sb/code.calls"
exit 0
EOF
    chmod +x "$sb/bin/code"
    # Broken-node stub for the fail-safe cases — a stub rather than an empty
    # PATH, since the snippet still needs date/sleep/dirname.
    mkdir -p "$sb/nonode"
    cat > "$sb/nonode/node" <<'EOF'
#!/bin/bash
echo "node: simulated failure" >&2
exit 127
EOF
    chmod +x "$sb/nonode/node"
    echo "$sb"
}

# Runs a driver against the MIRRORED snippet.
# Args: <shell> <sandbox> <driver> <SESSION_SYNC value|UNSET> [<with-node|no-node>]
run_mirror_driver() {
    local shell="$1" sb="$2" driver="$3" ss="${4:-UNSET}" node_mode="${5:-with-node}"
    local path_val="$sb/bin:$PATH"
    [ "$node_mode" = "no-node" ] && path_val="$sb/nonode:$sb/bin:$PATH"
    if [ "$ss" = "UNSET" ]; then
        env -u SESSION_SYNC -u CLAUDECODE -u GIT_SSH_COMMAND -u GIT_TERMINAL_PROMPT \
            HOME="$sb/home" PATH="$path_val" \
            SNIPPET="$sb/agents/profile-snippet.sh" \
            bash "$RUN_TIMEOUT" 30 "$shell" "$driver" 2>&1
    else
        env -u CLAUDECODE -u GIT_SSH_COMMAND -u GIT_TERMINAL_PROMPT \
            SESSION_SYNC="$ss" HOME="$sb/home" PATH="$path_val" \
            SNIPPET="$sb/agents/profile-snippet.sh" \
            bash "$RUN_TIMEOUT" 30 "$shell" "$driver" 2>&1
    fi
}

# ---------------------------------------------------------------------------
# TC1 / TC2 — Normal source: guard + AGENTS_CONFIG_DIR set, no errors
# ---------------------------------------------------------------------------
tc_normal() {
    local shell="$1" label="$2"
    local sb; sb="$(make_sandbox 0)"
    local drv="$sb/drv_normal.sh"
    cat > "$drv" <<'EOF'
. "$SNIPPET"
echo "CFGDIR=${AGENTS_CONFIG_DIR-MISSING}"
EOF
    local out; out="$(run_driver "$shell" "$sb" "$drv")"
    if echo "$out" | grep -q "CFGDIR=${AGENTS_DIR}" \
        && ! echo "$out" | grep -qi "error\|command not found"; then
        pass "$label: source sets AGENTS_CONFIG_DIR, no errors"
    else
        fail "$label: normal source. Output: $out"
    fi
    rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# TC3 / TC4 — codes is a defined function after source
# ---------------------------------------------------------------------------
tc_codes_defined() {
    local shell="$1" label="$2"
    local sb; sb="$(make_sandbox 0)"
    local drv="$sb/drv_codes.sh"
    cat > "$drv" <<'EOF'
. "$SNIPPET"
if type codes >/dev/null 2>&1; then echo "CODES=function"; else echo "CODES=missing"; fi
EOF
    local out; out="$(run_driver "$shell" "$sb" "$drv")"
    if echo "$out" | grep -q "CODES=function"; then
        pass "$label: codes is a defined function after source"
    else
        fail "$label: codes not defined. Output: $out"
    fi
    rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# TC5 / TC6 — Idempotency: the 2nd source returns before the fetch block, so the
#   fetch marker is printed once. FAIL-BEFORE-FIX: no guard → printed twice.
# ---------------------------------------------------------------------------
tc_idempotent() {
    local shell="$1" label="$2"
    local sb; sb="$(make_sandbox 1)"   # need git repo so fetch block emits its marker
    local drv="$sb/drv_idem.sh"
    cat > "$drv" <<'EOF'
. "$SNIPPET"
. "$SNIPPET"
echo "LOADED=${_AGENTS_PROFILE_LOADED-MISSING}"
EOF
    # SESSION_SYNC=on: this case counts fetch-block emissions, so the automatic
    # path must be enabled regardless of the machine's own toggle value.
    local out; out="$(run_driver "$shell" "$sb" "$drv" on)"
    local n; n="$(echo "$out" | grep -c "git fetch Claude session sync")"
    if [ "$n" -eq 1 ]; then
        pass "$label: second source short-circuits (fetch marker printed once)"
    else
        fail "$label: idempotency guard absent — fetch marker printed $n times (expected 1). Output: $out"
    fi
    rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# TC7 — _session_sync_fetch is used then cleaned up. "Absent after source" cannot
#   tell "never existed" from "removed", so STATIC + RUNTIME checks are combined.
# ---------------------------------------------------------------------------
tc_helper_cleaned() {
    local shell="$1" label="$2"
    local sb; sb="$(make_sandbox 1)"
    local drv="$sb/drv_helper.sh"
    cat > "$drv" <<'EOF'
. "$SNIPPET"
if type _session_sync_fetch >/dev/null 2>&1; then echo "HELPER=present"; else echo "HELPER=absent"; fi
EOF
    local out; out="$(run_driver "$shell" "$sb" "$drv" on)"
    local runtime_absent=0
    echo "$out" | grep -q "HELPER=absent" && runtime_absent=1

    local static_ok=0
    if grep -q '_session_sync_fetch()' "$SNIPPET" \
        && grep -Eq 'unset -f[[:space:]]+_session_sync_fetch' "$SNIPPET"; then
        static_ok=1
    fi

    if [ "$runtime_absent" = "1" ] && [ "$static_ok" = "1" ]; then
        pass "$label: _session_sync_fetch helper defined, unset -f'd, and absent after source"
    else
        fail "$label: helper contract unmet (runtime_absent=$runtime_absent static_ok=$static_ok). Output: $out"
    fi
    rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# TC10 — GIT_TERMINAL_PROMPT: fake git fetch receives GIT_TERMINAL_PROMPT=0
#   (fake git records "UNSET" when the snippet never exports it).
# ---------------------------------------------------------------------------
tc_git_terminal_prompt() {
    local sb; sb="$(make_sandbox 1)"
    local drv="$sb/drv_gtp.sh"
    cat > "$drv" <<'EOF'
. "$SNIPPET"
echo "DONE"
EOF
    local out; out="$(run_driver bash "$sb" "$drv" on)"
    if [ -f "$sb/gtp.out" ]; then
        local gtp; gtp="$(cat "$sb/gtp.out")"
        if [ "$gtp" = "0" ]; then
            pass "GIT_TERMINAL_PROMPT=0 passed to git fetch subshell"
        else
            fail "GIT_TERMINAL_PROMPT not set to 0 in fetch (got: '$gtp')"
        fi
    else
        fail "fetch never ran — gtp.out missing. Output: $out"
    fi
    rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# TC11 — Edge: no ~/.claude/projects/.git → fetch block skipped, no error
# ---------------------------------------------------------------------------
tc_no_git_repo() {
    local sb; sb="$(make_sandbox 0)"   # no projects/.git
    local drv="$sb/drv_norepo.sh"
    cat > "$drv" <<'EOF'
. "$SNIPPET"
echo "DONE"
EOF
    # SESSION_SYNC=on so the only possible reason for skipping the fetch block is
    # the missing repo — otherwise the assertion would pass vacuously.
    local out; out="$(run_driver bash "$sb" "$drv" on)"
    if echo "$out" | grep -q "DONE" \
        && ! echo "$out" | grep -q "git fetch Claude session sync" \
        && [ ! -f "$sb/gtp.out" ] \
        && ! echo "$out" | grep -qi "error\|command not found"; then
        pass "no-git-repo: fetch block skipped cleanly"
    else
        fail "no-git-repo edge case. Output: $out"
    fi
    rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# TC12 — git fetch exits nonzero → merge is skipped (error-handling path).
#   The fix gates the merge on [ "${_rc_ss:-1}" -eq 0 ], so a failed fetch must
#   not call git merge. Fake git (independent copy) is patched to exit 1.
# ---------------------------------------------------------------------------
tc_fetch_failure_skips_merge() {
    local sb; sb="$(make_sandbox 1)"
    # Patch fake git: fetch exits 1, merge records merged.out
    cat > "$sb/bin/git" <<EOF
#!/bin/bash
cmd=""
for a in "\$@"; do case "\$a" in fetch|merge|config) cmd="\$a"; break ;; esac; done
case "\$cmd" in
    fetch) printf '%s' "\${GIT_TERMINAL_PROMPT-UNSET}" > "$sb/gtp.out"; printf '%s' "\${GIT_SSH_COMMAND-UNSET}" > "$sb/sshcmd.out"; sleep 0.1; exit 1 ;;
    merge) printf 'merged' > "$sb/merged.out"; printf 'Updating abc1234..def5678\nFast-forward\n'; exit 0 ;;
    config)
        case "\$*" in
            *"--get core.sshCommand"*)
                if [ -f "$sb/core-sshcommand" ]; then cat "$sb/core-sshcommand"; exit 0; fi
                exit 1
                ;;
        esac
        exit 0
        ;;
    *) exit 0 ;;
esac
EOF
    chmod +x "$sb/bin/git"
    local drv="$sb/drv_fetchfail.sh"
    cat > "$drv" <<'EOF'
. "$SNIPPET"
echo "DONE"
EOF
    local out; out="$(run_driver bash "$sb" "$drv" on)"
    if echo "$out" | grep -q "DONE" \
        && [ ! -f "$sb/merged.out" ] \
        && ! echo "$out" | grep -qi "error\|command not found"; then
        pass "TC12: fetch failure → merge skipped, no crash"
    else
        fail "TC12: fetch failure handling. merged=$([ -f "$sb/merged.out" ] && echo yes || echo no). Output: $out"
    fi
    rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# TC-SSOT — profile-snippet.sh's inline fallback literals must equal the values
#   bin/lib/session-sync-markers.sh defines. The fallback only fires on a checkout
#   missing the lib, so drift is invisible at runtime yet breaks the sweep.
# ---------------------------------------------------------------------------
tc_marker_fallback_matches_lib() {
    if [ ! -f "$MARKERS_LIB" ]; then
        fail "TC-SSOT: marker lib not found at $MARKERS_LIB"
        return
    fi
    local lib_fetch lib_repair fb_fetch fb_repair
    lib_fetch="$(bash -c '. "$1"; printf "%s" "${AGENTS_SESSION_SYNC_FETCH_MARKER-}"' _ "$MARKERS_LIB" 2>/dev/null)"
    lib_repair="$(bash -c '. "$1"; printf "%s" "${AGENTS_SYMLINK_REPAIR_MARKER-}"' _ "$MARKERS_LIB" 2>/dev/null)"
    fb_fetch="$(grep -oE "AGENTS_SESSION_SYNC_FETCH_MARKER='[^']*'" "$SNIPPET" | head -1 | sed "s/^[^']*'//; s/'\$//")"
    fb_repair="$(grep -oE "AGENTS_SYMLINK_REPAIR_MARKER='[^']*'" "$SNIPPET" | head -1 | sed "s/^[^']*'//; s/'\$//")"

    if [ -n "$lib_fetch" ] && [ -n "$lib_repair" ] \
        && [ "$fb_fetch" = "$lib_fetch" ] && [ "$fb_repair" = "$lib_repair" ]; then
        pass "TC-SSOT: profile-snippet.sh fallback literals match bin/lib/session-sync-markers.sh"
    else
        fail "TC-SSOT: marker drift — fetch lib='$lib_fetch' fallback='$fb_fetch'; repair lib='$lib_repair' fallback='$fb_repair'"
    fi
}

# --- Run ---------------------------------------------------------------------
tc_normal bash "TC1"
tc_codes_defined bash "TC3"
tc_idempotent bash "TC5"
tc_helper_cleaned bash "TC7"
tc_git_terminal_prompt             # TC10
tc_no_git_repo                     # TC11
tc_fetch_failure_skips_merge       # TC12
tc_marker_fallback_matches_lib     # TC-SSOT

if [ "$HAVE_ZSH" = "1" ]; then
    tc_normal zsh "TC2"
    tc_codes_defined zsh "TC4"
    tc_idempotent zsh "TC6"
else
    echo "SKIP: zsh not available — TC2/TC4/TC6"
fi

# TC8/TC9 and TC13+ live in sibling part files so this file stays under the
# 500-line HARD limit of rules/coding/file-split.md. Each part file self-invokes
# its cases at source time.
# shellcheck source=tests/fix-1225-profile-snippet-guards/shell-compat.sh
. "${AGENTS_DIR}/tests/fix-1225-profile-snippet-guards/shell-compat.sh"
# shellcheck source=tests/fix-1225-profile-snippet-guards/session-sync-gate.sh
. "${AGENTS_DIR}/tests/fix-1225-profile-snippet-guards/session-sync-gate.sh"
# shellcheck source=tests/fix-1225-profile-snippet-guards/ssh-command-override.sh
. "${AGENTS_DIR}/tests/fix-1225-profile-snippet-guards/ssh-command-override.sh"
# shellcheck source=tests/fix-1225-profile-snippet-guards/ssh-command-injection.sh
. "${AGENTS_DIR}/tests/fix-1225-profile-snippet-guards/ssh-command-injection.sh"
# shellcheck source=tests/fix-1225-profile-snippet-guards/fetch-frequency-guard.sh
. "${AGENTS_DIR}/tests/fix-1225-profile-snippet-guards/fetch-frequency-guard.sh"
# shellcheck source=tests/fix-1225-profile-snippet-guards/fetch-guard-boundary-clock.sh
. "${AGENTS_DIR}/tests/fix-1225-profile-snippet-guards/fetch-guard-boundary-clock.sh"
# shellcheck source=tests/fix-1225-profile-snippet-guards/stdout-stderr-split.sh
. "${AGENTS_DIR}/tests/fix-1225-profile-snippet-guards/stdout-stderr-split.sh"
# shellcheck source=tests/fix-1225-profile-snippet-guards/fetch-kill-deadline.sh
. "${AGENTS_DIR}/tests/fix-1225-profile-snippet-guards/fetch-kill-deadline.sh"
# set-e-source-safety.sh reuses _ffg_stamp, so it must follow fetch-frequency-guard.sh.
# shellcheck source=tests/fix-1225-profile-snippet-guards/set-e-source-safety.sh
. "${AGENTS_DIR}/tests/fix-1225-profile-snippet-guards/set-e-source-safety.sh"

echo "----------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
