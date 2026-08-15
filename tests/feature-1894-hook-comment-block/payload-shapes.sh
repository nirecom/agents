#!/usr/bin/env bash
# tests/feature-1894-hook-comment-block/payload-shapes.sh
# Tests: hooks/block-comment-block-size.js, hooks/lib/write-tools.js
# Tags: comment-block-size, hook, pretooluse, payload, multiedit, fail-open, scope:issue-specific, scope:feature-1894, layer:TL2
#
# Part 2 — reconstructing the post-edit file from the payload.
#
# decision-boundary.sh assumes the hook knows what the file will look like after
# the tool runs. Producing that is the hook's most failure-prone job: it has to
# reimplement each tool's own semantics (first-match vs all-matches replacement,
# sequential MultiEdit application) from a JSON payload, and it has to do so
# before the tool has run, with no way to check its answer.
#
# So every branch of that reconstruction gets a row, and every row it CANNOT
# reconstruct gets an approve row. The direction is not symmetric on purpose: a
# hook that guesses wrong and approves loses a shift-left catch that pre-commit
# still makes; a hook that guesses wrong and blocks stops an author from writing
# a file for a reason that is not true, with no override anywhere. Uncertainty
# resolves to approve (detail plan S3-1 steps 2, 8 and 11).
#
# Sourced by the dispatcher; all helpers are defined there.

# ============================================================================
# W1 — Write: content IS the post file
# ============================================================================
w1_write_uses_content_verbatim() {
    local f
    # A pre file that is already clean, so a hook that scanned pre instead of
    # post would approve — the row would then be silently vacuous.
    f="$( { echo "var x = 1;"; cmt 2 old; } | wfile "w1.js" )"
    { echo "var x = 1;"; cmt 11 fresh; } > "$TMPDIR_BASE/w1.body"
    local snap; snap="$(snap_file "$f")"
    mkpayload Write "$REPO_M" "$f" "content=@$TMPDIR_BASE/w1.body"
    hk_run
    assert_decision "W1/write-judged-on-new-content" "block"
    # Reconstruction happens in memory. A hook that materialised the post-file
    # to scan it would have overwritten the user's file with content the tool
    # was about to be told not to write — the worst possible outcome of a guard.
    assert_file_untouched "W1/blocked-write-left-the-file-byte-identical" "$f" "$snap"

    # Repeated invocation: identical verdict, still no side effect.
    hk_run
    assert_decision "W1/repeat-invocation-is-stable" "block"
    assert_file_untouched "W1/repeat-invocation-still-touches-nothing" "$f" "$snap"

    # Mirror: a dirty pre file overwritten with clean content must be approved,
    # which a hook that scanned pre would get wrong in the other direction.
    f="$( { echo "var x = 1;"; cmt 13 old; } | wfile "w1b.js" )"
    { echo "var x = 1;"; cmt 2 fresh; } > "$TMPDIR_BASE/w1b.body"
    local snapb; snapb="$(snap_file "$f")"
    mkpayload Write "$REPO_M" "$f" "content=@$TMPDIR_BASE/w1b.body"
    hk_run
    assert_decision "W1/write-ignores-pre-content" "approve"
    assert_file_untouched "W1/approved-write-is-not-applied-by-the-hook" "$f" "$snapb"
}

# ============================================================================
# W2 — Edit: replace_all changes how many occurrences land
#
# With replace_all=false only the FIRST match is replaced. A hook that always
# replaces every occurrence would build a file the tool is not going to write,
# and here that difference is the difference between a block and an approve.
# ============================================================================
w2_edit_replace_all_semantics() {
    local f
    f="$( { echo "MARK"; code 1; echo "MARK"; } | wfile "w2.js" )"
    printf 'MARK' > "$TMPDIR_BASE/w2.old"
    # 6 comment lines per replacement, with no trailing newline: the old_string
    # is a whole line, so a terminator here would leave a blank line behind and
    # blank lines split comment runs.
    cmtn 6 x > "$TMPDIR_BASE/w2.new"

    # One replacement: two runs of 6 and 1 -> nothing over 10.
    mkpayload Edit "$REPO_M" "$f" \
        "old_string=@$TMPDIR_BASE/w2.old" "new_string=@$TMPDIR_BASE/w2.new" "replace_all=false"
    hk_run
    assert_decision "W2/first-match-only-stays-under" "approve"

    # Both replacements, with the code line between them removed so the two runs
    # merge: 6 + 6 = 12 consecutive comment lines.
    f="$( { echo "MARK"; echo "MARK"; } | wfile "w2b.js" )"
    local snapb; snapb="$(snap_file "$f")"
    mkpayload Edit "$REPO_M" "$f" \
        "old_string=@$TMPDIR_BASE/w2.old" "new_string=@$TMPDIR_BASE/w2.new" "replace_all=true"
    hk_run
    assert_decision "W2/replace-all-merges-runs-and-blocks" "block"
    # The replacement was simulated, not performed: MARK must still be MARK.
    assert_file_untouched "W2/replace-all-simulation-has-no-side-effect" "$f" "$snapb"

    # ...and the same payload WITHOUT replace_all must behave like false. An
    # implementation that treats a missing key as truthy inverts this row.
    f="$( { echo "MARK"; echo "MARK"; } | wfile "w2c.js" )"
    local snapc; snapc="$(snap_file "$f")"
    mkpayload Edit "$REPO_M" "$f" \
        "old_string=@$TMPDIR_BASE/w2.old" "new_string=@$TMPDIR_BASE/w2.new"
    hk_run
    assert_decision "W2/absent-replace_all-defaults-to-first-match" "approve"
    assert_file_untouched "W2/approved-edit-simulation-has-no-side-effect" "$f" "$snapc"
}

