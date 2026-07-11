#!/bin/bash
# tests/fix-unblock-branch-d/integration.sh
# Tests: hooks/enforce-worktree.js, hooks/enforce-worktree/branch-delete-guard.js, hooks/lib/command-parser.js
# Tags: worktree, enforce, hook, branch-delete, redirect, integration, scope:common
#
# End-to-end hook tests (real git repo + linked worktree fixtures) for the
# worktree-list-gated `git branch -d/-D` decision, plus the redirect-suffix
# regression (#1380/#1172): authorized force-deletes with Bash-appended
# trailing redirects (`2>&1`, `>/dev/null`, `2>/dev/null`, stacked) must ALLOW,
# while non-feature branches with a redirect suffix must still BLOCK.
#
# Runnable standalone:
#   bash tests/fix-unblock-branch-d/integration.sh
#
# L3 gap (what this test does NOT catch):
# - Whether a real Claude Code Bash tool invocation appends exactly the
#   redirect forms tested here (this spawns `node hooks/...` directly with a
#   synthetic payload, not a live session).
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: hook-registration.

# shellcheck source=_lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

PASS=0
FAIL=0

TMPDIR_BASE="$(node -e "
const os=require('os'),path=require('path'),fs=require('fs');
const d=path.join(os.tmpdir(),'unblock-branch-d-int-'+process.pid).replace(/\\\\/g,'/');
fs.mkdirSync(d,{recursive:true});
console.log(d);
" 2>/dev/null)"
[ -z "$TMPDIR_BASE" ] && TMPDIR_BASE="$(mktemp -d)"
trap 'chmod -R u+rwX "$TMPDIR_BASE" 2>/dev/null; rm -rf "$TMPDIR_BASE"' EXIT

# ─────────────────────────────────────────────────────────────────────────────
# T6 — main worktree, branch `foo` NOT registered to any linked worktree → ALLOW
# ─────────────────────────────────────────────────────────────────────────────

test_T6_allow_when_branch_not_in_worktree_list() {
    local repo="$TMPDIR_BASE/t6-repo"
    init_repo "$repo"
    (cd "$repo" && git branch foo 2>/dev/null)

    local payload out
    payload="$(hook_payload_bash 'git branch -d foo')"
    out="$(ENFORCE_WORKTREE=on run_hook "$payload" "$repo")"
    case "$out" in
        *"\"decision\":\"block\""*)
            fail "T6 expected ALLOW; got block: $out" ;;
        *)
            pass "T6 main-worktree + unregistered branch → ALLOW" ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# T7 — main worktree, branch `foo` IS checked out in a linked worktree → BLOCK
# ─────────────────────────────────────────────────────────────────────────────

test_T7_block_when_branch_in_linked_worktree() {
    local repo="$TMPDIR_BASE/t7-repo"
    local wpath="$TMPDIR_BASE/t7-wt"
    init_repo "$repo"
    add_linked_worktree "$repo" "$wpath" "foo"

    local payload out
    payload="$(hook_payload_bash 'git branch -d foo')"
    out="$(ENFORCE_WORKTREE=on run_hook "$payload" "$repo")"
    case "$out" in
        *"\"decision\":\"block\""*)
            case "$out" in
                *worktree-end*|*"worktree prune"*)
                    pass "T7 main + linked worktree using branch → BLOCK with worktree-end/prune hint" ;;
                *)
                    fail "T7 blocked but reason missing worktree-end / git worktree prune: $out" ;;
            esac
            ;;
        *)
            fail "T7 expected BLOCK; got: $out" ;;
    esac

    git -C "$repo" worktree remove --force "$wpath" 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
# T8 — `-D` with inline WORKTREE_END_SKILL prefix (feature-typed) → ALLOW
# ─────────────────────────────────────────────────────────────────────────────

