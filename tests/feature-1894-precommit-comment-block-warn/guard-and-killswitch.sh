#!/usr/bin/env bash
# tests/feature-1894-precommit-comment-block-warn/guard-and-killswitch.sh
# Tests: hooks/pre-commit, bin/review-comment-block-size
# Tags: comment-block-size, pre-commit, guard, kill-switch, argv, worktree, dotenv, scope:issue-specific, scope:feature-1894, layer:TL2
#
# Part 1 — who decides whether the section runs at all.
#
# Two independent conditions must BOTH hold: (a) the repo being committed to is
# the agents session repo, and (b) the scanner exists and is executable. Each
# verdict is pinned on its own (CPR-ORTH), and every case also asserts the argv
# the hook handed the scanner — "silent" must mean "not invoked", not "invoked
# and happened to print nothing".
#
# Now that the section blocks, a third question joins them: whether the kill
# switch can be flipped by whoever is running `git commit`. It must not be —
# COMMENT_BLOCK_ENFORCE is read from the config dir's .env only, so P05 drives
# both the honest path (.env) and the spoof (ambient shell variable).
#
# Sourced by the dispatcher; all helpers and constants are defined there.

# ============================================================================
# P01 — both conditions true + findings -> commit BLOCKED
# ============================================================================
p01_blocks_on_findings() {
    local repo; repo="$(make_repo p01 block "$NON_GITHUB")"
    stage_sample "$repo"
    run_precommit "$repo" "$repo" "COMMENT_BLOCK_ENFORCE=on"
    assert_eq "P01/rc-is-1" "1" "$RC"
    assert_contains "P01/full-output-echoed" "$SCANNER_HEADER" "$OUT$ERR"
    assert_contains "P01/block-line-echoed" "$BLOCK_LINE" "$OUT$ERR"
    assert_contains "P01/blocked-notice" "$BLOCK_NOTICE" "$OUT$ERR"
    # The retired advisory sentence must not survive alongside a blocking rc.
    assert_absent "P01/no-advisory-notice" "$ADVISORY_NOTICE" "$OUT$ERR"
    assert_absent "P01/not-reported-as-incomplete" "$FAILOPEN_NOTICE" "$OUT$ERR"
    # The hook must ask for staged mode, exactly once, with no extra flags:
    # `--all` here would scan the whole worktree on every commit.
    assert_eq "P01/scanner-argc" "1" "$(scanner_argc "$repo")"
    assert_eq "P01/scanner-argv" "--staged" "$(scanner_argv "$repo")"
}

# ============================================================================
# P01b — symmetric counterpart: a clean scan must not block, and must be quiet
# ============================================================================
p01b_clean_scan_passes_silently() {
    local repo; repo="$(make_repo p01b clean "$NON_GITHUB")"
    stage_sample "$repo"
    run_precommit "$repo" "$repo"
    assert_eq "P01b/rc-is-0" "0" "$RC"
    assert_eq "P01b/scanner-argv" "--staged" "$(scanner_argv "$repo")"
    # A blocking check that narrates every clean commit trains people to ignore
    # it, which is how the WARN version stopped being read in the first place.
    assert_absent "P01b/no-header-on-clean-run" "$SCANNER_HEADER" "$OUT$ERR"
    assert_absent "P01b/no-blocked-notice" "$BLOCK_NOTICE" "$OUT$ERR"
}

