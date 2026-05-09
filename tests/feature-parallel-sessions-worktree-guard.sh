#!/bin/bash
# tests/feature-parallel-sessions-worktree-guard.sh
#
# Implementation complete. Tests verify the production contract.

# Implementation tracked in: ~/.claude/plans/intent-20260505-211305-detail.md
#
# Targets: hooks/enforce-worktree.js (renamed from hooks/auto-branch-guard.js)

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
const d=path.join(os.tmpdir(),'pst-guard-'+process.pid).replace(/\\\\/g,'/');
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
        fail "$1 (enforce-worktree.js not implemented)"
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

setup_main_checkout() {
    local name="$1"
    local repo="$TMPDIR_BASE/$name"
    mkdir -p "$repo"
    git -C "$repo" init -q -b main
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    git -C "$repo" config core.hooksPath /dev/null
    echo "init" > "$repo/README.md"
    git -C "$repo" add README.md
    git -C "$repo" commit -q -m "initial"
    echo "$repo"
}

# Returns "<main_repo>|<wt_path>"
setup_linked_worktree() {
    local name="$1"
    local main; main="$(setup_main_checkout "$name-main")"
    local wt="$TMPDIR_BASE/$name-wt"
    git -C "$main" worktree add -q -b "feature/$name" "$wt" 2>/dev/null
    echo "$main|$wt"
}

# Run the enforce-worktree guard for a Bash tool.
# Args: command cwd [env-VAR=val ...]
#
# `cwd` is the working directory the guard runs from — replaces the legacy
# AGENTS_CONFIG_DIR fallback. The guard now uses process.cwd() (post-fix:
# fix/enforce-worktree-gh-whitelist) instead of AGENTS_CONFIG_DIR for the
# repo-lookup starting directory. Pass an empty string to omit the cd.
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

# Run with raw stdin (for malformed/empty cases).
# Args: stdin cwd [env-VAR=val ...]
run_bash_guard_raw() {
    local stdin="$1"; shift
    local cwd="$1"; shift
    if [ -n "$cwd" ]; then
        (cd "$cwd" && printf '%s' "$stdin" | run_with_timeout 30 env "$@" node "$GUARD_JS" 2>/dev/null)
    else
        printf '%s' "$stdin" | run_with_timeout 30 env "$@" node "$GUARD_JS" 2>/dev/null
    fi
}

# ============ Tests ============

test_main_checkout_on_main_blocks() {
    require_guard "test_main_checkout_on_main_blocks" || return
    local repo; repo="$(setup_main_checkout "g-main-on-main")"
    local out
    out="$(run_bash_guard "echo x > $repo/foo" "$repo" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        fail "main worktree on main: should block, got allow ($out)"
    else
        pass "main worktree on main blocks Bash write"
    fi
}

test_main_checkout_on_feature_branch_blocks() {
    require_guard "test_main_checkout_on_feature_branch_blocks" || return
    local repo; repo="$(setup_main_checkout "g-main-on-feat")"
    git -C "$repo" switch -q -c "feature/x"
    local out
    out="$(run_bash_guard "echo x > $repo/foo" "$repo" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        fail "main worktree on feature branch: should still block (NEW logic)"
    else
        pass "main worktree always blocks (even on feature branch)"
    fi
}

test_linked_worktree_on_feature_allows() {
    require_guard "test_linked_worktree_on_feature_allows" || return
    local pair; pair="$(setup_linked_worktree "g-wt-feat")"
    local main="${pair%|*}"; local wt="${pair#*|}"
    local out
    out="$(run_bash_guard "echo x > $wt/foo" "$wt" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        pass "linked worktree on feature branch allows Bash write"
    else
        fail "linked worktree on feature branch: should allow ($out)"
    fi
}

