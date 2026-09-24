#!/bin/bash
# Security/traversal-guard tests for worktree-notes.
# Tests: hooks/lib/worktree-notes.js
# Tags: worktree, notes, security, scope:common

. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

# ---- Sec1: run() traversal guard — copiedFiles ../etc/passwd ----
test_Sec1_run_traversal_in_copiedFiles() {
    require_lib "test_Sec1_run_traversal_in_copiedFiles" || return
    local main; main="$(setup_main_repo "sec1-main")"
    local wt;   wt="$(setup_worktree_dest "sec1-wt")"
    local main_node; main_node="$(node_path "$main")"

    local stderr
    stderr="$(lib_eval "
        try {
            const r = lib.run({
                mainRoot: process.argv[1],
                worktreePath: process.argv[2],
                branch: 'feature/sec1',
                createdDate: '2024-01-15',
                resolvedPath: process.argv[2],
                baseDir: null,
                copiedFiles: ['../etc/passwd'],
                excludePattern: 'WORKTREE_NOTES.md'
            });
            process.stdout.write('NOTHROW:' + JSON.stringify(r));
        } catch (e) {
            process.stderr.write('THROW:' + e.message);
        }
    " "$main_node" "$wt" 2>&1 >/dev/null)"

    if echo "$stderr" | grep -q "^THROW:"; then
        pass "Sec1: run() traversal guard — copiedFiles '../etc/passwd' throws (not into errors[])"
    else
        fail "Sec1: expected throw, got: $stderr"
    fi
}

# ---- Sec2: run() traversal guard — mainRoot has .. ----
test_Sec2_run_traversal_in_mainRoot() {
    require_lib "test_Sec2_run_traversal_in_mainRoot" || return
    local wt; wt="$(setup_worktree_dest "sec2-wt")"

    local stderr
    stderr="$(lib_eval "
        try {
            const r = lib.run({
                mainRoot: process.argv[1],
                worktreePath: process.argv[2],
                branch: 'feature/sec2',
                createdDate: '2024-01-15',
                resolvedPath: process.argv[2],
                baseDir: null,
                copiedFiles: [],
                excludePattern: 'WORKTREE_NOTES.md'
            });
            process.stdout.write('NOTHROW:' + JSON.stringify(r));
        } catch (e) {
            process.stderr.write('THROW:' + e.message);
        }
    " "$TMPDIR_BASE/../bad/main" "$wt" 2>&1 >/dev/null)"

    if echo "$stderr" | grep -q "^THROW:"; then
        pass "Sec2: run() traversal guard — mainRoot with '..' throws"
    else
        fail "Sec2: expected throw, got: $stderr"
    fi
}

# ---- Sec3: run() traversal guard — resolvedPath (worktree destination) has .. ----
test_Sec3_run_traversal_in_resolvedPath() {
    require_lib "test_Sec3_run_traversal_in_resolvedPath" || return
    local main; main="$(setup_main_repo "sec3-main")"
    local main_node; main_node="$(node_path "$main")"
    local wt; wt="$(setup_worktree_dest "sec3-wt")"

    local stderr
    stderr="$(lib_eval "
        try {
            const r = lib.run({
                mainRoot: process.argv[1],
                worktreePath: process.argv[2],
                branch: 'feature/sec3',
                createdDate: '2024-01-15',
                resolvedPath: '../../sensitive-path',
                baseDir: null,
                copiedFiles: [],
                excludePattern: 'WORKTREE_NOTES.md'
            });
            process.stdout.write('NOTHROW:' + JSON.stringify(r));
        } catch (e) {
            process.stderr.write('THROW:' + e.message);
        }
    " "$main_node" "$wt" 2>&1 >/dev/null)"

    if echo "$stderr" | grep -q "^THROW:"; then
        pass "Sec3: run() traversal guard — resolvedPath '../../sensitive-path' throws"
    else
        fail "Sec3: expected throw for traversal in resolvedPath, got: $stderr"
    fi
}

