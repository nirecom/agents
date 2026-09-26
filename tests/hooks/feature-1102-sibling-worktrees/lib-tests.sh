#!/bin/bash
# Lib-level tests: buildNotesBody/run() siblingWorktrees normal + idempotency
# Tests: hooks/lib/worktree-notes.js
# Tags: worktree, sibling, scope:issue-specific
#
# Security/error tests are in lib-security-tests.sh.

. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

# ---- SW1: siblingWorktrees with one entry → section with entry line ----
test_SW1_siblingWorktrees_one_entry() {
    require_lib "test_SW1_siblingWorktrees_one_entry" || return
    local wt; wt="$(setup_worktree_dest "sw1-wt")"
    lib_eval "lib.writeNotes({worktreePath:process.argv[1],branch:'feature/sw1',createdDate:'2024-01-15',resolvedPath:'/tmp/wt',baseDir:null,copiedFiles:[],siblingWorktrees:[{repo:'owner/r2',worktree_path:'/tmp/wt2'}]});" "$wt" >/dev/null 2>&1
    local f="$TMPDIR_BASE/sw1-wt/WORKTREE_NOTES.md"
    if grep -q "^## SiblingWorktrees$" "$f" 2>/dev/null && grep -q "^- repo: owner/r2, path: /tmp/wt2$" "$f" 2>/dev/null; then
        pass "SW1: siblingWorktrees one entry → '## SiblingWorktrees' section + entry line"
    else
        fail "SW1: expected '## SiblingWorktrees' + entry in $f (content: $(cat "$f" 2>/dev/null))"
    fi
}

# ---- SW2: siblingWorktrees=[] → section with (none) ----
test_SW2_siblingWorktrees_empty() {
    require_lib "test_SW2_siblingWorktrees_empty" || return
    local wt; wt="$(setup_worktree_dest "sw2-wt")"
    lib_eval "lib.writeNotes({worktreePath:process.argv[1],branch:'feature/sw2',createdDate:'2024-01-15',resolvedPath:'/tmp/wt',baseDir:null,copiedFiles:[],siblingWorktrees:[]});" "$wt" >/dev/null 2>&1
    local f="$TMPDIR_BASE/sw2-wt/WORKTREE_NOTES.md"
    if grep -q "^## SiblingWorktrees$" "$f" 2>/dev/null; then
        local s; s="$(awk '/^## SiblingWorktrees/{f=1;next} f && /^## /{f=0} f{print}' "$f")"
        if echo "$s" | grep -q "^- (none)$"; then
            pass "SW2: siblingWorktrees=[] → '## SiblingWorktrees' section with '- (none)'"
        else
            fail "SW2: '## SiblingWorktrees' found but missing '- (none)' (section: $s)"
        fi
    else
        fail "SW2: missing '## SiblingWorktrees' in $f (content: $(cat "$f" 2>/dev/null))"
    fi
}

# ---- SW3: siblingWorktrees param omitted → section with (none) (default) ----
test_SW3_siblingWorktrees_omitted() {
    require_lib "test_SW3_siblingWorktrees_omitted" || return
    local wt; wt="$(setup_worktree_dest "sw3-wt")"
    lib_eval "lib.writeNotes({worktreePath:process.argv[1],branch:'feature/sw3',createdDate:'2024-01-15',resolvedPath:'/tmp/wt',baseDir:null,copiedFiles:[]});" "$wt" >/dev/null 2>&1
    local f="$TMPDIR_BASE/sw3-wt/WORKTREE_NOTES.md"
    if grep -q "^## SiblingWorktrees$" "$f" 2>/dev/null; then
        local s; s="$(awk '/^## SiblingWorktrees/{f=1;next} f && /^## /{f=0} f{print}' "$f")"
        if echo "$s" | grep -q "^- (none)$"; then
            pass "SW3: siblingWorktrees omitted → '## SiblingWorktrees' with '- (none)' (default behavior)"
        else
            fail "SW3: '## SiblingWorktrees' found but missing '- (none)' (section: $s)"
        fi
    else
        fail "SW3: missing '## SiblingWorktrees' in $f (content: $(cat "$f" 2>/dev/null))"
    fi
}

