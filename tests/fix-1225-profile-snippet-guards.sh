#!/bin/bash
# tests/fix-1225-profile-snippet-guards.sh
# Tests: profile-snippet.sh
# Tags: installer, profile-snippet, idempotency, job-control, scope:issue-specific
#
# Issue #1225: profile-snippet.sh guards — idempotency guard, _session_sync_fetch
# helper with NO_MONITOR (no zsh job-control suspend output), GIT_TERMINAL_PROMPT=0
# in the fetch subshell, and unset -f cleanup of the helper after use.
#
# L2 broad-integration test: sources the real profile-snippet.sh in real bash and
# real zsh with a stubbed HOME (valid symlinks to neutralize the repair block) and
# a fake git on PATH (records GIT_TERMINAL_PROMPT, sleeps, exits 0).
#
# L3 gap (what this test does NOT catch):
# - real SSH passphrase prompting on `git fetch` against a passphrase-protected key
# - real iTerm/interactive-shell job-control rendering of "[N] + suspended"
# - real network fetch/merge against the live session-sync remote
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: installer

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SNIPPET="${AGENTS_DIR}/profile-snippet.sh"
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

    # Fake git: records GIT_TERMINAL_PROMPT for `fetch`, marks `merge`, no-ops else.
    mkdir -p "$sb/bin"
    cat > "$sb/bin/git" <<EOF
#!/bin/bash
# fake git for fix-1225 test
cmd=""
for a in "\$@"; do
    case "\$a" in
        fetch|merge) cmd="\$a"; break ;;
    esac
