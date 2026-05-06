#!/bin/bash
# tests/feature-parallel-sessions-worktree-config.sh
#
# Implementation complete. Tests verify the production contract.

# Implementation tracked in: ~/.claude/plans/intent-20260505-211305-detail.md
#
# Targets: hooks/lib/worktree-config.js

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
MODULE="${_AGENTS_DIR_NODE}/hooks/lib/worktree-config.js"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMPDIR_BASE="$(node -e "
const os=require('os'),path=require('path'),fs=require('fs');
const d=path.join(os.tmpdir(),'pst-cfg-'+process.pid).replace(/\\\\/g,'/');
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

# Run a node snippet that exercises worktree-config and prints "ok" or "ERROR:..."
# Args: env-VAR=val ... -- <node-snippet>
node_run() {
    local snippet="$1"
    run_with_timeout 30 node -e "
      try {
        const c = require('$MODULE');
        $snippet
      } catch (e) {
        console.log('ERROR:' + e.message);
      }
    " 2>/dev/null
}

# ============ getWorktreeBaseDir ============

test_base_dir_env_set() {
    # Verify that getWorktreeBaseDir() returns exactly what's in WORKTREE_BASE_DIR,
    # comparing inside node to avoid MSYS2 path auto-conversion on Windows.
    local verdict
    verdict="$(WORKTREE_BASE_DIR=/tmp/wt run_with_timeout 30 node -e "
      try {
        const c = require('$MODULE');
        const env = process.env.WORKTREE_BASE_DIR;
        const got = c.getWorktreeBaseDir();
        console.log(env === got ? 'ok' : 'MISMATCH:env=' + env + ' got=' + got);
      } catch (e) { console.log('ERROR:' + e.message); }
    " 2>/dev/null)"
    if [ "$verdict" = "ok" ]; then
        pass "WORKTREE_BASE_DIR set returns env value"
    else
        fail "$verdict"
    fi
}

test_base_dir_unset_default() {
    # Compare inside node to avoid backslash shell-escaping issues on Windows
    local verdict
    verdict="$(run_with_timeout 30 env -u WORKTREE_BASE_DIR node -e "
      try {
        const os=require('os'),path=require('path');
        const c = require('$MODULE');
        const actual   = c.getWorktreeBaseDir();
        const expected = path.join(os.homedir(),'git','worktrees');
        console.log(actual.toLowerCase() === expected.toLowerCase() ? 'ok' : 'MISMATCH:' + actual);
      } catch (e) { console.log('ERROR:' + e.message); }
    " 2>/dev/null)"
    if [ "$verdict" = "ok" ]; then
        pass "unset WORKTREE_BASE_DIR returns ~/git/worktrees"
    else
        fail "got: $verdict"
    fi
}

test_base_dir_idempotent() {
    # Compare both calls inside node to avoid MSYS2 path auto-conversion on Windows.
    local verdict
    verdict="$(WORKTREE_BASE_DIR=/tmp/wt run_with_timeout 30 node -e "
      try {
        const c = require('$MODULE');
        const env = process.env.WORKTREE_BASE_DIR;
        const a = c.getWorktreeBaseDir();
        const b = c.getWorktreeBaseDir();
        const ok = (a === b) && (a === env);
        console.log(ok ? 'ok' : 'MISMATCH:a=' + a + ' b=' + b + ' env=' + env);
      } catch (e) { console.log('ERROR:'+e.message); }
    " 2>/dev/null)"
    if [ "$verdict" = "ok" ]; then
        pass "getWorktreeBaseDir idempotent"
    else
        fail "non-idempotent: $verdict"
    fi
}

# ============ validateTaskName: valid ============

assert_validate_pass() {
    local name="$1"
    local result
    result="$(run_with_timeout 30 node -e "
      try {
        const c = require('$MODULE');
        const r = c.validateTaskName(process.argv[1]);
        console.log('OK:' + r);
      } catch (e) {
        console.log('THROW:' + e.message);
      }
    " -- "$name" 2>/dev/null)"
    case "$result" in
        OK:*)
            pass "validateTaskName('$name') passes"
            ;;
        *)
            fail "validateTaskName('$name') expected pass, got: $result"
            ;;
    esac
}

assert_validate_throws() {
    local label="$1" expr="$2"
    local result
    result="$(run_with_timeout 30 node -e "
      try {
        const c = require('$MODULE');
        const v = $expr;
        const r = c.validateTaskName(v);
        console.log('OK:' + r);
      } catch (e) {
        console.log('THROW:' + e.message);
      }
    " 2>/dev/null)"
    case "$result" in
        THROW:Cannot\ find\ module*)
            fail "validateTaskName($label): module not implemented (TDD red)"
            ;;
        THROW:*)
            pass "validateTaskName($label) throws"
            ;;
        *)
            fail "validateTaskName($label) expected throw, got: $result"
            ;;
    esac
}