test_T8_allow_force_delete_with_inline_prefix() {
    local repo="$TMPDIR_BASE/t8-repo"
    init_repo "$repo"
    (cd "$repo" && \
        git -c user.email=t@example.com -c user.name=t checkout -q -b feature/foo && \
        git -c user.email=t@example.com -c user.name=t commit --allow-empty --no-verify -q -m "divergent" && \
        git -c user.email=t@example.com -c user.name=t checkout -q main)

    local payload out
    payload="$(hook_payload_bash "WORKTREE_END_SKILL=1 git -C $repo branch -D feature/foo")"
    out="$(ENFORCE_WORKTREE=on run_hook "$payload" "$repo")"
    case "$out" in
        *"\"decision\":\"block\""*)
            fail "T8 expected ALLOW for inline-prefix -D on feature/foo; got block: $out" ;;
        *)
            pass "T8 inline WORKTREE_END_SKILL=1 prefix + -D on feature/foo → ALLOW" ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# T8b — `-D` WITHOUT inline prefix → BLOCK with WORKTREE_END_SKILL reason
# ─────────────────────────────────────────────────────────────────────────────

test_T8b_block_force_delete_without_inline_prefix() {
    local repo="$TMPDIR_BASE/t8b-repo"
    init_repo "$repo"
    (cd "$repo" && git branch feature/foo 2>/dev/null)

    local payload out
    payload="$(hook_payload_bash 'git branch -D feature/foo')"
    out="$(ENFORCE_WORKTREE=on run_hook "$payload" "$repo")"
    case "$out" in
        *"\"decision\":\"block\""*)
            case "$out" in
                *"WORKTREE_END_SKILL"*)
                    pass "T8b main + -D without inline prefix → BLOCK with WORKTREE_END_SKILL reason" ;;
                *)
                    fail "T8b blocked but reason missing 'WORKTREE_END_SKILL': $out" ;;
            esac
            ;;
        *)
            fail "T8b expected BLOCK for -D without inline prefix; got: $out" ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# T8c — combined-flag force forms without inline prefix → BLOCK
# ─────────────────────────────────────────────────────────────────────────────

test_T8c_block_combined_force_flags_without_prefix() {
    local repo="$TMPDIR_BASE/t8c-repo"
    init_repo "$repo"
    (cd "$repo" && git branch foo 2>/dev/null)

    local payload1 out1
    payload1="$(hook_payload_bash 'git branch -d -f foo')"
    out1="$(ENFORCE_WORKTREE=on run_hook "$payload1" "$repo")"
    case "$out1" in
        *"\"decision\":\"block\""*)
            pass "T8c form '-d -f' blocked without inline prefix" ;;
        *)
            fail "T8c form '-d -f' should BLOCK without inline prefix; got: $out1" ;;
    esac

    local payload2 out2
    payload2="$(hook_payload_bash 'git branch -d --force foo')"
    out2="$(ENFORCE_WORKTREE=on run_hook "$payload2" "$repo")"
    case "$out2" in
        *"\"decision\":\"block\""*)
            pass "T8c form '-d --force' blocked without inline prefix" ;;
        *)
            fail "T8c form '-d --force' should BLOCK without inline prefix; got: $out2" ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# T8d — inline prefix + non-feature-typed branch → BLOCK (defense-in-depth)
# ─────────────────────────────────────────────────────────────────────────────

test_T8d_block_inline_prefix_with_non_feature_branch() {
    local repo="$TMPDIR_BASE/t8d-repo"
    init_repo "$repo"
    (cd "$repo" && \
        git -c user.email=t@example.com -c user.name=t branch foo 2>/dev/null && \
        git -c user.email=t@example.com -c user.name=t branch release/v2 2>/dev/null)

    local payload1 out1
    payload1="$(hook_payload_bash "WORKTREE_END_SKILL=1 git -C $repo branch -D foo")"
    out1="$(ENFORCE_WORKTREE=on run_hook "$payload1" "$repo")"
    case "$out1" in
        *"\"decision\":\"block\""*)
            pass "T8d inline prefix + bare 'foo' → BLOCK (non-feature type)" ;;
        *)
            fail "T8d expected BLOCK for inline-prefix on bare 'foo'; got: $out1" ;;
    esac

    local payload2 out2
    payload2="$(hook_payload_bash "WORKTREE_END_SKILL=1 git -C $repo branch -D release/v2")"
    out2="$(ENFORCE_WORKTREE=on run_hook "$payload2" "$repo")"
    case "$out2" in
        *"\"decision\":\"block\""*)
            pass "T8d inline prefix + 'release/v2' → BLOCK (release not in allowed types)" ;;
        *)
            fail "T8d expected BLOCK for inline-prefix on 'release/v2'; got: $out2" ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# T9 — shell-chained form → BLOCK
