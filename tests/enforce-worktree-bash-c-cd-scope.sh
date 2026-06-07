#!/bin/bash
# tests/enforce-worktree-bash-c-cd-scope.sh
# Tests: hooks/lib/parse-git-args.js, hooks/enforce-worktree/git-repo-detection.js
# Tags: enforce-worktree, bash-c, cd, scope, worktree, git-repo-detection
#
# Tests for #566: findRepoRootForBash() must extract the `cd` target from
# `bash -c '...'` body via parseCdCommandInInterpreter(), so the linked
# worktree path is correctly resolved as the repo root.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
PARSE_GIT_ARGS_MODULE="${_AGENTS_DIR_NODE}/hooks/lib/parse-git-args.js"
GIT_REPO_DETECTION_MODULE="${_AGENTS_DIR_NODE}/hooks/enforce-worktree/git-repo-detection.js"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        "$@"
    fi
}

call_parse_cd_interp() {
    run_with_timeout 30 node -e "
      try {
        const m = require('$PARSE_GIT_ARGS_MODULE');
        if (typeof m.parseCdCommandInInterpreter !== 'function') {
          process.stdout.write('NOT_EXPORTED');
          process.exit(0);
        }
        const r = m.parseCdCommandInInterpreter(process.argv[1]);
        console.log(r === null ? '__NULL__' : r);
      } catch(e) { console.log('ERROR: ' + e.message); }
    " -- "$1" 2>/dev/null
}

call_find_repo_root() {
    run_with_timeout 30 node -e "
      try {
        const m = require('$GIT_REPO_DETECTION_MODULE');
        const r = m.findRepoRootForBash(process.argv[1]);
        console.log(r === null ? '__NULL__' : r);
      } catch(e) { console.log('ERROR: ' + e.message); }
    " -- "$1" 2>/dev/null
}

# ─────────────────────────────────────────────────────────────────────────────
# parseCdCommandInInterpreter unit tests
# ─────────────────────────────────────────────────────────────────────────────

assert_parse_cd_interp() {
    local desc="$1" input="$2" expected="$3"
    local got
    got="$(call_parse_cd_interp "$input")"
    if [ "$got" = "NOT_EXPORTED" ]; then
        fail "$desc: parseCdCommandInInterpreter NOT_EXPORTED (RED before #566 impl)"
        return
    fi
    if [ "$got" = "$expected" ]; then
        pass "$desc -> $got"
    else
        fail "$desc: expected '$expected', got '$got'"
    fi
}

test_parse_cd_interp_basic() {
    assert_parse_cd_interp "bash -c 'cd /abs/path && ls'" \
        "bash -c 'cd /abs/path && ls'" "/abs/path"
    assert_parse_cd_interp "sh -c 'cd /abs/path && ls'" \
        "sh -c 'cd /abs/path && ls'" "/abs/path"
    assert_parse_cd_interp "bash.exe -c 'cd /abs/path && ls'" \
        "bash.exe -c 'cd /abs/path && ls'" "/abs/path"
    assert_parse_cd_interp "zsh -c 'cd /abs/path && ls'" \
        "zsh -c 'cd /abs/path && ls'" "/abs/path"
    assert_parse_cd_interp "dash -c 'cd /abs/path && ls'" \
        "dash -c 'cd /abs/path && ls'" "/abs/path"
    # #566 codex HIGH: -lc (login shell) and other -*c* flag combinations
    # must be accepted, mirroring isReadOnlyInterpreterC()'s -\w*c\w* regex.
    assert_parse_cd_interp "bash -lc 'cd /abs/path && ls' (login shell)" \
        "bash -lc 'cd /abs/path && ls'" "/abs/path"
    assert_parse_cd_interp "bash -xc 'cd /abs/path && ls' (xtrace)" \
        "bash -xc 'cd /abs/path && ls'" "/abs/path"
    assert_parse_cd_interp "bash -cx 'cd /abs/path && ls' (c then x)" \
        "bash -cx 'cd /abs/path && ls'" "/abs/path"
    assert_parse_cd_interp "bash -lxc 'cd /abs/path && ls' (login+xtrace+c)" \
        "bash -lxc 'cd /abs/path && ls'" "/abs/path"
}