done
case "\$cmd" in
    fetch)
        printf '%s' "\${GIT_TERMINAL_PROMPT-UNSET}" > "$sb/gtp.out"
        sleep 0.1
        exit 0
        ;;
    merge)
        printf 'merged' > "$sb/merged.out"
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
# Args: <shell: bash|zsh> <sandbox> <driver-script-path>
run_driver() {
    local shell="$1" sb="$2" driver="$3"
    HOME="$sb/home" PATH="$sb/bin:$PATH" SNIPPET="$SNIPPET" \
        bash "$RUN_TIMEOUT" 30 "$shell" "$driver" 2>&1
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
# TC5 / TC6 — Idempotency: second source is an early return
#   We detect the early-return by a side effect: the fetch block prints
#   "git fetch Claude session sync ..." each time it runs. With the guard, the
#   2nd source returns before reaching the fetch block → message printed once.
#   FAIL-BEFORE-FIX: current code has no guard → message printed twice.
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
    local out; out="$(run_driver "$shell" "$sb" "$drv")"
    local n; n="$(echo "$out" | grep -c "git fetch Claude session sync")"
    if [ "$n" -eq 1 ]; then
        pass "$label: second source short-circuits (fetch marker printed once)"
    else
        fail "$label: idempotency guard absent — fetch marker printed $n times (expected 1). Output: $out"
    fi
    rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# TC7 — _session_sync_fetch helper is used then cleaned up (not leaked).
#   The planned change extracts the fetch block into a `_session_sync_fetch`
#   helper and `unset -f`s it after use. A pure runtime "absent after source"
#   probe cannot distinguish "never existed" (current code) from "defined then
#   removed" (fixed code) — both report absent. So TC7 combines two assertions:
#     (a) STATIC: the source defines `_session_sync_fetch` AND unsets it (-f).
#         FAIL-BEFORE-FIX: current source contains no such helper name.
#     (b) RUNTIME: after sourcing, the helper is NOT defined in the shell.
#   Both must hold. (a) fails on current code, so TC7 fails before the fix.
# ---------------------------------------------------------------------------
tc_helper_cleaned() {
    local shell="$1" label="$2"
    local sb; sb="$(make_sandbox 1)"
    local drv="$sb/drv_helper.sh"
    cat > "$drv" <<'EOF'
. "$SNIPPET"
if type _session_sync_fetch >/dev/null 2>&1; then echo "HELPER=present"; else echo "HELPER=absent"; fi
EOF
    local out; out="$(run_driver "$shell" "$sb" "$drv")"
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
# TC8 — bash-compat: sourcing in bash produces no "setopt: command not found"
#   The planned helper begins with a guarded `setopt LOCAL_OPTIONS NO_MONITOR`.
#   In bash that line must be guarded by ZSH_VERSION so `setopt` is never invoked.
# ---------------------------------------------------------------------------
tc_no_setopt_in_bash() {
    local sb; sb="$(make_sandbox 1)"
    local drv="$sb/drv_setopt.sh"
    cat > "$drv" <<'EOF'
. "$SNIPPET"
echo "DONE"
EOF
    local out; out="$(run_driver bash "$sb" "$drv")"
    if echo "$out" | grep -q "DONE" && ! echo "$out" | grep -qi "setopt"; then
        pass "bash-compat: no setopt error when sourcing in bash"
    else
        fail "bash-compat: setopt invoked under bash. Output: $out"
    fi
    rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# TC9 — No job control: sourcing in zsh with a slow fake git emits no
#   "suspended" / "[N] +" background-job notification.
#   FAIL-BEFORE-FIX: current code backgrounds the fetch without NO_MONITOR.
# ---------------------------------------------------------------------------
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
    # Run zsh interactively-ish: monitor mode only matters with -m / interactive,
    # but the planned fix uses NO_MONITOR explicitly. We assert no suspend output.
    local out; out="$(run_driver zsh "$sb" "$drv")"
    if echo "$out" | grep -Eq "suspended|\[[0-9]+\][[:space:]]*\+"; then
        fail "zsh job control: background suspend output present. Output: $out"
    else
        pass "zsh: no job-control suspend output from backgrounded fetch"
    fi
    rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# TC10 — GIT_TERMINAL_PROMPT: fake git fetch receives GIT_TERMINAL_PROMPT=0.
#   FAIL-BEFORE-FIX: current code does not export GIT_TERMINAL_PROMPT into the
#   fetch subshell → fake git records "UNSET".
# ---------------------------------------------------------------------------
tc_git_terminal_prompt() {
    local sb; sb="$(make_sandbox 1)"
    local drv="$sb/drv_gtp.sh"
    cat > "$drv" <<'EOF'
. "$SNIPPET"
echo "DONE"
EOF
    local out; out="$(run_driver bash "$sb" "$drv")"
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
    local out; out="$(run_driver bash "$sb" "$drv")"
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
#   The fix uses [ "${_rc_ss:-1}" -eq 0 ] to gate the merge, so a failed
#   fetch must not call git merge. Fake git is patched to exit 1 for fetch.
# ---------------------------------------------------------------------------
tc_fetch_failure_skips_merge() {
    local sb; sb="$(make_sandbox 1)"
    # Patch fake git: fetch exits 1, merge records merged.out
    cat > "$sb/bin/git" <<EOF
#!/bin/bash
cmd=""
for a in "\$@"; do case "\$a" in fetch|merge) cmd="\$a"; break ;; esac; done
case "\$cmd" in
    fetch) printf '%s' "\${GIT_TERMINAL_PROMPT-UNSET}" > "$sb/gtp.out"; sleep 0.1; exit 1 ;;
    merge) printf 'merged' > "$sb/merged.out"; exit 0 ;;
    *) exit 0 ;;
esac
EOF
    chmod +x "$sb/bin/git"
    local drv="$sb/drv_fetchfail.sh"
    cat > "$drv" <<'EOF'
. "$SNIPPET"
echo "DONE"
EOF
    local out; out="$(run_driver bash "$sb" "$drv")"
    if echo "$out" | grep -q "DONE" \
        && [ ! -f "$sb/merged.out" ] \
        && ! echo "$out" | grep -qi "error\|command not found"; then
        pass "TC12: fetch failure → merge skipped, no crash"
    else
        fail "TC12: fetch failure handling. merged=$([ -f "$sb/merged.out" ] && echo yes || echo no). Output: $out"
    fi
    rm -rf "$sb"
}

# --- Run ---------------------------------------------------------------------
tc_normal bash "TC1"
tc_codes_defined bash "TC3"
tc_idempotent bash "TC5"
tc_helper_cleaned bash "TC7"
tc_no_setopt_in_bash               # TC8
tc_git_terminal_prompt             # TC10
tc_no_git_repo                     # TC11
tc_fetch_failure_skips_merge       # TC12

if [ "$HAVE_ZSH" = "1" ]; then
    tc_normal zsh "TC2"
    tc_codes_defined zsh "TC4"
    tc_idempotent zsh "TC6"
else
    echo "SKIP: zsh not available — TC2/TC4/TC6"
fi
tc_no_job_control_zsh              # TC9 (self-skips if no zsh)

echo "----------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
