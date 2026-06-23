#!/bin/bash
# R-8 through R-11: redirect inside repo / New-Item inside repo / New-Item no -Path / sequenced cmd C1 fail-closed
# All cases assert that the hook blocks writes with targets inside or unparseable from main.

# ============================================================================
# R-8: redirect to path inside repo from main → block
# ============================================================================
test_r8_redirect_inside_repo_block() {
    require_impl "R-8" || return
    local repo; repo="$(setup_main_checkout "r8")"
    local out
    out="$(run_bash_guard "echo x > \"$repo/.claude/foo-r8\"" "$repo" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        fail "R-8: redirect inside repo from main: should block ($out)"
    else
        pass "R-8: redirect inside repo from main → block"
    fi
}

# ============================================================================
# R-9: New-Item -ItemType Directory inside repo → block
# ============================================================================
test_r9_new_item_inside_repo_block() {
    require_impl "R-9" || return
    local repo; repo="$(setup_main_checkout "r9")"
    local out
    out="$(run_bash_guard "New-Item -ItemType Directory -Path \"$repo/newdir-r9\"" "$repo" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        fail "R-9: New-Item inside repo from main: should block ($out)"
    else
        pass "R-9: New-Item inside repo from main → block"
    fi
}

# ============================================================================
# R-10: New-Item -ItemType Directory with no -Path → block (no parseable target, fail-closed)
# ============================================================================
test_r10_new_item_no_path_block() {
    require_impl "R-10" || return
    local repo; repo="$(setup_main_checkout "r10")"
    local out
    out="$(run_bash_guard "New-Item -ItemType Directory" "$repo" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        fail "R-10: New-Item -ItemType Directory (no -Path) from main: should block ($out)"
    else
        pass "R-10: New-Item -ItemType Directory (no -Path) from main → block (fail-closed)"
    fi
}

# ============================================================================
# R-11: sequenced command (first target outside, second inside) → block
# Universal rule is fail-closed on sequencing: even though first target is
# outside repo, the second target is inside → block (C1 trade-off).
# ============================================================================
test_r11_sequenced_cmd_block() {
    require_impl "R-11" || return
    local repo; repo="$(setup_main_checkout "r11")"
    local outside="$TMPDIR_BASE/foo-r11-$$"
    local inside="$repo/docs/history.md"
    local out
    out="$(run_bash_guard "echo x > $outside && rm $inside" "$repo" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        fail "R-11: sequenced cmd (mixed targets) from main: should block ($out)"
    else
        pass "R-11: sequenced cmd (mixed targets) from main → block (C1 fail-closed)"
    fi
}

# ============================================================================
# R-21: path traversal — outside-repo prefix that resolves back into repo → block
# Attack: `echo x > $TMPDIR_BASE/../<basename>/<repo-name>/foo-r21`
# String prefix is outside repo, but path.resolve() normalizes "..", revealing
# the actual target inside repo. A naive isPathOutsideRepo doing string-prefix
# comparison would mis-classify and allow. Must block (CWE-22).
# ============================================================================
test_r21_path_traversal_into_repo_block() {
    require_impl "R-21" || return
    local repo; repo="$(setup_main_checkout "r21")"
    # basename of TMPDIR_BASE — works on both POSIX-style and Windows-normalized paths
    local tmpdir_base_name="$(basename "$TMPDIR_BASE")"
    local tmpdir_parent="$(dirname "$TMPDIR_BASE")"
    # Construct traversal target: parent/<base>/r21/foo-r21 — resolves to $TMPDIR_BASE/r21/foo-r21 = inside repo
    local target="$tmpdir_parent/$tmpdir_base_name/r21/foo-r21"
    # Inject a "../" traversal segment by going through TMPDIR_BASE explicitly
    local trav_target="$TMPDIR_BASE/../$tmpdir_base_name/r21/foo-r21"
    local out
    out="$(run_bash_guard "echo x > $trav_target" "$repo" ENFORCE_WORKTREE=on)"
    if guard_decision "$out"; then
        fail "R-21: path traversal into repo from main: should block ($out)"
    else
        pass "R-21: path traversal into repo from main → block (CWE-22 normalization)"
    fi
}

test_r8_redirect_inside_repo_block
test_r9_new_item_inside_repo_block
test_r10_new_item_no_path_block
test_r11_sequenced_cmd_block
test_r21_path_traversal_into_repo_block