test_parse_cd_interp_fail_closed() {
    assert_parse_cd_interp "bash -c 'cd \$X && ls' (env-var)" \
        "bash -c 'cd \$X && ls'" "__NULL__"
    assert_parse_cd_interp "bash -c 'cd ~/foo && ls' (tilde)" \
        "bash -c 'cd ~/foo && ls'" "__NULL__"
    assert_parse_cd_interp "bash -c 'cd ./rel && ls' (relative path)" \
        "bash -c 'cd ./rel && ls'" "__NULL__"
    assert_parse_cd_interp "bash -c 'cd foo && ls' (bare relative name)" \
        "bash -c 'cd foo && ls'" "__NULL__"
    assert_parse_cd_interp "pwsh -Command 'cd /abs && ls' (not accepted)" \
        "pwsh -Command 'cd /abs && ls'" "__NULL__"
    assert_parse_cd_interp "fish -c 'cd /abs && ls' (fail-safe)" \
        "fish -c 'cd /abs && ls'" "__NULL__"
    assert_parse_cd_interp "python -c 'cd /abs && ls' (non-shell)" \
        "python -c 'cd /abs && ls'" "__NULL__"
}

# ─────────────────────────────────────────────────────────────────────────────
# findRepoRootForBash integration tests with real git fixtures
# ─────────────────────────────────────────────────────────────────────────────

