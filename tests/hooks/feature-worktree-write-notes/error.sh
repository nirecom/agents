#!/bin/bash
# Error-path tests for worktree-notes.
# Tests: hooks/lib/worktree-notes.js, bin/worktree-write-notes.js
# Tags: worktree, notes, scope:common

. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

# ---- Err1: appendExclude when .git is a file ----
test_Err1_appendExclude_git_is_file() {
    require_lib "test_Err1_appendExclude_git_is_file" || return
    local fake="$TMPDIR_BASE/err1-fake"
    mkdir -p "$fake"
    : > "$fake/.git"   # .git is a regular file
    local fake_node; fake_node="$(node_path "$fake")"

    local stderr
    stderr="$(lib_eval "
        try {
            lib.appendExclude({mainRoot: process.argv[1], pattern: 'WORKTREE_NOTES.md'});
            process.stdout.write('NOTHROW');
        } catch (e) {
            process.stderr.write(e.message);
        }
    " "$fake_node" 2>&1 >/dev/null)"

    if echo "$stderr" | grep -qi "unexpected" && echo "$stderr" | grep -qi "is a file"; then
        pass "Err1: appendExclude throws when .git is a file (msg contains 'unexpected' + 'is a file')"
    else
        fail "Err1: expected throw mentioning 'unexpected' + 'is a file' (got: $stderr)"
    fi
}

# ---- Err2: appendExclude when .git missing ----
test_Err2_appendExclude_no_git_dir() {
    require_lib "test_Err2_appendExclude_no_git_dir" || return
    local fake="$TMPDIR_BASE/err2-fake"
    mkdir -p "$fake"   # no .git at all
    local fake_node; fake_node="$(node_path "$fake")"

    local stderr
    stderr="$(lib_eval "
        try {
            lib.appendExclude({mainRoot: process.argv[1], pattern: 'WORKTREE_NOTES.md'});
            process.stdout.write('NOTHROW');
        } catch (e) {
            process.stderr.write(e.message);
        }
    " "$fake_node" 2>&1 >/dev/null)"

    if echo "$stderr" | grep -qi "no .git directory"; then
        pass "Err2: appendExclude throws when .git missing (msg contains 'no .git directory')"
    else
        fail "Err2: expected throw mentioning 'no .git directory' (got: $stderr)"
    fi
}

# ---- Err3: CLI invalid COPIED_JSON ----
test_Err3_cli_invalid_copied_json() {
    require_bin "test_Err3_cli_invalid_copied_json" || return
    local main; main="$(setup_main_repo "err3-main")"
    local wt;   wt="$(setup_worktree_dest "err3-wt")"
    local main_node; main_node="$(node_path "$main")"

    local code; code="$(run_bin_exitcode "$main_node" "$wt" "feature/err3" "" 'this is not json')"
    local errmsg; errmsg="$(run_bin_stderr "$main_node" "$wt" "feature/err3" "" 'this is not json')"

    if [ "$code" != "0" ] && [ -n "$errmsg" ]; then
        pass "Err3: CLI invalid COPIED_JSON → exit 1, stderr non-empty"
    else
        fail "Err3: expected non-zero exit + stderr, got code=$code stderr=$errmsg"
    fi
}

# ---- Err4: CLI missing branch (positional arg) ----
test_Err4_cli_missing_branch() {
    require_bin "test_Err4_cli_missing_branch" || return
    local main; main="$(setup_main_repo "err4-main")"
    local wt;   wt="$(setup_worktree_dest "err4-wt")"
    local main_node; main_node="$(node_path "$main")"

    local code; code="$(run_bin_exitcode "$main_node" "$wt" "")"
    local errmsg; errmsg="$(run_bin_stderr "$main_node" "$wt" "")"

    if [ "$code" != "0" ] && echo "$errmsg" | grep -qi "branch\|usage"; then
        pass "Err4: CLI missing branch arg → exit non-zero, usage mentions branch"
    else
        fail "Err4: code=$code stderr=$errmsg"
    fi
}

# ---- Err5: CLI notesWritten failure ----
test_Err5_cli_notesWritten_failure() {
    require_bin "test_Err5_cli_notesWritten_failure" || return
    local main; main="$(setup_main_repo "err5-main")"
    local main_node; main_node="$(node_path "$main")"
    local block_file="$TMPDIR_BASE/err5-block"
    : > "$block_file"
    local bad_wt="${block_file}/cannot/create/here"
    local bad_wt_node; bad_wt_node="$(node_path "$bad_wt")"

    local code; code="$(run_bin_exitcode "$main_node" "$bad_wt_node" "feature/err5" "" '{"copied":[]}')"
    local out; out="$(run_bin "$main_node" "$bad_wt_node" "feature/err5" "" '{"copied":[]}')"
    local errors; errors="$(json_field "$out" "errors")"

    if [ "$code" != "0" ]; then
        pass "Err5: CLI notesWritten failure → exit non-zero (errors=$errors)"
    else
        fail "Err5: expected non-zero exit, got code=$code errors=$errors"
    fi
}

