#!/bin/bash
# tests/fix-820-push-hardening.sh
# Tests: hooks/enforce-worktree.js, hooks/enforce-worktree/shared-cmd-utils.js
# Tags: worktree, enforce, hook, security, interpreter, rce
#
# Integration tests for fix #820: interpreter-wrapper + RCE-flag hardening
# in isAllowedPushAllExcluded.
#
# When a push command is wrapped in `bash -c '...'`, stripQuotedArgs collapses
# the body so hasShellChaining() returns false and the wrapper hides git push
# plus arbitrary shell metacharacters. rejectInterpreterAndChaining must catch
# this in isAllowedPushAllExcluded.
#
# RCE-flag cases: `-c core.sshCommand=…`, `--upload-pack=…`, `--receive-pack=…`
# enable command execution via the git transport. rejectRceGitFlags must catch
# these in the push predicate.

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

TMPDIR_BASE="$(node -e "
const os=require('os'),path=require('path'),fs=require('fs');
const d=path.join(os.tmpdir(),'push-820-hard-'+process.pid).replace(/\\\\/g,'/');
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

require_guard() {
    if [ ! -f "$GUARD_JS" ]; then
        fail "$1 (enforce-worktree.js not present)"
        return 1
    fi
    return 0
}

guard_decision() {
    local out="$1"
    if echo "$out" | grep -q '"decision":"block"'; then
        return 1
    fi
    return 0
}

norm_path() {
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$1"
    else
        echo "$1"
    fi
}

setup_remote() {
    local name="$1"
    local remote="$TMPDIR_BASE/$name-remote"
    mkdir -p "$remote"
    git -C "$remote" init -q --bare -b main
    norm_path "$remote"
}

setup_main_checkout_with_remote() {
    local name="$1"
    local remote_path; remote_path="$(setup_remote "$name")"
    local repo="$TMPDIR_BASE/$name"
    mkdir -p "$repo"
    git -C "$repo" init -q -b main
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    git -C "$repo" config core.hooksPath /dev/null
    git -C "$repo" remote add origin "$remote_path"
    mkdir -p "$repo/docs" "$repo/src"
    echo "init" > "$repo/README.md"
    git -C "$repo" add README.md
    git -C "$repo" commit -q -m "initial"
    git -C "$repo" push -q origin main >/dev/null 2>&1
    git -C "$repo" branch --set-upstream-to=origin/main main >/dev/null 2>&1 || true
    norm_path "$repo"
}

run_bash_guard() {
    local cmd="$1"; shift
    local cwd="$1"; shift
    local payload
    payload="$(node -e "
      const j = { session_id:'test', tool_name:'Bash', tool_input:{ command: process.argv[1] } };
      console.log(JSON.stringify(j));
    " -- "$cmd" 2>/dev/null)"
    if [ -n "$cwd" ]; then
        (cd "$cwd" && echo "$payload" | run_with_timeout 30 env "$@" node "$GUARD_JS" 2>/dev/null)
    else
        echo "$payload" | run_with_timeout 30 env "$@" node "$GUARD_JS" 2>/dev/null
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Interpreter-wrapper blocking
# ─────────────────────────────────────────────────────────────────────────────

test_push_bash_c_wrapper_blocks() {
    require_guard "test_push_bash_c_wrapper_blocks" || return
    local repo; repo="$(setup_main_checkout_with_remote "bash-c-push")"
    echo "a" > "$repo/docs/a.md"
    git -C "$repo" add docs/a.md
    git -C "$repo" commit -q -m "doc a"
    local out; out="$(run_bash_guard "bash -c 'git push origin main'" "$repo" \
        ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_EXCLUDE=**/docs/**")"
    if guard_decision "$out"; then
        fail "Fix #820: bash -c 'git push …' should block (interpreter wrapper) ($out)"
    else
        pass "Fix #820: bash -c 'git push origin main' blocks (interpreter wrapper)"
    fi
}

test_push_path_qualified_bash_c_wrapper_blocks() {
    require_guard "test_push_path_qualified_bash_c_wrapper_blocks" || return
    local repo; repo="$(setup_main_checkout_with_remote "binbash-c-push")"
    echo "a" > "$repo/docs/a.md"
    git -C "$repo" add docs/a.md
    git -C "$repo" commit -q -m "doc a"
    local out; out="$(run_bash_guard "/bin/bash -c 'git push'" "$repo" \
        ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_EXCLUDE=**/docs/**")"
    if guard_decision "$out"; then
        fail "Fix #820: /bin/bash -c 'git push' should block (path-qualified) ($out)"
    else
        pass "Fix #820: /bin/bash -c 'git push' blocks (path-qualified)"
    fi
}