# ---- SW4: siblingWorktrees with 2 entries → both rendered correctly ----
test_SW4_siblingWorktrees_two_entries() {
    require_lib "test_SW4_siblingWorktrees_two_entries" || return
    local wt; wt="$(setup_worktree_dest "sw4-wt")"
    lib_eval "lib.writeNotes({worktreePath:process.argv[1],branch:'feature/sw4',createdDate:'2024-01-15',resolvedPath:'/tmp/wt',baseDir:null,copiedFiles:[],siblingWorktrees:[{repo:'owner/r2',worktree_path:'/tmp/wt2'},{repo:'owner/r3',worktree_path:'/tmp/wt3'}]});" "$wt" >/dev/null 2>&1
    local f="$TMPDIR_BASE/sw4-wt/WORKTREE_NOTES.md"
    local sibling_section; sibling_section="$(awk '/^## SiblingWorktrees/{f=1;next} f && /^## /{f=0} f{print}' "$f" 2>/dev/null)"
    if grep -q "^## SiblingWorktrees$" "$f" 2>/dev/null \
       && grep -q "^- repo: owner/r2, path: /tmp/wt2$" "$f" 2>/dev/null \
       && grep -q "^- repo: owner/r3, path: /tmp/wt3$" "$f" 2>/dev/null \
       && ! echo "$sibling_section" | grep -q "^- (none)$"; then
        pass "SW4: siblingWorktrees 2 entries → both entry lines present, no '- (none)' in section"
    else
        fail "SW4: expected both entry lines without '- (none)' in section of $f (sibling_section: $sibling_section) (content: $(cat "$f" 2>/dev/null))"
    fi
}

# ---- SW-Idm1: idempotency — writeNotes with siblingWorktrees called twice → identical content ----
test_SWIdm1_writeNotes_idempotent() {
    require_lib "test_SWIdm1_writeNotes_idempotent" || return
    local wt; wt="$(setup_worktree_dest "swidm1-wt")"
    local snip="lib.writeNotes({worktreePath:process.argv[1],branch:'feature/swidm1',createdDate:'2024-01-15',resolvedPath:'/tmp/wt',baseDir:null,copiedFiles:[],siblingWorktrees:[{repo:'owner/r2',worktree_path:'/tmp/wt2'}]});"
    lib_eval "$snip" "$wt" >/dev/null 2>&1
    lib_eval "$snip" "$wt" >/dev/null 2>&1
    local f="$TMPDIR_BASE/swidm1-wt/WORKTREE_NOTES.md"
    if [ ! -f "$f" ]; then fail "SW-Idm1: WORKTREE_NOTES.md not created (implementation not found)"; return; fi
    local sc ec
    sc="$(grep -c "^## SiblingWorktrees$" "$f" 2>/dev/null || echo 0)"
    ec="$(grep -c "^- repo: owner/r2, path: /tmp/wt2$" "$f" 2>/dev/null || echo 0)"
    if [ "$sc" = "1" ] && [ "$ec" = "1" ]; then
        pass "SW-Idm1: writeNotes called twice → single '## SiblingWorktrees' section, single entry (idempotent)"
    else
        fail "SW-Idm1: expected 1 section + 1 entry after two writes, got section_count=$sc entry_count=$ec (content: $(cat "$f" 2>/dev/null))"
    fi
}

# ============ Run all ============

test_SW1_siblingWorktrees_one_entry
test_SW2_siblingWorktrees_empty
test_SW3_siblingWorktrees_omitted
test_SW4_siblingWorktrees_two_entries
test_SWIdm1_writeNotes_idempotent

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $FAIL