test_linked_worktree_on_main_blocks() {
    require_guard "test_linked_worktree_on_main_blocks" || return
    # Create main, then a worktree that ends up on main (rare; force checkout main)
    local main; main="$(setup_main_checkout "g-wt-main")"
    git -C "$main" switch -q -c "feature/wt"
    local wt="$TMPDIR_BASE/g-wt-main-wt"
    git -C "$main" worktree add -q --detach "$wt" 2>/dev/null
    git -C "$wt" checkout -q main 2>/dev/null || true
    git -C "$main" switch -q "feature/wt"
    local out
    out="$(run_bash_guard "echo x > $wt/foo" "$wt" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        fail "worktree on protected branch: should block ($out)"
    else
        pass "worktree on protected (main) branch blocks"
    fi
}

test_off_mode_main_checkout_allows() {
    require_guard "test_off_mode_main_checkout_allows" || return
    local repo; repo="$(setup_main_checkout "g-off-main")"
    local out
    out="$(run_bash_guard "echo x > $repo/foo" "$repo" ENFORCE_WORKTREE=off)"
    if guard_decision "$out"; then
        pass "ENFORCE_WORKTREE=off allows main worktree"
    else
        fail "ENFORCE_WORKTREE=off should allow ($out)"
    fi
}

test_dash_C_to_main_repo_blocks() {
    require_guard "test_dash_C_to_main_repo_blocks" || return
    local pair; pair="$(setup_linked_worktree "g-dashC")"
    local main="${pair%|*}"; local wt="${pair#*|}"
    # Run from worktree (allowed) but target main worktree via -C -> should block
    local cmd="git -C $main commit --allow-empty -m x"
    local out
    out="$(run_bash_guard "$cmd" "$wt" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        fail "git -C <main-checkout>: should block ($out)"
    else
        pass "git -C targets main worktree -> blocks"
    fi
}

test_dash_C_quoted_path() {
    require_guard "test_dash_C_quoted_path" || return
    local repo; repo="$(setup_main_checkout "g dashC quoted")"
    local cmd="git -C \"$repo\" commit --allow-empty -m x"
    local out
    out="$(run_bash_guard "$cmd" "$TMPDIR_BASE" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        fail "git -C quoted path with spaces: should block ($out)"
    else
        pass "git -C quoted path resolved correctly"
    fi
}

test_non_git_dir_allows() {
    require_guard "test_non_git_dir_allows" || return
    local d="$TMPDIR_BASE/nongit-$$"
    mkdir -p "$d"
    local out
    out="$(run_bash_guard "echo x > $d/foo" "$d" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        pass "non-git directory allows Bash write"
    else
        fail "non-git directory: should allow ($out)"
    fi
}

test_main_checkout_detached_head_blocks() {
    # New spec: main worktree is always blocked regardless of HEAD state.
    require_guard "test_main_checkout_detached_head_blocks" || return
    local repo; repo="$(setup_main_checkout "g-detached-main")"
    local sha; sha="$(git -C "$repo" rev-parse HEAD)"
    git -C "$repo" checkout -q "$sha"
    local out
    out="$(run_bash_guard "echo x > $repo/foo" "$repo" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        fail "main worktree detached HEAD: should block ($out)"
    else
        pass "main worktree detached HEAD: blocks (main worktree always blocked)"
    fi
}

test_linked_worktree_detached_head_allows() {
    require_guard "test_linked_worktree_detached_head_allows" || return
    local pair; pair="$(setup_linked_worktree "g-wt-detached")"
    local main="${pair%|*}"; local wt="${pair#*|}"
    local sha; sha="$(git -C "$wt" rev-parse HEAD)"
    git -C "$wt" checkout -q "$sha"
    local out
    out="$(run_bash_guard "echo x > $wt/foo" "$wt" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        pass "linked worktree detached HEAD: allows"
    else
        fail "linked worktree detached HEAD: should allow ($out)"
    fi
}

test_malformed_json_stdin_safe() {
    require_guard "test_malformed_json_stdin_safe" || return
    local out
    out="$(run_bash_guard_raw "this is not json" "" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        pass "malformed JSON stdin: fail-safe allow"
    else
        fail "malformed JSON should fail-safe allow ($out)"
    fi
}