# ============================================================================
# W3 — MultiEdit applies edits in sequence, each onto the previous result
# ============================================================================
w3_multiedit_is_sequential() {
    local f
    f="$( { echo "A"; echo "B"; } | wfile "w3.js" )"
    printf 'A' > "$TMPDIR_BASE/w3.a"
    printf 'B' > "$TMPDIR_BASE/w3.b"
    cmtn 6 p > "$TMPDIR_BASE/w3.six"
    cmtn 5 q > "$TMPDIR_BASE/w3.five"
    # 6 + 5 = 11 consecutive lines, but only if BOTH edits are applied and
    # applied to the same evolving buffer.
    local snap; snap="$(snap_file "$f")"
    mkpayload MultiEdit "$REPO_M" "$f" \
        "e0.old_string=@$TMPDIR_BASE/w3.a" "e0.new_string=@$TMPDIR_BASE/w3.six" \
        "e1.old_string=@$TMPDIR_BASE/w3.b" "e1.new_string=@$TMPDIR_BASE/w3.five"
    hk_run
    assert_decision "W3/both-edits-applied-crosses-threshold" "block"
    # Sequential application is the most tempting place to "just apply it and
    # re-read": the buffer must stay a buffer.
    assert_file_untouched "W3/sequential-application-stays-in-memory" "$f" "$snap"

    # The chaining half: the second edit's old_string exists ONLY in the result
    # of the first. A hook that matched every edit against the original pre file
    # would call this a mismatch and approve.
    f="$( { echo "SEED"; code 1; } | wfile "w3b.js" )"
    local snapb; snapb="$(snap_file "$f")"
    printf 'SEED' > "$TMPDIR_BASE/w3b.seed"
    printf 'STAGE2' > "$TMPDIR_BASE/w3b.stage2"
    cmt 12 r > "$TMPDIR_BASE/w3b.twelve"
    mkpayload MultiEdit "$REPO_M" "$f" \
        "e0.old_string=@$TMPDIR_BASE/w3b.seed" "e0.new_string=@$TMPDIR_BASE/w3b.stage2" \
        "e1.old_string=@$TMPDIR_BASE/w3b.stage2" "e1.new_string=@$TMPDIR_BASE/w3b.twelve"
    hk_run
    assert_decision "W3/second-edit-sees-first-edits-output" "block"
    assert_file_untouched "W3/chained-edit-simulation-has-no-side-effect" "$f" "$snapb"
}

# ============================================================================
# W4 — old_string that is not in the file: approve
#
# The tool call itself is going to fail. Blocking here would replace a clear
# tool-level error with a confusing policy verdict about a file state that will
# never exist.
# ============================================================================
w4_unmatched_old_string_approves() {
    local f
    f="$( { echo "var x = 1;"; cmt 13 legacy; } | wfile "w4.js" )"
    printf 'THIS-STRING-IS-NOT-IN-THE-FILE' > "$TMPDIR_BASE/w4.old"
    cmt 3 y > "$TMPDIR_BASE/w4.new"
    local snap; snap="$(snap_file "$f")"
    mkpayload Edit "$REPO_M" "$f" \
        "old_string=@$TMPDIR_BASE/w4.old" "new_string=@$TMPDIR_BASE/w4.new"
    hk_run
    assert_decision "W4/unmatched-edit-approves" "approve"
    assert_clean_exit "W4/hook-exits-0"
    assert_file_untouched "W4/unmatched-edit-changes-nothing-on-disk" "$f" "$snap"

    # Same for a MultiEdit whose later step cannot apply: the tool will reject
    # the whole call, so there is no post state to judge.
    printf 'var x = 1;' > "$TMPDIR_BASE/w4.ok"
    cmt 12 z > "$TMPDIR_BASE/w4.twelve"
    mkpayload MultiEdit "$REPO_M" "$f" \
        "e0.old_string=@$TMPDIR_BASE/w4.ok" "e0.new_string=@$TMPDIR_BASE/w4.twelve" \
        "e1.old_string=@$TMPDIR_BASE/w4.old" "e1.new_string=@$TMPDIR_BASE/w4.new"
    hk_run
    assert_decision "W4/multiedit-with-unmatched-step-approves" "approve"
    # The partially-applicable MultiEdit is where a write-then-scan hook would
    # leave the file half-edited even though the tool will reject the call.
    assert_file_untouched "W4/partial-multiedit-leaves-no-half-applied-file" "$f" "$snap"
}

