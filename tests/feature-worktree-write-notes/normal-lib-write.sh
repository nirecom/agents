#!/bin/bash
# writeNotes + appendExclude normal/idempotency tests.
# Tests: hooks/lib/worktree-notes.js
# Tags: worktree, notes, scope:common

. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

# ---- N1: writeNotes generates exact markdown ----
test_N1_writeNotes_exact_content() {
    require_lib "test_N1_writeNotes_exact_content" || return
    local wt; wt="$(setup_worktree_dest "n1-wt")"

    lib_eval "
        const r = lib.writeNotes({
            worktreePath: process.argv[1],
            branch: 'feature/foo',
            createdDate: '2024-01-15',
            resolvedPath: '/tmp/wt',
            baseDir: 'C:/git/worktrees',
            mainRoot: '/tmp/main',
            sessionId: 'sess-abc-123',
            copiedFiles: ['a.env','b/.env.local']
        });
        process.stdout.write(JSON.stringify(r));
    " "$wt" >/dev/null 2>&1

    local notes_file="$TMPDIR_BASE/n1-wt/WORKTREE_NOTES.md"
    if [ ! -f "$notes_file" ]; then
        fail "N1: WORKTREE_NOTES.md not created at $notes_file"
        return
    fi

    local expected
    expected="$(printf '%s\n' \
        '# Worktree Notes' \
        'Branch: feature/foo' \
        'Created: 2024-01-15' \
        'Path: /tmp/wt' \
        'Main repo: /tmp/main' \
        'WORKTREE_BASE_DIR: C:/git/worktrees' \
        'Session-ID: sess-abc-123' \
        '' \
        '## Gitignored files copied from main' \
        '- a.env' \
        '- b/.env.local' \
        '' \
        '## BugsFound' \
        '- (none)' \
        '' \
        '## RelatedTasks' \
        '- (none)' \
        '' \
        '## NextTasks' \
        '- (none)' \
        '' \
        '## History Notes' \
        '- (none)' \
        '' \
        '## Changelog Notes' \
        '- (none)' \
        '' \
        '## SiblingWorktrees' \
        '- (none)')"

    local actual; actual="$(cat "$notes_file")"
    if [ "$actual" = "$expected" ]; then
        pass "N1: writeNotes generates correct markdown content (byte-for-byte)"
    else
        fail "N1: content mismatch
--- expected ---
$expected
--- actual ---
$actual
---"
    fi
}

# ---- N2: copiedFiles=[] → "- (none)" ----
test_N2_writeNotes_empty_copied_renders_none() {
    require_lib "test_N2_writeNotes_empty_copied_renders_none" || return
    local wt; wt="$(setup_worktree_dest "n2-wt")"
    lib_eval "lib.writeNotes({worktreePath:process.argv[1],branch:'feature/empty',createdDate:'2024-01-15',resolvedPath:'/tmp/wt',baseDir:'C:/git/worktrees',copiedFiles:[]});" "$wt" >/dev/null 2>&1
    local notes_file="$TMPDIR_BASE/n2-wt/WORKTREE_NOTES.md"
    if grep -q "^- (none)$" "$notes_file" 2>/dev/null; then
        pass "N2: copiedFiles=[] renders '- (none)' line"
    else
        fail "N2: missing '- (none)' line in $notes_file"
    fi
}

# ---- N3: baseDir=null → "(default)" ----
test_N3_writeNotes_null_baseDir_renders_default() {
    require_lib "test_N3_writeNotes_null_baseDir_renders_default" || return
    local wt; wt="$(setup_worktree_dest "n3-wt")"
    lib_eval "lib.writeNotes({worktreePath:process.argv[1],branch:'feature/x',createdDate:'2024-01-15',resolvedPath:'/tmp/wt',baseDir:null,copiedFiles:['a.env']});" "$wt" >/dev/null 2>&1
    local notes_file="$TMPDIR_BASE/n3-wt/WORKTREE_NOTES.md"
    if grep -q "^WORKTREE_BASE_DIR: (default)$" "$notes_file" 2>/dev/null; then
        pass "N3: baseDir=null renders 'WORKTREE_BASE_DIR: (default)'"
    else
        fail "N3: missing 'WORKTREE_BASE_DIR: (default)' in $notes_file"
    fi
}