# ---- Err-symlink: run() detects .git that is a symlink ----
# NOTE: expected to FAIL until implementation adds symlink detection.
test_Errsymlink_git_is_symlink() {
    require_bin "test_Errsymlink_git_is_symlink" || return
    if ! command -v ln >/dev/null 2>&1; then
        pass "Err-symlink: skipped — ln not available on this platform"
        return
    fi

    local main; main="$(setup_main_repo "errsymlink-main")"
    local main_node; main_node="$(node_path "$main")"

    local symlink_dir="$TMPDIR_BASE/errsymlink-wt"
    mkdir -p "$symlink_dir"
    ln -s /tmp/not-real-git-target "$symlink_dir/.git" 2>/dev/null || {
        pass "Err-symlink: skipped — ln -s failed (likely Windows without symlink privilege)"
        rm -rf "$symlink_dir"
        return
    }

    local symlink_dir_node; symlink_dir_node="$(node_path "$symlink_dir")"
    local code; code="$(run_bin_exitcode "$main_node" "$symlink_dir_node" "feature/errsymlink" "" '{"copied":[]}')"
    local out;  out="$(run_bin "$main_node" "$symlink_dir_node" "feature/errsymlink" "" '{"copied":[]}')"
    local errors; errors="$(json_field "$out" "errors")"

    if [ "$code" != "0" ]; then
        pass "Err-symlink: .git is a symlink → CLI exits non-zero (code=$code)"
    elif echo "$errors" | grep -qi "symlink\|link\|not a directory\|ENOTDIR"; then
        pass "Err-symlink: .git is a symlink → errors[] contains symlink-related message"
    else
        fail "Err-symlink: expected non-zero exit or symlink error, got code=$code errors=$errors"
    fi
}

# ---- Err-partial: appendExclude fails after writeNotes succeeds (partial failure) ----
# NOTE: expected to FAIL until implementation handles partial-failure mode.
# On Windows/WSL, chmod 000 may be a no-op; the test gracefully skips in that case.
test_Errpartial_partial_failure_exclude_unwritable() {
    require_bin "test_Errpartial_partial_failure_exclude_unwritable" || return
    local main; main="$(setup_main_repo "errpartial-main")"
    local main_node; main_node="$(node_path "$main")"
    local wt; wt="$(setup_worktree_dest "errpartial-wt")"

    local git_info_dir="$main/.git/info"
    mkdir -p "$git_info_dir"
    printf "# git exclude\n" > "$git_info_dir/exclude"
    chmod 000 "$git_info_dir/exclude" 2>/dev/null

    if [ -w "$git_info_dir/exclude" ]; then
        chmod 644 "$git_info_dir/exclude" 2>/dev/null
        pass "Err-partial: skipped — chmod 000 is a no-op on this platform (Windows/WSL)"
        return
    fi

    local wt_node; wt_node="$(node_path "$wt")"
    local code; code="$(run_bin_exitcode "$main_node" "$wt_node" "feature/errpartial" "" '{"copied":[]}')"
    local out;  out="$(run_bin "$main_node" "$wt_node" "feature/errpartial" "" '{"copied":[]}')"
    local notesWritten; notesWritten="$(json_field "$out" "notesWritten")"
    local errors; errors="$(json_field "$out" "errors")"

    chmod 644 "$git_info_dir/exclude" 2>/dev/null

    local notes_file="$TMPDIR_BASE/errpartial-wt/WORKTREE_NOTES.md"
    if [ "$notesWritten" = "true" ] && [ "$errors" != "[]" ]; then
        pass "Err-partial: notesWritten=true + errors[] non-empty → partial failure reported (code=$code, errors=$errors)"
    elif [ "$code" != "0" ]; then
        pass "Err-partial: appendExclude failure → CLI exits non-zero (code=$code, errors=$errors)"
    else
        fail "Err-partial: expected non-zero exit or errors[] when exclude is unwritable, got code=$code notesWritten=$notesWritten errors=$errors notes_exists=$([ -f "$notes_file" ] && echo yes || echo no)"
    fi
}

# ============ Run all ============

test_Err1_appendExclude_git_is_file
test_Err2_appendExclude_no_git_dir
test_Err3_cli_invalid_copied_json
test_Err4_cli_missing_branch
test_Err5_cli_notesWritten_failure
test_Errsymlink_git_is_symlink
test_Errpartial_partial_failure_exclude_unwritable

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $FAIL
