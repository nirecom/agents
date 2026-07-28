#!/bin/bash
# tests/fix-389-load-env-default-fallback.sh
# Tests: hooks/lib/load-env.js
# Tags: env, load-env, worktree, scope:issue-specific
# RED for issue #389.
#
# STATUS:
#   T389-1..6 — GREEN today and must stay green (untouched by #1569 / #1630).
#   T389-7    — GREEN today; it PINS the deliberate policy asymmetry introduced
#               by C4: loadDefaultEnv keeps its short-circuit (an explicit
#               AGENTS_CONFIG_DIR is the ONLY config source and never falls
#               through to the module / realpath candidates), whereas
#               resolveAgentsConfigDir DOES fall through. Sharing
#               configDirCandidates() between them must not merge the two
#               selection policies.
#   T389-8    — RED until C4 lands (candidate values are not yet routed through
#               normalizeCwd + path.resolve, so a Windows-POSIX env value is
#               passed to path.join verbatim and the .env is never found).
#               SKIPPED on non-win32.
#
# TL3 gap (what this TL2 test does NOT catch):
# - actual symlink resolution in a live ~\.claude\ → C:\git\agents\ setup
# - ENOLINK or unusual symlink types on Windows NTFS
# - a real hook process whose AGENTS_CONFIG_DIR was dropped by a subagent spawn
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: hook-registration.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

LOAD_ENV="$AGENTS_DIR/hooks/lib/load-env.js"
LOAD_ENV_NODE="$_AGENTS_DIR_NODE/hooks/lib/load-env.js"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

require_source() {
    local path="$1" label="$2"
    if [ ! -f "$path" ]; then skip "$label (source not implemented yet)"; return 1; fi
    return 0
}

