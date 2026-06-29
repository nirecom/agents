#!/bin/bash
# CLI-level tests: bin/worktree-write-notes.js SIBLING_WORKTREES_JSON
# Tests: bin/worktree-write-notes.js
# Tags: worktree, sibling, security, scope:issue-specific

. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

# ---- SW-CLI1: SIBLING_WORKTREES_JSON env var → entry in SiblingWorktrees section ----
test_SWCLI1_sibling_worktrees_json_env() {
    require_bin "test_SWCLI1_sibling_worktrees_json_env" || return
    local main; main="$(setup_main_repo "swcli1-main")"
    local wt;   wt="$(setup_worktree_dest "swcli1-wt")"
    local main_node; main_node="$(node_path "$main")"

    SIBLING_WORKTREES_JSON='[{"repo":"owner/r2","worktree_path":"/tmp/wt2"}]' \
        run_bin "$main_node" "$wt" "feature/swcli1" "" '{"copied":[]}' >/dev/null 2>&1

    local notes_file="$TMPDIR_BASE/swcli1-wt/WORKTREE_NOTES.md"
    if grep -q "^## SiblingWorktrees$" "$notes_file" 2>/dev/null \
       && grep -q "^- repo: owner/r2, path: /tmp/wt2$" "$notes_file" 2>/dev/null; then
        pass "SW-CLI1: SIBLING_WORKTREES_JSON env → '## SiblingWorktrees' section with entry"
    else
        fail "SW-CLI1: expected section+entry in $notes_file (content: $(cat "$notes_file" 2>/dev/null))"
    fi
}

# ---- SW-CLI2: SIBLING_WORKTREES_JSON invalid JSON → exit 0 (fallback), (none) in section ----
test_SWCLI2_sibling_worktrees_invalid_json_fallback() {
    require_bin "test_SWCLI2_sibling_worktrees_invalid_json_fallback" || return
    local main; main="$(setup_main_repo "swcli2-main")"
    local wt;   wt="$(setup_worktree_dest "swcli2-wt")"
    local main_node; main_node="$(node_path "$main")"

    local code
    SIBLING_WORKTREES_JSON='INVALID JSON' \
        run_bin "$main_node" "$wt" "feature/swcli2" "" '{"copied":[]}' >/dev/null 2>&1
    code=$?

    local notes_file="$TMPDIR_BASE/swcli2-wt/WORKTREE_NOTES.md"
    local has_section=0
    local has_none=0
    grep -q "^## SiblingWorktrees$" "$notes_file" 2>/dev/null && has_section=1
    grep -q "^- (none)$" "$notes_file" 2>/dev/null && has_none=1

    if [ "$code" = "0" ] && [ "$has_section" = "1" ] && [ "$has_none" = "1" ]; then
        pass "SW-CLI2: SIBLING_WORKTREES_JSON invalid JSON → exit 0 (fallback), '## SiblingWorktrees\n- (none)'"
    else
        fail "SW-CLI2: expected exit 0 + section with (none), got code=$code has_section=$has_section has_none=$has_none"
    fi
}

# ---- SW-CLI3: newline injection via SIBLING_WORKTREES_JSON → rejected or sanitized ----
# NOTE: this test is expected to FAIL until the implementation validates newlines in
# worktree_path values passed via the SIBLING_WORKTREES_JSON env var.
test_SWCLI3_newline_injection_via_env() {
    require_bin "test_SWCLI3_newline_injection_via_env" || return
    local main; main="$(setup_main_repo "swcli3-main")"
    local wt;   wt="$(setup_worktree_dest "swcli3-wt")"
    local main_node; main_node="$(node_path "$main")"

    local payload
    payload='[{"repo":"owner/r","worktree_path":"/tmp/wt\nmalicious"}]'

    local code
    SIBLING_WORKTREES_JSON="$payload" \
        run_bin "$main_node" "$wt" "feature/swcli3" "" '{"copied":[]}' >/dev/null 2>&1
    code=$?

    local notes_file="$TMPDIR_BASE/swcli3-wt/WORKTREE_NOTES.md"

    # Accept either: non-zero exit (validation rejection) OR exit 0 with newline NOT in notes
    if [ "$code" != "0" ]; then
        pass "SW-CLI3: SIBLING_WORKTREES_JSON newline in worktree_path → CLI rejected (exit $code)"
        return
    fi

    # exit 0 path: the malicious newline content must NOT appear as a separate line
    if grep -q "^malicious$" "$notes_file" 2>/dev/null; then
        fail "SW-CLI3: newline injection in worktree_path leaked into notes as bare 'malicious' line (unsanitized)"
    else
        pass "SW-CLI3: SIBLING_WORKTREES_JSON newline in worktree_path → exit 0 but newline not in notes (sanitized)"
    fi
}

