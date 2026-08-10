#!/usr/bin/env bash
# tests/feature-1894-precommit-comment-block-warn/guard-and-killswitch.sh
# Tests: hooks/pre-commit, bin/review-comment-block-size
# Tags: comment-block-size, pre-commit, guard, kill-switch, argv, worktree, scope:issue-specific, scope:feature-1894, layer:TL2
#
# Part 1 — who decides whether the section runs at all.
#
# Two independent conditions must BOTH hold: (a) the repo being committed to is
# the agents session repo, and (b) the scanner exists and is executable. Each
# verdict is pinned on its own (CPR-ORTH), and every case also asserts the argv
# the hook handed the scanner — "silent" must mean "not invoked", not "invoked
# and happened to print nothing".
#
# Sourced by the dispatcher; all helpers and constants are defined there.

# ============================================================================
# P01 — both conditions true + findings -> advisory output, commit passes
# ============================================================================
p01_warns_and_continues() {
    local repo; repo="$(make_repo p01 warn "$NON_GITHUB")"
    stage_sample "$repo"
    run_precommit "$repo" "$repo" "COMMENT_BLOCK_WARN=on"
    assert_eq "P01/rc-unchanged" "0" "$RC"
    assert_contains "P01/full-output-echoed" "$SCANNER_HEADER" "$OUT$ERR"
    assert_contains "P01/warn-line-echoed" "$WARN_LINE" "$OUT$ERR"
    assert_contains "P01/advisory-notice" "$ADVISORY_NOTICE" "$OUT$ERR"
    # The hook must ask for staged mode, exactly once, with no extra flags:
    # `--all` here would scan the whole worktree on every commit.
    assert_eq "P01/scanner-argc" "1" "$(scanner_argc "$repo")"
    assert_eq "P01/scanner-argv" "--staged" "$(scanner_argv "$repo")"
}

# ============================================================================
# P02 / P02b — condition (a): _is_agents_session_repo(), both verdicts
# ============================================================================
p02_foreign_repo_untouched() {
    # The foreign repo carries its OWN executable scanner, so a silent run can
    # only mean "the repo-identity guard rejected it" — not "nothing to run".
    local cfg; cfg="$(make_repo p02cfg warn "$NON_GITHUB")"
    local other; other="$(make_repo p02other warn "$NON_GITHUB")"
    stage_sample "$other"
    run_precommit "$other" "$cfg"
    assert_eq "P02/rc" "0" "$RC"
    assert_absent "P02/section-silent-in-foreign-repo" "$SCANNER_HEADER" "$OUT$ERR"
    assert_eq "P02/configured-scanner-not-invoked" "not-invoked" "$(scanner_argv "$cfg")"
    assert_eq "P02/local-scanner-not-invoked" "not-invoked" "$(scanner_argv "$other")"
}

p02b_linked_worktree_is_the_same_repo() {
    # A linked worktree has a different top-level path but the same common dir.
    # Identity must be decided on the common dir: every /worktree-start session
    # commits from a linked worktree, so a path-equality guard would silently
    # disable the check for the exact workflow it was written for.
    local cfg; cfg="$(make_repo p02bcfg warn "$NON_GITHUB")"
    local wt="$TMPDIR_BASE/p02bwt"
    if ! git -C "$cfg" worktree add -q -b feat "$wt" >/dev/null 2>&1; then
        skip "P02b: git worktree add unavailable in this fixture — linked-worktree identity unverified"
        return
    fi
    stage_sample "$wt"
    run_precommit "$wt" "$cfg"
    assert_eq "P02b/rc" "0" "$RC"
    assert_contains "P02b/linked-worktree-still-scanned" "$WARN_LINE" "$OUT$ERR"
    assert_eq "P02b/scanner-invoked-with-staged" "--staged" "$(scanner_argv "$cfg")"
}

# ============================================================================
# P03 / P03b — condition (b): scanner present and executable, both verdicts
# ============================================================================
p03_agents_repo_without_scanner_silent() {
    local repo; repo="$(make_repo p03 none "$NON_GITHUB")"
    stage_sample "$repo"
    run_precommit "$repo" "$repo"
    assert_eq "P03/rc" "0" "$RC"
    assert_absent "P03/no-scanner-no-output" "comment-block" "$OUT$ERR"
}

p03b_scanner_present_but_not_executable() {
    local repo; repo="$(make_repo p03b noexec "$NON_GITHUB")"
    if [ -x "$repo/bin/review-comment-block-size" ]; then
        # MSYS2/NTFS reports every regular file as r-xr-xr-x, so the "present
        # but not executable" state cannot be produced here. The guard's false
        # verdict is still covered by P03 (script absent).
        skip "P03b: execute bit cannot be cleared on this filesystem — -x false verdict covered by P03"
        return
    fi
    stage_sample "$repo"
    run_precommit "$repo" "$repo"
    assert_eq "P03b/rc" "0" "$RC"
    assert_absent "P03b/non-executable-scanner-silent" "comment-block" "$OUT$ERR"
}

# ============================================================================
# P04 — COMMENT_BLOCK_WARN kill switch, both verdicts
# ============================================================================
p04_kill_switch() {
    local repo; repo="$(make_repo p04 warn "$NON_GITHUB")"
    stage_sample "$repo"
    run_precommit "$repo" "$repo" "COMMENT_BLOCK_WARN=off"
    assert_eq "P04/off-rc" "0" "$RC"
    assert_absent "P04/off-silences-section" "$WARN_LINE" "$OUT$ERR"
    # `off` must short-circuit before the scanner runs, not merely swallow it.
    assert_eq "P04/off-skips-invocation" "not-invoked" "$(scanner_argv "$repo")"

    # Symmetric counterpart. run_precommit removes COMMENT_BLOCK_WARN from the
    # child environment first, so this is the genuinely-unset branch and not
    # whatever the developer's .env happens to hold.
    run_precommit "$repo" "$repo"
    assert_contains "P04/unset-still-emits" "$WARN_LINE" "$OUT$ERR"
    assert_eq "P04/unset-invokes-scanner" "--staged" "$(scanner_argv "$repo")"
}

p01_warns_and_continues
p02_foreign_repo_untouched
p02b_linked_worktree_is_the_same_repo
p03_agents_repo_without_scanner_silent
p03b_scanner_present_but_not_executable
p04_kill_switch