# ─────────────────────────────────────────────────────────────────────────────

test_T9_block_shell_chained() {
    local repo="$TMPDIR_BASE/t9-repo"
    init_repo "$repo"
    (cd "$repo" && git branch foo 2>/dev/null)

    local payload out
    payload="$(hook_payload_bash 'git branch -d foo && echo x')"
    out="$(ENFORCE_WORKTREE=on run_hook "$payload" "$repo")"
    case "$out" in
        *"\"decision\":\"block\""*)
            pass "T9 shell-chained branch-delete → BLOCK" ;;
        *)
            fail "T9 expected BLOCK for shell-chained command; got: $out" ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# T10 — from a LINKED worktree, delete of an unregistered branch → ALLOW
# ─────────────────────────────────────────────────────────────────────────────

test_T10_allow_from_linked_worktree() {
    local repo="$TMPDIR_BASE/t10-repo"
    local wpath="$TMPDIR_BASE/t10-wt"
    init_repo "$repo"
    add_linked_worktree "$repo" "$wpath" "feature/work"
    (cd "$repo" && git branch foo 2>/dev/null)

    local payload out
    payload="$(hook_payload_bash 'git branch -d foo')"
    out="$(ENFORCE_WORKTREE=on run_hook "$payload" "$wpath")"
    case "$out" in
        *"\"decision\":\"block\""*)
            fail "T10 expected ALLOW from linked worktree; got block: $out" ;;
        *)
            pass "T10 linked-worktree branch-delete on unregistered branch → ALLOW" ;;
    esac

    git -C "$repo" worktree remove --force "$wpath" 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
# T11 — path outside any git repo → ALLOW
# ─────────────────────────────────────────────────────────────────────────────

test_T11_allow_when_outside_git_repo() {
    local nonrepo="$TMPDIR_BASE/t11-nonrepo"
    mkdir -p "$nonrepo"

    local payload out
    payload="$(hook_payload_bash 'git branch -d foo')"
    out="$(ENFORCE_WORKTREE=on run_hook "$payload" "$nonrepo")"
    case "$out" in
        *"\"decision\":\"block\""*)
            fail "T11 expected ALLOW outside any git repo; got block: $out" ;;
        *)
            pass "T11 outside git repo → ALLOW" ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# T12 — `git worktree list --porcelain` fails → BLOCK (fail-closed)
# ─────────────────────────────────────────────────────────────────────────────

test_T12_fail_closed_on_registry_fetch_failure() {
    local repo="$TMPDIR_BASE/t12-repo"
    init_repo "$repo"
    (cd "$repo" && git branch foo 2>/dev/null)

    chmod -R 000 "$repo/.git" 2>/dev/null || true

    local payload out
    payload="$(hook_payload_bash 'git branch -d foo')"
    out="$(ENFORCE_WORKTREE=on run_hook "$payload" "$repo" 2>&1)"
    chmod -R u+rwX "$repo/.git" 2>/dev/null || true

    case "$out" in
        *"\"decision\":\"block\""*)
            pass "T12 worktree-list failure → BLOCK (fail-closed)" ;;
        *)
            # SKIPPED: registry-fetch failure (git worktree list errors) → BLOCK
            # Because: chmod 000 on .git is ineffective on Windows / for privileged
            #   users, so the fault cannot be injected on this platform. Counted
            #   as SKIP (not pass) to avoid a false-green.
            # L3 gap: a real POSIX CI host with an unprivileged user is required
            #   to exercise the fail-closed path when the worktree-list call fails.
            case "$(uname -s 2>/dev/null)" in
                MINGW*|MSYS*|CYGWIN*)
                    skip "T12 registry-fetch-failure (Windows chmod 000 ineffective; cannot inject fault)" ;;
                *)
                    fail "T12 expected BLOCK on registry-fetch failure; got: $out" ;;
            esac
            ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# T17 — inline prefix + `feat/` branch type → ALLOW