# ---- I1: writeNotes idempotency ----
test_I1_writeNotes_idempotent() {
    require_lib "test_I1_writeNotes_idempotent" || return
    local wt; wt="$(setup_worktree_dest "i1-wt")"

    local snippet="
        const args = {
            worktreePath: process.argv[1],
            branch: 'feature/i',
            createdDate: '2024-01-15',
            resolvedPath: '/tmp/wt',
            baseDir: 'C:/git/worktrees',
            mainRoot: '/tmp/main',
            sessionId: 'sess-abc-123',
            copiedFiles: ['a.env','b/.env.local']
        };
        lib.writeNotes(args);
        lib.writeNotes(args);
    "
    lib_eval "$snippet" "$wt" >/dev/null 2>&1

    local notes_file="$TMPDIR_BASE/i1-wt/WORKTREE_NOTES.md"
    if [ ! -f "$notes_file" ]; then fail "I1: WORKTREE_NOTES.md not created"; return; fi

    local expected
    expected="$(printf '%s\n' \
        '# Worktree Notes' \
        'Branch: feature/i' \
        'Created: 2024-01-15' \
        'Path: /tmp/wt' \
        'Main repo: /tmp/main' \
        'WORKTREE_BASE_DIR: C:/git/worktrees' \
        'Session-ID: sess-abc-123' \
        '' \
        '## Gitignored files copied from main' \
        '- a.env' \
        '- b/.env.local' \
        '' \
        '## BugsFound' \
        '- (none)' \
        '' \
        '## RelatedTasks' \
        '- (none)' \
        '' \
        '## NextTasks' \
        '- (none)' \
        '' \
        '## History Notes' \
        '- (none)' \
        '' \
        '## Changelog Notes' \
        '- (none)' \
        '' \
        '## SiblingWorktrees' \
        '- (none)')"
    local actual; actual="$(cat "$notes_file")"
    if [ "$actual" = "$expected" ]; then
        pass "I1: writeNotes is idempotent (second call produces identical content)"
    else
        fail "I1: content differs after second call"
    fi
}

# ---- SID1: buildNotesBody includes Session-ID header when provided ----
test_SID1_writeNotes_session_id_header() {
    require_lib "test_SID1_writeNotes_session_id_header" || return
    local wt; wt="$(setup_worktree_dest "sid1-wt")"
    lib_eval "lib.writeNotes({worktreePath:process.argv[1],branch:'feature/sid1',createdDate:'2024-01-15',resolvedPath:'/tmp/wt',baseDir:null,sessionId:'abc-123',copiedFiles:[]});" "$wt" >/dev/null 2>&1
    local notes_file="$TMPDIR_BASE/sid1-wt/WORKTREE_NOTES.md"
    if grep -q "^Session-ID: abc-123$" "$notes_file" 2>/dev/null; then
        pass "SID1: writeNotes includes 'Session-ID: abc-123' when sessionId provided"
    else
        fail "SID1: missing 'Session-ID: abc-123' in $notes_file (content: $(cat "$notes_file" 2>/dev/null))"
    fi
}

# ---- SID2: buildNotesBody omits Session-ID header when sessionId not provided ----
test_SID2_writeNotes_omitted_session_id() {
    require_lib "test_SID2_writeNotes_omitted_session_id" || return
    local wt; wt="$(setup_worktree_dest "sid2-wt")"
    lib_eval "lib.writeNotes({worktreePath:process.argv[1],branch:'feature/sid2',createdDate:'2024-01-15',resolvedPath:'/tmp/wt',baseDir:null,copiedFiles:[]});" "$wt" >/dev/null 2>&1
    local notes_file="$TMPDIR_BASE/sid2-wt/WORKTREE_NOTES.md"
    if ! grep -q "^Session-ID:" "$notes_file" 2>/dev/null; then
        pass "SID2: writeNotes omits 'Session-ID:' line when sessionId not provided"
    else
        fail "SID2: unexpected 'Session-ID:' line found in $notes_file"
    fi
}

