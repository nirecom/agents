#!/bin/bash
# Lib-level security/error tests: run() siblingWorktrees validation
# Tests: hooks/lib/worktree-notes.js
# Tags: worktree, sibling, security, scope:issue-specific

. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

# ---- SW-Sec1: run() rejects newline in siblingWorktrees repo name ----
test_SWSec1_newline_in_repo_name_rejected() {
    require_lib "test_SWSec1_newline_in_repo_name_rejected" || return
    local main; main="$(setup_main_repo "swsec1-main")"
    local wt;   wt="$(setup_worktree_dest "swsec1-wt")"
    local mn; mn="$(node_path "$main")"
    local stderr
    stderr="$(lib_eval "try{lib.run({mainRoot:process.argv[1],worktreePath:process.argv[2],branch:'feature/swsec1',createdDate:'2024-01-15',resolvedPath:process.argv[2],baseDir:null,copiedFiles:[],excludePattern:'WORKTREE_NOTES.md',siblingWorktrees:[{repo:'owner/\nrepo',worktree_path:'/tmp/wt'}]});process.stdout.write('NOTHROW');}catch(e){process.stderr.write('THROW:'+e.message);}" "$mn" "$wt" 2>&1 >/dev/null)"
    if echo "$stderr" | grep -q "^THROW:"; then
        pass "SW-Sec1: run() rejects newline in siblingWorktrees repo name (throws)"
    else
        fail "SW-Sec1: expected throw for newline in repo name, got: $stderr"
    fi
}
# ---- SW-Sec2: run() rejects path traversal in siblingWorktrees worktree_path ----
test_SWSec2_path_traversal_in_sibling_path_rejected() {
    require_lib "test_SWSec2_path_traversal_in_sibling_path_rejected" || return
    local main; main="$(setup_main_repo "swsec2-main")"
    local wt;   wt="$(setup_worktree_dest "swsec2-wt")"
    local mn; mn="$(node_path "$main")"
    local stderr
    stderr="$(lib_eval "try{lib.run({mainRoot:process.argv[1],worktreePath:process.argv[2],branch:'feature/swsec2',createdDate:'2024-01-15',resolvedPath:process.argv[2],baseDir:null,copiedFiles:[],excludePattern:'WORKTREE_NOTES.md',siblingWorktrees:[{repo:'owner/repo',worktree_path:'../../../etc'}]});process.stdout.write('NOTHROW');}catch(e){process.stderr.write('THROW:'+e.message);}" "$mn" "$wt" 2>&1 >/dev/null)"
    if echo "$stderr" | grep -q "^THROW:"; then
        pass "SW-Sec2: run() rejects path traversal in siblingWorktrees worktree_path (throws)"
    else
        fail "SW-Sec2: expected throw for path traversal in sibling path, got: $stderr"
    fi
}

