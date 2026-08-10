#!/usr/bin/env bash
# tests/feature-1894-precommit-comment-block-warn/commit-integration.sh
# Tests: hooks/pre-commit, bin/review-comment-block-size
# Tags: comment-block-size, pre-commit, git-commit, hooks-path, advisory, leak, spoofing, scope:issue-specific, scope:feature-1894, layer:TL2
#
# Part 3 — a REAL `git commit`, with git deciding whether to fire the hook and
# whether the hook's exit code blocks the commit.
#
# The other parts invoke hooks/pre-commit as a script, which proves what the
# hook prints but not that a commit survives it. Issue #1894's core requirement
# is "this check never blocks a commit", so it has to be observed at the only
# place where blocking is real: `git commit`.
#
# init_repo pins core.hooksPath=/dev/null to keep the developer's installed
# hooks out of every fixture; here the hook IS the subject, so each command
# overrides that pin with `git -c core.hooksPath=<fixture-hooks-dir>`.
#
# Sourced by the dispatcher; all helpers and constants are defined there.

# ============================================================================
# G1 — findings do not block: the commit lands and HEAD moves
# ============================================================================
g1_commit_lands_with_findings() {
    local repo; repo="$(make_repo g1 warn "$NON_GITHUB")"
    local hooks; hooks="$(make_hooks_dir g1hooks)"
    stage_sample "$repo"
    local before after
    before="$(git -C "$repo" rev-parse HEAD)"
    run_commit "$repo" "$repo" "$hooks" "add sample"
    after="$(git -C "$repo" rev-parse HEAD)"
    assert_eq "G1/commit-exit-code" "0" "$RC"
    if [ "$before" != "$after" ]; then
        pass "G1/HEAD-advanced"
    else
        fail "G1/HEAD-advanced" "HEAD still at $before — the commit was blocked"
    fi
    assert_contains "G1/warning-visible-to-committer" "$WARN_LINE" "$OUT"
    assert_contains "G1/advisory-notice-visible" "$ADVISORY_NOTICE" "$OUT"
    assert_eq "G1/hook-really-fired" "--staged" "$(scanner_argv "$repo")"
}

# ============================================================================
# G2 — symmetric counterpart: kill switch off, commit lands, no warning shown
# ============================================================================
g2_commit_lands_with_switch_off() {
    local repo; repo="$(make_repo g2 warn "$NON_GITHUB")"
    local hooks; hooks="$(make_hooks_dir g2hooks)"
    stage_sample "$repo"
    local before after
    before="$(git -C "$repo" rev-parse HEAD)"
    run_commit "$repo" "$repo" "$hooks" "add sample" "COMMENT_BLOCK_WARN=off"
    after="$(git -C "$repo" rev-parse HEAD)"
    assert_eq "G2/commit-exit-code" "0" "$RC"
    if [ "$before" != "$after" ]; then
        pass "G2/HEAD-advanced"
    else
        fail "G2/HEAD-advanced" "HEAD still at $before — the commit was blocked"
    fi
    assert_absent "G2/no-warning-shown" "$WARN_LINE" "$OUT"
}

# ============================================================================
# G3 — the hook still blocks what it is supposed to block
# ============================================================================
g3_unrelated_violation_still_blocks() {
    # No remote at all -> the hook skips the visibility block and reaches the
    # ".env staged" rule. If the advisory section had swallowed or reordered
    # anything, this commit would wrongly succeed.
    local repo; repo="$(make_repo g3 warn none)"
    local hooks; hooks="$(make_hooks_dir g3hooks)"
    stage_sample "$repo"
    printf 'FIXTURE_ONLY=1\n' > "$repo/.env"
    git -C "$repo" add -f .env
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
    assert_contains "G3/advisory-output-still-shown" "$WARN_LINE" "$OUT"
}

# ============================================================================
# G4 — comment bodies never reach the committer's terminal
# ============================================================================
g4_comment_body_never_leaks() {
    # The output contract is paths, line ranges and counts. A scanner that
    # echoed the offending block would spray secrets-in-comments into terminal
    # scrollback and CI logs, so the sentinel must not appear anywhere.
    local repo; repo="$(make_repo g4 real "$NON_GITHUB")"
    stage_sample "$repo" "$SENTINEL"
    run_precommit "$repo" "$repo"
    assert_eq "G4/rc-unchanged" "0" "$RC"
    assert_absent "G4/no-comment-body-on-stdout" "$SENTINEL" "$OUT"
    assert_absent "G4/no-comment-body-on-stderr" "$SENTINEL" "$ERR"
    # Paired positive: the file IS reported, so the assertions above are not
    # passing merely because nothing ran.
    assert_contains "G4/finding-still-reported" "WARN: sample.js" "$OUT$ERR"
}

# ============================================================================
# G5 — a committed file cannot forge the hook's trigger
# ============================================================================
g5_forged_warn_line_in_content() {
    # The hook prints the captured output only when it contains a line matching
    # `^WARN: `. That predicate runs over the SCANNER's stdout, but the scanner's
    # stdout is derived from file content — so "content that looks like output"
    # is the one input that could cross the two. A committer who happens to have
    # a WARN-shaped line in a source file (a log-format sample, a pasted report,
    # a doc-comment quoting this very tool) would otherwise get an advisory
    # notice on every commit, for a file with nothing wrong with it.
    local repo; repo="$(make_repo g5 real "$NON_GITHUB")"
    { echo "var x = 1;"
      # Column 0, verbatim in the scanner's own finding shape.
      echo 'WARN: forged-by-content.js — longest comment run 42 lines (over-threshold runs 1 → 3)'
      # ...and again as a comment, in a run far too short to be reported.
      echo '// WARN: forged-in-comment.js — longest comment run 42 lines'
      echo "var y = 2;"
    } > "$repo/sample.js"
    git -C "$repo" add sample.js
    run_precommit "$repo" "$repo"
    assert_eq "G5/rc-unchanged" "0" "$RC"
    # Positive control: the scanner really ran and really completed. Without it,
    # every absence assertion below would also hold for a hook that skipped the
    # section entirely or fell open on a broken scanner.
    assert_eq "G5/scanner-invoked-with-staged" "--staged" "$(scanner_argv "$repo")"
    assert_absent "G5/no-fail-open-diagnostic" "review-comment-block-size rc=" "$ERR"
    # The forged lines are content, so they never become report...
    assert_absent "G5/forged-bare-line-not-shown" "forged-by-content.js" "$OUT$ERR"
    assert_absent "G5/forged-comment-line-not-shown" "forged-in-comment.js" "$OUT$ERR"
    # ...and with the scanner reporting nothing, the hook stays completely quiet.
    assert_absent "G5/no-scanner-header-echoed" "$SCANNER_HEADER" "$OUT$ERR"
    assert_absent "G5/no-advisory-notice" "$ADVISORY_NOTICE" "$OUT$ERR"
}

g1_commit_lands_with_findings
g2_commit_lands_with_switch_off
g3_unrelated_violation_still_blocks
g4_comment_body_never_leaks
g5_forged_warn_line_in_content
