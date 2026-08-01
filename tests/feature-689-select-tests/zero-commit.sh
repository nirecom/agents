# Part of tests/feature-689-select-tests.sh (sourced, not standalone).
# Tests: bin/select-tests.sh, bin/resolve-merge-base.sh
# Tags: test-selection, merge-base, zero-commit, degradation, scope:issue-specific, pwsh-not-required, TL2

# ============================================================================
# S14-S19 — #1779: the branch that has not committed yet.
#
# `git switch -c work` and then work. Until the first commit lands, `git merge-base main HEAD`
# answers with HEAD itself — a CORRECT base, resolved by the ordinary path, reported as
# RESOLVED. `<base>...HEAD` is then empty by construction, so the selector selects nothing and
# exits 0, and run-tests reports "0 tests" over a working tree full of staged work. Nothing in
# the chain is in an error state; that is precisely why it went unnoticed.
#
# This is NOT S11. There an empty range between two real commits means nothing changed, and an
# empty selection is the right answer. Here the range is empty because there is no range, and
# the right answer is the working tree. S11 now asserts base != HEAD so the two fixtures cannot
# drift into each other.
#
# The fallback has to read BOTH halves of the working tree: `git diff HEAD` covers tracked
# files (staged and unstaged alike) and is blind to untracked ones, so a brand-new file — the
# most likely thing on a branch this young — would be dropped by the tracked half alone.
# S14b/S15 are what keep the two halves from collapsing into one.
#
# RUN_TL3 is pinned explicitly on every row. Left unset it is read from the developer's real
# config, and a host with RUN_TL3=on would append the whole TL3 tier, making "non-empty
# selection" true for a reason none of these rows are about.
# ============================================================================

# A repository whose current branch has ZERO commits of its own: one base commit, `base` pinned
# to it, and everything after that left in the working tree. base == HEAD by construction.
#
# A file argument prefixed `+` is NEW (absent from the base commit); an unprefixed one is
# tracked by the base commit and then modified. That split is what lets one fixture express
# "tracked change", "new file", and S14b's "both at once" without three near-copies.
#
# <mode> controls staging only:
#   staged     `git add -A` after the edits — issue #1779's reported scenario
#   unstaged   edits left in the worktree, never added
#   untracked  no add either; asserts every file was given as new
make_zero_commit_repo() { # <repo> <mode> [ [+]path... ]
    local repo="$1" mode="$2"; shift 2
    local f p
    mkdir -p "$repo/tests/_archive" "$repo/bin" "$repo/skills/run-tests" "$repo/docs"
    git -C "$repo" init -q
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name  "Test"
    : > "$repo/tests/run-tests.sh"
    : > "$repo/tests/feature-689-select-tests.sh"
    # Pre-create the tracked files so a later edit to them is a MODIFICATION rather than an
    # addition; the `+` ones are deliberately left out of this commit.
    for f in "$@"; do
        case "$f" in
            +*) continue ;;
        esac
        mkdir -p "$repo/$(dirname "$f")"
        echo "original" > "$repo/$f"
    done
    git -C "$repo" add -A
    git -C "$repo" -c core.hooksPath= commit -q -m "base"
    # No second commit. `base` and HEAD are the same object from here on.
    git -C "$repo" branch -f base HEAD

    for f in "$@"; do
        p="${f#+}"
        if [ "$mode" = "untracked" ] && [ "$p" = "$f" ]; then
            fail "make_zero_commit_repo: mode=untracked was given a tracked path '$f'"
            return 1
        fi
        mkdir -p "$repo/$(dirname "$p")"
        echo "change" >> "$repo/$p"
    done
    [ "$mode" = "staged" ] && git -C "$repo" add -A
    return 0
}

# Guards every row below: if the fixture stopped producing base == HEAD there would be no
# zero-commit condition left to test, and the rows would pass or fail for unrelated reasons.
assert_zero_commit() { # <row> <repo> ; 0 when the premise holds
    local row="$1" repo="$2"
    if [ "$(git -C "$repo" rev-parse base)" = "$(git -C "$repo" rev-parse HEAD)" ]; then
        return 0
    fi
    fail "$row: fixture premise broken — base != HEAD, so this is not a zero-commit branch"
    return 1
}

