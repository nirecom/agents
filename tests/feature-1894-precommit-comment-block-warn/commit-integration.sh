#!/usr/bin/env bash
# tests/feature-1894-precommit-comment-block-warn/commit-integration.sh
# Tests: hooks/pre-commit, bin/review-comment-block-size
# Tags: comment-block-size, pre-commit, git-commit, hooks-path, block, leak, spoofing, scope:issue-specific, scope:feature-1894, layer:TL2
#
# Part 3 — a REAL `git commit`, with git deciding whether to fire the hook and
# whether the hook's exit code blocks the commit.
#
# The other parts invoke hooks/pre-commit as a script, which proves what the
# hook prints but not what happens to the commit. Issue #1894's core requirement
# is now "this check DOES block a commit", and blocking is only real in one
# place: `git commit` leaving HEAD where it was. Both directions are asserted —
# a gate that blocks everything is as broken as one that blocks nothing.
#
# init_repo pins core.hooksPath=/dev/null to keep the developer's installed
# hooks out of every fixture; here the hook IS the subject, so each command
# overrides that pin with `git -c core.hooksPath=<fixture-hooks-dir>`.
#
# Sourced by the dispatcher; all helpers and constants are defined there.

# ============================================================================
# G1 — findings block: the commit is rejected and HEAD does not move
# ============================================================================
g1_commit_blocked_by_findings() {
    local repo; repo="$(make_repo g1 block "$NON_GITHUB")"
    local hooks; hooks="$(make_hooks_dir g1hooks "$repo")"
    stage_sample "$repo"
    local before after
    before="$(git -C "$repo" rev-parse HEAD)"
    run_commit "$repo" "$repo" "$hooks" "add sample"
    after="$(git -C "$repo" rev-parse HEAD)"
    if [ "$RC" != "0" ]; then
        pass "G1/commit-exit-code-nonzero"
    else
        fail "G1/commit-exit-code-nonzero" "git commit succeeded despite a BLOCK finding"
    fi
    assert_eq "G1/HEAD-unchanged" "$before" "$after"
    assert_contains "G1/finding-visible-to-committer" "$BLOCK_LINE" "$OUT"
    assert_contains "G1/blocked-notice-visible" "$BLOCK_NOTICE" "$OUT"
    assert_absent "G1/no-advisory-notice" "$ADVISORY_NOTICE" "$OUT"
    assert_eq "G1/hook-really-fired" "--staged" "$(scanner_argv "$repo")"
    # The staged content must survive a blocked commit: a gate that also
    # discarded the index would be far worse than the problem it prevents.
    assert_contains "G1/index-intact" "sample.js" "$(git -C "$repo" diff --cached --name-only)"
}

# ============================================================================
# G2 — symmetric counterpart: kill switch off, commit lands, nothing shown
# ============================================================================
g2_commit_lands_with_switch_off() {
    local repo; repo="$(make_repo g2 block "$NON_GITHUB")"
    local hooks; hooks="$(make_hooks_dir g2hooks "$repo")"
    stage_sample "$repo"
    local before after
    before="$(git -C "$repo" rev-parse HEAD)"
    run_commit "$repo" "$repo" "$hooks" "add sample" "COMMENT_BLOCK_ENFORCE=off"
    after="$(git -C "$repo" rev-parse HEAD)"
    assert_eq "G2/commit-exit-code" "0" "$RC"
    if [ "$before" != "$after" ]; then
        pass "G2/HEAD-advanced"
    else
        fail "G2/HEAD-advanced" "HEAD still at $before — the commit was blocked"
    fi
    assert_absent "G2/no-finding-shown" "$BLOCK_LINE" "$OUT"
}

# ============================================================================
# G2b — a clean scan lets a real commit through
#
# Without this row, G1 would be satisfied by a hook that blocks unconditionally.
# ============================================================================
g2b_clean_commit_lands() {
    local repo; repo="$(make_repo g2b clean "$NON_GITHUB")"
    local hooks; hooks="$(make_hooks_dir g2bhooks "$repo")"
    stage_sample "$repo"
    local before after
    before="$(git -C "$repo" rev-parse HEAD)"
    run_commit "$repo" "$repo" "$hooks" "add sample"
    after="$(git -C "$repo" rev-parse HEAD)"
    assert_eq "G2b/commit-exit-code" "0" "$RC"
    if [ "$before" != "$after" ]; then
        pass "G2b/HEAD-advanced"
    else
        fail "G2b/HEAD-advanced" "a clean scan blocked the commit"
    fi
    assert_eq "G2b/hook-really-fired" "--staged" "$(scanner_argv "$repo")"
}

