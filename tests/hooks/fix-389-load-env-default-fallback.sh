#!/bin/bash
# tests/hooks/fix-389-load-env-default-fallback.sh
# Tests: hooks/lib/load-env.js, hooks/lib/script-checkout-root.js
# Tags: env, load-env, worktree, scope:issue-specific
# T389-1..6 live here; T389-7/8 (load-env's own AGENTS_MAIN_ROOT read) in agents-main-root-cases.sh;
# CV-1..5 (#2100, resolveConfigVar) in resolve-config-var-cases.sh. T389-8 skips off win32.
# TL3 gap (what this TL2 test does NOT catch): live ~\.claude\ → C:\git\agents\ symlink
# resolution, ENOLINK / unusual NTFS symlink types, a hook whose AGENTS_MAIN_ROOT a subagent spawn dropped.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: hook-registration.

set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
_ISOLATION_TMP_ROOT="$(make_tmp)"; readonly _ISOLATION_TMP_ROOT
harness_isolate "$_ISOLATION_TMP_ROOT"
trap 'rm -rf "$_ISOLATION_TMP_ROOT"' EXIT

if command -v cygpath >/dev/null 2>&1; then
    _SCRIPT_CHECKOUT_ROOT_NODE="$(cygpath -m "$SCRIPT_CHECKOUT_ROOT")"
else
    _SCRIPT_CHECKOUT_ROOT_NODE="$SCRIPT_CHECKOUT_ROOT"
fi

LOAD_ENV="$SCRIPT_CHECKOUT_ROOT/hooks/lib/load-env.js"
LOAD_ENV_NODE="$_SCRIPT_CHECKOUT_ROOT_NODE/hooks/lib/load-env.js"

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

