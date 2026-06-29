#!/bin/bash
# CLI + session-id tests for worktree-notes bin/worktree-write-notes.js.
# Tests: bin/worktree-write-notes.js
# Tags: worktree, notes, scope:common

. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

# ---- N7: CLI happy path ----
test_N7_cli_happy_path() {
    require_bin "test_N7_cli_happy_path" || return
    local main; main="$(setup_main_repo "n7-main")"
    local wt;   wt="$(setup_worktree_dest "n7-wt")"
    local main_node; main_node="$(node_path "$main")"

    local out; out="$(run_bin "$main_node" "$wt" "feature/n7" "" '{"copied":["a.env","b/.env.local"]}')"
    local code=$?
    local notesWritten; notesWritten="$(json_field "$out" "notesWritten")"
    local excludeAdded; excludeAdded="$(json_field "$out" "excludeAdded")"
    local errors; errors="$(json_field "$out" "errors")"

    if [ "$code" = "0" ] && [ "$notesWritten" = "true" ] && [ "$excludeAdded" = "true" ] \
       && [ "$errors" = "[]" ] && [ -f "$TMPDIR_BASE/n7-wt/WORKTREE_NOTES.md" ] \
       && grep -q "^WORKTREE_NOTES.md$" "$main/.git/info/exclude"; then
        pass "N7: CLI happy path → exit 0, JSON ok, files created"
    else
        fail "N7: code=$code notesWritten=$notesWritten excludeAdded=$excludeAdded errors=$errors (out=$out)"
    fi
}

# ---- I4: CLI idempotency ----
test_I4_cli_idempotent() {
    require_bin "test_I4_cli_idempotent" || return
    local main; main="$(setup_main_repo "i4-main")"
    local wt;   wt="$(setup_worktree_dest "i4-wt")"
    local main_node; main_node="$(node_path "$main")"

    run_bin "$main_node" "$wt" "feature/i4" "" '{"copied":["a.env"]}' >/dev/null 2>&1
    local notes_file="$TMPDIR_BASE/i4-wt/WORKTREE_NOTES.md"
    local before_md5
    before_md5="$(node -e "
        const c=require('crypto'),fs=require('fs');
        process.stdout.write(c.createHash('md5').update(fs.readFileSync(process.argv[1])).digest('hex'));
    " -- "$notes_file" 2>/dev/null)"

    local code2; code2="$(run_bin_exitcode "$main_node" "$wt" "feature/i4" "" '{"copied":["a.env"]}')"
    local out2; out2="$(run_bin "$main_node" "$wt" "feature/i4" "" '{"copied":["a.env"]}')"
    local excludeAdded2; excludeAdded2="$(json_field "$out2" "excludeAdded")"
    local reason2; reason2="$(json_field "$out2" "excludeSkipReason")"

    local after_md5
    after_md5="$(node -e "
        const c=require('crypto'),fs=require('fs');
        process.stdout.write(c.createHash('md5').update(fs.readFileSync(process.argv[1])).digest('hex'));
    " -- "$notes_file" 2>/dev/null)"

    if [ "$code2" = "0" ] && [ "$excludeAdded2" = "false" ] && [ "$reason2" = "already-present" ] \
       && [ "$before_md5" = "$after_md5" ]; then
        pass "I4: CLI second run → exit 0, excludeAdded=false, reason=already-present, content unchanged"
    else
        fail "I4: code=$code2 excludeAdded=$excludeAdded2 reason=$reason2 (md5 before=$before_md5 after=$after_md5)"
    fi
}

# ---- N8: WORKTREE_BASE_DIR env unset → "(default)" ----
test_N8_env_unset_defaults() {
    require_bin "test_N8_env_unset_defaults" || return
    local main; main="$(setup_main_repo "n8-main")"
    local wt;   wt="$(setup_worktree_dest "n8-wt")"
    local main_node; main_node="$(node_path "$main")"

    (
        unset WORKTREE_BASE_DIR
        COPIED_JSON='{"copied":[]}' run_with_timeout 120 node "$BIN_JS" "$main_node" "$wt" "feature/n8" "" >/dev/null 2>&1
    )

    local notes_file="$TMPDIR_BASE/n8-wt/WORKTREE_NOTES.md"
    if grep -q "^WORKTREE_BASE_DIR: (default)$" "$notes_file" 2>/dev/null; then
        pass "N8: WORKTREE_BASE_DIR env unset → '(default)'"
    else
        fail "N8: '(default)' line not found in $notes_file"
    fi
}

# ---- N9: WORKTREE_BASE_DIR env set → that value ----
test_N9_env_set_uses_value() {
    require_bin "test_N9_env_set_uses_value" || return
    local main; main="$(setup_main_repo "n9-main")"
    local wt;   wt="$(setup_worktree_dest "n9-wt")"
    local main_node; main_node="$(node_path "$main")"

    (
        export WORKTREE_BASE_DIR="C:/custom/path"
        COPIED_JSON='{"copied":[]}' run_with_timeout 120 node "$BIN_JS" "$main_node" "$wt" "feature/n9" "" >/dev/null 2>&1
    )

    local notes_file="$TMPDIR_BASE/n9-wt/WORKTREE_NOTES.md"
    if grep -q "^WORKTREE_BASE_DIR: C:/custom/path$" "$notes_file" 2>/dev/null; then
        pass "N9: WORKTREE_BASE_DIR='C:/custom/path' → recorded in notes"
    else
        fail "N9: expected 'WORKTREE_BASE_DIR: C:/custom/path' in $notes_file (content: $(cat "$notes_file" 2>/dev/null))"
    fi
}