# S14: the tracked, unstaged half. A non-empty selection is the assertion; the degradation
# notice on stderr is the other half of it, because a selector that silently switched ranges
# would leave the caller believing it diffed the branch.
test_S14_zero_commit_unstaged_selects() {
    local repo="$TMPDIR_BASE/s14"
    make_zero_commit_repo "$repo" unstaged "bin/select-tests.sh" || return
    assert_zero_commit "S14_zero_commit_unstaged_selects" "$repo" || return
    run_auto "$repo" RESOLVED 0 BASE_IS_HEAD=true RUN_TL3=off
    if [ "$SA_RC" != "0" ]; then
        fail "S14_zero_commit_unstaged_selects: expected exit 0, got rc=$SA_RC
--- stderr ---
$SA_ERR"
    elif ! echo "$SA_OUT" | grep -q "tests/feature-689-select-tests.sh"; then
        fail "S14_zero_commit_unstaged_selects: an unstaged change to bin/select-tests.sh on a zero-commit branch selected nothing
--- output ---
$SA_OUT
--- stderr ---
$SA_ERR"
    elif ! printf '%s\n' "$SA_ERR" | grep -qiE "base_is_head|zero[- ]commit|working tree|uncommitted"; then
        fail "S14_zero_commit_unstaged_selects: the range was switched without saying so on stderr
--- stderr ---
$SA_ERR"
    else
        pass "S14_zero_commit_unstaged_selects: a zero-commit branch selects from the working tree and says it degraded"
    fi
}

# S14b: #1779 as reported — everything `git add -A`ed, nothing committed. Both a modified
# tracked file and a new file, because a fallback built on `git diff HEAD` alone covers the
# first and misses the second, and staging does not change that.
test_S14b_zero_commit_staged_selects_both() {
    local repo="$TMPDIR_BASE/s14b"
    make_zero_commit_repo "$repo" staged "bin/select-tests.sh" "+bin/zero-commit.sh" || return
    assert_zero_commit "S14b_zero_commit_staged_selects_both" "$repo" || return
    run_auto "$repo" RESOLVED 0 BASE_IS_HEAD=true RUN_TL3=off
    local missing=""
    echo "$SA_OUT" | grep -q "tests/feature-689-select-tests.sh" || missing="$missing [select-tests stem]"
    echo "$SA_OUT" | grep -q "tests/feature-1779-zero-commit.sh" || missing="$missing [zero-commit stem]"
    if [ "$SA_RC" != "0" ]; then
        fail "S14b_zero_commit_staged_selects_both: expected exit 0, got rc=$SA_RC
--- stderr ---
$SA_ERR"
    elif [ -n "$missing" ]; then
        fail "S14b_zero_commit_staged_selects_both: missing$missing
--- output ---
$SA_OUT
--- stderr ---
$SA_ERR"
    else
        pass "S14b_zero_commit_staged_selects_both: fully staged work on a zero-commit branch selects both stems"
    fi
}

# S15: the untracked half on its own. `git diff HEAD` reports nothing for this repository, so
# a fallback that stopped there would produce the same empty selection as the bug.
test_S15_zero_commit_untracked_selects() {
    local repo="$TMPDIR_BASE/s15"
    make_zero_commit_repo "$repo" untracked "+bin/zero-commit.sh" || return
    assert_zero_commit "S15_zero_commit_untracked_selects" "$repo" || return
    # Premise: the tracked half really is blind here, so the row can only pass via ls-files.
    if [ -n "$(git -C "$repo" diff --name-only HEAD)" ]; then
        fail "S15_zero_commit_untracked_selects: fixture premise broken — git diff HEAD is non-empty, so the untracked path is not being exercised"
        return
    fi
    run_auto "$repo" RESOLVED 0 BASE_IS_HEAD=true RUN_TL3=off
    if [ "$SA_RC" != "0" ]; then
        fail "S15_zero_commit_untracked_selects: expected exit 0, got rc=$SA_RC
--- stderr ---
$SA_ERR"
    elif echo "$SA_OUT" | grep -q "tests/feature-1779-zero-commit.sh"; then
        pass "S15_zero_commit_untracked_selects: an untracked-only new file is still picked up"
    else
        fail "S15_zero_commit_untracked_selects: the new untracked file was dropped from the fallback set
--- output ---
$SA_OUT
--- stderr ---
$SA_ERR"
    fi
}

# S16: an OLD resolver. The field is new, so a copy of bin/resolve-merge-base.sh that predates
# the fix simply does not print it — and the absent field must not read as `false`, which is
# the answer that reproduces the bug. The selector can settle the question itself
# (`git rev-parse <base>` against HEAD), and it has to say that it did.
test_S16_zero_commit_field_absent_still_falls_back() {
    local repo="$TMPDIR_BASE/s16"
    make_zero_commit_repo "$repo" staged "bin/select-tests.sh" || return
    assert_zero_commit "S16_zero_commit_field_absent_still_falls_back" "$repo" || return
    run_auto "$repo" RESOLVED 0 BASE_IS_HEAD=omit RUN_TL3=off
    if [ "$SA_RC" != "0" ]; then
        fail "S16_zero_commit_field_absent_still_falls_back: expected exit 0, got rc=$SA_RC
--- stderr ---
$SA_ERR"
    elif ! echo "$SA_OUT" | grep -q "tests/feature-689-select-tests.sh"; then
        fail "S16_zero_commit_field_absent_still_falls_back: with base_is_head absent the selector fell back to the empty range
--- output ---
$SA_OUT
--- stderr ---
$SA_ERR"
    elif ! printf '%s\n' "$SA_ERR" | grep -qiE "base_is_head"; then
        fail "S16_zero_commit_field_absent_still_falls_back: the selector did not report that the resolver never told it
--- stderr ---
$SA_ERR"
    else
        pass "S16_zero_commit_field_absent_still_falls_back: a resolver too old to report base_is_head is detected locally and noted"
    fi
}

