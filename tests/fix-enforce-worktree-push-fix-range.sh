#!/bin/bash
# tests/fix-enforce-worktree-push-fix-range.sh
#
# Integration tests for hooks/enforce-worktree.js — Fix 1:
# isAllowedPushAllExcluded(cmd, repoRoot, excludePatterns)
#
# `git push` should be allowed from the main worktree when ALL files in
# ALL outgoing commits (the `<upstream>..HEAD` range, not just HEAD) are
# covered by ENFORCE_WORKTREE_EXCLUDE patterns.
#
# Range scan uses `git log --name-only --pretty=format: <upstream>..HEAD`.
#
# TDD note: Fix 1 is not yet implemented in the hook source. Tests whose
# expected decision is ALLOW will currently FAIL RED. Tests whose expected
# decision is BLOCK should already pass — those exercise the existing
# fail-closed paths in the hook.

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
const d=path.join(os.tmpdir(),'push-fix-range-'+process.pid).replace(/\\\\/g,'/');
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

# Returns 0 if allow, 1 if block.
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

# Create a "fake remote" bare-ish repo to act as origin.
# Returns the remote path (norm_path-converted).
setup_remote() {
    local name="$1"
    local remote="$TMPDIR_BASE/$name-remote"
    mkdir -p "$remote"
    git -C "$remote" init -q --bare -b main
    norm_path "$remote"
}

# Setup a main checkout with origin remote, initial README on main pushed to origin,
# so origin/main is set and tracking is configured.
# Returns the local repo path (norm_path-converted).
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
    # Push initial commit to origin/main so the upstream is established.
    git -C "$repo" push -q origin main >/dev/null 2>&1
    # Make the local main track origin/main.
    git -C "$repo" branch --set-upstream-to=origin/main main >/dev/null 2>&1 || true
    norm_path "$repo"
}

# Run guard for a Bash command from a cwd, with optional env vars.
# Args: cmd cwd [env-VAR=val ...]
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
# ALLOW cases (expected RED until Fix 1 is implemented)
# ─────────────────────────────────────────────────────────────────────────────

test_push_no_outgoing_commits_allows() {
    require_guard "test_push_no_outgoing_commits_allows" || return
    # Repo state: origin/main == HEAD (no outgoing commits).
    local repo; repo="$(setup_main_checkout_with_remote "no-outgoing")"
    local out; out="$(run_bash_guard "git push" "$repo" \
        ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_EXCLUDE=**/docs/**")"
    if guard_decision "$out"; then
        pass "Fix 1: push with no outgoing commits allows"
    else
        fail "Fix 1: push with no outgoing commits should allow ($out)"
    fi
}

test_push_all_commits_excluded_allows() {
    require_guard "test_push_all_commits_excluded_allows" || return
    local repo; repo="$(setup_main_checkout_with_remote "all-excl")"
    # Two commits, each touching only docs/* — all covered by EXCLUDE=docs/**.
    echo "a" > "$repo/docs/a.md"
    git -C "$repo" add docs/a.md
    git -C "$repo" commit -q -m "doc a"
    echo "b" > "$repo/docs/b.md"
    git -C "$repo" add docs/b.md
    git -C "$repo" commit -q -m "doc b"
    local out; out="$(run_bash_guard "git push" "$repo" \
        ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_EXCLUDE=**/docs/**")"
    if guard_decision "$out"; then
        pass "Fix 1: push with all outgoing commits docs/** allows"
    else
        fail "Fix 1: push with all-docs outgoing commits should allow ($out)"
    fi
}

test_push_one_commit_non_excluded_blocks() {
    require_guard "test_push_one_commit_non_excluded_blocks" || return
    local repo; repo="$(setup_main_checkout_with_remote "one-src")"
    echo "a" > "$repo/docs/a.md"
    git -C "$repo" add docs/a.md
    git -C "$repo" commit -q -m "doc a"
    # This commit touches src/main.js — not covered by EXCLUDE=docs/**
    echo "code" > "$repo/src/main.js"
    git -C "$repo" add src/main.js
    git -C "$repo" commit -q -m "src code"
    local out; out="$(run_bash_guard "git push" "$repo" \
        ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_EXCLUDE=**/docs/**")"
    if guard_decision "$out"; then
        fail "Fix 1: push with non-excluded src commit should block ($out)"
    else
        pass "Fix 1: push with one src commit blocks"
    fi
}

test_push_non_excluded_then_reverted_blocks() {
    require_guard "test_push_non_excluded_then_reverted_blocks" || return
    # Commit N touches src/main.js; commit N+1 deletes it. Net HEAD diff is empty
    # vs upstream, but the RANGE scan must still see src/main.js in commit N.
    local repo; repo="$(setup_main_checkout_with_remote "src-reverted")"
    echo "code" > "$repo/src/main.js"
    git -C "$repo" add src/main.js
    git -C "$repo" commit -q -m "add src code"
    git -C "$repo" rm -q "src/main.js"
    git -C "$repo" commit -q -m "remove src code"
    local out; out="$(run_bash_guard "git push" "$repo" \
        ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_EXCLUDE=**/docs/**")"
    if guard_decision "$out"; then
        fail "Fix 1: push with deleted-but-historical src file should block ($out)"
    else
        pass "Fix 1: push with non-excluded file in range (deleted in N+1) blocks"
    fi
}