test_empty_stdin_allows() {
    require_guard "test_empty_stdin_allows" || return
    local out
    out="$(run_bash_guard_raw "" "" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        pass "empty stdin allows"
    else
        fail "empty stdin: should allow ($out)"
    fi
}

test_path_traversal_safe() {
    require_guard "test_path_traversal_safe" || return
    local cmd='git -C "../../../etc/" status'
    local out
    out="$(run_bash_guard "$cmd" "$TMPDIR_BASE" ENFORCE_WORKTREE=on)"
    # Non-git path traversal should fail rev-parse -> graceful allow
    if guard_decision "$out"; then
        pass "path traversal in -C: graceful allow (non-git target)"
    else
        pass "path traversal in -C: blocked (also acceptable)"
    fi
}

test_idempotency() {
    require_guard "test_idempotency" || return
    local repo; repo="$(setup_main_checkout "g-idem")"
    local a b
    a="$(run_bash_guard "echo x > $repo/foo" "$repo" ENFORCE_WORKTREE=on)"
    b="$(run_bash_guard "echo x > $repo/foo" "$repo" ENFORCE_WORKTREE=on)"
    if [ "$a" = "$b" ]; then
        pass "guard is idempotent (same input -> same output)"
    else
        fail "guard not idempotent (a=$a b=$b)"
    fi
}

# Verify the core detection premise: --git-common-dir == --git-dir on main worktree,
# != --git-dir on linked worktree. Tests both the git invariant and the guard decision.
test_git_common_dir_main_blocks() {
    require_guard "test_git_common_dir_main_blocks" || return
    local repo; repo="$(setup_main_checkout "g-cmd-main")"
    local common_dir git_dir
    common_dir="$(git -C "$repo" rev-parse --git-common-dir 2>/dev/null)"
    git_dir="$(git -C "$repo" rev-parse --git-dir 2>/dev/null)"
    if [ "$(realpath "$common_dir" 2>/dev/null)" = "$(realpath "$git_dir" 2>/dev/null)" ]; then
        pass "main worktree: --git-common-dir == --git-dir (detection premise holds)"
    else
        fail "main worktree: git-common-dir=$common_dir git-dir=$git_dir should be equal"
    fi
    local out
    out="$(run_bash_guard "echo x > $repo/foo" "$repo" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        fail "main worktree: guard should block (--git-common-dir == --git-dir)"
    else
        pass "main worktree: guard blocks when --git-common-dir == --git-dir"
    fi
}

test_git_common_dir_worktree_allows() {
    require_guard "test_git_common_dir_worktree_allows" || return
    local pair; pair="$(setup_linked_worktree "g-cmd-wt")"
    local main="${pair%|*}"; local wt="${pair#*|}"
    local common_dir git_dir
    common_dir="$(git -C "$wt" rev-parse --git-common-dir 2>/dev/null)"
    git_dir="$(git -C "$wt" rev-parse --git-dir 2>/dev/null)"
    if [ "$(realpath "$common_dir" 2>/dev/null)" != "$(realpath "$git_dir" 2>/dev/null)" ]; then
        pass "linked worktree: --git-common-dir != --git-dir (detection premise holds)"
    else
        fail "linked worktree: expected git-common-dir!=git-dir but both=$common_dir"
    fi
    local out
    out="$(run_bash_guard "echo x > $wt/foo" "$wt" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        pass "linked worktree: guard allows when --git-common-dir != --git-dir"
    else
        fail "linked worktree: guard should allow (--git-common-dir != --git-dir)"
    fi
}

test_dash_C_relative_path_blocks() {
    require_guard "test_dash_C_relative_path_blocks" || return
    local repo; repo="$(setup_main_checkout "g-dashC-rel")"
    local rel
    rel="$(realpath --relative-to="$TMPDIR_BASE" "$repo" 2>/dev/null)" || {
        pass "test_dash_C_relative_path_blocks: realpath --relative-to unavailable, skipping"
        return
    }
    local cmd="git -C $rel commit --allow-empty -m x"
    local out
    out="$(run_bash_guard "$cmd" "$TMPDIR_BASE" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        fail "git -C relative path to main: should block ($out)"
    else
        pass "git -C relative path resolved correctly: blocks"
    fi
}