# ---- SW-Sec3: run() rejects shell metacharacters in siblingWorktrees repo field ----
test_SWSec3_shell_injection_in_repo_field_rejected() {
    require_lib "test_SWSec3_shell_injection_in_repo_field_rejected" || return
    local main; main="$(setup_main_repo "swsec3-main")"
    local wt;   wt="$(setup_worktree_dest "swsec3-wt")"
    local mn; mn="$(node_path "$main")"
    local all_passed=1
    for bad_repo in 'owner/$(rm -rf /tmp/injected)' 'owner/repo && evil' 'owner/repo|cat /etc/passwd' 'owner/repo;evil' 'owner/`id`'; do
        local stderr
        stderr="$(lib_eval "try{lib.run({mainRoot:process.argv[1],worktreePath:process.argv[2],branch:'feature/swsec3',createdDate:'2024-01-15',resolvedPath:process.argv[2],baseDir:null,copiedFiles:[],excludePattern:'WORKTREE_NOTES.md',siblingWorktrees:[{repo:process.argv[3],worktree_path:process.argv[2]}]});process.stdout.write('NOTHROW');}catch(e){process.stderr.write('THROW:'+e.message);}" "$mn" "$wt" "$bad_repo" 2>&1 >/dev/null)"
        if ! echo "$stderr" | grep -q "^THROW:"; then
            all_passed=0
            fail "SW-Sec3: run() did NOT throw for shell metacharacters in repo='$bad_repo' (got: $stderr)"
            break
        fi
    done
    if [ "$all_passed" = "1" ]; then
        pass "SW-Sec3: run() rejects shell metacharacters in siblingWorktrees repo field (\$(), &&, |, ;, backtick)"
    fi
}
# ---- SW-Sec4: run() rejects newline in siblingWorktrees worktree_path ----
test_SWSec4_newline_in_worktree_path_rejected() {
    require_lib "test_SWSec4_newline_in_worktree_path_rejected" || return
    local main; main="$(setup_main_repo "swsec4-main")"
    local wt;   wt="$(setup_worktree_dest "swsec4-wt")"
    local mn; mn="$(node_path "$main")"
    local stderr
    stderr="$(lib_eval "try{lib.run({mainRoot:process.argv[1],worktreePath:process.argv[2],branch:'feature/swsec4',createdDate:'2024-01-15',resolvedPath:process.argv[2],baseDir:null,copiedFiles:[],excludePattern:'WORKTREE_NOTES.md',siblingWorktrees:[{repo:'owner/repo',worktree_path:'/tmp/wt\nmalicious'}]});process.stdout.write('NOTHROW');}catch(e){process.stderr.write('THROW:'+e.message);}" "$mn" "$wt" 2>&1 >/dev/null)"
    if echo "$stderr" | grep -q "^THROW:"; then
        pass "SW-Sec4: run() rejects newline in siblingWorktrees worktree_path (throws)"
    else
        fail "SW-Sec4: expected throw for newline in worktree_path, got: $stderr"
    fi
}
# ---- SW-Sec5: null repo in siblingWorktrees entry → not written as literal "null" ----
test_SWSec5_null_repo_not_written() {
    require_lib "test_SWSec5_null_repo_not_written" || return
    local wt; wt="$(setup_worktree_dest "swsec5-wt")"
    lib_eval "lib.writeNotes({worktreePath:process.argv[1],branch:'feature/swsec5',createdDate:'2024-01-15',resolvedPath:'/tmp/wt',baseDir:null,copiedFiles:[],siblingWorktrees:[{repo:null,worktree_path:'/tmp/wt'}]});" "$wt" >/dev/null 2>&1
    local f="$TMPDIR_BASE/swsec5-wt/WORKTREE_NOTES.md"
    local section; section="$(awk '/^## SiblingWorktrees/{f=1;next} f && /^## /{f=0} f{print}' "$f" 2>/dev/null)"
    if echo "$section" | grep -q "null"; then
        fail "SW-Sec5: literal 'null' written as repo name in SiblingWorktrees (section: $section)"
    else
        pass "SW-Sec5: null repo in sibling entry not written as literal 'null' (silently skipped or '- (none)')"
    fi
}
# ---- SW-Sec6: null worktree_path in siblingWorktrees entry → not written as literal "null" ----
test_SWSec6_null_worktree_path_not_written() {
    require_lib "test_SWSec6_null_worktree_path_not_written" || return
    local wt; wt="$(setup_worktree_dest "swsec6-wt")"
    lib_eval "lib.writeNotes({worktreePath:process.argv[1],branch:'feature/swsec6',createdDate:'2024-01-15',resolvedPath:'/tmp/wt',baseDir:null,copiedFiles:[],siblingWorktrees:[{repo:'owner/r2',worktree_path:null}]});" "$wt" >/dev/null 2>&1
    local f="$TMPDIR_BASE/swsec6-wt/WORKTREE_NOTES.md"
    local section; section="$(awk '/^## SiblingWorktrees/{f=1;next} f && /^## /{f=0} f{print}' "$f" 2>/dev/null)"
    if echo "$section" | grep -q "path: null"; then
        fail "SW-Sec6: literal 'null' written as worktree_path in SiblingWorktrees (section: $section)"
    else
        pass "SW-Sec6: null worktree_path in sibling entry not written as literal 'null' (silently skipped or '- (none)')"
    fi
}
# ---- SW-Sec7: shell metacharacters in siblingWorktrees worktree_path → rejected or sanitized ----
test_SWSec7_shell_injection_in_worktree_path_rejected() {
    require_lib "test_SWSec7_shell_injection_in_worktree_path_rejected" || return
    local main; main="$(setup_main_repo "swsec7-main")"
    local wt;   wt="$(setup_worktree_dest "swsec7-wt")"
    local mn; mn="$(node_path "$main")"
    local all_passed=1
    for bad_path in '/tmp/wt; rm -rf /' '/tmp/wt && evil' '/tmp/wt|cat /etc/passwd' '/tmp/wt`id`'; do
        local stderr
        stderr="$(lib_eval "try{lib.run({mainRoot:process.argv[1],worktreePath:process.argv[2],branch:'feature/swsec7',createdDate:'2024-01-15',resolvedPath:process.argv[2],baseDir:null,copiedFiles:[],excludePattern:'WORKTREE_NOTES.md',siblingWorktrees:[{repo:'owner/repo',worktree_path:process.argv[3]}]});process.stdout.write('NOTHROW');}catch(e){process.stderr.write('THROW:'+e.message);}" "$mn" "$wt" "$bad_path" 2>&1 >/dev/null)"
        if ! echo "$stderr" | grep -q "^THROW:"; then
            all_passed=0
            fail "SW-Sec7: run() did NOT throw for shell metacharacters in worktree_path='$bad_path' (got: $stderr)"
            break
        fi
    done
    if [ "$all_passed" = "1" ]; then
        pass "SW-Sec7: run() rejects shell metacharacters in siblingWorktrees worktree_path (;, &&, |, backtick)"
    fi
}