test_push_explicit_branch_allows() {
    require_guard "test_push_explicit_branch_allows" || return
    # `git push origin feature` — explicit refspec, range = origin/feature..HEAD.
    local repo; repo="$(setup_main_checkout_with_remote "explicit-br")"
    # Create feature branch, push it so origin/feature exists.
    git -C "$repo" switch -q -c feature
    git -C "$repo" push -q -u origin feature 2>/dev/null
    # New docs/** commit on feature.
    echo "a" > "$repo/docs/a.md"
    git -C "$repo" add docs/a.md
    git -C "$repo" commit -q -m "doc on feature"
    local out; out="$(run_bash_guard "git push origin feature" "$repo" \
        ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_EXCLUDE=**/docs/**")"
    if guard_decision "$out"; then
        pass "Fix 1: push origin <branch> with EXCLUDE-only commits allows"
    else
        fail "Fix 1: push origin <branch> EXCLUDE-only should allow ($out)"
    fi
}

test_push_no_args_with_upstream_allows() {
    require_guard "test_push_no_args_with_upstream_allows" || return
    # `git push` (no args) with upstream tracking set.
    local repo; repo="$(setup_main_checkout_with_remote "no-args-up")"
    echo "a" > "$repo/docs/a.md"
    git -C "$repo" add docs/a.md
    git -C "$repo" commit -q -m "doc a"
    local out; out="$(run_bash_guard "git push" "$repo" \
        ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_EXCLUDE=**/docs/**")"
    if guard_decision "$out"; then
        pass "Fix 1: bare 'git push' with upstream + EXCLUDE-only allows"
    else
        fail "Fix 1: bare 'git push' with upstream EXCLUDE-only should allow ($out)"
    fi
}

test_push_origin_only_with_tracking_allows() {
    require_guard "test_push_origin_only_with_tracking_allows" || return
    # `git push origin` (remote only, no branch). Single remote + tracking branch
    # → should resolve to origin/main..HEAD.
    local repo; repo="$(setup_main_checkout_with_remote "origin-only")"
    echo "a" > "$repo/docs/a.md"
    git -C "$repo" add docs/a.md
    git -C "$repo" commit -q -m "doc a"
    local out; out="$(run_bash_guard "git push origin" "$repo" \
        ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_EXCLUDE=**/docs/**")"
    if guard_decision "$out"; then
        pass "Fix 1: 'git push origin' with tracking + EXCLUDE-only allows"
    else
        fail "Fix 1: 'git push origin' EXCLUDE-only should allow ($out)"
    fi
}

test_push_u_origin_branch_allows() {
    require_guard "test_push_u_origin_branch_allows" || return
    # `git push -u origin feature` — explicit branch with -u flag.
    local repo; repo="$(setup_main_checkout_with_remote "u-origin-br")"
    git -C "$repo" switch -q -c feature
    git -C "$repo" push -q -u origin feature 2>/dev/null
    echo "a" > "$repo/docs/a.md"
    git -C "$repo" add docs/a.md
    git -C "$repo" commit -q -m "doc on feature"
    local out; out="$(run_bash_guard "git push -u origin feature" "$repo" \
        ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_EXCLUDE=**/docs/**")"
    if guard_decision "$out"; then
        pass "Fix 1: 'git push -u origin <branch>' with EXCLUDE-only allows"
    else
        fail "Fix 1: 'git push -u origin <branch>' EXCLUDE-only should allow ($out)"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# BLOCK cases — fail-closed inputs that the hook must reject regardless
# ─────────────────────────────────────────────────────────────────────────────

test_push_colon_refspec_blocks() {
    require_guard "test_push_colon_refspec_blocks" || return
    # `git push origin HEAD:main` — colon-mapped refspec.
    local repo; repo="$(setup_main_checkout_with_remote "colon-rs")"
    echo "a" > "$repo/docs/a.md"
    git -C "$repo" add docs/a.md
    git -C "$repo" commit -q -m "doc a"
    local out; out="$(run_bash_guard "git push origin HEAD:main" "$repo" \
        ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_EXCLUDE=**/docs/**")"
    if guard_decision "$out"; then
        fail "Fix 1: push with colon refspec should block (fail-closed) ($out)"
    else
        pass "Fix 1: push with colon refspec blocks (fail-closed)"
    fi
}