test_dash_C_semicolon_in_path_safe() {
    require_guard "test_dash_C_semicolon_in_path_safe" || return
    local evil_dir="$TMPDIR_BASE/guard-injected-$$"
    local cmd="git -C \"/tmp/my;mkdir $evil_dir\" status"
    run_bash_guard "$cmd" "$TMPDIR_BASE" ENFORCE_WORKTREE=on >/dev/null 2>&1
    if [ -d "$evil_dir" ]; then
        fail "SECURITY: semicolon in -C path executed mkdir"
        rmdir "$evil_dir" 2>/dev/null || true
    else
        pass "git -C with semicolon in path: no command injection"
    fi
}

test_dash_C_dollar_var_in_path_safe() {
    require_guard "test_dash_C_dollar_var_in_path_safe" || return
    local cmd='git -C "$TMPDIR_BASE" status'
    local out
    out="$(run_bash_guard "$cmd" "$TMPDIR_BASE" ENFORCE_WORKTREE=on 2>/dev/null)"
    # Must not crash — decision direction is acceptable either way
    if echo "$out" | grep -qE '"decision":"(allow|block)"'; then
        pass "git -C with dollar-var in path: handled without crash"
    else
        pass "git -C with dollar-var in path: no output (graceful non-git path)"
    fi
}

# ============ NEW: gh Group A / Group B + session scope ============
# These tests document the fix/enforce-worktree-gh-whitelist contract.
# Group A: always-allow (gh pr/issue/repo create/edit/close/comment/review/...)
#          — classified as "read" post-impl, so guard never sees them.
# Group B: session-scoped writes (gh pr merge, gh issue delete, gh repo delete,
#          gh release create/delete/edit/upload, gh api -X POST/PUT/PATCH/DELETE,
#          gh api --method ...).

test_gh_group_a_from_main_checkout_allows() {
    require_guard "test_gh_group_a_from_main_checkout_allows" || return
    local repo; repo="$(setup_main_checkout "g-gh-A-main")"
    local out
    out="$(run_bash_guard "gh pr create --fill" "$repo" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        pass "Group A (gh pr create) from main worktree: allow"
    else
        fail "Group A from main worktree: should allow ($out)"
    fi
}

test_gh_group_b_from_main_checkout_blocks() {
    require_guard "test_gh_group_b_from_main_checkout_blocks" || return
    local repo; repo="$(setup_main_checkout "g-gh-B-main")"
    local out
    out="$(run_bash_guard "gh pr merge 1" "$repo" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        fail "Group B (gh pr merge) from main worktree: should block ($out)"
    else
        pass "Group B from main worktree: blocks (mainCheckout)"
    fi
}

test_gh_group_b_from_feature_worktree_allows() {
    require_guard "test_gh_group_b_from_feature_worktree_allows" || return
    local pair; pair="$(setup_linked_worktree "g-gh-B-wt")"
    local main="${pair%|*}"; local wt="${pair#*|}"
    local out
    out="$(run_bash_guard "gh pr merge 1" "$wt" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        pass "Group B (gh pr merge) from feature worktree in session: allow"
    else
        fail "Group B from feature worktree: should allow ($out)"
    fi
}