# ---- SW-Err1: siblingWorktrees array containing non-object entry → rejected or skipped ----
# NOTE: expected to FAIL until implementation validates array entries.
test_SWErr1_non_object_entry_in_siblingWorktrees() {
    require_lib "test_SWErr1_non_object_entry_in_siblingWorktrees" || return
    local main; main="$(setup_main_repo "swerr1-main")"
    local wt;   wt="$(setup_worktree_dest "swerr1-wt")"
    local mn; mn="$(node_path "$main")"

    local result
    result="$(lib_eval "
        try {
            const r = lib.run({
                mainRoot: process.argv[1],
                worktreePath: process.argv[2],
                branch: 'feature/swerr1',
                createdDate: '2024-01-15',
                resolvedPath: process.argv[2],
                baseDir: null,
                copiedFiles: [],
                excludePattern: 'WORKTREE_NOTES.md',
                siblingWorktrees: [42]
            });
            process.stdout.write('NOTHROW:' + JSON.stringify(r));
        } catch (e) {
            process.stderr.write('THROW:' + e.message);
        }
    " "$mn" "$wt" 2>&1)"

    if echo "$result" | grep -q "^THROW:"; then
        pass "SW-Err1: run() rejects non-object entry [42] in siblingWorktrees (throws)"
        return
    fi
    local notes_file="$TMPDIR_BASE/swerr1-wt/WORKTREE_NOTES.md"
    local section; section="$(awk '/^## SiblingWorktrees/{f=1;next} f && /^## /{f=0} f{print}' "$notes_file" 2>/dev/null)"
    if echo "$section" | grep -q "42"; then
        fail "SW-Err1: number 42 written into SiblingWorktrees section (not validated); section: $section"
    else
        fail "SW-Err1: run() did not throw for non-object entry in siblingWorktrees (result: $result)"
    fi
}

# ---- SW-Err2: siblingWorktrees array entry is null → graceful handling ----
# NOTE: expected to FAIL until implementation handles mixed null/valid arrays.
test_SWErr2_null_entry_in_siblingWorktrees() {
    require_lib "test_SWErr2_null_entry_in_siblingWorktrees" || return
    local main; main="$(setup_main_repo "swerr2-main")"
    local wt;   wt="$(setup_worktree_dest "swerr2-wt")"
    local mn; mn="$(node_path "$main")"

    local result
    result="$(lib_eval "
        try {
            const r = lib.run({
                mainRoot: process.argv[1],
                worktreePath: process.argv[2],
                branch: 'feature/swerr2',
                createdDate: '2024-01-15',
                resolvedPath: process.argv[2],
                baseDir: null,
                copiedFiles: [],
                excludePattern: 'WORKTREE_NOTES.md',
                siblingWorktrees: [null, {repo:'owner/r2', worktree_path:'/tmp/wt2'}]
            });
            process.stdout.write('NOTHROW:' + JSON.stringify(r));
        } catch (e) {
            process.stderr.write('THROW:' + e.message);
        }
    " "$mn" "$wt" 2>&1)"

    if echo "$result" | grep -q "^THROW:"; then
        pass "SW-Err2: run() rejects null entry in siblingWorktrees (throws)"
        return
    fi
    local notes_file="$TMPDIR_BASE/swerr2-wt/WORKTREE_NOTES.md"
    local section; section="$(awk '/^## SiblingWorktrees/{f=1;next} f && /^## /{f=0} f{print}' "$notes_file" 2>/dev/null)"
    if echo "$section" | grep -q "^- repo: null"; then
        fail "SW-Err2: literal 'null' written as repo in SiblingWorktrees section (section: $section)"
    elif echo "$section" | grep -q "path: null"; then
        fail "SW-Err2: literal 'null' written as path in SiblingWorktrees section (section: $section)"
    else
        fail "SW-Err2: run() did not throw for null entry in siblingWorktrees (result: $result)"
    fi
}