# ─────────────────────────────────────────────────────────────────────────────

test_T17_allow_feat_prefix_branch_delete() {
    local repo="$TMPDIR_BASE/t17-repo"
    init_repo "$repo"
    (cd "$repo" && \
        git -c user.email=t@example.com -c user.name=t checkout -q -b feat/fix-541 && \
        git -c user.email=t@example.com -c user.name=t commit --allow-empty --no-verify -q -m "divergent" && \
        git -c user.email=t@example.com -c user.name=t checkout -q main)
    local payload out
    payload="$(hook_payload_bash "WORKTREE_END_SKILL=1 git -C $repo branch -D feat/fix-541")"
    out="$(ENFORCE_WORKTREE=on run_hook "$payload" "$repo")"
    case "$out" in
        *'"decision":"block"'*)
            fail "T17 expected ALLOW for inline-prefix -D on feat/fix-541; got block: $out" ;;
        *)
            pass "T17 inline WORKTREE_END_SKILL=1 + feat/ branch type → ALLOW" ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# T18 — inline prefix + branch name without slash → BLOCK
# ─────────────────────────────────────────────────────────────────────────────

test_T18_block_feat_no_slash() {
    local repo="$TMPDIR_BASE/t18-repo"
    init_repo "$repo"
    (cd "$repo" && git -c user.email=t@example.com -c user.name=t branch feat-baz 2>/dev/null)
    local payload out
    payload="$(hook_payload_bash "WORKTREE_END_SKILL=1 git -C $repo branch -D feat-baz")"
    out="$(ENFORCE_WORKTREE=on run_hook "$payload" "$repo")"
    case "$out" in
        *'"decision":"block"'*)
            pass "T18 inline prefix + feat-baz (no slash) → BLOCK (type/name required)" ;;
        *)
            fail "T18 expected BLOCK for feat-baz without slash; got: $out" ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# T19 — regression: `feature/` still works
# ─────────────────────────────────────────────────────────────────────────────

test_T19_regression_feature_prefix_still_allowed() {
    local repo="$TMPDIR_BASE/t19-repo"
    init_repo "$repo"
    (cd "$repo" && \
        git -c user.email=t@example.com -c user.name=t checkout -q -b feature/regression-check && \
        git -c user.email=t@example.com -c user.name=t commit --allow-empty --no-verify -q -m "divergent" && \
        git -c user.email=t@example.com -c user.name=t checkout -q main)
    local payload out
    payload="$(hook_payload_bash "WORKTREE_END_SKILL=1 git -C $repo branch -D feature/regression-check")"
    out="$(ENFORCE_WORKTREE=on run_hook "$payload" "$repo")"
    case "$out" in
        *'"decision":"block"'*)
            fail "T19 expected ALLOW for inline-prefix on feature/; got block: $out" ;;
        *)
            pass "T19 regression: feature/ branch type still ALLOW" ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# NEW T20–T24 — redirect-suffix regression (#1380/#1172), end-to-end hook.
#
# Attack-scenario structure (test-design.md #1001 pattern 2): each ALLOW case
# reproduces the exact Bash-tool-appended redirect that currently BREAKS the
# `[ \t]*$` anchor, then asserts the hook does NOT block. T24 is the paired
# Negative assertion (pattern 1): a non-feature branch with the same redirect
# suffix must STILL block — the redirect tolerance must not open a bypass.
#
# FAIL-BEFORE-FIX: T20–T23 BLOCK now (predicate anchor rejects the suffix) →
# they FAIL until the source fix lands. T24 already blocks → it PASSES now and
# must keep passing.
# ─────────────────────────────────────────────────────────────────────────────