# ---- SW-CLI4: SIBLING_WORKTREES_JSON unset → exit 0, SiblingWorktrees section with (none) ----
test_SWCLI4_sibling_worktrees_json_unset() {
    require_bin "test_SWCLI4_sibling_worktrees_json_unset" || return
    local main; main="$(setup_main_repo "swcli4-main")"
    local wt;   wt="$(setup_worktree_dest "swcli4-wt")"
    local main_node; main_node="$(node_path "$main")"

    local code
    unset SIBLING_WORKTREES_JSON
    run_bin "$main_node" "$wt" "feature/swcli4" "" '{"copied":[]}' >/dev/null 2>&1
    code=$?

    local notes_file="$TMPDIR_BASE/swcli4-wt/WORKTREE_NOTES.md"
    if [ "$code" = "0" ] \
       && grep -q "^## SiblingWorktrees$" "$notes_file" 2>/dev/null \
       && grep -q "^- (none)$" "$notes_file" 2>/dev/null; then
        pass "SW-CLI4: SIBLING_WORKTREES_JSON unset → exit 0, '## SiblingWorktrees\n- (none)'"
    else
        fail "SW-CLI4: expected exit 0 + section with (none), got code=$code (content: $(cat "$notes_file" 2>/dev/null))"
    fi
}

# ---- SW-CLI5: SIBLING_WORKTREES_JSON empty string → exit 0, SiblingWorktrees section with (none) ----
test_SWCLI5_sibling_worktrees_json_empty_string() {
    require_bin "test_SWCLI5_sibling_worktrees_json_empty_string" || return
    local main; main="$(setup_main_repo "swcli5-main")"
    local wt;   wt="$(setup_worktree_dest "swcli5-wt")"
    local main_node; main_node="$(node_path "$main")"

    local code
    SIBLING_WORKTREES_JSON='' \
        run_bin "$main_node" "$wt" "feature/swcli5" "" '{"copied":[]}' >/dev/null 2>&1
    code=$?

    local notes_file="$TMPDIR_BASE/swcli5-wt/WORKTREE_NOTES.md"
    if [ "$code" = "0" ] \
       && grep -q "^## SiblingWorktrees$" "$notes_file" 2>/dev/null \
       && grep -q "^- (none)$" "$notes_file" 2>/dev/null; then
        pass "SW-CLI5: SIBLING_WORKTREES_JSON='' → exit 0, '## SiblingWorktrees\n- (none)'"
    else
        fail "SW-CLI5: expected exit 0 + section with (none), got code=$code (content: $(cat "$notes_file" 2>/dev/null))"
    fi
}

# ---- SW-CLI6: two valid sibling entries via SIBLING_WORKTREES_JSON → both rendered ----
# NOTE: expected to FAIL until the implementation handles multiple entries.
test_SWCLI6_sibling_worktrees_json_two_entries() {
    require_bin "test_SWCLI6_sibling_worktrees_json_two_entries" || return
    local main; main="$(setup_main_repo "swcli6-main")"
    local wt;   wt="$(setup_worktree_dest "swcli6-wt")"
    local main_node; main_node="$(node_path "$main")"

    SIBLING_WORKTREES_JSON='[{"repo":"owner/r2","worktree_path":"/tmp/wt2"},{"repo":"owner/r3","worktree_path":"/tmp/wt3"}]' \
        run_bin "$main_node" "$wt" "feature/swcli6" "" '{"copied":[]}' >/dev/null 2>&1

    local notes_file="$TMPDIR_BASE/swcli6-wt/WORKTREE_NOTES.md"
    if grep -q "^## SiblingWorktrees$" "$notes_file" 2>/dev/null \
       && grep -q "^- repo: owner/r2, path: /tmp/wt2$" "$notes_file" 2>/dev/null \
       && grep -q "^- repo: owner/r3, path: /tmp/wt3$" "$notes_file" 2>/dev/null; then
        pass "SW-CLI6: SIBLING_WORKTREES_JSON two entries → both '- repo:' lines in SiblingWorktrees"
    else
        fail "SW-CLI6: expected two entry lines in $notes_file (content: $(cat "$notes_file" 2>/dev/null))"
    fi
}