# S17: the degraded set has to feed the TL3 trigger exactly like an ordinary one. Otherwise the
# tier silently stops running for the entire pre-first-commit window of every branch.
test_S17_zero_commit_tl3_appends() {
    local repo="$TMPDIR_BASE/s17"
    make_zero_commit_repo "$repo" staged "bin/select-tests.sh" || return
    assert_zero_commit "S17_zero_commit_tl3_appends" "$repo" || return
    run_auto "$repo" RESOLVED 0 BASE_IS_HEAD=true RUN_TL3=on
    if [ "$SA_RC" != "0" ]; then
        fail "S17_zero_commit_tl3_appends: the run did not succeed (rc=$SA_RC), so nothing about TL3 is proven
--- stderr ---
$SA_ERR"
    elif echo "$SA_OUT" | grep -q "TL3-fake-"; then
        pass "S17_zero_commit_tl3_appends: RUN_TL3=on appends the tier from the degraded change set"
    else
        fail "S17_zero_commit_tl3_appends: a non-docs zero-commit change did not trigger TL3
--- output ---
$SA_OUT"
    fi
}

# S18: and the docs-only exemption survives the degradation too. The fallback must hand
# bin/is-docs-only the same kind of path list, or the cheap case starts paying the TL3 bill.
#
# "no TL3" is a NEGATIVE assertion and the bug satisfies it for free — an empty change set
# skips the tier for entirely the wrong reason. So the row also requires the degradation notice
# on stderr: without it the run never reached the docs-only classifier at all and the absence
# of TL3 proves nothing.
test_S18_zero_commit_docs_only_skips_tl3() {
    local repo="$TMPDIR_BASE/s18"
    make_zero_commit_repo "$repo" staged "docs/history.md" || return
    assert_zero_commit "S18_zero_commit_docs_only_skips_tl3" "$repo" || return
    run_auto "$repo" RESOLVED 0 BASE_IS_HEAD=true RUN_TL3=on
    if [ "$SA_RC" != "0" ]; then
        fail "S18_zero_commit_docs_only_skips_tl3: the run did not succeed (rc=$SA_RC), so 'no TL3' proves nothing
--- stderr ---
$SA_ERR"
    elif ! printf '%s\n' "$SA_ERR" | grep -qiE "base_is_head|zero[- ]commit|working tree|uncommitted"; then
        fail "S18_zero_commit_docs_only_skips_tl3: no degradation notice on stderr, so the run never reached the docs-only classifier and 'no TL3' proves nothing
--- stderr ---
$SA_ERR"
    elif echo "$SA_OUT" | grep -q "TL3-fake-"; then
        fail "S18_zero_commit_docs_only_skips_tl3: TL3 appended for a docs-only zero-commit change
--- output ---
$SA_OUT"
    else
        pass "S18_zero_commit_docs_only_skips_tl3: the docs-only exemption still applies on the degraded path"
    fi
}

# S19: the degraded path is still git, and git can still fail. When it does, the answer is the
# selector's existing git-error exit 1 — NOT exit 0 with an empty selection (the #1779 failure
# mode dressed up as success) and NOT exit 4 (which claims the base is untrustworthy when the
# resolver answered fine).
test_S19_zero_commit_git_failure_is_exit_1() {
    local nonrepo="$TMPDIR_BASE/s19-not-a-repo"
    mkdir -p "$nonrepo"
    if git -C "$nonrepo" rev-parse --git-dir >/dev/null 2>&1; then
        fail "S19_zero_commit_git_failure_is_exit_1: fixture premise broken — $nonrepo is inside a git repository"
        return
    fi
    run_auto "$nonrepo" RESOLVED 0 BASE_IS_HEAD=true RUN_TL3=off
    if [ "$SA_RC" = "1" ]; then
        pass "S19_zero_commit_git_failure_is_exit_1: a git failure on the degraded path exits 1"
    else
        fail "S19_zero_commit_git_failure_is_exit_1: expected exit 1, got rc=$SA_RC out='$SA_OUT'
--- stderr ---
$SA_ERR"
    fi
}