# Helper: create a divergent feature branch, then POSITIVELY assert ALLOW
# (exit 0 + allow payload `{}`, no `decision` key) via assert_hook_allow. This
# fails-loud on hook crash / empty output / malformed JSON, closing the
# false-green gap that a bare "block absent" check leaves open.
_assert_we_redirect_allow() {
    local repo="$1" branch="$2" cmd="$3" label="$4"
    init_repo "$repo"
    (cd "$repo" && \
        git -c user.email=t@example.com -c user.name=t checkout -q -b "$branch" && \
        git -c user.email=t@example.com -c user.name=t commit --allow-empty --no-verify -q -m "divergent" && \
        git -c user.email=t@example.com -c user.name=t checkout -q main)
    local payload out rc
    payload="$(hook_payload_bash "$cmd")"
    out="$(ENFORCE_WORKTREE=on run_hook_stdout "$payload" "$repo")"; rc=$?
    assert_hook_allow "$label" "$out" "$rc"
}

test_T20_allow_WE_force_delete_with_2and1_suffix() {
    local repo="$TMPDIR_BASE/t20-repo"
    _assert_we_redirect_allow "$repo" "feature/foo" \
        "WORKTREE_END_SKILL=1 git -C $repo branch -D feature/foo 2>&1" \
        "T20 WE force-delete + ' 2>&1' suffix → ALLOW"
}

test_T21_allow_WE_force_delete_with_devnull_suffix() {
    local repo="$TMPDIR_BASE/t21-repo"
    _assert_we_redirect_allow "$repo" "feature/foo" \
        "WORKTREE_END_SKILL=1 git -C $repo branch -D feature/foo >/dev/null" \
        "T21 WE force-delete + ' >/dev/null' suffix → ALLOW"
}

test_T22_allow_WE_force_delete_with_2devnull_suffix() {
    local repo="$TMPDIR_BASE/t22-repo"
    _assert_we_redirect_allow "$repo" "feature/foo" \
        "WORKTREE_END_SKILL=1 git -C $repo branch -D feature/foo 2>/dev/null" \
        "T22 WE force-delete + ' 2>/dev/null' suffix → ALLOW"
}

test_T23_allow_WE_force_delete_stacked_redirect() {
    local repo="$TMPDIR_BASE/t23-repo"
    _assert_we_redirect_allow "$repo" "feature/foo" \
        "WORKTREE_END_SKILL=1 git -C $repo branch -D feature/foo >/dev/null 2>&1" \
        "T23 WE force-delete + stacked ' >/dev/null 2>&1' → ALLOW"
}

test_T24_block_WE_nonfeature_with_redirect() {
    local repo="$TMPDIR_BASE/t24-repo"
    init_repo "$repo"
    (cd "$repo" && git -c user.email=t@example.com -c user.name=t branch main-copy 2>/dev/null)
    local payload out rc
    # `main` is the checked-out branch, so target a protected-shape name the
    # branch-name validation rejects even after redirect stripping.
    payload="$(hook_payload_bash "WORKTREE_END_SKILL=1 git -C $repo branch -D main 2>&1")"
    out="$(ENFORCE_WORKTREE=on run_hook_stdout "$payload" "$repo")"; rc=$?
    assert_hook_block "T24 WE force-delete of 'main' + ' 2>&1' → BLOCK (fail-closed holds)" "$out" "$rc"
}

# ─────────────────────────────────────────────────────────────────────────────
# Run all tests in this group
# ─────────────────────────────────────────────────────────────────────────────

test_T6_allow_when_branch_not_in_worktree_list
test_T7_block_when_branch_in_linked_worktree
test_T8_allow_force_delete_with_inline_prefix
test_T8b_block_force_delete_without_inline_prefix
test_T8c_block_combined_force_flags_without_prefix
test_T8d_block_inline_prefix_with_non_feature_branch
test_T9_block_shell_chained
test_T10_allow_from_linked_worktree
test_T11_allow_when_outside_git_repo
test_T12_fail_closed_on_registry_fetch_failure
test_T17_allow_feat_prefix_branch_delete
test_T18_block_feat_no_slash
test_T19_regression_feature_prefix_still_allowed
test_T20_allow_WE_force_delete_with_2and1_suffix
test_T21_allow_WE_force_delete_with_devnull_suffix
test_T22_allow_WE_force_delete_with_2devnull_suffix
test_T23_allow_WE_force_delete_stacked_redirect
test_T24_block_WE_nonfeature_with_redirect

echo ""
echo "─────────────────────────────────────────"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
