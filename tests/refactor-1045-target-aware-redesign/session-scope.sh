#!/bin/bash
# R-20 (NEW): session-scope multi-repo guard
#
# Scenario: From main worktree of repoA, with sessionRoots=[repoA, repoB],
# a Bash command writes a target inside repoB (outside repoA but inside session scope).
#
# Pre-Tighten (current impl): universal-target-allow.js uses isPathOutsideRepo(bare, repoRoot)
# where repoRoot=repoA. The target is outside repoA → universal rule ALLOWs (WRONG).
# This test FAILS pre-Tighten — that is expected and intentional (test-before-code contract).
#
# Post-Tighten: universal-target-allow.js uses areAllBashTargetsOutsideSessionScope(targets, sessionRoots).
# The target is inside repoB which is in sessionRoots → universal rule ABSTAINs (correct).
# Abstain → falls through to downstream main-worktree-allows chain → BLOCK.
# This test PASSES post-Tighten.
#
# Injection: ENFORCE_WORKTREE_EXTRA_REPOS=<repoB> (semicolon-separated list per session-scope.js).
# The hook's getSessionRepoRoots() includes repoA (CWD root) and repoB (from EXTRA_REPOS).

# ============================================================================
# R-20: from main worktree of repoA, sessionRoots=[repoA, repoB],
#        write target inside repoB → universal rule MUST abstain → block
# ============================================================================
test_r20_session_scope_cross_repo_block() {
    require_impl "R-20" || return

    # Set up two independent main-worktree repos: r20-a and r20-b.
    local repo_a; repo_a="$(setup_main_checkout "r20-a")"
    local repo_b; repo_b="$(setup_main_checkout "r20-b")"

    # Write target is a file inside repoB — outside repoA but inside session scope.
    local target_inside_b="$repo_b/some-file-r20"

    # CWD = repoA main worktree; ENFORCE_WORKTREE_EXTRA_REPOS injects repoB into session scope.
    local out
    out="$(run_bash_guard "echo x > $target_inside_b" "$repo_a" \
        ENFORCE_WORKTREE=on \
        "ENFORCE_WORKTREE_EXTRA_REPOS=$repo_b")"

    # Expected: BLOCK (universal rule abstains because target is inside repoB which
    # is in session scope; downstream main-worktree block fires).
    # Pre-Tighten: ALLOW (universal rule incorrectly allows because target is outside repoA).
    if guard_decision "$out"; then
        fail "R-20: cross-repo write inside session-scope repoB from repoA main: should block ($out)"
    else
        pass "R-20: cross-repo write inside session-scope repoB → universal rule abstains → block"
    fi
}

test_r20_session_scope_cross_repo_block