test_validate_valid_names() {
    assert_validate_pass "aws-iam"
    assert_validate_pass "foo_bar"
    assert_validate_pass "Foo-Bar"
    assert_validate_pass "foo123"
    assert_validate_pass "---"
    # Single character names
    assert_validate_pass "a"
    assert_validate_pass "1"
    assert_validate_pass "-"
    assert_validate_pass "_"
    # Pure numeric
    assert_validate_pass "123"
    assert_validate_pass "000"
    # Leading digit
    assert_validate_pass "1foo"
    assert_validate_pass "9bar"
    # Double-dash prefix (not special at file level)
    assert_validate_pass "--foo"
}

test_validate_long_name() {
    local long; long="$(printf 'a%.0s' $(seq 1 1000))"
    assert_validate_pass "$long"
}

# ============ validateTaskName: invalid ============

test_validate_empty_throws() {
    assert_validate_throws "''" "''"
}

test_validate_null_throws() {
    assert_validate_throws "null" "null"
}

test_validate_undefined_throws() {
    assert_validate_throws "undefined" "undefined"
}

test_validate_security_throws() {
    assert_validate_throws "'../escape'" "'../escape'"
    assert_validate_throws "'foo/bar'" "'foo/bar'"
    assert_validate_throws "'foo\\\\bar'" "'foo\\\\bar'"
    assert_validate_throws "';rm -rf /'" "';rm -rf /'"
    assert_validate_throws "'\`cmd\`'" "'\`cmd\`'"
    assert_validate_throws "'foo;ls'" "'foo;ls'"
    assert_validate_throws "'foo bar'" "'foo bar'"
    assert_validate_throws "'foo\\nbar'" "'foo\\nbar'"
    assert_validate_throws "'.hidden'" "'.hidden'"
    assert_validate_throws "'foo.'" "'foo.'"
}

test_validate_extended_security_throws() {
    # Glob expansion characters
    assert_validate_throws "'foo{bar}' (brace)" "'foo{bar}'"
    assert_validate_throws "'foo[bar]' (bracket)" "'foo[bar]'"
    assert_validate_throws "'foo*bar' (glob)" "'foo*bar'"
    # Environment variable expansion
    assert_validate_throws "'\$HOME' (dollar-var)" "'\$HOME'"
    assert_validate_throws "'foo\${VAR}' (dollar-brace)" "'foo\${VAR}'"
    # Tab character (not same as space, distinct rejection)
    assert_validate_throws "'foo\\tbar' (tab)" "'foo\\tbar'"
    # Non-ASCII (unicode) — rejected by [a-zA-Z0-9_-]+ pattern
    assert_validate_throws "'café' (non-ASCII)" "'café'"
    assert_validate_throws "'北京' (CJK)" "'北京'"
}

# ============ buildWorktreePath ============

test_build_valid() {
    # Compute both expected and actual inside a single node process to avoid
    # shell backslash interpolation issues on Windows (path.join returns '\' on win32).
    local verdict
    verdict="$(run_with_timeout 30 env -u WORKTREE_BASE_DIR node -e "
      try {
        const os=require('os'),path=require('path');
        const c = require('$MODULE');
        const actual   = c.buildWorktreePath('aws-iam','agents');
        const expected = path.join(os.homedir(),'git','worktrees','aws-iam','agents');
        console.log(actual.toLowerCase() === expected.toLowerCase() ? 'ok' : 'MISMATCH:actual=' + actual + ' expected=' + expected);
      } catch (e) { console.log('THROW:'+e.message); }
    " 2>/dev/null)"
    if [ "$verdict" = "ok" ]; then
        pass "buildWorktreePath('aws-iam','agents') joins path"
    else
        fail "buildWorktreePath: $verdict"
    fi
}

test_build_invalid_taskname_throws() {
    local result
    result="$(run_with_timeout 30 node -e "
      try {
        const c = require('$MODULE');
        const r = c.buildWorktreePath('foo/bar','agents');
        console.log('OK:'+r);
      } catch (e) { console.log('THROW:'+e.message); }
    " 2>/dev/null)"
    case "$result" in
        THROW:Cannot\ find\ module*)
            fail "buildWorktreePath: module not implemented (TDD red)"
            ;;
        THROW:*)
            pass "buildWorktreePath throws on invalid taskName"
            ;;
        *)
            fail "expected throw, got: $result"
            ;;
    esac
}

# ============ Run all ============

test_base_dir_env_set
test_base_dir_unset_default
test_base_dir_idempotent
test_validate_valid_names
test_validate_long_name
test_validate_empty_throws
test_validate_null_throws
test_validate_undefined_throws
test_validate_security_throws
test_validate_extended_security_throws
test_build_valid
test_build_invalid_taskname_throws

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $FAIL
