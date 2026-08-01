# Part of tests/feature-689-select-tests.sh (sourced, not standalone).
# Tests: bin/select-tests.sh
# Tags: test-selection, merge-base, zero-commit, degradation, gitignore, parser, table-driven, scope:issue-specific, pwsh-not-required, TL2

# ============================================================================
# S21-S24 — the EDGES of the working-tree fallback: where it must not reach, and what the
# kv parser does with every value of base_is_head it can be handed.
#
# S14-S19 pin the fallback where it is supposed to fire. These rows pin the other three sides
# of it, all of which fail silently rather than loudly:
#
#   S21  an ordinary branch WITH commits, whose working tree happens to be dirty. The fallback
#        must not fire; if it did, every normal run would start selecting tests for scratch
#        files nobody is asking about — and, worse, would narrow to the working tree and lose
#        the committed range entirely on a clean checkout.
#   S22  a gitignored file is not work. Build output and local scratch live there.
#   S23  and it stays invisible even when the fallback IS firing for other reasons.
#   S24  the parser table. `base_is_head` arrives as text from another process; `true`, `false`,
#        nothing at all and something unrecognised are four different inputs and the selector's
#        answer to each has to be a decision rather than an accident of shell truthiness.
#
# RUN_TL3 is pinned on every row for the reason given in zero-commit.sh: unpinned, a host with
# RUN_TL3=on appends the whole tier and every "the selection is empty" assertion below becomes
# false for a reason none of these rows are about.
# ============================================================================

# The degradation notice the selector prints when it switches to the working tree. Matching the
# notice rather than the selection is what lets a row tell "the fallback did not fire" apart from
# "the fallback fired and found nothing" — two outcomes with identical stdout.
ZC_DEGRADE_RE='base_is_head|zero[- ]commit|working tree|uncommitted'

zc_check() { # <row> <desc> <want> <got>
    if [ "$4" = "$3" ]; then pass "$1: $2"; else fail "$1: $2 -- want [$3] got [$4]"; fi
}

# S21: an ordinary branch, with commits, carrying an uncommitted decoy that is NOT in the
# committed range — and with the resolver too old to report base_is_head, so the selector has to
# settle the question itself. The decoy's stem has a test file of its own in the fake tree, so if
# the local check answered "zero commit" the decoy would appear in stdout and be visible here.
#
# This is the CPR-5 counterpart of S16: the same absent field, the same local observation, and
# the OPPOSITE answer. S16 alone would be satisfied by a selector that degraded unconditionally
# whenever the field was missing, which is every old-resolver install on every ordinary branch.
test_S21_normal_branch_field_absent_ignores_worktree() {
    local repo="$TMPDIR_BASE/s21"
    make_repo "$repo" "bin/select-tests.sh"
    if [ "$(git -C "$repo" rev-parse base)" = "$(git -C "$repo" rev-parse HEAD)" ]; then
        fail "S21_normal_branch_field_absent_ignores_worktree: fixture premise broken — base == HEAD, so this is a zero-commit branch and the row asserts the wrong thing"
        return
    fi
    # The decoy: never committed, never staged, and outside the committed range by construction.
    mkdir -p "$repo/bin"
    printf 'scratch\n' > "$repo/bin/zero-commit.sh"
    run_auto "$repo" RESOLVED 0 BASE_IS_HEAD=omit RUN_TL3=off

    local missing=""
    echo "$SA_OUT" | grep -q "tests/feature-689-select-tests.sh" || missing="$missing [committed-range stem]"
    if [ "$SA_RC" != "0" ]; then
        fail "S21_normal_branch_field_absent_ignores_worktree: expected exit 0, got rc=$SA_RC
--- stderr ---
$SA_ERR"
    elif [ -n "$missing" ]; then
        fail "S21_normal_branch_field_absent_ignores_worktree: missing$missing — the committed range was lost
--- output ---
$SA_OUT"
    elif echo "$SA_OUT" | grep -q "tests/feature-1779-zero-commit.sh"; then
        fail "S21_normal_branch_field_absent_ignores_worktree: an uncommitted decoy leaked into the selection on a branch that has commits
--- output ---
$SA_OUT
--- stderr ---
$SA_ERR"
    elif printf '%s\n' "$SA_ERR" | grep -qiE "$ZC_DEGRADE_RE"; then
        fail "S21_normal_branch_field_absent_ignores_worktree: the selector degraded to the working tree on a branch with commits
--- stderr ---
$SA_ERR"
    else
        pass "S21_normal_branch_field_absent_ignores_worktree: an absent field on an ordinary branch resolves to the committed range, and working-tree noise stays out"
    fi
}