# ============================================================================
# G2c — a broken scanner must NOT block (fail-open), and must say so
#
# The asymmetry with G1 is the design decision recorded in detail plan S2-5:
# rc 1 is a verdict, every other non-zero rc is an outage. Conflating them means
# a bad Node install brick-walls every commit on the machine.
# ============================================================================
g2c_broken_scanner_fails_open() {
    local repo; repo="$(make_repo g2c rc3 "$NON_GITHUB")"
    local hooks; hooks="$(make_hooks_dir g2chooks "$repo")"
    stage_sample "$repo"
    local before after
    before="$(git -C "$repo" rev-parse HEAD)"
    run_commit "$repo" "$repo" "$hooks" "add sample"
    after="$(git -C "$repo" rev-parse HEAD)"
    assert_eq "G2c/commit-exit-code" "0" "$RC"
    if [ "$before" != "$after" ]; then
        pass "G2c/HEAD-advanced"
    else
        fail "G2c/HEAD-advanced" "an rc-3 internal error blocked the commit (must fail open)"
    fi
    # Fail-open is only acceptable while it is loud (detail plan S2-5).
    assert_contains "G2c/failopen-diagnostic-shown" "$FAILOPEN_NOTICE" "$OUT"

    # An rc the contract does not name at all takes the same path.
    local r2; r2="$(make_repo g2c2 rc7 "$NON_GITHUB")"
    local h2; h2="$(make_hooks_dir g2c2hooks "$r2")"
    stage_sample "$r2"
    before="$(git -C "$r2" rev-parse HEAD)"
    run_commit "$r2" "$r2" "$h2" "add sample"
    after="$(git -C "$r2" rev-parse HEAD)"
    assert_eq "G2c/unknown-rc-commit-exit-code" "0" "$RC"
    if [ "$before" != "$after" ]; then
        pass "G2c/unknown-rc-HEAD-advanced"
    else
        fail "G2c/unknown-rc-HEAD-advanced" "rc 7 blocked the commit"
    fi
    assert_contains "G2c/unknown-rc-diagnostic-shown" "$FAILOPEN_NOTICE" "$OUT"
}

# ============================================================================
# G3 — the hook's other blocking rules are unaffected
# ============================================================================
g3_unrelated_violation_still_blocks() {
    # No remote at all -> the hook skips the visibility block and reaches the
    # ".env staged" rule. If the comment-block section had swallowed or
    # reordered anything, this commit would wrongly succeed.
    local repo; repo="$(make_repo g3 block none)"
    local hooks; hooks="$(make_hooks_dir g3hooks "$repo")"
    stage_sample "$repo"
    printf 'FIXTURE_ONLY=1\n' > "$repo/.env.staged-probe"
    git -C "$repo" add -f .env.staged-probe
    git -C "$repo" mv -f .env.staged-probe .env 2>/dev/null || {
        printf 'FIXTURE_ONLY=1\n' > "$repo/.env"
        git -C "$repo" add -f .env
    }
    local before after
    before="$(git -C "$repo" rev-parse HEAD)"
    run_commit "$repo" "$repo" "$hooks" "should be blocked"
    after="$(git -C "$repo" rev-parse HEAD)"
    if [ "$RC" != "0" ]; then
        pass "G3/blocking-rule-still-blocks"
    else
        fail "G3/blocking-rule-still-blocks" "commit succeeded with a staged .env"
    fi
    assert_eq "G3/HEAD-unchanged" "$before" "$after"
}

# ============================================================================
# G4 — comment bodies never reach the committer's terminal
# ============================================================================
g4_comment_body_never_leaks() {
    # The output contract is paths, line ranges and counts. A scanner that
    # echoed the offending block would spray secrets-in-comments into terminal
    # scrollback and CI logs — and now that the output is printed on a BLOCKED
    # commit, it is exactly the output a frustrated committer will paste into a
    # chat window. The sentinel must not appear anywhere.
    local repo; repo="$(make_repo g4 real "$NON_GITHUB")"
    stage_sample "$repo" "$SENTINEL"
    run_precommit "$repo" "$repo"
    assert_absent "G4/no-comment-body-on-stdout" "$SENTINEL" "$OUT"
    assert_absent "G4/no-comment-body-on-stderr" "$SENTINEL" "$ERR"
    # Paired positive: the file IS reported, so the assertions above are not
    # passing merely because nothing ran.
    assert_contains "G4/finding-still-reported" "sample.js" "$OUT$ERR"
    assert_eq "G4/real-scanner-blocked-the-commit" "1" "$RC"
}

