#!/bin/bash
# tests/fix-enforce-worktree-hooks-bypass.sh
# Tests: hooks/enforce-worktree.js
# Tags: worktree, enforce, hook, bin, env
#
# Tests for hooks/enforce-worktree.js — detection of git-hooks bypass attempts.
#
# Post-fix the module exports `hasGitHooksBypass(cmd)` which returns true for
# any command that disables hooks via `-c core.hooksPath=...`, `--config-env`,
# `GIT_CONFIG_PARAMETERS`, or `GIT_CONFIG_COUNT/KEY_N/VALUE_N` env vars.
# The PreToolUse hook then blocks such commands even from linked worktrees.
#
# Before the fix:
#   - bypass_check returns "UNDEFINED" (export missing) -> unit tests FAIL.
#   - Integration tests still see "allow" on linked worktrees -> tests FAIL.
# Those failures are EXPECTED for write-first TDD.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
GUARD_JS="${_AGENTS_DIR_NODE}/hooks/enforce-worktree.js"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

require_guard() {
    if [ ! -f "$GUARD_JS" ]; then
        fail "$1 (enforce-worktree.js not present)"
        return 1
    fi
    return 0
}

TMPDIR_BASE="$(node -e "
const os=require('os'),path=require('path'),fs=require('fs');
const d=path.join(os.tmpdir(),'bypass-test-'+process.pid).replace(/\\\\/g,'/');
fs.mkdirSync(d,{recursive:true});
console.log(d);
" 2>/dev/null)"
[ -z "$TMPDIR_BASE" ] && TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        "$@"
    fi
}

# Returns "bypass", "clean", or "UNDEFINED" if export missing.
bypass_check() {
    run_with_timeout 30 node -e "
      const m = require('$GUARD_JS');
      const fn = m.hasGitHooksBypass;
      if (typeof fn !== 'function') { console.log('UNDEFINED'); process.exit(0); }
      console.log(fn(process.argv[1]) ? 'bypass' : 'clean');
    " -- "$1" 2>/dev/null
}

# Build a main repo + linked worktree. Echoes the (norm-pathed) worktree path.
setup_linked_worktree() {
    local name="$1"
    local main_repo="$TMPDIR_BASE/${name}-main"
    mkdir -p "$main_repo"
    git -C "$main_repo" init -q -b main
    git -C "$main_repo" config user.email "test@example.com"
    git -C "$main_repo" config user.name "Test"
    git -C "$main_repo" config core.hooksPath /dev/null
    echo "init" > "$main_repo/README.md"
    git -C "$main_repo" add README.md
    git -C "$main_repo" commit -q -m "initial"
    local wt="$TMPDIR_BASE/${name}-wt"
    git -C "$main_repo" worktree add -q -b "feature/$name" "$wt" 2>/dev/null
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$wt"
    else
        echo "$wt"
    fi
}

# Run the PreToolUse hook with a Bash payload. Echoes hook stdout (JSON).
run_hook() {
    local cmd="$1" cwd="$2"
    local payload
    payload=$(node -e 'const j={session_id:"test",tool_name:"Bash",tool_input:{command:process.argv[1]},cwd:process.argv[2]};console.log(JSON.stringify(j))' -- "$cmd" "$cwd" 2>/dev/null)
    (cd "$cwd" && echo "$payload" | \
        ENFORCE_WORKTREE=on AGENTS_CONFIG_DIR="$AGENTS_DIR" \
        run_with_timeout 30 node "$GUARD_JS" 2>/dev/null)
}

