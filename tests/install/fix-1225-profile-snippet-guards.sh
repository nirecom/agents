#!/bin/bash
# tests/install/fix-1225-profile-snippet-guards.sh
# Tests: profile-snippet.sh, bin/lib/session-sync-markers.sh
# Tags: installer, profile-snippet, idempotency, job-control, ssh, stdout-stderr, scope:issue-specific
#
# Issue #1225 guards (idempotency, _session_sync_fetch + NO_MONITOR, GIT_TERMINAL_PROMPT=0,
# unset -f cleanup), #2160 (progress on stderr, core.sshCommand-aware GIT_SSH_COMMAND, fetch
# frequency stamp) and #2658 (the startup fetch is `session-sync-engine startup`).
# TL2 broad integration: sources a mirrored snippet in real bash and zsh with a stubbed HOME,
# a fake git on PATH and a recording stub engine; TC16d-i and TC-DEADLINE use the real engine.

set -u

# TL3 gap (what this test does NOT catch):
# - real SSH passphrase prompting on `git fetch` against a passphrase-protected key
# - real iTerm/interactive-shell job-control rendering of "[N] + suspended"
# - real network fetch against the live session-sync remote; the stub-engine cases never fetch
# - the snippet running from its real install location (every case sources a byte-identical copy)
# - the real dotfileslink.sh and its wait for a live Claude Code (the mirror stubs it)
# - the value actually shipped in the real .env (the mirror has none on purpose)
# - Claude Code's own shell-snapshot capture of a real login shell's stdout
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: installer

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SNIPPET="${SCRIPT_CHECKOUT_ROOT}/profile-snippet.sh"
MARKERS_LIB="${SCRIPT_CHECKOUT_ROOT}/bin/lib/session-sync-markers.sh"
RUN_TIMEOUT="${SCRIPT_CHECKOUT_ROOT}/bin/run-with-timeout.sh"
# shellcheck source=/dev/null
. "${SCRIPT_CHECKOUT_ROOT}/tests/lib/home-userprofile-pin.sh"
# shellcheck source=tests/install/fix-1225-profile-snippet-guards/sandbox.sh
. "${SCRIPT_CHECKOUT_ROOT}/tests/install/fix-1225-profile-snippet-guards/sandbox.sh"

# The real engine resolves its plans dir from these pins (rules/test/fixture-isolation.md).
_FIX1225_TMP="$(mktemp -d "${TMPDIR:-/tmp}/fix1225-pins.XXXXXX")"
readonly _FIX1225_TMP
trap 'rm -rf "$_FIX1225_TMP"' EXIT
export WORKFLOW_STATE_DIR="$(mirror_native_path "$_FIX1225_TMP/state")" WORKFLOW_PLANS_DIR="$(mirror_native_path "$_FIX1225_TMP/plans")"
unset CLAUDE_CODE_SESSION_ID

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; }

HAVE_ZSH=0
command -v zsh >/dev/null 2>&1 && HAVE_ZSH=1