# ---- N4: appendExclude appends new pattern to existing file ----
test_N4_appendExclude_appends_to_existing() {
    require_lib "test_N4_appendExclude_appends_to_existing" || return
    local main; main="$(setup_main_repo "n4-main")"
    local main_node; main_node="$(node_path "$main")"
    mkdir -p "$main/.git/info"
    printf 'existing-pattern\n' > "$main/.git/info/exclude"

    local out
    out="$(lib_eval "const r=lib.appendExclude({mainRoot:process.argv[1],pattern:'WORKTREE_NOTES.md'});process.stdout.write(JSON.stringify(r));" "$main_node" 2>/dev/null)"
    local added; added="$(json_field "$out" "excludeAdded")"
    if [ "$added" = "true" ] && grep -q "^WORKTREE_NOTES.md$" "$main/.git/info/exclude" \
       && grep -q "^existing-pattern$" "$main/.git/info/exclude"; then
        pass "N4: appendExclude appends new pattern to existing exclude file"
    else
        fail "N4: appendExclude failed (out=$out)"
    fi
}

# ---- N5: appendExclude creates .git/info/ + exclude when missing ----
test_N5_appendExclude_creates_dir_and_file() {
    require_lib "test_N5_appendExclude_creates_dir_and_file" || return
    local main; main="$(setup_main_repo "n5-main")"
    local main_node; main_node="$(node_path "$main")"
    rm -rf "$main/.git/info"

    local out
    out="$(lib_eval "const r=lib.appendExclude({mainRoot:process.argv[1],pattern:'WORKTREE_NOTES.md'});process.stdout.write(JSON.stringify(r));" "$main_node" 2>/dev/null)"
    local added; added="$(json_field "$out" "excludeAdded")"
    if [ "$added" = "true" ] && [ -d "$main/.git/info" ] \
       && grep -q "^WORKTREE_NOTES.md$" "$main/.git/info/exclude"; then
        pass "N5: appendExclude creates .git/info/ dir and exclude file"
    else
        fail "N5: missing dir/file or pattern not added (out=$out)"
    fi
}

# ---- I2: appendExclude already-present → skip ----
test_I2_appendExclude_already_present() {
    require_lib "test_I2_appendExclude_already_present" || return
    local main; main="$(setup_main_repo "i2-main")"
    local main_node; main_node="$(node_path "$main")"
    mkdir -p "$main/.git/info"
    printf 'foo\nWORKTREE_NOTES.md\nbar\n' > "$main/.git/info/exclude"
    local before_md5
    before_md5="$(node -e "const c=require('crypto'),fs=require('fs');process.stdout.write(c.createHash('md5').update(fs.readFileSync(process.argv[1])).digest('hex'));" -- "$main/.git/info/exclude" 2>/dev/null)"
    local out
    out="$(lib_eval "const r=lib.appendExclude({mainRoot:process.argv[1],pattern:'WORKTREE_NOTES.md'});process.stdout.write(JSON.stringify(r));" "$main_node" 2>/dev/null)"
    local added; added="$(json_field "$out" "excludeAdded")"
    local reason; reason="$(json_field "$out" "excludeSkipReason")"
    local after_md5
    after_md5="$(node -e "const c=require('crypto'),fs=require('fs');process.stdout.write(c.createHash('md5').update(fs.readFileSync(process.argv[1])).digest('hex'));" -- "$main/.git/info/exclude" 2>/dev/null)"
    if [ "$added" = "false" ] && [ "$reason" = "already-present" ] && [ "$before_md5" = "$after_md5" ]; then
        pass "I2: appendExclude when already present → excludeAdded=false, reason=already-present, file unchanged"
    else
        fail "I2: expected added=false reason=already-present, got added=$added reason=$reason (file changed: $before_md5 → $after_md5)"
    fi
}

# ============ Run all ============

test_N1_writeNotes_exact_content
test_N2_writeNotes_empty_copied_renders_none
test_N3_writeNotes_null_baseDir_renders_default
test_I1_writeNotes_idempotent
test_SID1_writeNotes_session_id_header
test_SID2_writeNotes_omitted_session_id
test_N4_appendExclude_appends_to_existing
test_N5_appendExclude_creates_dir_and_file
test_I2_appendExclude_already_present

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $FAIL
