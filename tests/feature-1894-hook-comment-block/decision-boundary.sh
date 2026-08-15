#!/usr/bin/env bash
# tests/feature-1894-hook-comment-block/decision-boundary.sh
# Tests: hooks/block-comment-block-size.js, hooks/lib/comment-block-scan.js
# Tags: comment-block-size, hook, pretooluse, boundary, absolute-judgment, table-driven, scope:issue-specific, scope:feature-1894, layer:TL2
#
# Part 1 — what the hook decides, and on what.
#
# Two rules produce every row here, and both were settled after a round of
# review that found holes in the alternatives:
#
#   (1) The verdict is computed on the POST-edit file only. Comparing post
#       against pre ("block only when it got worse") passes a file that already
#       had a 12-line block and gains a second 11-line block somewhere else —
#       `longest` is 12 before and 12 after, so nothing "worsened" while the
#       file got materially worse (detail plan S3-2).
#   (2) The comparator is `>`, not `>=`. COMMENT_BLOCK_MAX_LINES names the
#       largest run that is still ALLOWED, so at the default 10 a 10-line run is
#       silent and an 11-line run is a violation. Every boundary row below is
#       paired — 10 approve next to 11 block — because a one-off in either
#       direction is the single most likely implementation slip and a lone
#       "11 blocks" row cannot see it.
#
# Rule (1) has a cost the suite pins on purpose: a file with a pre-existing
# violation is unwritable until the violation is fixed, even for an edit that
# never goes near it (D4). That is the accepted design, not an oversight.
#
# Sourced by the dispatcher; all helpers are defined there.

# ============================================================================
# D1 — the case from the issue: 5 existing + 6 added = 11
#
# This is why an added-lines-only rule was rejected. The edit adds 6 comment
# lines, which no per-edit threshold would flag; the file ends up with an
# 11-line run, which is the thing that matters.
# ============================================================================
d1_existing_plus_added_crosses_the_line() {
    local f
    f="$( { echo "var x = 1;"; cmt 5 c; echo "var y = 2;"; } | wfile "d1.js" )"
    { cmt 6 more; echo "var y = 2;"; } > "$TMPDIR_BASE/d1.new"
    printf 'var y = 2;' > "$TMPDIR_BASE/d1.old"
    local snap; snap="$(snap_file "$f")"
    mkpayload Edit "$REPO_M" "$f" "old_string=@$TMPDIR_BASE/d1.old" "new_string=@$TMPDIR_BASE/d1.new"
    hk_run
    assert_decision "D1/five-plus-six-is-blocked" "block"
    assert_clean_exit "D1/hook-exits-0"
    # The hook advises; the tool writes. A blocked verdict must leave the file
    # exactly as it was — and so must an approved one, since the write happens
    # in the host after the hook has exited (see snap_file in the dispatcher).
    assert_file_untouched "D1/blocked-edit-left-the-file-byte-identical" "$f" "$snap"

    # Repeated invocation: same payload, same verdict, still no side effect.
    hk_run
    assert_decision "D1/repeat-invocation-is-stable" "block"
    assert_file_untouched "D1/repeat-invocation-still-touches-nothing" "$f" "$snap"

    # Paired negative, same shape: 5 existing + 5 added = 10, still allowed.
    { cmt 5 more; echo "var y = 2;"; } > "$TMPDIR_BASE/d1.new5"
    mkpayload Edit "$REPO_M" "$f" "old_string=@$TMPDIR_BASE/d1.old" "new_string=@$TMPDIR_BASE/d1.new5"
    hk_run
    assert_decision "D1/five-plus-five-is-allowed" "approve"
    assert_file_untouched "D1/approved-edit-is-not-applied-by-the-hook" "$f" "$snap"
}

# ============================================================================
# D2 / D3 — the comparator boundary on a whole-file Write
# ============================================================================
d2_boundary_pair_on_write() {
    local f="$REPO_M/d2.js"
    rm -f "$REPO/d2.js"
    { echo "var x = 1;"; cmt 10 c; echo "var y = 2;"; } > "$TMPDIR_BASE/d2.ten"
    mkpayload Write "$REPO_M" "$f" "content=@$TMPDIR_BASE/d2.ten"
    hk_run
    assert_decision "D2/exactly-threshold-is-allowed" "approve"
    # An approved Write is still the HOST's write to make: the hook must not
    # have created the file on its way to saying yes.
    assert_file_absent "D2/approved-write-did-not-create-the-file" "$REPO/d2.js"

    { echo "var x = 1;"; cmt 11 c; echo "var y = 2;"; } > "$TMPDIR_BASE/d2.eleven"
    mkpayload Write "$REPO_M" "$f" "content=@$TMPDIR_BASE/d2.eleven"
    hk_run
    assert_decision "D3/one-over-threshold-is-blocked" "block"
    assert_file_absent "D3/blocked-write-did-not-create-the-file" "$REPO/d2.js"
}