# ---- SW-CLI-Idm1: idempotency — two runs with same SIBLING_WORKTREES_JSON → no duplicate entries ----
# May PASS or FAIL depending on whether worktree-write-notes.js overwrites or appends.
test_SWCLIIdm1_cli_idempotency_sibling_worktrees() {
    require_bin "test_SWCLIIdm1_cli_idempotency_sibling_worktrees" || return
    local main; main="$(setup_main_repo "swcliidm1-main")"
    local wt;   wt="$(setup_worktree_dest "swcliidm1-wt")"
    local main_node; main_node="$(node_path "$main")"

    local payload='[{"repo":"owner/r2","worktree_path":"/tmp/wt2"}]'

    # First run
    SIBLING_WORKTREES_JSON="$payload" \
        run_bin "$main_node" "$wt" "feature/swcliidm1" "" '{"copied":[]}' >/dev/null 2>&1
    # Second run — same payload, same dest
    SIBLING_WORKTREES_JSON="$payload" \
        run_bin "$main_node" "$wt" "feature/swcliidm1" "" '{"copied":[]}' >/dev/null 2>&1

    local notes_file="$TMPDIR_BASE/swcliidm1-wt/WORKTREE_NOTES.md"
    if [ ! -f "$notes_file" ]; then
        fail "SW-CLI-Idm1: WORKTREE_NOTES.md not created after two runs"
        return
    fi

    local entry_count
    entry_count="$(grep -c "^- repo: owner/r2, path: /tmp/wt2$" "$notes_file" 2>/dev/null || echo 0)"
    if [ "$entry_count" = "1" ]; then
        pass "SW-CLI-Idm1: two runs with same SIBLING_WORKTREES_JSON → exactly 1 entry (idempotent)"
    else
        fail "SW-CLI-Idm1: expected 1 entry after two runs, got $entry_count (notes: $(cat "$notes_file" 2>/dev/null))"
    fi
}

# ---- SW-CLI-Err1: non-object entry in SIBLING_WORKTREES_JSON → rejected or sanitized ----
# NOTE: expected to FAIL until implementation validates array entries from env var.
test_SWCLIErr1_non_object_entry_via_env() {
    require_bin "test_SWCLIErr1_non_object_entry_via_env" || return
    local main; main="$(setup_main_repo "swclierr1-main")"
    local wt;   wt="$(setup_worktree_dest "swclierr1-wt")"
    local main_node; main_node="$(node_path "$main")"

    local code
    SIBLING_WORKTREES_JSON='[42]' \
        run_bin "$main_node" "$wt" "feature/swclierr1" "" '{"copied":[]}' >/dev/null 2>&1
    code=$?

    local notes_file="$TMPDIR_BASE/swclierr1-wt/WORKTREE_NOTES.md"

    if [ "$code" != "0" ]; then
        pass "SW-CLI-Err1: SIBLING_WORKTREES_JSON='[42]' → CLI exits non-zero (rejected)"
        return
    fi
    # Exit 0 path: "42" must NOT appear in SiblingWorktrees section
    local section; section="$(awk '/^## SiblingWorktrees/{f=1;next} f && /^## /{f=0} f{print}' "$notes_file" 2>/dev/null)"
    if echo "$section" | grep -q "42"; then
        fail "SW-CLI-Err1: number 42 written into SiblingWorktrees section (not validated); section: $section"
    else
        fail "SW-CLI-Err1: CLI exited 0 and 42 is not in notes, but no validation error was raised (code=$code)"
    fi
}

# ============ Run all ============
test_SWCLI1_sibling_worktrees_json_env
test_SWCLI2_sibling_worktrees_invalid_json_fallback
test_SWCLI3_newline_injection_via_env
test_SWCLI4_sibling_worktrees_json_unset
test_SWCLI5_sibling_worktrees_json_empty_string
test_SWCLI6_sibling_worktrees_json_two_entries
test_SWCLIIdm1_cli_idempotency_sibling_worktrees
test_SWCLIErr1_non_object_entry_via_env
echo ""
echo "Results: $PASS passed, $FAIL failed"
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $FAIL
