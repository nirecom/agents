#!/bin/bash
# Tests: hooks/enforce-worktree/git-repo-detection.js
# Tags: worktree, enforce, hook, cwd, scope:issue-specific
#
# Verifies that findRepoRootForBash resolves the repo root from the Bash tool's
# `cwd` parameter (NEW 2nd arg `toolCwd` in fix #286) when the command itself
# carries no `git -C <path>` and no payload `cd <path>`. Without this, repo-root
# resolution falls back to process.cwd() (the main worktree), so commands issued
# from a linked worktree are mis-attributed and over-blocked.
#
# Precedence contract (detail.md Step 5):
#   startDir = cArg || cdArg || toolCwd || process.cwd()

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
MODULE="${_AGENTS_DIR_NODE}/hooks/enforce-worktree/git-repo-detection.js"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

assert_fn_result() {
    local desc="$1" got="$2" expected="$3"
    if [ "$got" = "$expected" ]; then
        pass "$desc"
    else
        fail "$desc: expected '$expected', got '$got'"
    fi
}

# Build a throwaway git repo to serve as toolCwd. mktemp -d works on both
# Git Bash and POSIX; convert to forward-slash form for node consumption.
REPO_DIR="$(mktemp -d 2>/dev/null)"
if [ -z "$REPO_DIR" ]; then
    echo "ERROR: mktemp -d failed"; exit 1
fi
trap 'rm -rf "$REPO_DIR"' EXIT
git -C "$REPO_DIR" init -q >/dev/null 2>&1
# Node-friendly form (forward slashes; absolute).
if command -v cygpath >/dev/null 2>&1; then
    REPO_DIR_NODE="$(cygpath -m "$REPO_DIR")"
else
    REPO_DIR_NODE="$REPO_DIR"
fi
# Resolve the git toplevel of the temp repo for comparison (handles macOS
# /private symlink and any normalization git applies).
EXPECTED_ROOT="$(run_with_timeout 30 node -e "
  const { spawnSync } = require('child_process');
  const r = spawnSync('git', ['rev-parse', '--show-toplevel'],
    { cwd: process.argv[1], encoding: 'utf8' });
  process.stdout.write((r.stdout || '').trim());
" -- "$REPO_DIR_NODE" 2>/dev/null)"

# call_find CMD [TOOLCWD]
# Invokes findRepoRootForBash(cmd, toolCwd). When TOOLCWD is the literal token
# __UNDEF__, the 2nd arg is omitted entirely (single-arg call) so the
# pre-existing behavior is exercised.
call_find() {
    local cmd="$1"
    local toolcwd="${2:-__UNDEF__}"
    run_with_timeout 30 node -e "
      try {
        const m = require('$MODULE');
        const cmd = process.argv[1];
        const tc = process.argv[2];
        let r;
        if (tc === '__UNDEF__') r = m.findRepoRootForBash(cmd);
        else r = m.findRepoRootForBash(cmd, tc);
        console.log(String(r));
      } catch (e) { console.log('ERROR: ' + e.message); }
    " -- "$cmd" "$toolcwd" 2>/dev/null
}

# ─────────────────────────────────────────────────────────────────────────────
# L3 gap: these tests call findRepoRootForBash directly (unit/L2). They do not
# exercise the real PreToolUse event path where Claude Code supplies
# `toolInput.cwd` → `_toolCwd` → findRepoRootForBash inside enforce-worktree.js.
# An L3 test would issue a real Bash tool call from a linked worktree (with the
# tool's cwd set) inside a `claude -p` session and observe whether the hook
# resolves the repo root from that cwd rather than from process.cwd().
# ─────────────────────────────────────────────────────────────────────────────

test_toolcwd_reporoot() {
    # case (a) — NEW BEHAVIOR (will fail until git-repo-detection.js adds the
    # 2nd `toolCwd` arg): cmd has no -C and no cd; toolCwd is inside a git repo
    # → repo root resolves from toolCwd (NOT process.cwd()).
    assert_fn_result 'no -C/cd, toolCwd inside repo → repo root from toolCwd' \
        "$(call_find 'rm -rf foo' "$REPO_DIR_NODE")" \
        "$EXPECTED_ROOT"

    # case (b) — EXISTING BEHAVIOR (must pass now and after fix): no -C/cd and
    # no toolCwd (single-arg call) → falls back to process.cwd() resolution.
    # Asserted as not-throwing and not-empty; matches the pre-existing
    # single-arg contract (returns process.cwd()'s repo root or null).
    local single_arg
    single_arg="$(call_find 'rm -rf foo')"
    case "$single_arg" in
        ERROR:*|"")
            fail "no -C/cd, no toolCwd → single-arg fallback: got '$single_arg'" ;;
        *)
            pass 'no -C/cd, no toolCwd → single-arg fallback resolves (no throw)' ;;
    esac

    # case (c) — `-C <path>` takes precedence over toolCwd. cmd points -C at the
    # temp repo while toolCwd is a bogus path; the -C path must win. This holds
    # both NOW (only cArg is consulted) and AFTER the fix (cArg precedes
    # toolCwd in the fallback chain) — stable.
    assert_fn_result '-C <repo> with bogus toolCwd → -C path wins' \
        "$(call_find "git -C $REPO_DIR_NODE status" '/nonexistent/bogus/xyz')" \
        "$EXPECTED_ROOT"
}

test_toolcwd_reporoot

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