# ============================================================================
# G5 — a committed file cannot forge the hook's trigger
# ============================================================================
g5_forged_finding_line_in_content() {
    # The hook's verdict now rides on the scanner's exit code rather than on a
    # grep of its stdout, which is the stronger design — but the scanner's
    # stdout is still derived from file content, so "content that looks like
    # output" remains the one input that could cross the two. A committer whose
    # source file happens to contain a BLOCK-shaped line (a log-format sample, a
    # pasted report, a doc-comment quoting this very tool) must not be blocked
    # by their own text.
    local repo; repo="$(make_repo g5 real "$NON_GITHUB")"
    { echo "var x = 1;"
      # Column 0, verbatim in the scanner's own finding shape.
      echo 'BLOCK: forged-by-content.js — longest comment run 42 lines (over-threshold runs 1 → 3)'
      # ...and again as a comment, in a run far too short to be reported.
      echo '// BLOCK: forged-in-comment.js — longest comment run 42 lines'
      echo "var y = 2;"
    } > "$repo/sample.js"
    git -C "$repo" add sample.js
    run_precommit "$repo" "$repo"
    assert_eq "G5/rc-is-0" "0" "$RC"
    # Positive control: the scanner really ran and really completed. Without it,
    # every absence assertion below would also hold for a hook that skipped the
    # section entirely or fell open on a broken scanner.
    assert_eq "G5/scanner-invoked-with-staged" "--staged" "$(scanner_argv "$repo")"
    assert_absent "G5/no-fail-open-diagnostic" "$FAILOPEN_NOTICE" "$ERR"
    # The forged lines are content, so they never become report...
    assert_absent "G5/forged-bare-line-not-shown" "forged-by-content.js" "$OUT$ERR"
    assert_absent "G5/forged-comment-line-not-shown" "forged-in-comment.js" "$OUT$ERR"
    # ...and with the scanner reporting nothing, the hook stays completely quiet.
    assert_absent "G5/no-scanner-header-echoed" "$SCANNER_HEADER" "$OUT$ERR"
    assert_absent "G5/no-blocked-notice" "$BLOCK_NOTICE" "$OUT$ERR"
}

# ============================================================================
# G6 — the one-word bypass, attempted the way it would actually be attempted
#
# `COMMENT_BLOCK_ENFORCE=off git commit -m ...` is a single word in front of a
# command someone is already typing. Part 1 pins that the hook ignores the
# ambient value; this pins the consequence that matters — the commit still does
# not land. Same for the threshold, which is the quieter of the two bypasses
# because it leaves the check nominally enabled.
# ============================================================================
g6_ambient_env_cannot_unblock_a_commit() {
    local repo; repo="$(make_repo g6 block "$NON_GITHUB")"
    local hooks; hooks="$(make_hooks_dir g6hooks "$repo")"
    stage_sample "$repo"
    local before after
    before="$(git -C "$repo" rev-parse HEAD)"
    run_commit_ambient "$repo" "$repo" "$hooks" "sneak it past" "COMMENT_BLOCK_ENFORCE=off"
    after="$(git -C "$repo" rev-parse HEAD)"
    if [ "$RC" != "0" ]; then
        pass "G6/ambient-killswitch-commit-still-rejected"
    else
        fail "G6/ambient-killswitch-commit-still-rejected" "COMMENT_BLOCK_ENFORCE=off git commit succeeded"
    fi
    assert_eq "G6/ambient-killswitch-HEAD-unchanged" "$before" "$after"

    # The threshold is consumed by the CLI, not by the hook, so this row runs
    # the real scanner: a stub would return rc 1 regardless and the assertion
    # would hold even if the ambient value were honoured.
    local r2; r2="$(make_repo g6b real "$NON_GITHUB")"
    local h2; h2="$(make_hooks_dir g6bhooks "$r2")"
    stage_sample "$r2"
    before="$(git -C "$r2" rev-parse HEAD)"
    run_commit_ambient "$r2" "$r2" "$h2" "raise the bar" "COMMENT_BLOCK_MAX_LINES=999999"
    after="$(git -C "$r2" rev-parse HEAD)"
    if [ "$RC" != "0" ]; then
        pass "G6/ambient-threshold-commit-still-rejected"
    else
        fail "G6/ambient-threshold-commit-still-rejected" "an ambient threshold lifted the gate"
    fi
    assert_eq "G6/ambient-threshold-HEAD-unchanged" "$before" "$after"
}

g1_commit_blocked_by_findings
g2_commit_lands_with_switch_off
g2b_clean_commit_lands
g2c_broken_scanner_fails_open
g3_unrelated_violation_still_blocks
g4_comment_body_never_leaks
g5_forged_finding_line_in_content
g6_ambient_env_cannot_unblock_a_commit