test_push_env_bash_c_wrapper_blocks() {
    require_guard "test_push_env_bash_c_wrapper_blocks" || return
    local repo; repo="$(setup_main_checkout_with_remote "env-bash-c-push")"
    echo "a" > "$repo/docs/a.md"
    git -C "$repo" add docs/a.md
    git -C "$repo" commit -q -m "doc a"
    local out; out="$(run_bash_guard "env bash -c 'git push'" "$repo" \
        ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_EXCLUDE=**/docs/**")"
    if guard_decision "$out"; then
        fail "Fix #820: env bash -c 'git push' should block (launcher prefix) ($out)"
    else
        pass "Fix #820: env bash -c 'git push' blocks (launcher prefix)"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# RCE-flag blocking
# ─────────────────────────────────────────────────────────────────────────────

test_push_rce_c_sshcommand_blocks() {
    require_guard "test_push_rce_c_sshcommand_blocks" || return
    local repo; repo="$(setup_main_checkout_with_remote "rce-sshcmd-push")"
    echo "a" > "$repo/docs/a.md"
    git -C "$repo" add docs/a.md
    git -C "$repo" commit -q -m "doc a"
    local out; out="$(run_bash_guard "git -c core.sshCommand=curl push" "$repo" \
        ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_EXCLUDE=**/docs/**")"
    if guard_decision "$out"; then
        fail "Fix #820: git -c core.sshCommand=… push should block (RCE flag) ($out)"
    else
        pass "Fix #820: git -c core.sshCommand=curl push blocks (RCE flag)"
    fi
}

test_push_rce_upload_pack_blocks() {
    require_guard "test_push_rce_upload_pack_blocks" || return
    local repo; repo="$(setup_main_checkout_with_remote "rce-upload-push")"
    echo "a" > "$repo/docs/a.md"
    git -C "$repo" add docs/a.md
    git -C "$repo" commit -q -m "doc a"
    local out; out="$(run_bash_guard "git --upload-pack=cmd push" "$repo" \
        ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_EXCLUDE=**/docs/**")"
    if guard_decision "$out"; then
        fail "Fix #820: git --upload-pack=cmd push should block (RCE flag) ($out)"
    else
        pass "Fix #820: git --upload-pack=cmd push blocks (RCE flag)"
    fi
}

test_push_rce_receive_pack_blocks() {
    require_guard "test_push_rce_receive_pack_blocks" || return
    local repo; repo="$(setup_main_checkout_with_remote "rce-receive-push")"
    echo "a" > "$repo/docs/a.md"
    git -C "$repo" add docs/a.md
    git -C "$repo" commit -q -m "doc a"
    local out; out="$(run_bash_guard "git --receive-pack=cmd push" "$repo" \
        ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_EXCLUDE=**/docs/**")"
    if guard_decision "$out"; then
        fail "Fix #820: git --receive-pack=cmd push should block (RCE flag) ($out)"
    else
        pass "Fix #820: git --receive-pack=cmd push blocks (RCE flag)"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Regression pin
# ─────────────────────────────────────────────────────────────────────────────

test_push_plain_origin_main_still_allows() {
    require_guard "test_push_plain_origin_main_still_allows" || return
    local repo; repo="$(setup_main_checkout_with_remote "plain-orig-main")"
    echo "a" > "$repo/docs/a.md"
    git -C "$repo" add docs/a.md
    git -C "$repo" commit -q -m "doc a"
    local out; out="$(run_bash_guard "git push origin main" "$repo" \
        ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_EXCLUDE=**/docs/**")"
    if guard_decision "$out"; then
        pass "Fix #820 regression: git push origin main with docs-only commits still allows"
    else
        fail "Fix #820 regression: git push origin main should allow ($out)"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Run all
# ─────────────────────────────────────────────────────────────────────────────

test_push_bash_c_wrapper_blocks
test_push_path_qualified_bash_c_wrapper_blocks
test_push_env_bash_c_wrapper_blocks
test_push_rce_c_sshcommand_blocks
test_push_rce_upload_pack_blocks
test_push_rce_receive_pack_blocks
test_push_plain_origin_main_still_allows

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"

if [ $FAIL -eq 0 ]; then exit 0; else exit 1; fi