# ============================================================================
# W5 — tools whose payload cannot be reconstructed: approve, by design
#
# editFiles and NotebookEdit are in the same settings.json matcher group but do
# not carry a reconstructable before/after in their payload. They are approved
# deliberately, with hooks/pre-commit as their backstop — a documented hole
# (detail plan S3-1 step 2, Risks). Pinned so it stays a decision rather than
# decaying into an accident, and so nobody "fixes" it into a guess.
# ============================================================================
w5_unreconstructable_tools_approve() {
    local f
    f="$( { echo "var x = 1;"; cmt 14 legacy; } | wfile "w5.js" )"
    local snap; snap="$(snap_file "$f")"
    local t
    for t in editFiles NotebookEdit; do
        cmt 14 legacy > "$TMPDIR_BASE/w5.body"
        mkpayload "$t" "$REPO_M" "$f" "content=@$TMPDIR_BASE/w5.body"
        hk_run
        assert_decision "W5/$t-approves" "approve"
        assert_file_untouched "W5/$t-touches-nothing" "$f" "$snap"
    done

    # An unwatched tool entirely (the hook may be reached via a broader matcher
    # than it wants) must also pass straight through.
    mkpayload Bash "$REPO_M" "-" "command=echo hi"
    hk_run
    assert_decision "W5/Bash-approves" "approve"
}

# ============================================================================
# W6 — degenerate payloads: never crash, never block
#
# A PreToolUse hook that throws on an unexpected payload turns into an error on
# every tool call. Fail-open is the contract (detail plan S3-1 step 11), and it
# has to be an APPROVE verdict, not a non-zero exit.
# ============================================================================
w6_degenerate_payloads_approve() {
    printf 'not json at all' > "$PAYLOAD_FILE"
    hk_run
    assert_decision "W6/malformed-stdin-approves" "approve"
    assert_clean_exit "W6/malformed-stdin-exits-0"

    : > "$PAYLOAD_FILE"
    hk_run
    assert_decision "W6/empty-stdin-approves" "approve"
    assert_clean_exit "W6/empty-stdin-exits-0"

    printf '{"tool_name":"Write"}' > "$PAYLOAD_FILE"
    hk_run
    assert_decision "W6/no-tool-input-approves" "approve"

    mkpayload Write "$REPO_M" "-" "content=x"
    hk_run
    assert_decision "W6/no-file-path-approves" "approve"

    # A directory where a file is expected: readFileSync throws EISDIR.
    mkpayload Write "$REPO_M" "$REPO_M" "content=x"
    hk_run
    assert_decision "W6/directory-as-file-path-approves" "approve"
    assert_clean_exit "W6/directory-as-file-path-exits-0"
    # ...and the directory is still a directory. A fail-open path that writes
    # before it validates would clobber it.
    if [ -d "$REPO" ]; then
        pass "W6/directory-target-not-replaced-by-a-file"
    else
        fail "W6/directory-target-not-replaced-by-a-file" "$REPO is no longer a directory"
    fi
}

# ============================================================================
# W7 — very large files are skipped
#
# Symmetric with the CLI's byte cap: an Edit to a multi-megabyte generated file
# should not spend the hot path scanning it. The cap is a performance guard, so
# its direction is approve.
# ============================================================================
w7_oversized_content_approves() {
    local f="$REPO_M/w7.js"
    rm -f "$REPO/w7.js"
    { cmt 11 c
      # ~1.1 MB of code lines after the violation, so the file is over the cap
      # while still containing something that would otherwise block.
      local i
      for ((i = 0; i < 20000; i++)); do
          echo "var padpadpadpadpadpadpadpadpadpadpadpadpadpadpadpadpad$i = $i;"
      done
    } > "$TMPDIR_BASE/w7.body"
    mkpayload Write "$REPO_M" "$f" "content=@$TMPDIR_BASE/w7.body"
    hk_run
    assert_decision "W7/oversized-file-approves" "approve"
    assert_clean_exit "W7/oversized-file-exits-0"
    # Skipping the scan must also mean skipping any write: the megabyte of
    # content in the payload never reaches disk from inside the hook.
    assert_file_absent "W7/oversized-payload-never-written-to-disk" "$REPO/w7.js"
}

w1_write_uses_content_verbatim
w2_edit_replace_all_semantics
w3_multiedit_is_sequential
w4_unmatched_old_string_approves
w5_unreconstructable_tools_approve
w6_degenerate_payloads_approve
w7_oversized_content_approves