test_push_refs_heads_prefix_blocks() {
    require_guard "test_push_refs_heads_prefix_blocks" || return
    # `git push origin refs/heads/main` — full ref path.
    local repo; repo="$(setup_main_checkout_with_remote "refs-heads")"
    echo "a" > "$repo/docs/a.md"
    git -C "$repo" add docs/a.md
    git -C "$repo" commit -q -m "doc a"
    local out; out="$(run_bash_guard "git push origin refs/heads/main" "$repo" \
        ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_EXCLUDE=**/docs/**")"
    if guard_decision "$out"; then
        fail "Fix 1: push with refs/heads prefix should block ($out)"
    else
        pass "Fix 1: push with refs/heads prefix blocks (fail-closed)"
    fi
}

test_push_force_marker_blocks() {
    require_guard "test_push_force_marker_blocks" || return
    # `git push origin +feature` — '+' is the force-update marker.
    local repo; repo="$(setup_main_checkout_with_remote "force-mark")"
    git -C "$repo" switch -q -c feature
    git -C "$repo" push -q -u origin feature 2>/dev/null
    echo "a" > "$repo/docs/a.md"
    git -C "$repo" add docs/a.md
    git -C "$repo" commit -q -m "doc a"
    local out; out="$(run_bash_guard "git push origin +feature" "$repo" \
        ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_EXCLUDE=**/docs/**")"
    if guard_decision "$out"; then
        fail "Fix 1: push with '+' force marker should block ($out)"
    else
        pass "Fix 1: push with '+' force marker blocks (fail-closed)"
    fi
}

test_push_multiple_refspecs_blocks() {
    require_guard "test_push_multiple_refspecs_blocks" || return
    # `git push origin feature main` — multiple refspecs.
    local repo; repo="$(setup_main_checkout_with_remote "multi-rs")"
    git -C "$repo" switch -q -c feature
    git -C "$repo" push -q -u origin feature 2>/dev/null
    git -C "$repo" switch -q main
    echo "a" > "$repo/docs/a.md"
    git -C "$repo" add docs/a.md
    git -C "$repo" commit -q -m "doc a"
    local out; out="$(run_bash_guard "git push origin feature main" "$repo" \
        ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_EXCLUDE=**/docs/**")"
    if guard_decision "$out"; then
        fail "Fix 1: push with multiple refspecs should block ($out)"
    else
        pass "Fix 1: push with multiple refspecs blocks (fail-closed)"
    fi
}

test_push_u_origin_ambiguous_blocks() {
    require_guard "test_push_u_origin_ambiguous_blocks" || return
    # `git push -u origin` — -u without a branch is ambiguous in this context.
    # The hook should fail-closed when the explicit branch is missing.
    local repo; repo="$(setup_main_checkout_with_remote "u-ambig")"
    echo "a" > "$repo/docs/a.md"
    git -C "$repo" add docs/a.md
    git -C "$repo" commit -q -m "doc a"
    local out; out="$(run_bash_guard "git push -u origin" "$repo" \
        ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_EXCLUDE=**/docs/**")"
    if guard_decision "$out"; then
        fail "Fix 1: 'git push -u origin' (no branch) should block ($out)"
    else
        pass "Fix 1: 'git push -u origin' ambiguous blocks (fail-closed)"
    fi
}

test_push_no_upstream_blocks() {
    require_guard "test_push_no_upstream_blocks" || return
    # Repo with no upstream configured on the current branch.
    local remote_path; remote_path="$(setup_remote "no-upstream")"
    local repo="$TMPDIR_BASE/no-upstream"
    mkdir -p "$repo"
    git -C "$repo" init -q -b main
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    git -C "$repo" config core.hooksPath /dev/null
    git -C "$repo" remote add origin "$remote_path"
    mkdir -p "$repo/docs"
    echo "a" > "$repo/docs/a.md"
    git -C "$repo" add docs/a.md
    git -C "$repo" commit -q -m "doc a"
    # No `git push -u`/`git branch --set-upstream-to` — upstream is unset.
    repo="$(norm_path "$repo")"
    local out; out="$(run_bash_guard "git push" "$repo" \
        ENFORCE_WORKTREE=on "ENFORCE_WORKTREE_EXCLUDE=**/docs/**")"
    if guard_decision "$out"; then
        fail "Fix 1: 'git push' with no upstream should block ($out)"
    else
        pass "Fix 1: 'git push' with no upstream blocks (fail-closed)"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Run all
# ─────────────────────────────────────────────────────────────────────────────

# ALLOW cases (RED until Fix 1 implemented)
test_push_no_outgoing_commits_allows
test_push_all_commits_excluded_allows
test_push_explicit_branch_allows
test_push_no_args_with_upstream_allows
test_push_origin_only_with_tracking_allows
test_push_u_origin_branch_allows

# BLOCK cases (current hook already blocks)
test_push_one_commit_non_excluded_blocks
test_push_non_excluded_then_reverted_blocks
test_push_colon_refspec_blocks
test_push_refs_heads_prefix_blocks
test_push_force_marker_blocks
test_push_multiple_refspecs_blocks
test_push_u_origin_ambiguous_blocks
test_push_no_upstream_blocks

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"

if [ $FAIL -eq 0 ]; then exit 0; else exit 1; fi
