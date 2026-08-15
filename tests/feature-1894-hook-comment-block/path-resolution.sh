#!/usr/bin/env bash
# tests/feature-1894-hook-comment-block/path-resolution.sh
# Tests: hooks/block-comment-block-size.js, hooks/lib/path-normalize.js
# Tags: comment-block-size, hook, pretooluse, path-resolution, worktree, windows, regression, scope:issue-specific, scope:feature-1894, layer:TL2

# Part 3 — which file the hook actually opens. A wrong resolution never
# surfaces as an error: the read fails or returns something else, the hook
# fails open, and the gate silently stops gating — the quietest way this
# feature can die. Two pinned failure modes, both prior plan regressions:
# `path.resolve(process.cwd(), p)` (a PreToolUse hook's cwd is rarely the
# repo being edited — resolveRepoCwd() exists for this); and ignoring
# `input.cwd` when it disagrees with CLAUDE_PROJECT_DIR (the linked-worktree
# signal, and the normal case here, not an edge one). Dispatcher runs from
# $NEUTRAL_CWD, so a process.cwd()-based implementation can't pass by luck.

# Sourced by the dispatcher; all helpers are defined there.

# ============================================================================
# R1 — absolute file_path, hook launched from an unrelated directory
# ============================================================================
r1_absolute_path_from_neutral_cwd() {
    local f
    f="$( { echo "var x = 1;"; cmt 12 legacy; } | wfile "r1.js" )"
    printf 'var x = 1;' > "$TMPDIR_BASE/r1.old"
    printf 'var x = 2;' > "$TMPDIR_BASE/r1.new"
    mkpayload Edit "$REPO_M" "$f" \
        "old_string=@$TMPDIR_BASE/r1.old" "new_string=@$TMPDIR_BASE/r1.new"
    hk_run
    assert_decision "R1/absolute-path-is-read" "block"

    # Control: same absolute path, clean file. Proves R1 is reading THAT file
    # and reacting to its content, not blocking on the path shape.
    f="$( { echo "var x = 1;"; cmt 2 ok; } | wfile "r1b.js" )"
    mkpayload Edit "$REPO_M" "$f" \
        "old_string=@$TMPDIR_BASE/r1.old" "new_string=@$TMPDIR_BASE/r1.new"
    hk_run
    assert_decision "R1/control-clean-file-approves" "approve"
}

# ============================================================================
# R2 — relative file_path resolves against the payload's cwd
# ============================================================================
r2_relative_path_uses_payload_cwd() {
    { echo "var x = 1;"; cmt 12 legacy; } | wfile "r2.js" >/dev/null
    printf 'var x = 1;' > "$TMPDIR_BASE/r2.old"
    printf 'var x = 2;' > "$TMPDIR_BASE/r2.new"
    mkpayload Edit "$REPO_M" "r2.js" \
        "old_string=@$TMPDIR_BASE/r2.old" "new_string=@$TMPDIR_BASE/r2.new"
    hk_run
    assert_decision "R2/relative-path-resolved-against-payload-cwd" "block"
    assert_clean_exit "R2/hook-exits-0"

    # The regression this case exists for: with process.cwd() as the base, the
    # same payload resolves to $NEUTRAL_CWD/r2.js. Assert that file genuinely
    # does not exist, so the row above cannot pass for the wrong reason.
    if [ ! -e "$NEUTRAL_CWD/r2.js" ]; then
        pass "R2/control-no-such-file-under-process-cwd"
    else
        fail "R2/control-no-such-file-under-process-cwd" "$NEUTRAL_CWD/r2.js exists; R2 proves nothing"
    fi
}

