#!/bin/bash
# SiblingWorktrees section tests via writeNotes lib (non-security cases).
# Tests: hooks/lib/worktree-notes.js
# Tags: worktree, notes, sibling, scope:common
#
# Security tests for sibling worktrees (SW-Sec*) are in
# tests/feature-1102-sibling-worktrees/lib-tests.sh.
# CLI-level sibling tests are in tests/feature-1102-sibling-worktrees/cli-tests.sh.

. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

# L3 gap (what this test does NOT catch):
# - Real worktree-start session populating WORKTREE_NOTES.md ## SiblingWorktrees
#   via intent.md ## worktrees → SIBLING_WORKTREES_JSON env pipeline.
# Covered by tests/feature-1102-sibling-worktrees.sh at the CLI boundary.

# ---- SW-Notes1: writeNotes with siblingWorktrees omitted → section with (none) ----
test_SWNotes1_omitted_siblingWorktrees_renders_none() {
    require_lib "test_SWNotes1_omitted_siblingWorktrees_renders_none" || return
    local wt; wt="$(setup_worktree_dest "swnotes1-wt")"

    lib_eval "
        lib.writeNotes({
            worktreePath: process.argv[1],
            branch: 'feature/swnotes1',
            createdDate: '2024-01-15',
            resolvedPath: '/tmp/wt',
            baseDir: null,
            copiedFiles: []
        });
    " "$wt" >/dev/null 2>&1

    local notes_file="$TMPDIR_BASE/swnotes1-wt/WORKTREE_NOTES.md"
    if grep -q "^## SiblingWorktrees$" "$notes_file" 2>/dev/null \
       && grep -q "^- (none)$" "$notes_file" 2>/dev/null; then
        pass "SW-Notes1: siblingWorktrees omitted → '## SiblingWorktrees' section with '- (none)'"
    else
        fail "SW-Notes1: expected section + (none) in $notes_file (content: $(cat "$notes_file" 2>/dev/null))"
    fi
}

# ---- SW-Notes2: writeNotes with siblingWorktrees=[] → section with (none) ----
test_SWNotes2_empty_siblingWorktrees_renders_none() {
    require_lib "test_SWNotes2_empty_siblingWorktrees_renders_none" || return
    local wt; wt="$(setup_worktree_dest "swnotes2-wt")"

    lib_eval "
        lib.writeNotes({
            worktreePath: process.argv[1],
            branch: 'feature/swnotes2',
            createdDate: '2024-01-15',
            resolvedPath: '/tmp/wt',
            baseDir: null,
            copiedFiles: [],
            siblingWorktrees: []
        });
    " "$wt" >/dev/null 2>&1

    local notes_file="$TMPDIR_BASE/swnotes2-wt/WORKTREE_NOTES.md"
    if grep -q "^## SiblingWorktrees$" "$notes_file" 2>/dev/null \
       && grep -q "^- (none)$" "$notes_file" 2>/dev/null; then
        pass "SW-Notes2: siblingWorktrees=[] → '## SiblingWorktrees' section with '- (none)'"
    else
        fail "SW-Notes2: expected section + (none) in $notes_file (content: $(cat "$notes_file" 2>/dev/null))"
    fi
}

# ---- SW-Notes3: writeNotes with one sibling entry → section with entry line ----
test_SWNotes3_one_siblingWorktrees_entry() {
    require_lib "test_SWNotes3_one_siblingWorktrees_entry" || return
    local wt; wt="$(setup_worktree_dest "swnotes3-wt")"

    lib_eval "
        lib.writeNotes({
            worktreePath: process.argv[1],
            branch: 'feature/swnotes3',
            createdDate: '2024-01-15',
            resolvedPath: '/tmp/wt',
            baseDir: null,
            copiedFiles: [],
            siblingWorktrees: [{repo:'owner/r2', worktree_path:'/tmp/wt2'}]
        });
    " "$wt" >/dev/null 2>&1

    local notes_file="$TMPDIR_BASE/swnotes3-wt/WORKTREE_NOTES.md"
    if grep -q "^## SiblingWorktrees$" "$notes_file" 2>/dev/null \
       && grep -q "^- repo: owner/r2, path: /tmp/wt2$" "$notes_file" 2>/dev/null; then
        pass "SW-Notes3: one sibling entry → '## SiblingWorktrees' section + entry line"
    else
        fail "SW-Notes3: expected section + entry in $notes_file (content: $(cat "$notes_file" 2>/dev/null))"
    fi
}

# ---- SW-Notes4: SiblingWorktrees section appears at end of notes (after Changelog Notes) ----
test_SWNotes4_section_ordering() {
    require_lib "test_SWNotes4_section_ordering" || return
    local wt; wt="$(setup_worktree_dest "swnotes4-wt")"

    lib_eval "
        lib.writeNotes({
            worktreePath: process.argv[1],
            branch: 'feature/swnotes4',
            createdDate: '2024-01-15',
            resolvedPath: '/tmp/wt',
            baseDir: null,
            copiedFiles: []
        });
    " "$wt" >/dev/null 2>&1

    local notes_file="$TMPDIR_BASE/swnotes4-wt/WORKTREE_NOTES.md"
    if [ ! -f "$notes_file" ]; then
        fail "SW-Notes4: WORKTREE_NOTES.md not created"
        return
    fi

    local changelog_line sibling_line
    changelog_line="$(grep -n "^## Changelog Notes$" "$notes_file" 2>/dev/null | cut -d: -f1)"
    sibling_line="$(grep -n "^## SiblingWorktrees$" "$notes_file" 2>/dev/null | cut -d: -f1)"

    if [ -n "$changelog_line" ] && [ -n "$sibling_line" ] \
       && [ "$sibling_line" -gt "$changelog_line" ]; then
        pass "SW-Notes4: '## SiblingWorktrees' appears after '## Changelog Notes' (line $sibling_line > $changelog_line)"
    else
        fail "SW-Notes4: expected '## SiblingWorktrees' after '## Changelog Notes', got changelog=$changelog_line sibling=$sibling_line"
    fi
}

# ============ Run all ============

test_SWNotes1_omitted_siblingWorktrees_renders_none
test_SWNotes2_empty_siblingWorktrees_renders_none
test_SWNotes3_one_siblingWorktrees_entry
test_SWNotes4_section_ordering

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $FAIL