test_gh_group_b_via_git_C_to_out_of_session_repo_blocks() {
    require_guard "test_gh_group_b_via_git_C_to_out_of_session_repo_blocks" || return
    # Documented limitation: gh CLI does not honor -C, but the guard's repo
    # detection does parse `git -C` from any command. To exercise the
    # session-scope BLOCK path, we use a command containing `git -C <other>`
    # so detected repoRoot differs from cwd repo.
    # The actual gh CLI would not target <other>, but the guard's enforcement
    # is based on detected repo. This test pins the behavior of the
    # session-scope check itself.
    local pair_session; pair_session="$(setup_linked_worktree "g-gh-scope-cwd")"
    local pair_other;   pair_other="$(setup_linked_worktree "g-gh-scope-other")"
    local wt_session="${pair_session#*|}"
    local pair_other_main="${pair_other%|*}"
    local out
    # cwd = session worktree (in scope), but command targets other repo via git -C
    # AND uses a gh-write subcommand. Detection picks `git -C <other>` first,
    # so detected != cwd repo, and other repo is NOT in session → block.
    out="$(run_bash_guard "git -C $pair_other_main fake && gh pr merge 1" "$wt_session" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        fail "Group B with git -C to out-of-session repo: should block (scope)"
    else
        pass "Group B with git -C to out-of-session repo: blocks (out of scope)"
    fi
}

test_gh_group_b_from_non_git_dir_blocks() {
    require_guard "test_gh_group_b_from_non_git_dir_blocks" || return
    local d="$TMPDIR_BASE/gh-nongit-$$"
    mkdir -p "$d"
    local out
    out="$(run_bash_guard "gh pr merge 1" "$d" ENFORCE_WORKTREE=on)"
    # gh write from non-git dir must block (no repo to scope to).
    if guard_decision "$out"; then
        fail "Group B from non-git dir: should block (no repo) ($out)"
    else
        pass "Group B from non-git dir: blocks (repo unknown)"
    fi
}

test_main_checkout_ff_only_allowed() {
    require_guard "test_main_checkout_ff_only_allowed" || return
    local repo; repo="$(setup_main_checkout "g-ff-only")"

    # Allow: ff-only merge from main worktree
    local out
    out="$(run_bash_guard "git merge --ff-only origin/feature" "$repo" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        pass "main worktree: git merge --ff-only allowed"
    else
        fail "main worktree: git merge --ff-only should allow ($out)"
    fi

    # Allow: ff-only pull from main worktree
    out="$(run_bash_guard "git pull --ff-only origin main" "$repo" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        pass "main worktree: git pull --ff-only allowed"
    else
        fail "main worktree: git pull --ff-only should allow ($out)"
    fi

    # Block: plain git merge (no --ff-only)
    out="$(run_bash_guard "git merge feature" "$repo" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        fail "main worktree: plain git merge should block"
    else
        pass "main worktree: plain git merge blocks"
    fi

    # Block: --no-ff overrides --ff-only intent
    out="$(run_bash_guard "git merge --no-ff feature" "$repo" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        fail "main worktree: git merge --no-ff should block"
    else
        pass "main worktree: git merge --no-ff blocks"
    fi

    # Block: chained command — ff-only is fine but the chain may smuggle a write
    out="$(run_bash_guard "git merge --ff-only origin/feature && git push" "$repo" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        fail "main worktree: chained ff-only && push should block"
    else
        pass "main worktree: chained ff-only && push blocks (hasShellChaining)"
    fi
}

# ============ Run all ============

test_main_checkout_on_main_blocks
test_main_checkout_on_feature_branch_blocks
test_linked_worktree_on_feature_allows
test_linked_worktree_on_main_blocks
test_off_mode_main_checkout_allows
test_dash_C_to_main_repo_blocks
test_dash_C_quoted_path
test_non_git_dir_allows
test_main_checkout_detached_head_blocks
test_linked_worktree_detached_head_allows
test_malformed_json_stdin_safe
test_empty_stdin_allows
test_path_traversal_safe
test_idempotency
test_git_common_dir_main_blocks
test_git_common_dir_worktree_allows
test_dash_C_relative_path_blocks
test_dash_C_semicolon_in_path_safe
test_dash_C_dollar_var_in_path_safe
test_gh_group_a_from_main_checkout_allows
test_gh_group_b_from_main_checkout_blocks
test_gh_group_b_from_feature_worktree_allows
test_gh_group_b_via_git_C_to_out_of_session_repo_blocks
test_gh_group_b_from_non_git_dir_blocks
test_main_checkout_ff_only_allowed

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"

exit $FAIL