# 0 if allow, 1 if block.
guard_decision() {
    local out="$1"
    if echo "$out" | grep -q '"decision":"block"'; then
        return 1
    fi
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Helper: assert bypass / clean for unit cases.
expect_bypass() {
    local label="$1" cmd="$2"
    local r; r="$(bypass_check "$cmd")"
    if [ "$r" = "bypass" ]; then
        pass "$label"
    else
        fail "$label (expected bypass, got $r)"
    fi
}

expect_clean() {
    local label="$1" cmd="$2"
    local r; r="$(bypass_check "$cmd")"
    if [ "$r" = "clean" ]; then
        pass "$label"
    else
        fail "$label (expected clean, got $r)"
    fi
}

expect_block() {
    local label="$1" cmd="$2" cwd="$3"
    local out; out="$(run_hook "$cmd" "$cwd")"
    if guard_decision "$out"; then
        fail "$label (expected block, got allow: $out)"
    else
        pass "$label"
    fi
}

expect_allow() {
    local label="$1" cmd="$2" cwd="$3"
    local out; out="$(run_hook "$cmd" "$cwd")"
    if guard_decision "$out"; then
        pass "$label"
    else
        fail "$label (expected allow, got block: $out)"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Section U: Unit tests (hasGitHooksBypass) ==="
require_guard "Section U preflight" || { echo "Total: PASS=$PASS FAIL=$FAIL"; exit 1; }

# Should return bypass
expect_bypass "U1: -c core.hooksPath=/dev/null commit" \
    'git -c core.hooksPath=/dev/null commit -m "msg"'
expect_bypass "U2: -c core.hooksPath= commit (empty value)" \
    'git -c core.hooksPath= commit -m "msg"'
expect_bypass "U3: -c core.hooksPath=/tmp/empty commit" \
    'git -c core.hooksPath=/tmp/empty commit'
expect_bypass "U4: git -C /repo -c core.hooksPath=/dev/null commit" \
    'git -C /repo -c core.hooksPath=/dev/null commit'
expect_bypass "U5: -c \"core.hooksPath=/dev/null\" commit" \
    'git -c "core.hooksPath=/dev/null" commit'
expect_bypass "U6: -c '\''core.hooksPath=/dev/null'\'' commit" \
    "git -c 'core.hooksPath=/dev/null' commit"
expect_bypass "U7: case-insensitive CORE.HOOKSPATH" \
    'git -c CORE.HOOKSPATH=/dev/null commit'
expect_bypass "U8: -c core.hooksPath=/dev/null push" \
    'git -c core.hooksPath=/dev/null push'
expect_bypass "U9: --config-env=core.hooksPath=ENV_VAR" \
    'git --config-env=core.hooksPath=ENV_VAR commit'
expect_bypass "U10: --config-env core.hooksPath=ENV_VAR (space form)" \
    'git --config-env core.hooksPath=ENV_VAR commit'
expect_bypass "U11: -C /repo --config-env=core.hooksPath=X commit" \
    'git -C /repo --config-env=core.hooksPath=X commit'

# Should return clean
expect_clean "U12: literal in commit message (-m)" \
    'git commit -m "use git -c core.hooksPath=/dev/null"'
expect_clean "U13: literal core.hooksPath in -m text" \
    "git commit -m 'core.hooksPath=foo'"
expect_clean "U14: plain commit" \
    'git commit -m "msg"'
expect_clean "U15: unrelated -c (user.name)" \
    'git -c user.name=foo commit -m "msg"'
expect_clean "U16: git config core.hooksPath (subcommand, not -c)" \
    'git config core.hooksPath /dev/null'
expect_clean "U17: -ccore.hooksPath=... (attached, out-of-scope)" \
    'git -ccore.hooksPath=/dev/null commit'
expect_clean "U18: empty string" \
    ''
expect_clean "U19: --config-env literal in -m" \
    'git commit -m "see --config-env=core.hooksPath=X"'

# GIT_CONFIG_PARAMETERS env-var prefix forms
expect_bypass "U20: GIT_CONFIG_PARAMETERS unquoted" \
    "GIT_CONFIG_PARAMETERS='core.hooksPath=/dev/null' git commit"
expect_bypass "U21: GIT_CONFIG_PARAMETERS double-quoted" \
    'GIT_CONFIG_PARAMETERS="core.hooksPath=/dev/null" git commit'
expect_bypass "U22: GIT_CONFIG_PARAMETERS no quotes" \
    'GIT_CONFIG_PARAMETERS=core.hooksPath=/dev/null git commit'
expect_bypass "U23: GIT_CONFIG_PARAMETERS nested single quotes" \
    'GIT_CONFIG_PARAMETERS="'"'"'core.hooksPath=/dev/null'"'"'" git commit'

# GIT_CONFIG_COUNT/KEY_N/VALUE_N
expect_bypass "U24: GIT_CONFIG_COUNT=1 with KEY_0=core.hooksPath" \
    'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null git commit'
expect_bypass "U25: GIT_CONFIG_KEY_5=core.hooksPath (non-zero index)" \
    'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_5=core.hooksPath GIT_CONFIG_VALUE_5=/tmp git push'
expect_bypass "U26: GIT_CONFIG_COUNT=2 mixed entries (one is hooksPath)" \
    "GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0='core.hooksPath' GIT_CONFIG_VALUE_0=/dev/null GIT_CONFIG_KEY_1=user.name GIT_CONFIG_VALUE_1=foo git commit"
expect_bypass "U27: GIT_CONFIG_PARAMETERS list w/ hooksPath" \
    'GIT_CONFIG_PARAMETERS="'"'"'a=b'"'"' '"'"'core.hooksPath=/dev/null'"'"'" git commit'
expect_bypass "U28: GIT_CONFIG_KEY_0 with extra env after" \
    'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath FOO=bar git push'
expect_bypass "U28b: bare GIT_CONFIG_KEY_0 (no COUNT)" \
    'GIT_CONFIG_KEY_0=core.hooksPath git commit'
expect_bypass "U29: trailing command after literal echo" \
    'echo "GIT_CONFIG_PARAMETERS=other"; GIT_CONFIG_PARAMETERS='"'"'core.hooksPath=/dev/null'"'"' git commit'

# Clean: literal-text false positives
expect_clean "U30: -m literal with quoted -c" \
    "git commit -m 'use git -c \"core.hooksPath=/dev/null\"'"
expect_clean "U31: -m double-quoted with literal single quotes" \
    'git commit -m "use git -c '"'"'core.hooksPath=/dev/null'"'"'"'
expect_clean "U32: echo literal text (no git invocation)" \
    'echo "GIT_CONFIG_PARAMETERS='"'"'core.hooksPath=...'"'"' git"'
expect_clean "U33: GIT_CONFIG_PARAMETERS unrelated key" \
    "GIT_CONFIG_PARAMETERS='user.name=foo' git commit"
expect_clean "U34: GIT_CONFIG_KEY_0=user.name" \
    'GIT_CONFIG_KEY_0=user.name GIT_CONFIG_VALUE_0=foo git commit'
expect_clean "U35: literal key name inside -m" \
    "git commit -m 'GIT_CONFIG_KEY_0=core.hooksPath ...'"
expect_clean "U36: GIT_CONFIG_COUNT=0" \
    'GIT_CONFIG_COUNT=0 git commit'
expect_clean "U37: env-var prefixes echo, separator before git push" \
    "GIT_CONFIG_PARAMETERS='core.hooksPath=/dev/null' echo hi; git push"
expect_clean "U38: env-var after && does not prefix git" \
    'cmd1 && GIT_CONFIG_KEY_0=core.hooksPath foo'
expect_clean "U39: unrelated GIT_CONFIG_PARAMETERS + literal -m text" \
    "GIT_CONFIG_PARAMETERS='user.name=x' git commit -m \"core.hooksPath\""

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== Section I: Integration tests (hook + linked worktree) ==="
require_guard "Section I preflight" || { echo "Total: PASS=$PASS FAIL=$FAIL"; exit 1; }

INT_WT="$(setup_linked_worktree 'int')"
if [ -z "$INT_WT" ] || [ ! -d "$INT_WT" ]; then
    fail "Section I: linked worktree setup failed"
    echo "Total: PASS=$PASS FAIL=$FAIL"
    exit 1
fi

expect_block "I1: -c core.hooksPath=/dev/null commit blocks" \
    'git -c core.hooksPath=/dev/null commit -m "msg"' "$INT_WT"
expect_block "I2: -c core.hooksPath= (empty) blocks" \
    'git -c core.hooksPath= commit' "$INT_WT"
expect_block "I3: --config-env=core.hooksPath=X blocks" \
    'git --config-env=core.hooksPath=X commit' "$INT_WT"
expect_block "I4: -c \"core.hooksPath=/dev/null\" blocks" \
    'git -c "core.hooksPath=/dev/null" commit' "$INT_WT"
expect_allow "I5: literal in -m message allows" \
    'git commit -m "git -c core.hooksPath=/dev/null"' "$INT_WT"
expect_allow "I6: literal in nested-quote -m message allows" \
    "git commit -m 'use git -c \"core.hooksPath=/dev/null\"'" "$INT_WT"
expect_block "I7: GIT_CONFIG_PARAMETERS env bypass blocks" \
    "GIT_CONFIG_PARAMETERS='core.hooksPath=/dev/null' git commit" "$INT_WT"
expect_block "I8: GIT_CONFIG_COUNT/KEY_N env bypass blocks" \
    'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null git commit' "$INT_WT"
expect_block "I9: GIT_CONFIG_PARAMETERS list bypass blocks" \
    'GIT_CONFIG_PARAMETERS="'"'"'a=b'"'"' '"'"'core.hooksPath=/dev/null'"'"'" git commit' "$INT_WT"
expect_allow "I10: env-var prefixes echo (not git) allows" \
    "GIT_CONFIG_PARAMETERS='core.hooksPath=/dev/null' echo hi; git push" "$INT_WT"
expect_allow "I11: unrelated GIT_CONFIG_PARAMETERS + literal -m allows" \
    "GIT_CONFIG_PARAMETERS='user.name=x' git commit -m \"core.hooksPath\"" "$INT_WT"
expect_allow "I12: plain commit allows" \
    'git commit -m "msg"' "$INT_WT"
expect_allow "I13: git status (read) allows" \
    'git status' "$INT_WT"

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
if [ $FAIL -eq 0 ]; then exit 0; else exit 1; fi