# ============================================================================
# D4 — an unrelated edit to a file that already violates: still blocked
#
# The sharp edge of absolute judgment, pinned as a requirement. A later change
# that "fixes the annoyance" by only blocking on worsening has to fail here.
# ============================================================================
d4_untouched_existing_violation_still_blocks() {
    local f
    f="$( { echo "var x = 1;"; cmt 12 legacy; echo "var y = 2;"; } | wfile "d4.js" )"
    printf 'var y = 2;' > "$TMPDIR_BASE/d4.old"
    printf 'var y = 3;' > "$TMPDIR_BASE/d4.new"
    local snap; snap="$(snap_file "$f")"
    mkpayload Edit "$REPO_M" "$f" "old_string=@$TMPDIR_BASE/d4.old" "new_string=@$TMPDIR_BASE/d4.new"
    hk_run
    assert_decision "D4/edit-far-from-the-violation-is-blocked" "block"
    assert_file_untouched "D4/blocked-edit-left-the-legacy-file-intact" "$f" "$snap"

    # The counterpart that makes the rule liveable: an edit that REMOVES the
    # violation must go through. Without this row, "block everything" passes.
    { echo "var x = 1;"; cmt 3 legacy; echo "var y = 2;"; } > "$TMPDIR_BASE/d4.fix"
    mkpayload Write "$REPO_M" "$f" "content=@$TMPDIR_BASE/d4.fix"
    hk_run
    assert_decision "D4/edit-that-fixes-it-is-allowed" "approve"
    # Symmetric with the blocked row: approving is not applying.
    assert_file_untouched "D4/approved-write-is-not-applied-by-the-hook" "$f" "$snap"
}

# ============================================================================
# D5 — a second violation elsewhere, with `longest` unchanged
#
# The exact false-negative that killed the worsening-only design: longest is 12
# before and 12 after, so a max-based comparison sees no change while the file
# gains a whole new violation.
# ============================================================================
d5_second_violation_without_raising_longest() {
    local f
    f="$( { echo "var x = 1;"; cmt 12 legacy; echo "var y = 2;"; } | wfile "d5.js" )"
    { echo "var x = 1;"; cmt 12 legacy; echo "var y = 2;"; cmt 11 fresh; echo "var z = 3;"; } \
        > "$TMPDIR_BASE/d5.new"
    local snap; snap="$(snap_file "$f")"
    mkpayload Write "$REPO_M" "$f" "content=@$TMPDIR_BASE/d5.new"
    hk_run
    assert_decision "D5/added-second-run-is-blocked" "block"
    assert_file_untouched "D5/blocked-write-left-the-file-byte-identical" "$f" "$snap"
    # Both runs belong in the reason: a report that names only the longest one
    # sends the author back for a second round on the other.
    local ranges
    ranges="$(printf '%s\n' "$HK_OUT" | grep -oE 'L[0-9]+-L[0-9]+' | sort -u | wc -l)"
    if [ "$ranges" -ge 2 ]; then
        pass "D5/both-runs-reported"
    else
        fail "D5/both-runs-reported" "found $ranges range(s) in: $HK_OUT"
    fi
}

# ============================================================================
# D6 — a brand-new file has no pre content to compare against
#
# The pre-commit layer treats a new file as an absolute-value case for the same
# reason (no baseline blob). Here it falls out of the design rather than being a
# special case, which is exactly what should be asserted.
# ============================================================================
d6_new_file_boundary_pair() {
    local f="$REPO_M/d6-brand-new.js"
    rm -f "$REPO/d6-brand-new.js"
    { echo "var x = 1;"; cmt 11 c; } > "$TMPDIR_BASE/d6.eleven"
    mkpayload Write "$REPO_M" "$f" "content=@$TMPDIR_BASE/d6.eleven"
    hk_run
    assert_decision "D6/new-file-over-threshold-is-blocked" "block"
    assert_clean_exit "D6/no-crash-on-missing-pre-file"
    # The proposed file must still not exist: a hook that materialised it while
    # judging would have created the very file it just refused.
    assert_file_absent "D6/blocked-new-file-stays-absent" "$REPO/d6-brand-new.js"

    { echo "var x = 1;"; cmt 10 c; } > "$TMPDIR_BASE/d6.ten"
    mkpayload Write "$REPO_M" "$f" "content=@$TMPDIR_BASE/d6.ten"
    hk_run
    assert_decision "D6/new-file-at-threshold-is-allowed" "approve"
    assert_file_absent "D6/approved-new-file-stays-absent-until-the-host-writes" "$REPO/d6-brand-new.js"
}