# ---------------------------------------------------------------------------
# TC1 / TC2 — Normal source: guard + AGENTS_MAIN_ROOT set, no errors
# ---------------------------------------------------------------------------
tc_normal() {
    local shell="$1" label="$2"
    local sb; sb="$(make_mirror_sandbox 0)"
    local drv="$sb/drv_normal.sh"
    cat > "$drv" <<'EOF'
. "$SNIPPET"
echo "CFGDIR=${AGENTS_MAIN_ROOT-MISSING}"
EOF
    local want; want="$(cd "$sb/agents" && pwd)"
    local out; out="$(run_mirror_driver "$shell" "$sb" "$drv")"
    if echo "$out" | grep -qF "CFGDIR=$want" \
        && ! echo "$out" | grep -qi "error\|command not found"; then
        pass "$label: source sets AGENTS_MAIN_ROOT, no errors"
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
    local sb; sb="$(make_mirror_sandbox 0)"
    local drv="$sb/drv_codes.sh"
    cat > "$drv" <<'EOF'
. "$SNIPPET"
if type codes >/dev/null 2>&1; then echo "CODES=function"; else echo "CODES=missing"; fi
EOF
    local out; out="$(run_mirror_driver "$shell" "$sb" "$drv")"
    if echo "$out" | grep -q "CODES=function"; then
        pass "$label: codes is a defined function after source"
    else
        fail "$label: codes not defined. Output: $out"
    fi
    rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# TC5 / TC6 — Idempotency: the 2nd source returns before the fetch block, so the
#   engine starts once. The driver removes the stamp between the two sources, or
#   the frequency guard alone would hide a missing idempotency guard.
# ---------------------------------------------------------------------------
tc_idempotent() {
    local shell="$1" label="$2"
    local sb; sb="$(make_mirror_sandbox 1)"   # need git repo so fetch block emits its marker
    local drv="$sb/drv_idem.sh"
    cat > "$drv" <<'EOF'
. "$SNIPPET"
rm -f "$HOME/.claude/projects/.git/agents-last-fetch"
. "$SNIPPET"
echo "LOADED=${_AGENTS_PROFILE_LOADED-MISSING}"
EOF
    # SESSION_SYNC=on: this case counts fetch-block emissions, so the automatic
    # path must be enabled regardless of the machine's own toggle value.
    local out; out="$(run_mirror_driver "$shell" "$sb" "$drv" on)"
    local n calls=0
    n="$(echo "$out" | grep -c "git fetch Claude session sync")"
    [ -f "$sb/engine.calls" ] && calls="$(grep -c called "$sb/engine.calls")"
    if [ "$n" -eq 1 ] && [ "$calls" -eq 1 ]; then
        pass "$label: second source short-circuits (fetch marker printed once, engine started once)"
    else
        fail "$label: idempotency guard absent — marker printed $n times, engine started $calls times (expected 1/1). Output: $out"
    fi
    rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# TC7 — _session_sync_fetch is used then cleaned up. "Absent after source" cannot
#   tell "never existed" from "removed", so STATIC + RUNTIME checks are combined.
# ---------------------------------------------------------------------------
tc_helper_cleaned() {
    local shell="$1" label="$2"
    local sb; sb="$(make_mirror_sandbox 1)"
    local drv="$sb/drv_helper.sh"
    cat > "$drv" <<'EOF'
. "$SNIPPET"
if type _session_sync_fetch >/dev/null 2>&1; then echo "HELPER=present"; else echo "HELPER=absent"; fi
EOF
    local out; out="$(run_mirror_driver "$shell" "$sb" "$drv" on)"
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
# TC10 — the engine receives GIT_TERMINAL_PROMPT=0 (the stub records "UNSET" when the
#   snippet never sets it) and its startup arguments, --claude-dir naming the pinned home.
# ---------------------------------------------------------------------------
tc_git_terminal_prompt() {
    local sb; sb="$(make_mirror_sandbox 1)"
    local drv="$sb/drv_gtp.sh"
    cat > "$drv" <<'EOF'
. "$SNIPPET"
echo "DONE"
EOF
    local out; out="$(run_mirror_driver bash "$sb" "$drv" on)"
    if [ -f "$sb/gtp.out" ]; then
        local gtp action quiet claude_dir want_dir
        gtp="$(cat "$sb/gtp.out")"
        action="$(head -1 "$sb/engine-argv.out")"
        quiet="$(grep -c -x -e '--quiet' "$sb/engine-argv.out")"
        claude_dir="$(awk 'prev == "--claude-dir" { print; exit } { prev = $0 }' "$sb/engine-argv.out")"
        want_dir="$(mirror_native_path "$sb/home/.claude")"
        if [ "$gtp" = "0" ] && [ "$action" = "startup" ] && [ "$quiet" = "1" ] && [ "$(mirror_native_path "$claude_dir")" = "$want_dir" ]; then
            pass "GIT_TERMINAL_PROMPT=0 and 'startup --quiet --claude-dir <home>/.claude' reach the engine"
        else
            fail "engine contract: GIT_TERMINAL_PROMPT='$gtp' action='$action' quiet=$quiet claude-dir='$claude_dir' (want '$want_dir')"
        fi
    else
        fail "engine never ran — gtp.out missing. Output: $out"
    fi
    rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# TC11 — Edge: no ~/.claude/projects/.git → fetch block skipped, no error
# ---------------------------------------------------------------------------
tc_no_git_repo() {
    local sb; sb="$(make_mirror_sandbox 0)"   # no projects/.git
    local drv="$sb/drv_norepo.sh"
    cat > "$drv" <<'EOF'
. "$SNIPPET"
echo "DONE"
EOF
    # SESSION_SYNC=on so the only possible reason for skipping the fetch block is
    # the missing repo — otherwise the assertion would pass vacuously.
    local out; out="$(run_mirror_driver bash "$sb" "$drv" on)"
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
# TC12 — the engine exits nonzero → the shell carries on (error-handling path).
#   Whether a failed fetch skips the integration is the engine's own contract.
# ---------------------------------------------------------------------------
tc_engine_failure_keeps_shell() {
    local sb; sb="$(make_mirror_sandbox 1)"
    printf '1' > "$sb/engine-exit-code.txt"
    local drv="$sb/drv_fetchfail.sh"
    cat > "$drv" <<'EOF'
. "$SNIPPET"
echo "DONE"
EOF
    local out; out="$(run_mirror_driver bash "$sb" "$drv" on)"
    if echo "$out" | grep -q "DONE" \
        && [ -f "$sb/gtp.out" ] \
        && ! echo "$out" | grep -qi "error\|command not found"; then
        pass "TC12: engine failure → the shell finishes, no crash"
    else
        fail "TC12: engine failure handling. engine_ran=$([ -f "$sb/gtp.out" ] && echo yes || echo no). Output: $out"
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
tc_engine_failure_keeps_shell      # TC12
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
# shellcheck source=tests/install/fix-1225-profile-snippet-guards/shell-compat.sh
. "${SCRIPT_CHECKOUT_ROOT}/tests/install/fix-1225-profile-snippet-guards/shell-compat.sh"
# shellcheck source=tests/install/fix-1225-profile-snippet-guards/session-sync-gate.sh
. "${SCRIPT_CHECKOUT_ROOT}/tests/install/fix-1225-profile-snippet-guards/session-sync-gate.sh"
# shellcheck source=tests/install/fix-1225-profile-snippet-guards/ssh-command-override.sh
. "${SCRIPT_CHECKOUT_ROOT}/tests/install/fix-1225-profile-snippet-guards/ssh-command-override.sh"
# shellcheck source=tests/install/fix-1225-profile-snippet-guards/ssh-command-injection.sh
. "${SCRIPT_CHECKOUT_ROOT}/tests/install/fix-1225-profile-snippet-guards/ssh-command-injection.sh"
# shellcheck source=tests/install/fix-1225-profile-snippet-guards/fetch-frequency-guard.sh
. "${SCRIPT_CHECKOUT_ROOT}/tests/install/fix-1225-profile-snippet-guards/fetch-frequency-guard.sh"
# shellcheck source=tests/install/fix-1225-profile-snippet-guards/fetch-guard-boundary-clock.sh
. "${SCRIPT_CHECKOUT_ROOT}/tests/install/fix-1225-profile-snippet-guards/fetch-guard-boundary-clock.sh"
# shellcheck source=tests/install/fix-1225-profile-snippet-guards/stdout-stderr-split.sh
. "${SCRIPT_CHECKOUT_ROOT}/tests/install/fix-1225-profile-snippet-guards/stdout-stderr-split.sh"
# shellcheck source=tests/install/fix-1225-profile-snippet-guards/fetch-kill-deadline.sh
. "${SCRIPT_CHECKOUT_ROOT}/tests/install/fix-1225-profile-snippet-guards/fetch-kill-deadline.sh"
# set-e-source-safety.sh reuses _ffg_stamp, so it must follow fetch-frequency-guard.sh.
# shellcheck source=tests/install/fix-1225-profile-snippet-guards/set-e-source-safety.sh
. "${SCRIPT_CHECKOUT_ROOT}/tests/install/fix-1225-profile-snippet-guards/set-e-source-safety.sh"

echo "----------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
