#!/bin/bash
# run() normal/idempotency tests for worktree-notes lib.
# Tests: hooks/lib/worktree-notes.js
# Tags: worktree, notes, scope:common

. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

# ---- N6: run() happy path ----
test_N6_run_happy_path() {
    require_lib "test_N6_run_happy_path" || return
    local main; main="$(setup_main_repo "n6-main")"
    local wt;   wt="$(setup_worktree_dest "n6-wt")"
    local main_node; main_node="$(node_path "$main")"

    local out
    out="$(lib_eval "
        const r = lib.run({
            mainRoot: process.argv[1],
            worktreePath: process.argv[2],
            branch: 'feature/n6',
            createdDate: '2024-01-15',
            resolvedPath: process.argv[2],
            baseDir: null,
            copiedFiles: ['a.env'],
            excludePattern: 'WORKTREE_NOTES.md'
        });
        process.stdout.write(JSON.stringify(r));
    " "$main_node" "$wt" 2>/dev/null)"

    local notesWritten; notesWritten="$(json_field "$out" "notesWritten")"
    local excludeAdded; excludeAdded="$(json_field "$out" "excludeAdded")"
    local errors; errors="$(json_field "$out" "errors")"
    if [ "$notesWritten" = "true" ] && [ "$excludeAdded" = "true" ] && [ "$errors" = "[]" ]; then
        pass "N6: run() happy path → notesWritten=true, excludeAdded=true, errors=[]"
    else
        fail "N6: got notesWritten=$notesWritten excludeAdded=$excludeAdded errors=$errors (out=$out)"
    fi
}

# ---- N6b: run() writes Main repo line matching mainRoot (forward-slash normalized) ----
test_N6b_run_writes_main_repo_line() {
    require_lib "test_N6b_run_writes_main_repo_line" || return
    local main; main="$(setup_main_repo "n6b-main")"
    local wt;   wt="$(setup_worktree_dest "n6b-wt")"
    local main_node; main_node="$(node_path "$main")"

    lib_eval "
        lib.run({
            mainRoot: process.argv[1],
            worktreePath: process.argv[2],
            branch: 'feature/n6b',
            createdDate: '2024-01-15',
            resolvedPath: process.argv[2],
            baseDir: null,
            sessionId: 'sess-abc-123',
            copiedFiles: [],
            excludePattern: 'WORKTREE_NOTES.md'
        });
    " "$main_node" "$wt" >/dev/null 2>&1

    local notes_file="$TMPDIR_BASE/n6b-wt/WORKTREE_NOTES.md"
    if [ ! -f "$notes_file" ]; then
        fail "N6b: notes file not created at $notes_file"
        return
    fi
    local expected_main
    expected_main="$(node -e "console.log(process.argv[1].replace(/\\\\/g,'/'))" -- "$main_node" 2>/dev/null)"
    if grep -q "^Main repo: ${expected_main}$" "$notes_file" \
       && grep -q "^Session-ID: sess-abc-123$" "$notes_file"; then
        pass "N6b: run() writes 'Main repo: <forward-slash normalized mainRoot>' and 'Session-ID: sess-abc-123'"
    else
        fail "N6b: expected 'Main repo: ${expected_main}' in $notes_file
content:
$(cat "$notes_file")"
    fi
}

# ---- I3: run() second call (idempotency) ----
test_I3_run_idempotent() {
    require_lib "test_I3_run_idempotent" || return
    local main; main="$(setup_main_repo "i3-main")"
    local wt;   wt="$(setup_worktree_dest "i3-wt")"
    local main_node; main_node="$(node_path "$main")"

    local out1 out2
    out1="$(lib_eval "
        const r = lib.run({
            mainRoot: process.argv[1],
            worktreePath: process.argv[2],
            branch: 'feature/i3',
            createdDate: '2024-01-15',
            resolvedPath: process.argv[2],
            baseDir: null,
            copiedFiles: ['a.env'],
            excludePattern: 'WORKTREE_NOTES.md'
        });
        process.stdout.write(JSON.stringify(r));
    " "$main_node" "$wt" 2>/dev/null)"

    local notes_file="$TMPDIR_BASE/i3-wt/WORKTREE_NOTES.md"
    local before_md5
    before_md5="$(node -e "const c=require('crypto'),fs=require('fs');process.stdout.write(c.createHash('md5').update(fs.readFileSync(process.argv[1])).digest('hex'));" -- "$notes_file" 2>/dev/null)"

    out2="$(lib_eval "
        const r = lib.run({
            mainRoot: process.argv[1],
            worktreePath: process.argv[2],
            branch: 'feature/i3',
            createdDate: '2024-01-15',
            resolvedPath: process.argv[2],
            baseDir: null,
            copiedFiles: ['a.env'],
            excludePattern: 'WORKTREE_NOTES.md'
        });
        process.stdout.write(JSON.stringify(r));
    " "$main_node" "$wt" 2>/dev/null)"

    local after_md5
    after_md5="$(node -e "const c=require('crypto'),fs=require('fs');process.stdout.write(c.createHash('md5').update(fs.readFileSync(process.argv[1])).digest('hex'));" -- "$notes_file" 2>/dev/null)"

    local notesWritten2; notesWritten2="$(json_field "$out2" "notesWritten")"
    local excludeAdded2; excludeAdded2="$(json_field "$out2" "excludeAdded")"
    local reason2; reason2="$(json_field "$out2" "excludeSkipReason")"
    local errors2; errors2="$(json_field "$out2" "errors")"

    if [ "$notesWritten2" = "true" ] && [ "$excludeAdded2" = "false" ] \
       && [ "$reason2" = "already-present" ] && [ "$errors2" = "[]" ] \
       && [ "$before_md5" = "$after_md5" ]; then
        pass "I3: run() second call idempotent (notesWritten=true, excludeAdded=false, reason=already-present, file unchanged)"
    else
        fail "I3: notesWritten=$notesWritten2 excludeAdded=$excludeAdded2 reason=$reason2 errors=$errors2 (md5 before=$before_md5 after=$after_md5)"
    fi
}

# ============ Run all ============

test_N6_run_happy_path
test_N6b_run_writes_main_repo_line
test_I3_run_idempotent

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $FAIL