# ---- SW-Edge1: empty-string repo field in sibling entry → skipped or non-zero exit ----
# NOTE: expected to FAIL until implementation validates empty string fields.
test_SWEdge1_empty_string_repo_field() {
    require_lib "test_SWEdge1_empty_string_repo_field" || return
    local main; main="$(setup_main_repo "swedge1-main")"
    local wt;   wt="$(setup_worktree_dest "swedge1-wt")"
    local mn; mn="$(node_path "$main")"

    local result
    result="$(lib_eval "
        try {
            const r = lib.run({
                mainRoot: process.argv[1],
                worktreePath: process.argv[2],
                branch: 'feature/swedge1',
                createdDate: '2024-01-15',
                resolvedPath: process.argv[2],
                baseDir: null,
                copiedFiles: [],
                excludePattern: 'WORKTREE_NOTES.md',
                siblingWorktrees: [{repo: '', worktree_path: '/tmp/wt'}]
            });
            process.stdout.write('NOTHROW:' + JSON.stringify(r));
        } catch (e) {
            process.stderr.write('THROW:' + e.message);
        }
    " "$mn" "$wt" 2>&1)"

    if echo "$result" | grep -q "^THROW:"; then
        pass "SW-Edge1: run() rejects empty-string repo field (throws)"
        return
    fi
    local notes_file="$TMPDIR_BASE/swedge1-wt/WORKTREE_NOTES.md"
    local section; section="$(awk '/^## SiblingWorktrees/{f=1;next} f && /^## /{f=0} f{print}' "$notes_file" 2>/dev/null)"
    if echo "$section" | grep -qE "^- repo: , path:"; then
        fail "SW-Edge1: empty-string repo written as '- repo: , path: ...' (not validated/skipped; section: $section)"
    else
        fail "SW-Edge1: run() did not throw for empty repo field (result: $result)"
    fi
}

# ---- SW-Sec8: combined newline injection in both repo and worktree_path ----
# NOTE: expected to FAIL until implementation validates both fields simultaneously.
test_SWSec8_combined_newline_in_repo_and_path() {
    require_lib "test_SWSec8_combined_newline_in_repo_and_path" || return
    local main; main="$(setup_main_repo "swsec8-main")"
    local wt;   wt="$(setup_worktree_dest "swsec8-wt")"
    local mn; mn="$(node_path "$main")"

    local result
    result="$(lib_eval "
        try {
            const r = lib.run({
                mainRoot: process.argv[1],
                worktreePath: process.argv[2],
                branch: 'feature/swsec8',
                createdDate: '2024-01-15',
                resolvedPath: process.argv[2],
                baseDir: null,
                copiedFiles: [],
                excludePattern: 'WORKTREE_NOTES.md',
                siblingWorktrees: [{repo: 'owner/r\nmalicious', worktree_path: '/tmp/wt\nbad'}]
            });
            process.stdout.write('NOTHROW:' + JSON.stringify(r));
        } catch (e) {
            process.stderr.write('THROW:' + e.message);
        }
    " "$mn" "$wt" 2>&1)"

    if echo "$result" | grep -q "^THROW:"; then
        pass "SW-Sec8: run() rejects combined newline injection in repo+worktree_path (throws)"
        return
    fi
    local notes_file="$TMPDIR_BASE/swsec8-wt/WORKTREE_NOTES.md"
    local repo_leak=0; local path_leak=0
    grep -q "^malicious$" "$notes_file" 2>/dev/null && repo_leak=1
    grep -q "^bad$" "$notes_file" 2>/dev/null && path_leak=1
    if [ "$repo_leak" = "1" ] || [ "$path_leak" = "1" ]; then
        fail "SW-Sec8: newline leaked into notes (repo_leak=$repo_leak path_leak=$path_leak)"
    else
        fail "SW-Sec8: run() did not throw for combined newline injection (result: $result)"
    fi
}

# ============ Run all ============
test_SWSec1_newline_in_repo_name_rejected
test_SWSec2_path_traversal_in_sibling_path_rejected
test_SWSec3_shell_injection_in_repo_field_rejected
test_SWSec4_newline_in_worktree_path_rejected
test_SWSec5_null_repo_not_written
test_SWSec6_null_worktree_path_not_written
test_SWSec7_shell_injection_in_worktree_path_rejected
test_SWErr1_non_object_entry_in_siblingWorktrees
test_SWErr2_null_entry_in_siblingWorktrees
test_SWEdge1_empty_string_repo_field
test_SWSec8_combined_newline_in_repo_and_path
echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $FAIL