# A zero-commit fixture whose .gitignore is part of the BASE COMMIT, plus one ignored file in the
# working tree. Committing the .gitignore matters: staged, it would itself be a change, and then
# S22's "nothing here is a change" premise would be false before the ignored file even mattered.
# Any trailing paths are tracked files that get modified and staged, exactly as in
# make_zero_commit_repo's `staged` mode.
make_zc_ignoring() { # <repo> <ignored-path> [tracked-path...]
    local repo="$1" ignored="$2"; shift 2
    local f
    mkdir -p "$repo/tests/_archive" "$repo/bin" "$repo/docs"
    git -C "$repo" init -q
    git -C "$repo" config core.hooksPath "$repo/.git/no-such-hooks"
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name  "Test"
    printf '%s\n' "$ignored" > "$repo/.gitignore"
    for f in "$@"; do
        mkdir -p "$repo/$(dirname "$f")"
        printf 'original\n' > "$repo/$f"
    done
    git -C "$repo" add -A
    git -C "$repo" commit -q -m "base"
    git -C "$repo" branch -f base HEAD
    for f in "$@"; do
        printf 'change\n' >> "$repo/$f"
    done
    [ $# -gt 0 ] && git -C "$repo" add -A
    mkdir -p "$repo/$(dirname "$ignored")"
    printf 'build noise\n' > "$repo/$ignored"
    return 0
}

# S22: a zero-commit branch whose ONLY working-tree content is ignored. Nothing here is a change,
# so nothing may be selected and the expensive tier must stay unrun even with RUN_TL3=on.
#
# `git ls-files --others` without `--exclude-standard` is the mistake this row exists for. It is
# one flag, it looks harmless, and with it every `node_modules` and build directory on a
# zero-commit branch becomes a changed file.
test_S22_gitignored_file_is_not_a_change() {
    local repo="$TMPDIR_BASE/s22"
    make_zc_ignoring "$repo" 'bin/zero-commit.sh'
    assert_zero_commit "S22_gitignored_file_is_not_a_change" "$repo" || return
    # Premise: git really is ignoring it. A pattern that did not match would make every
    # assertion below pass while testing nothing.
    if git -C "$repo" ls-files --others --exclude-standard | grep -q 'zero-commit'; then
        fail "S22_gitignored_file_is_not_a_change: fixture premise broken — the .gitignore pattern did not take effect"
        return
    fi
    run_auto "$repo" RESOLVED 0 BASE_IS_HEAD=true RUN_TL3=on
    if [ "$SA_RC" != "0" ]; then
        fail "S22_gitignored_file_is_not_a_change: expected exit 0, got rc=$SA_RC
--- stderr ---
$SA_ERR"
    elif echo "$SA_OUT" | grep -q "tests/feature-1779-zero-commit.sh"; then
        fail "S22_gitignored_file_is_not_a_change: the ignored file produced a stem match
--- output ---
$SA_OUT"
    elif echo "$SA_OUT" | grep -q "TL3-fake-"; then
        fail "S22_gitignored_file_is_not_a_change: the ignored file triggered the TL3 tier
--- output ---
$SA_OUT"
    else
        pass "S22_gitignored_file_is_not_a_change: a gitignored file contributes neither a stem nor a TL3 trigger"
    fi
}

# S23: the same exclusion, but with the fallback demonstrably working. S22's assertions are all
# negative and an empty selection satisfies them for free; here a real staged change is present,
# so the row can only pass if the fallback produced a set AND that set excluded the ignored file.
test_S23_gitignored_excluded_from_a_live_fallback() {
    local repo="$TMPDIR_BASE/s23"
    make_zc_ignoring "$repo" 'bin/zero-commit.sh' "bin/select-tests.sh"
    assert_zero_commit "S23_gitignored_excluded_from_a_live_fallback" "$repo" || return
    run_auto "$repo" RESOLVED 0 BASE_IS_HEAD=true RUN_TL3=off
    if [ "$SA_RC" != "0" ]; then
        fail "S23_gitignored_excluded_from_a_live_fallback: expected exit 0, got rc=$SA_RC
--- stderr ---
$SA_ERR"
    elif ! echo "$SA_OUT" | grep -q "tests/feature-689-select-tests.sh"; then
        fail "S23_gitignored_excluded_from_a_live_fallback: the staged change selected nothing, so the exclusion below proves nothing
--- output ---
$SA_OUT
--- stderr ---
$SA_ERR"
    elif echo "$SA_OUT" | grep -q "tests/feature-1779-zero-commit.sh"; then
        fail "S23_gitignored_excluded_from_a_live_fallback: the ignored file joined a working fallback set
--- output ---
$SA_OUT"
    else
        pass "S23_gitignored_excluded_from_a_live_fallback: a live fallback set carries the staged change and not the ignored file"
    fi
}

# S23b: a zero-commit branch with NOTHING in it. Not a bug and not an error — there genuinely is
# no work — so the answer is the ordinary empty selection and exit 0, never a crash or a non-zero
# code. `set -euo pipefail` plus a `grep -c` over empty input is the shape that gets this wrong,
# and it would break the branch-just-created case for every user of the selector.
test_S23b_clean_zero_commit_branch_is_empty_not_an_error() {
    local repo="$TMPDIR_BASE/s23b"
    make_zero_commit_repo "$repo" staged || return
    assert_zero_commit "S23b_clean_zero_commit_branch_is_empty_not_an_error" "$repo" || return
    if [ -n "$(git -C "$repo" status --porcelain)" ]; then
        fail "S23b_clean_zero_commit_branch_is_empty_not_an_error: fixture premise broken — the tree is not clean"
        return
    fi
    run_auto "$repo" RESOLVED 0 BASE_IS_HEAD=true RUN_TL3=off
    if [ "$SA_RC" != "0" ]; then
        fail "S23b_clean_zero_commit_branch_is_empty_not_an_error: a clean zero-commit branch exited $SA_RC
--- stderr ---
$SA_ERR"
    elif [ -n "$SA_OUT" ]; then
        fail "S23b_clean_zero_commit_branch_is_empty_not_an_error: nothing changed, yet tests were selected
--- output ---
$SA_OUT"
    else
        pass "S23b_clean_zero_commit_branch_is_empty_not_an_error: an empty working tree on a zero-commit branch is an empty selection, exit 0"
    fi
}

# S24: the kv parser, one row per value it can receive.
#
# `base_is_head` crosses a process boundary as text, and the selector's parser is hand-written.
# Four inputs, and three of them are ways of saying "the resolver did not answer":
#
#   true     the resolver observed base == HEAD. Believe it.
#   false    the resolver observed otherwise. Believe that too — this is the value every
#            ordinary branch carries, and a selector that degraded on it would narrow every
#            run to the working tree.
#   absent   a resolver older than the fix. Reading absence as `false` restores the bug
#            permanently and silently, so the selector observes the fact itself instead.
#   garbage  an unrecognised value is not evidence of anything, so it takes the SAME path as
#            absent. The failure this rules out is a truthiness test — `[[ -n $v ]]` reads
#            `garbage` as yes and `[[ $v != false ]]` reads it as yes as well, and either one
#            would degrade an ordinary branch on a single typo in the resolver.
#
# The last three inputs are therefore run against BOTH a zero-commit repository and an ordinary
# one: the two self-derived answers are what makes "settles it locally" different from "assumes".
# The range actually taken is read off the degradation notice, and the selection is asserted
# alongside it so a row cannot be satisfied by a notice printed over an empty set.
test_S24_base_is_head_parser_table() {
    local name value kind want_range want_sel repo n=0
    local got_range got_sel
    while IFS='|' read -r name value kind want_range want_sel; do
        [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
        name="${name//[[:space:]]/}"
        value="${value//[[:space:]]/}"
        kind="${kind//[[:space:]]/}"
        want_range="${want_range//[[:space:]]/}"
        want_sel="${want_sel//[[:space:]]/}"
        n=$((n + 1))
        repo="$TMPDIR_BASE/s24-$n"
        if [ "$kind" = "zero" ]; then
            make_zero_commit_repo "$repo" staged "bin/select-tests.sh" || continue
            assert_zero_commit "S24[$name]" "$repo" || continue
        else
            make_repo "$repo" "bin/select-tests.sh"
            if [ "$(git -C "$repo" rev-parse base)" = "$(git -C "$repo" rev-parse HEAD)" ]; then
                fail "S24[$name]: fixture premise broken — the 'normal' fixture has no commits of its own"
                continue
            fi
        fi
        run_auto "$repo" RESOLVED 0 "BASE_IS_HEAD=$value" RUN_TL3=off
        if [ "$SA_RC" != "0" ]; then
            fail "S24[$name]: expected exit 0, got rc=$SA_RC
--- stderr ---
$SA_ERR"
            continue
        fi
        if printf '%s\n' "$SA_ERR" | grep -qiE "$ZC_DEGRADE_RE"; then got_range="degraded"; else got_range="committed"; fi
        if [ -n "$SA_OUT" ]; then got_sel="nonempty"; else got_sel="empty"; fi
        zc_check "S24[$name]" "base_is_head=$value on a $kind branch picks the $want_range range" "$want_range" "$got_range"
        zc_check "S24[$name]" "and the selection is $want_sel" "$want_sel" "$got_sel"
    done <<'TABLE'
true-on-zero      | true    | zero   | degraded  | nonempty
false-on-zero     | false   | zero   | committed | empty
absent-on-zero    | omit    | zero   | degraded  | nonempty
garbage-on-zero   | garbage | zero   | degraded  | nonempty
true-on-normal    | true    | normal | degraded  | empty
absent-on-normal  | omit    | normal | committed | nonempty
garbage-on-normal | garbage | normal | committed | nonempty
TABLE
    if [ "$n" -lt 7 ]; then
        fail "S24: only $n table rows ran; the heredoc is not being read"
    fi
}