# ============================================================================
# D7 — what a blocked author is told
#
# The message is the entire remedy path: the hook offers no override, so if the
# reason does not say what to fix and where the rule lives, the author's only
# recourse is to guess or to ask the user — which is the loop #1894 exists to
# end.
# ============================================================================
d7_block_reason_is_actionable() {
    local f="$REPO_M/d7.js"
    { echo "var x = 1;"; cmt 14 c; } > "$TMPDIR_BASE/d7.body"
    mkpayload Write "$REPO_M" "$f" "content=@$TMPDIR_BASE/d7.body"
    hk_run
    assert_decision "D7/premise-blocked" "block"
    assert_file_absent "D7/blocked-write-created-nothing" "$REPO/d7.js"
    assert_contains "D7/names-the-file" "d7.js" "$HK_OUT"
    assert_contains "D7/names-the-range" "L2-L15" "$HK_OUT"
    assert_contains "D7/states-the-threshold" "10" "$HK_OUT"
    assert_contains "D7/points-at-the-rule" "rules/coding/file-split.md" "$HK_OUT"
    # No bypass exists, so none may be advertised. A reason that names a marker
    # would send authors to a sentinel that does not work here — and would be
    # read as permission to try (see no-bypass.sh).
    assert_absent "D7/offers-no-workflow-off" "WORKFLOW_OFF" "$HK_OUT"
    assert_absent "D7/offers-no-worktree-off" "WORKTREE_OFF" "$HK_OUT"
    # Nor may it leak the comment text it is complaining about: the reason goes
    # into a transcript, and comments are where credentials get parked.
    assert_absent "D7/no-comment-body-in-reason" "// c 7" "$HK_OUT"
}

d7b_reason_caps_the_detail_lines() {
    # Same cap as the CLI report (5 + "and N more"). A file mid-refactor can hold
    # a dozen over-threshold runs, and a hook reason is a modal message, not a
    # report — dumping all of them buries the first one.
    local f="$REPO_M/d7b.js"
    : > "$TMPDIR_BASE/d7b.body"
    local i
    for i in $(seq 1 8); do
        { code 2; cmt 11 "run$i"; } >> "$TMPDIR_BASE/d7b.body"
    done
    mkpayload Write "$REPO_M" "$f" "content=@$TMPDIR_BASE/d7b.body"
    hk_run
    assert_decision "D7b/premise-blocked" "block"
    assert_file_absent "D7b/blocked-write-created-nothing" "$REPO/d7b.js"
    local ranges
    ranges="$(printf '%s\n' "$HK_OUT" | grep -oE 'L[0-9]+-L[0-9]+' | sort -u | wc -l)"
    if [ "$ranges" -le 5 ]; then
        pass "D7b/detail-lines-capped-at-5"
    else
        fail "D7b/detail-lines-capped-at-5" "reason lists $ranges ranges"
    fi
    assert_contains "D7b/remainder-is-acknowledged" "more" "$HK_OUT"
}

# ============================================================================
# D8 — comment forms other than `//`
#
# The scan core owns the recognition rules and scan-core-node.sh tables them
# exhaustively. What belongs HERE is only that the hook feeds it real post-edit
# content: a hook wired to the wrong string (pre instead of post, or the raw
# new_string instead of the reconstructed file) would still pass every `//` row
# above by accident but cannot pass a shape it never assembled.
# ============================================================================
d8_hash_comments_in_a_shell_file() {
    local f="$REPO_M/d8.sh"
    { echo "x=1"; local i; for i in $(seq 1 11); do echo "# note $i"; done; echo "y=2"; } \
        > "$TMPDIR_BASE/d8.body"
    mkpayload Write "$REPO_M" "$f" "content=@$TMPDIR_BASE/d8.body"
    hk_run
    assert_decision "D8/hash-run-over-threshold-is-blocked" "block"
    assert_file_absent "D8/blocked-shell-file-stays-absent" "$REPO/d8.sh"

    { echo "x=1"; for i in $(seq 1 10); do echo "# note $i"; done; echo "y=2"; } \
        > "$TMPDIR_BASE/d8.ok"
    mkpayload Write "$REPO_M" "$f" "content=@$TMPDIR_BASE/d8.ok"
    hk_run
    assert_decision "D8/hash-run-at-threshold-is-allowed" "approve"
    assert_file_absent "D8/approved-shell-file-stays-absent" "$REPO/d8.sh"
}

d1_existing_plus_added_crosses_the_line
d2_boundary_pair_on_write
d4_untouched_existing_violation_still_blocks
d5_second_violation_without_raising_longest
d6_new_file_boundary_pair
d7_block_reason_is_actionable
d7b_reason_caps_the_detail_lines
d8_hash_comments_in_a_shell_file