test_find_repo_root_bash_c_cd() {
    local tmpdir
    tmpdir="$(mktemp -d)" || { fail "mktemp failed"; return; }

    # Create a main git repo
    local main_repo="$tmpdir/main-repo"
    mkdir -p "$main_repo"
    git -C "$main_repo" init -q
    # Need git user.email/name for commit; fall back if unset
    git -C "$main_repo" -c user.email=test@example.com -c user.name=test \
        commit --allow-empty -m "init" -q 2>/dev/null

    # Create a linked worktree
    local wt_dir="$tmpdir/linked-wt"
    git -C "$main_repo" worktree add "$wt_dir" -b "test-branch" -q 2>/dev/null

    # Convert wt_dir to Node.js-compatible path on Windows
    local wt_node_path="$wt_dir"
    if command -v cygpath >/dev/null 2>&1; then
        wt_node_path="$(cygpath -m "$wt_dir")"
    fi

    # #566 codex MEDIUM#7: assert the exact linked-worktree root, not just non-null.
    # Non-null could mean the function fell back to process.cwd() and the regression
    # would silently re-emerge. Normalize path separators for cross-platform compare.
    local expected_root="$wt_node_path"
    # git rev-parse --show-toplevel returns a real (resolved) path. mktemp may return
    # a symlink path on macOS. Resolve via node to a canonical form.
    expected_root="$(run_with_timeout 30 node -e "
      try { console.log(require('fs').realpathSync(process.argv[1]).replace(/\\\\/g, '/')); }
      catch(e) { console.log(process.argv[1]); }
    " -- "$wt_node_path" 2>/dev/null)"

    local result
    result="$(run_with_timeout 30 node -e "
      try {
        const m = require('$GIT_REPO_DETECTION_MODULE');
        const cmd = \"bash -c 'cd \" + process.argv[1] + \" && git status'\";
        const r = m.findRepoRootForBash(cmd);
        console.log(r ? r.replace(/\\\\/g, '/') : '__NULL__');
      } catch(e) { console.log('ERROR: ' + e.message); }
    " -- "$wt_node_path" 2>/dev/null)"

    if [ "$result" = "__NULL__" ] || [[ "$result" == "ERROR:"* ]]; then
        fail "findRepoRootForBash(bash -c cd linked-wt): expected '$expected_root', got '$result'"
    elif [ "$result" = "$expected_root" ]; then
        pass "findRepoRootForBash(bash -c 'cd <linked-wt> && git status') -> '$result' (exact match)"
    else
        fail "findRepoRootForBash(bash -c cd linked-wt): expected '$expected_root', got '$result' (likely fell back to cwd)"
    fi

    # #566 HIGH: bash -lc must also resolve correctly (login-shell form).
    result="$(run_with_timeout 30 node -e "
      try {
        const m = require('$GIT_REPO_DETECTION_MODULE');
        const cmd = \"bash -lc 'cd \" + process.argv[1] + \" && git status'\";
        const r = m.findRepoRootForBash(cmd);
        console.log(r ? r.replace(/\\\\/g, '/') : '__NULL__');
      } catch(e) { console.log('ERROR: ' + e.message); }
    " -- "$wt_node_path" 2>/dev/null)"
    if [ "$result" = "$expected_root" ]; then
        pass "findRepoRootForBash(bash -lc 'cd <linked-wt> && git status') -> '$result' (login-shell form)"
    else
        fail "findRepoRootForBash(bash -lc cd linked-wt): expected '$expected_root', got '$result'"
    fi

    # Regression: git -C path
    result="$(run_with_timeout 30 node -e "
      try {
        const m = require('$GIT_REPO_DETECTION_MODULE');
        const cmd = 'git -C ' + process.argv[1] + ' status';
        const r = m.findRepoRootForBash(cmd);
        console.log(r || '__NULL__');
      } catch(e) { console.log('ERROR: ' + e.message); }
    " -- "$wt_node_path" 2>/dev/null)"
    if [ "$result" = "__NULL__" ] || [[ "$result" == "ERROR:"* ]]; then
        fail "findRepoRootForBash(git -C <linked-wt>): regression — expected non-null root, got '$result'"
    else
        pass "findRepoRootForBash('git -C <linked-wt> status') -> '$result' (regression: -C path still works)"
    fi

    # Regression: bare cd (parseCdCommand existing behavior)
    result="$(run_with_timeout 30 node -e "
      try {
        const m = require('$GIT_REPO_DETECTION_MODULE');
        const cmd = 'cd ' + process.argv[1] + ' && git status';
        const r = m.findRepoRootForBash(cmd);
        console.log(r || '__NULL__');
      } catch(e) { console.log('ERROR: ' + e.message); }
    " -- "$wt_node_path" 2>/dev/null)"
    if [ "$result" = "__NULL__" ] || [[ "$result" == "ERROR:"* ]]; then
        fail "findRepoRootForBash(cd <linked-wt>): regression — expected non-null root, got '$result'"
    else
        pass "findRepoRootForBash('cd <linked-wt> && git status') -> '$result' (regression: bare cd still works)"
    fi

    # Cleanup
    rm -rf "$tmpdir" 2>/dev/null || true
}

test_find_repo_root_fail_closed() {
    # Env-var: must not crash
    local result
    result="$(call_find_repo_root "bash -c 'cd \$X && ls'")"
    if [[ "$result" == "ERROR:"* ]]; then
        fail "findRepoRootForBash(bash -c 'cd \$X && ls') crashed: $result"
    else
        pass "findRepoRootForBash(bash -c 'cd \$X && ls') -> '$result' (no crash)"
    fi

    # Tilde: must not crash
    result="$(call_find_repo_root "bash -c 'cd ~/foo && ls'")"
    if [[ "$result" == "ERROR:"* ]]; then
        fail "findRepoRootForBash(bash -c 'cd ~/foo && ls') crashed: $result"
    else
        pass "findRepoRootForBash(bash -c 'cd ~/foo && ls') -> '$result' (no crash)"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Run all
# ─────────────────────────────────────────────────────────────────────────────

test_parse_cd_interp_basic
test_parse_cd_interp_fail_closed
test_find_repo_root_bash_c_cd
test_find_repo_root_fail_closed

echo ""
echo "─────────────────────────────────────────"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