# T389-1: AGENTS_MAIN_ROOT is set to a temp dir containing .env → loaded.
run_t389_1() {
    require_source "$LOAD_ENV" "T389-1: AGENTS_MAIN_ROOT points to temp dir with .env -> loaded" || return
    local tmp out rc
    tmp="$(mktemp -d "$_ISOLATION_TMP_ROOT/t389.XXXXXX")"
    printf 'TEST_T389_1_KEY=loaded_value\n' > "$tmp/.env"
    out=$(AGENTS_MAIN_ROOT="$tmp" run_with_timeout 5 node -e "
const {loadDefaultEnv} = require('$LOAD_ENV_NODE');
const ok = loadDefaultEnv();
process.stdout.write(JSON.stringify({ok, val: process.env.TEST_T389_1_KEY || ''}));
" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && echo "$out" | grep -q '"val":"loaded_value"' && echo "$out" | grep -q '"ok":true'; then
        pass "T389-1: AGENTS_MAIN_ROOT points to temp dir with .env -> loaded"
    else
        fail "T389-1: AGENTS_MAIN_ROOT points to temp dir with .env -> loaded (rc=$rc, out=$out)"
    fi
}

# T389-2: the realpath fallback (~/.claude/hooks/lib/... → real C:/git/agents/...)
# still exists and is still USED. Behavioural on script-checkout-root.js (C4 moved
# realpathSync there; a load-env.js grep would pass on a comment):
#   (a) enumeration — AGENTS_MAIN_ROOT unset yields a `realpath`-sourced candidate.
#   (b) selection — when the module anchor does NOT validate, the realpath
#       candidate is adopted (the symlinked-install case).
# Real symlink resolution on a live ~/.claude install stays the TL3 gap.
run_t389_2() {
    local label="T389-2: realpath candidate is enumerated and adopted (script-checkout-root.js)"
    require_source "$SCRIPT_CHECKOUT_ROOT/hooks/lib/script-checkout-root.js" "$label" || return
    local out rc
    out=$(run_with_timeout 5 env -u AGENTS_MAIN_ROOT node -e "
const script_checkout_root = require('$_SCRIPT_CHECKOUT_ROOT_NODE/hooks/lib/script-checkout-root.js');
const sources = script_checkout_root.scriptCheckoutRootCandidates().map((c) => c.source);
const real = '$_SCRIPT_CHECKOUT_ROOT_NODE';
// module candidate deliberately unresolvable -> only the realpath one can win.
const picked = script_checkout_root._resolveFromCandidates([
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
    if echo "$out" | grep -q "\"picked\":\"$_SCRIPT_CHECKOUT_ROOT_NODE\""; then
        pass "$label"
    else
        fail "$label (realpath candidate not adopted when the module anchor fails: $out)"
    fi
}

# _t389_3_probe <cwd> <load-env.js path> — loads with AGENTS_MAIN_ROOT unset from a neutral
# directory; prints {ok, canary} or THREW.
_t389_3_probe() {
    local cwd="$1" module="$2"
    cd "$cwd" || return 1
    run_with_timeout 5 env -u AGENTS_MAIN_ROOT -u CLAUDE_PROJECT_DIR node -e "
const {loadDefaultEnv} = require('$module');
let ok;
try { ok = loadDefaultEnv(); } catch (e) { process.stdout.write('THREW: ' + e.message); process.exit(0); }
process.stdout.write(JSON.stringify({ok, canary: process.env.T389_3_CANARY || ''}));
" 2>/dev/null
}

# T389-3: AGENTS_MAIN_ROOT unset and no .env at the checkout the reader runs from → a
# graceful no-op that REPORTS it loaded nothing. load-env.js runs from a throwaway copy
# of hooks/lib whose root has no .env: the root of this checkout may carry one, and then
# the state under test would never be reached. T389-3b is the control: the same copy
# with a .env answers true, so ok=false above is the absence and not a broken copy.
run_t389_3() {
    local label="T389-3: no AGENTS_MAIN_ROOT and no .env -> graceful no-op, loadDefaultEnv returns false"
    require_source "$LOAD_ENV" "$label" || return
    local root cwd copied_node out rc
    root="$(mktemp -d "$_ISOLATION_TMP_ROOT/t389-3-module.XXXXXX")"
    cwd="$(mktemp -d "$_ISOLATION_TMP_ROOT/t389-3-cwd.XXXXXX")"
    mkdir -p "$root/hooks/lib"
    if ! cp -r "$(dirname "$LOAD_ENV")/." "$root/hooks/lib/"; then
        fail "$label (fixture: could not copy hooks/lib)"
        return
    fi
    if [ -e "$root/.env" ]; then
        fail "$label (fixture: the copied root already has a .env)"
        return
    fi
    copied_node="$(np "$root")/hooks/lib/load-env.js"
    out="$(_t389_3_probe "$cwd" "$copied_node")"; rc=$?
    if [ $rc -eq 0 ] && [ "$out" = '{"ok":false,"canary":""}' ]; then
        pass "$label"
    else
        fail "$label (rc=$rc, out=$out)"
    fi
    printf 'T389_3_CANARY=present\n' > "$root/.env"
    out="$(_t389_3_probe "$cwd" "$copied_node")"; rc=$?
    if [ $rc -eq 0 ] && [ "$out" = '{"ok":true,"canary":"present"}' ]; then
        pass "T389-3b: control — the same copy with a .env loads it and returns true"
    else
        fail "T389-3b: control — the same copy with a .env loads it and returns true (rc=$rc, out=$out)"
    fi
    rm -rf "$root" "$cwd"
}

# T389-4: When KEY="" (empty string) exists in process.env, loadDefaultEnv
# MUST overwrite it with the .env value. The fix in load-env.js uses
# `if (process.env[key])` so empty-string is falsy and does NOT shadow the
# .env value. Windows propagates VAR="" into child processes even when the
# parent shell shows it as unset, so this is a real-world Windows scenario.
run_t389_4() {
    require_source "$LOAD_ENV" "T389-4: empty-string process.env does NOT shadow .env value" || return
    local tmp out rc
    tmp="$(mktemp -d "$_ISOLATION_TMP_ROOT/t389.XXXXXX")"
    printf 'LOAD_ENV_TEST_KEY=fromfile\n' > "$tmp/.env"
    out=$(AGENTS_MAIN_ROOT="$tmp" LOAD_ENV_TEST_KEY="" run_with_timeout 5 node -e "
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
    tmp="$(mktemp -d "$_ISOLATION_TMP_ROOT/t389.XXXXXX")"
    printf 'LOAD_ENV_TEST_KEY=fromfile\n' > "$tmp/.env"
    out=$(AGENTS_MAIN_ROOT="$tmp" LOAD_ENV_TEST_KEY="fromenv" run_with_timeout 5 node -e "
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
    tmp="$(mktemp -d "$_ISOLATION_TMP_ROOT/t389.XXXXXX")"
    printf 'LOAD_ENV_TEST_SECRET=fromfile\n' > "$tmp/.env"
    out_stderr=$(AGENTS_MAIN_ROOT="$tmp" AGENTS_HOOK_DEBUG=1 LOAD_ENV_TEST_SECRET="supersecret" \
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
    # Two separate claims: the line naming the key must EXIST (silence would make the
    # leak check below vacuous), and neither value may appear anywhere on stderr.
    if echo "$out_stderr" | grep -q "LOAD_ENV_TEST_SECRET"; then
        pass "T389-6: the debug output has a line naming the shadowed key"
    else
        fail "T389-6: the debug output has a line naming the shadowed key (stderr: $out_stderr)"
    fi
    if echo "$out_stderr" | grep -q -e "supersecret" -e "fromfile"; then
        fail "T389-6: stderr carries a value of the shadowed key (must not leak): $out_stderr"
    else
        pass "T389-6: the debug output carries neither the exported nor the .env value"
    fi
}

# shellcheck source=./fix-389-load-env-default-fallback/agents-main-root-cases.sh
. "$(dirname "${BASH_SOURCE[0]}")/fix-389-load-env-default-fallback/agents-main-root-cases.sh"
# shellcheck source=./fix-389-load-env-default-fallback/resolve-config-var-cases.sh
. "$(dirname "${BASH_SOURCE[0]}")/fix-389-load-env-default-fallback/resolve-config-var-cases.sh"

case_begin "t389-1-agents-main-root-env-loaded" "hooks/lib/load-env.js"
run_t389_1
case_end
case_begin "t389-2-realpath-candidate-adopted" "hooks/lib/script-checkout-root.js"
run_t389_2
case_end
case_begin "t389-3-no-env-graceful-noop" "hooks/lib/load-env.js"
run_t389_3
case_end
case_begin "t389-4-empty-env-overwritten-by-dotenv" "hooks/lib/load-env.js"
run_t389_4
case_end
case_begin "t389-5-nonempty-env-wins-over-dotenv" "hooks/lib/load-env.js"
run_t389_5
case_end
case_begin "t389-6-debug-logs-key-not-value" "hooks/lib/load-env.js"
run_t389_6
case_end
case_begin "t389-7-explicit-agents-main-root-no-fallthrough" "hooks/lib/load-env.js"
run_t389_7
case_end
case_begin "t389-8-windows-posix-agents-main-root-normalized" "hooks/lib/load-env.js"
run_t389_8
case_end
case_begin "cv-1-process-env-beats-dotenv" "hooks/lib/load-env.js"
run_cv_1
case_end
case_begin "cv-2-empty-env-falls-to-dotenv-with-overlay" "hooks/lib/load-env.js"
run_cv_2
case_end
case_begin "cv-3-repo-root-reads-effective-env" "hooks/lib/load-env.js"
run_cv_3
case_end
case_begin "cv-4-absent-everywhere-returns-default" "hooks/lib/load-env.js"
run_cv_4
case_end
case_begin "cv-5-load-fail-sets-flag" "hooks/lib/load-env.js"
run_cv_5
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