# T389-1: AGENTS_CONFIG_DIR is set to a temp dir containing .env → loaded.
run_t389_1() {
    require_source "$LOAD_ENV" "T389-1: AGENTS_CONFIG_DIR points to temp dir with .env -> loaded" || return
    local tmp out rc
    tmp="$(mktemp -d)"
    printf 'TEST_T389_1_KEY=loaded_value\n' > "$tmp/.env"
    out=$(AGENTS_CONFIG_DIR="$tmp" run_with_timeout 5 node -e "
const {loadDefaultEnv} = require('$LOAD_ENV_NODE');
const ok = loadDefaultEnv();
process.stdout.write(JSON.stringify({ok, val: process.env.TEST_T389_1_KEY || ''}));
" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && echo "$out" | grep -q '"val":"loaded_value"' && echo "$out" | grep -q '"ok":true'; then
        pass "T389-1: AGENTS_CONFIG_DIR points to temp dir with .env -> loaded"
    else
        fail "T389-1: AGENTS_CONFIG_DIR points to temp dir with .env -> loaded (rc=$rc, out=$out)"
    fi
}

# T389-2: the realpath fallback (~/.claude/hooks/lib/... → real C:/git/agents/...)
# still exists and is still USED.
#
# Retargeted for C4: the realpathSync call moved out of load-env.js into
# hooks/lib/agents-config-dir.js (configDirCandidates), so grepping load-env.js
# for `realpathSync(` no longer touches the code it claims to cover — it was
# passing on an explanatory COMMENT that happened to contain the token. This is
# now behavioural on the module that actually produces the candidate:
#   (a) enumeration — with AGENTS_CONFIG_DIR unset, configDirCandidates() emits a
#       `realpath`-sourced candidate. Deleting the realpathSync call makes the
#       source disappear; a comment cannot satisfy this.
#   (b) selection — when the module-anchored candidate does NOT validate, the
#       realpath candidate is the one adopted (the symlinked-install case).
# Real symlink resolution on a live ~/.claude install stays the TL3 gap.
run_t389_2() {
    local label="T389-2: realpath candidate is enumerated and adopted (agents-config-dir.js)"
    require_source "$AGENTS_DIR/hooks/lib/agents-config-dir.js" "$label" || return
    local out rc
    out=$(run_with_timeout 5 env -u AGENTS_CONFIG_DIR node -e "
const acd = require('$_AGENTS_DIR_NODE/hooks/lib/agents-config-dir.js');
const sources = acd.configDirCandidates().map((c) => c.source);
const real = '$_AGENTS_DIR_NODE';
// module candidate deliberately unresolvable -> only the realpath one can win.
const picked = acd._resolveFromCandidates([
  { dir: real + '/no-such-module-anchor', source: 'module' },
  { dir: real, source: 'realpath' },
]);
process.stdout.write(JSON.stringify({ sources, picked }));
" 2>/dev/null)
    rc=$?
    if [ $rc -ne 0 ]; then
        fail "$label (rc=$rc, out=$out)"
        return
    fi
    if ! echo "$out" | grep -q '"realpath"'; then
        fail "$label (no realpath-sourced candidate enumerated: $out)"
        return
    fi
    if echo "$out" | grep -q "\"picked\":\"$_AGENTS_DIR_NODE\""; then
        pass "$label"
    else
        fail "$label (realpath candidate not adopted when the module anchor fails: $out)"
    fi
}

# T389-3: AGENTS_CONFIG_DIR unset and realpath fallback path has no .env →
# falls through gracefully (no crash, no env loaded).
run_t389_3() {
    require_source "$LOAD_ENV" "T389-3: no AGENTS_CONFIG_DIR and no .env -> graceful no-op" || return
    local tmp out rc
    tmp="$(mktemp -d)"
    # Run from a directory with no .env anywhere reachable. Unset
    # AGENTS_CONFIG_DIR so loadDefaultEnv falls into the fallback chain. The
    # function must not throw; existing repo .env may still be picked up via
    # the file-relative fallback, so we only assert rc=0.
    out=$(cd "$tmp" && run_with_timeout 5 env -u AGENTS_CONFIG_DIR node -e "
const {loadDefaultEnv} = require('$LOAD_ENV_NODE');
try {
  loadDefaultEnv();
  process.stdout.write('ok');
} catch (e) {
  process.stdout.write('THREW: ' + e.message);
}
" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$out" = "ok" ]; then
        pass "T389-3: no AGENTS_CONFIG_DIR and no .env -> graceful no-op"
    else
        fail "T389-3: no AGENTS_CONFIG_DIR and no .env -> graceful no-op (rc=$rc, out=$out)"
    fi
}

# T389-4: When KEY="" (empty string) exists in process.env, loadDefaultEnv
# MUST overwrite it with the .env value. The fix in load-env.js uses
# `if (process.env[key])` so empty-string is falsy and does NOT shadow the
# .env value. Windows propagates VAR="" into child processes even when the
# parent shell shows it as unset, so this is a real-world Windows scenario.
run_t389_4() {
    require_source "$LOAD_ENV" "T389-4: empty-string process.env does NOT shadow .env value" || return
    local tmp out rc
    tmp="$(mktemp -d)"
    printf 'LOAD_ENV_TEST_KEY=fromfile\n' > "$tmp/.env"
    out=$(AGENTS_CONFIG_DIR="$tmp" LOAD_ENV_TEST_KEY="" run_with_timeout 5 node -e "
const {loadDefaultEnv} = require('$LOAD_ENV_NODE');
loadDefaultEnv();
process.stdout.write(process.env.LOAD_ENV_TEST_KEY || '');
" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$out" = "fromfile" ]; then
        pass "T389-4: empty-string process.env does NOT shadow .env value"
    else
        fail "T389-4: empty-string process.env does NOT shadow .env value (rc=$rc, out='$out', expected 'fromfile')"
    fi
}

# T389-5: When KEY is set to a NON-EMPTY value in process.env, loadDefaultEnv
# MUST NOT overwrite it. Non-empty process.env wins (existing behavior
# preserved by the empty-string fix).
run_t389_5() {
    require_source "$LOAD_ENV" "T389-5: non-empty process.env wins over .env value" || return
    local tmp out rc
    tmp="$(mktemp -d)"
    printf 'LOAD_ENV_TEST_KEY=fromfile\n' > "$tmp/.env"
    out=$(AGENTS_CONFIG_DIR="$tmp" LOAD_ENV_TEST_KEY="fromenv" run_with_timeout 5 node -e "
const {loadDefaultEnv} = require('$LOAD_ENV_NODE');
loadDefaultEnv();
process.stdout.write(process.env.LOAD_ENV_TEST_KEY || '');
" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$out" = "fromenv" ]; then
        pass "T389-5: non-empty process.env wins over .env value"
    else
        fail "T389-5: non-empty process.env wins over .env value (rc=$rc, out='$out', expected 'fromenv')"
    fi
}

# T389-6: AGENTS_HOOK_DEBUG=1 + non-empty env var shadows .env value → debug
# message to stderr contains the key NAME but NOT the secret value.
# Security: the debug path must not leak the pre-existing secret into logs.
run_t389_6() {
    require_source "$LOAD_ENV" "T389-6: debug message includes key name, not secret value" || return
    local tmp out_stderr rc
    tmp="$(mktemp -d)"
    printf 'LOAD_ENV_TEST_SECRET=fromfile\n' > "$tmp/.env"
    out_stderr=$(AGENTS_CONFIG_DIR="$tmp" AGENTS_HOOK_DEBUG=1 LOAD_ENV_TEST_SECRET="supersecret" \
        run_with_timeout 5 node -e "
const {loadDefaultEnv} = require('$LOAD_ENV_NODE');
loadDefaultEnv();
" 2>&1 >/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -ne 0 ]; then
        fail "T389-6: node exited with rc=$rc"
        return
    fi
    if echo "$out_stderr" | grep -q "LOAD_ENV_TEST_SECRET"; then
        if echo "$out_stderr" | grep -q "supersecret"; then
            fail "T389-6: stderr contains secret value 'supersecret' (must not leak): $out_stderr"
        else
            pass "T389-6: debug message includes key name, not secret value"
        fi
    else
        # Debug output may be absent when key is skipped without logging — only
        # fail if the secret itself appears.
        if echo "$out_stderr" | grep -q "supersecret"; then
            fail "T389-6: stderr contains secret value 'supersecret' (must not leak): $out_stderr"
        else
            pass "T389-6: debug message includes key name, not secret value (no debug output — key skipped silently)"
        fi
    fi
}

# shellcheck source=./fix-389-load-env-default-fallback/config-dir-cases.sh
. "$(dirname "${BASH_SOURCE[0]}")/fix-389-load-env-default-fallback/config-dir-cases.sh"


run_t389_1
run_t389_2
run_t389_3
run_t389_4
run_t389_5
run_t389_6
run_t389_7
run_t389_8

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