# ---- Sec4: run() rejects newline in branch param ----
# NOTE: expected to FAIL until implementation validates the branch parameter.
test_Sec4_run_newline_in_branch() {
    require_lib "test_Sec4_run_newline_in_branch" || return
    local main; main="$(setup_main_repo "sec4-main")"
    local wt;   wt="$(setup_worktree_dest "sec4-wt")"
    local main_node; main_node="$(node_path "$main")"

    local result
    result="$(lib_eval "
        try {
            const r = lib.run({
                mainRoot: process.argv[1],
                worktreePath: process.argv[2],
                branch: 'feature/test\nmalicious',
                createdDate: '2024-01-15',
                resolvedPath: process.argv[2],
                baseDir: null,
                copiedFiles: [],
                excludePattern: 'WORKTREE_NOTES.md'
            });
            process.stdout.write('NOTHROW:' + JSON.stringify(r));
        } catch (e) {
            process.stderr.write('THROW:' + e.message);
        }
    " "$main_node" "$wt" 2>&1)"

    if echo "$result" | grep -q "^THROW:"; then
        pass "Sec4: run() rejects newline in branch param (throws)"
        return
    fi
    local notes_file="$TMPDIR_BASE/sec4-wt/WORKTREE_NOTES.md"
    if grep -q "^malicious$" "$notes_file" 2>/dev/null; then
        fail "Sec4: newline injection in branch leaked into notes as bare 'malicious' line"
    else
        fail "Sec4: run() did not throw and did not produce a NOTHROW marker (result: $result)"
    fi
}

# ---- Sec8: run() rejects newline in mainRoot param ----
# NOTE: expected to FAIL until implementation validates mainRoot for newlines.
test_Sec8_run_newline_in_mainRoot() {
    require_lib "test_Sec8_run_newline_in_mainRoot" || return
    local wt; wt="$(setup_worktree_dest "sec8-wt")"

    local result
    result="$(lib_eval "
        try {
            const r = lib.run({
                mainRoot: '/tmp/main\nmalicious',
                worktreePath: process.argv[1],
                branch: 'feature/sec8',
                createdDate: '2024-01-15',
                resolvedPath: process.argv[1],
                baseDir: null,
                copiedFiles: [],
                excludePattern: 'WORKTREE_NOTES.md'
            });
            process.stdout.write('NOTHROW:' + JSON.stringify(r));
        } catch (e) {
            process.stderr.write('THROW:' + e.message);
        }
    " "$wt" 2>&1)"

    if echo "$result" | grep -q "^THROW:"; then
        pass "Sec8: run() rejects newline in mainRoot param (throws)"
        return
    fi
    local notes_file="$TMPDIR_BASE/sec8-wt/WORKTREE_NOTES.md"
    if grep -q "^malicious$" "$notes_file" 2>/dev/null; then
        fail "Sec8: newline injection in mainRoot leaked into notes as bare 'malicious' line"
    else
        fail "Sec8: run() did not throw (result: $result)"
    fi
}

# ---- Sec11: run() rejects non-string entry in copiedFiles array ----
# NOTE: expected to FAIL until implementation validates copiedFiles entries.
test_Sec11_run_non_string_in_copiedFiles() {
    require_lib "test_Sec11_run_non_string_in_copiedFiles" || return
    local main; main="$(setup_main_repo "sec11-main")"
    local wt;   wt="$(setup_worktree_dest "sec11-wt")"
    local main_node; main_node="$(node_path "$main")"

    local result
    result="$(lib_eval "
        try {
            const r = lib.run({
                mainRoot: process.argv[1],
                worktreePath: process.argv[2],
                branch: 'feature/sec11',
                createdDate: '2024-01-15',
                resolvedPath: process.argv[2],
                baseDir: null,
                copiedFiles: [42],
                excludePattern: 'WORKTREE_NOTES.md'
            });
            process.stdout.write('NOTHROW:' + JSON.stringify(r));
        } catch (e) {
            process.stderr.write('THROW:' + e.message);
        }
    " "$main_node" "$wt" 2>&1)"

    if echo "$result" | grep -q "^THROW:"; then
        pass "Sec11: run() rejects non-string copiedFiles entry [42] (throws)"
        return
    fi
    local notes_file="$TMPDIR_BASE/sec11-wt/WORKTREE_NOTES.md"
    if grep -q "^- 42$" "$notes_file" 2>/dev/null; then
        fail "Sec11: number 42 written as file entry '- 42' in notes (not validated)"
    else
        fail "Sec11: run() did not throw (result: $result)"
    fi
}

# ============ Run all ============

test_Sec1_run_traversal_in_copiedFiles
test_Sec2_run_traversal_in_mainRoot
test_Sec3_run_traversal_in_resolvedPath
test_Sec4_run_newline_in_branch
test_Sec8_run_newline_in_mainRoot
test_Sec11_run_non_string_in_copiedFiles

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $FAIL