# ============================================================================
# P02 / P02b — condition (a): _is_agents_session_repo(), both verdicts
# ============================================================================
p02_foreign_repo_untouched() {
    # The foreign repo carries its OWN executable scanner, so a silent run can
    # only mean "the repo-identity guard rejected it" — not "nothing to run".
    local cfg; cfg="$(make_repo p02cfg block "$NON_GITHUB")"
    local other; other="$(make_repo p02other block "$NON_GITHUB")"
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
    local cfg; cfg="$(make_repo p02bcfg block "$NON_GITHUB")"
    local wt="$TMPDIR_BASE/p02bwt"
    if ! git -C "$cfg" worktree add -q -b feat "$wt" >/dev/null 2>&1; then
        skip "P02b: git worktree add unavailable in this fixture — linked-worktree identity unverified"
        return
    fi
    stage_sample "$wt"
    run_precommit "$wt" "$cfg"
    assert_eq "P02b/rc-is-1" "1" "$RC"
    assert_contains "P02b/linked-worktree-still-scanned" "$BLOCK_LINE" "$OUT$ERR"
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
# P04 — COMMENT_BLOCK_ENFORCE kill switch, both verdicts
# ============================================================================
p04_kill_switch() {
    local repo; repo="$(make_repo p04 block "$NON_GITHUB")"
    stage_sample "$repo"
    run_precommit "$repo" "$repo" "COMMENT_BLOCK_ENFORCE=off"
    assert_eq "P04/off-rc" "0" "$RC"
    assert_absent "P04/off-silences-section" "$BLOCK_LINE" "$OUT$ERR"
    # `off` must short-circuit before the scanner runs, not merely swallow it.
    assert_eq "P04/off-skips-invocation" "not-invoked" "$(scanner_argv "$repo")"
    # ...but it must not be silent about it. A disabled blocking check that says
    # nothing is indistinguishable from a check that is passing, which is how a
    # gate quietly stops existing (detail plan S2-5).
    assert_contains "P04/off-announces-itself" "comment-block" "$ERR"

    # Symmetric counterpart. The .env is rewritten per invocation, so this is
    # the genuinely-unset branch and not a leftover from the previous case.
    run_precommit "$repo" "$repo"
    assert_eq "P04/unset-rc-is-1" "1" "$RC"
    assert_contains "P04/unset-still-blocks" "$BLOCK_LINE" "$OUT$ERR"
    assert_eq "P04/unset-invokes-scanner" "--staged" "$(scanner_argv "$repo")"

    # A value that is neither on nor off is not "off": only the exact string
    # disables the gate, or a typo becomes a silent bypass.
    run_precommit "$repo" "$repo" "COMMENT_BLOCK_ENFORCE=offf"
    assert_eq "P04/typo-does-not-disable" "1" "$RC"
    run_precommit "$repo" "$repo" "COMMENT_BLOCK_ENFORCE=OFF"
    assert_eq "P04/uppercase-does-not-disable" "1" "$RC"
}

# ============================================================================
# P05 — the kill switch cannot be flipped from the committer's shell
#
# `COMMENT_BLOCK_ENFORCE=off git commit ...` is the single most direct bypass of
# this whole issue, and it costs one word to attempt. The .env-only resolution
# is what closes it, so both halves are pinned: the .env value decides, and the
# ambient value with the OPPOSITE meaning changes nothing.
# ============================================================================
p05_ambient_cannot_disable() {
    local repo; repo="$(make_repo p05 block "$NON_GITHUB")"
    stage_sample "$repo"
    # .env says on (the base pin), the shell says off -> still blocks.
    run_precommit_ambient "$repo" "$repo" "COMMENT_BLOCK_ENFORCE=on"
    assert_eq "P05/premise-env-on-blocks" "1" "$RC"

    _pc_env "$repo" 0 "COMMENT_BLOCK_ENFORCE=on"
    RC=0
    OUT="$( (cd "$repo" \
        && unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID \
        && run_with_timeout 60 env "${PC_ENVS[@]}" "COMMENT_BLOCK_ENFORCE=off" \
            bash "$repo/hooks/pre-commit") 2>&1 )" || RC=$?
    assert_eq "P05/ambient-off-is-ignored" "1" "$RC"
    assert_contains "P05/ambient-off-still-blocks" "$BLOCK_LINE" "$OUT"

    # The mirror image: .env off, shell on. If the ambient copy were consulted
    # at all, one of these two directions would move.
    _pc_env "$repo" 0 "COMMENT_BLOCK_ENFORCE=off"
    RC=0
    OUT="$( (cd "$repo" \
        && unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID \
        && run_with_timeout 60 env "${PC_ENVS[@]}" "COMMENT_BLOCK_ENFORCE=on" \
            bash "$repo/hooks/pre-commit") 2>&1 )" || RC=$?
    assert_eq "P05/ambient-on-cannot-re-enable" "0" "$RC"
}

# ============================================================================
# P06 — the obsolete names are inert, and say so once
#
# COMMENT_BLOCK_WARN=off in a stale .env must NOT disable the new gate: honouring
# it would let a setting written to silence a warning silently switch off a
# block (detail plan S4-2, the fail-open direction). It gets a NOTE, not effect.
# ============================================================================
p06_obsolete_names_are_inert() {
    local repo; repo="$(make_repo p06 block "$NON_GITHUB")"
    stage_sample "$repo"
    run_precommit "$repo" "$repo" "COMMENT_BLOCK_WARN=off"
    assert_eq "P06/obsolete-killswitch-does-not-disable" "1" "$RC"
    assert_contains "P06/obsolete-killswitch-still-blocks" "$BLOCK_LINE" "$OUT$ERR"

    # The threshold twin: an obsolete name must not raise the bar either.
    run_precommit "$repo" "$repo" "COMMENT_BLOCK_WARN_LINES=999999"
    assert_eq "P06/obsolete-threshold-does-not-lift" "1" "$RC"
}

p01_blocks_on_findings
p01b_clean_scan_passes_silently
p02_foreign_repo_untouched
p02b_linked_worktree_is_the_same_repo
p03_agents_repo_without_scanner_silent
p03b_scanner_present_but_not_executable
p04_kill_switch
p05_ambient_cannot_disable
p06_obsolete_names_are_inert