# ---- CMD1: SKILL.md POSIX template (plain filenames) ----
test_CMD1_skill_template_basic() {
    require_bin "test_CMD1_skill_template_basic" || return
    local main; main="$(setup_main_repo "cmd1-main")"
    local wt;   wt="$(setup_worktree_dest "cmd1-wt")"
    local main_node; main_node="$(node_path "$main")"

    bash -c "
        COPIED_JSON='{\"copied\":[\"foo.env\",\"bar.local\"],\"skipped\":[],\"denied\":[],\"errors\":[]}' \
        node '$BIN_JS' '$main_node' '$wt' 'feature/test'
    " >/dev/null 2>&1

    local notes_file="$TMPDIR_BASE/cmd1-wt/WORKTREE_NOTES.md"
    if [ -f "$notes_file" ] \
       && grep -q "^- foo.env$" "$notes_file" \
       && grep -q "^- bar.local$" "$notes_file" \
       && grep -q "^WORKTREE_NOTES.md$" "$main/.git/info/exclude"; then
        pass "CMD1: SKILL.md POSIX template → notes contains foo.env+bar.local, exclude has WORKTREE_NOTES.md"
    else
        fail "CMD1: notes/exclude not as expected (notes content: $(cat "$notes_file" 2>/dev/null))"
    fi
}

# ---- CMD2: filename with spaces ----
test_CMD2_skill_template_filename_with_spaces() {
    require_bin "test_CMD2_skill_template_filename_with_spaces" || return
    local main; main="$(setup_main_repo "cmd2-main")"
    local wt;   wt="$(setup_worktree_dest "cmd2-wt")"
    local main_node; main_node="$(node_path "$main")"

    bash -c "
        COPIED_JSON='{\"copied\":[\"my file.env\"]}' \
        node '$BIN_JS' '$main_node' '$wt' 'feature/test'
    " >/dev/null 2>&1

    local notes_file="$TMPDIR_BASE/cmd2-wt/WORKTREE_NOTES.md"
    if [ -f "$notes_file" ] && grep -q "^- my file\.env$" "$notes_file"; then
        pass "CMD2: filename with spaces → '- my file.env' in notes"
    else
        fail "CMD2: '- my file.env' not in $notes_file (content: $(cat "$notes_file" 2>/dev/null))"
    fi
}

# ---- CMD3: Windows-style backslash path ----
test_CMD3_skill_template_windows_path() {
    require_bin "test_CMD3_skill_template_windows_path" || return
    local main; main="$(setup_main_repo "cmd3-main")"
    local wt;   wt="$(setup_worktree_dest "cmd3-wt")"
    local main_node; main_node="$(node_path "$main")"

    bash -c "
        COPIED_JSON='{\"copied\":[\"sub\\\\dir\\\\file\"]}' \
        node '$BIN_JS' '$main_node' '$wt' 'feature/test'
    " >/dev/null 2>&1

    local notes_file="$TMPDIR_BASE/cmd3-wt/WORKTREE_NOTES.md"
    if [ -f "$notes_file" ] && grep -F -q -e '- sub\dir\file' "$notes_file"; then
        pass "CMD3: Windows-style path 'sub\\dir\\file' → recorded as-is"
    else
        fail "CMD3: '- sub\\dir\\file' not in $notes_file (content: $(cat "$notes_file" 2>/dev/null))"
    fi
}

# ---- SID3: CLI passes session-id through to WORKTREE_NOTES.md ----
test_SID3_cli_session_id_passthrough() {
    require_bin "test_SID3_cli_session_id_passthrough" || return
    local main; main="$(setup_main_repo "sid3-main")"
    local wt;   wt="$(setup_worktree_dest "sid3-wt")"
    local main_node; main_node="$(node_path "$main")"

    run_bin "$main_node" "$wt" "feature/sid3" "" '{"copied":[]}' "abc-123" >/dev/null 2>&1

    local notes_file="$TMPDIR_BASE/sid3-wt/WORKTREE_NOTES.md"
    if grep -q "^Session-ID: abc-123$" "$notes_file" 2>/dev/null; then
        pass "SID3: CLI session-id arg passes through to WORKTREE_NOTES.md"
    else
        fail "SID3: 'Session-ID: abc-123' not found in $notes_file (content: $(cat "$notes_file" 2>/dev/null))"
    fi
}

# ---- SID4: CLI rejects invalid session-id ----
test_SID4_cli_session_id_validation() {
    require_bin "test_SID4_cli_session_id_validation" || return
    local main; main="$(setup_main_repo "sid4-main")"
    local wt;   wt="$(setup_worktree_dest "sid4-wt")"
    local main_node; main_node="$(node_path "$main")"

    local code; code="$(run_bin_exitcode "$main_node" "$wt" "feature/sid4" "" '{"copied":[]}' "bad/path")"
    local errmsg; errmsg="$(run_bin_stderr "$main_node" "$wt" "feature/sid4" "" '{"copied":[]}' "bad/path")"

    if [ "$code" = "1" ] && echo "$errmsg" | grep -qi "invalid\|sessionId\|session"; then
        pass "SID4: CLI exits 1 and prints error for invalid session-id 'bad/path'"
    else
        fail "SID4: expected exit 1 + error msg, got code=$code stderr='$errmsg'"
    fi
}

# ============ Run all ============

test_N7_cli_happy_path
test_I4_cli_idempotent
test_N8_env_unset_defaults
test_N9_env_set_uses_value
test_CMD1_skill_template_basic
test_CMD2_skill_template_filename_with_spaces
test_CMD3_skill_template_windows_path
test_SID3_cli_session_id_passthrough
test_SID4_cli_session_id_validation

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $FAIL