# ============================================================================
# R3 — linked worktree: input.cwd wins over CLAUDE_PROJECT_DIR
#
# Both paths hold a file with the same name and DIFFERENT content, so the
# verdict alone says which one was opened. A hook that preferred
# CLAUDE_PROJECT_DIR approves; the correct one blocks.
# ============================================================================
r3_linked_worktree_cwd_wins() {
    local wt="$TMPDIR_BASE/linked-wt"
    mkdir -p "$wt"
    { echo "var x = 1;"; cmt 12 in-worktree; } > "$wt/r3.js"
    { echo "var x = 1;"; cmt 2 in-project-dir; } > "$REPO/r3.js"
    printf 'var x = 1;' > "$TMPDIR_BASE/r3.old"
    printf 'var x = 2;' > "$TMPDIR_BASE/r3.new"

    mkpayload Edit "$(mpath "$wt")" "r3.js" \
        "old_string=@$TMPDIR_BASE/r3.old" "new_string=@$TMPDIR_BASE/r3.new"
    hk_run "CLAUDE_PROJECT_DIR=$REPO_M"
    assert_decision "R3/input-cwd-beats-CLAUDE_PROJECT_DIR" "block"

    # Mirror image, so the row above is a preference and not a coin that always
    # lands the same way: swap the contents and the verdict must swap too.
    { echo "var x = 1;"; cmt 2 in-worktree; } > "$wt/r3.js"
    { echo "var x = 1;"; cmt 12 in-project-dir; } > "$REPO/r3.js"
    mkpayload Edit "$(mpath "$wt")" "r3.js" \
        "old_string=@$TMPDIR_BASE/r3.old" "new_string=@$TMPDIR_BASE/r3.new"
    hk_run "CLAUDE_PROJECT_DIR=$REPO_M"
    assert_decision "R3/project-dir-copy-is-not-consulted" "approve"
}

# ============================================================================
# R4 — CLAUDE_PROJECT_DIR is used when the payload carries no cwd
# ============================================================================
r4_project_dir_fallback() {
    { echo "var x = 1;"; cmt 12 legacy; } | wfile "r4.js" >/dev/null
    printf 'var x = 1;' > "$TMPDIR_BASE/r4.old"
    printf 'var x = 2;' > "$TMPDIR_BASE/r4.new"
    mkpayload Edit "-" "r4.js" \
        "old_string=@$TMPDIR_BASE/r4.old" "new_string=@$TMPDIR_BASE/r4.new"
    hk_run "CLAUDE_PROJECT_DIR=$REPO_M"
    assert_decision "R4/falls-back-to-CLAUDE_PROJECT_DIR" "block"
}

# ============================================================================
# R5 — unresolvable path: approve, do not crash
# ============================================================================
r5_unresolvable_path_approves() {
    printf 'anything' > "$TMPDIR_BASE/r5.old"
    printf 'else' > "$TMPDIR_BASE/r5.new"
    mkpayload Edit "-" "no-such-file-anywhere.js" \
        "old_string=@$TMPDIR_BASE/r5.old" "new_string=@$TMPDIR_BASE/r5.new"
    hk_run
    assert_decision "R5/unreadable-pre-file-approves" "approve"
    assert_clean_exit "R5/hook-exits-0"
}

# ============================================================================
# R6 — POSIX drive-letter paths (Windows/msys)
#
# Claude Code on Windows hands hooks `/c/git/...` shapes that Node cannot open.
# normalizeCwd() converts them; without it this hook is dead on the platform the
# repo is developed on, and dead in the quiet direction (read fails, fail-open,
# no gate).
# ============================================================================
r6_posix_drive_letter_path() {
    case "$REPO_M" in
        [a-zA-Z]:/*) ;;
        *) skip "R6: fixture path is not drive-lettered — POSIX drive-letter conversion is not applicable here"
           return ;;
    esac
    { echo "var x = 1;"; cmt 12 legacy; } | wfile "r6.js" >/dev/null
    # C:/x/y -> /c/x/y, the exact shape msys hands over.
    local drive="${REPO_M%%:*}"
    local rest="${REPO_M#*:}"
    local posix_repo="/$(printf '%s' "$drive" | tr 'A-Z' 'a-z')$rest"
    printf 'var x = 1;' > "$TMPDIR_BASE/r6.old"
    printf 'var x = 2;' > "$TMPDIR_BASE/r6.new"
    mkpayload Edit "-" "$posix_repo/r6.js" \
        "old_string=@$TMPDIR_BASE/r6.old" "new_string=@$TMPDIR_BASE/r6.new"
    hk_run
    assert_decision "R6/posix-drive-letter-path-is-read" "block"
    assert_clean_exit "R6/hook-exits-0"
}

r1_absolute_path_from_neutral_cwd
r2_relative_path_uses_payload_cwd
r3_linked_worktree_cwd_wins
r4_project_dir_fallback
r5_unresolvable_path_approves
r6_posix_drive_letter_path
