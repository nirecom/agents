#!/bin/bash
# CLI validation tests: JSON type, empty array, path traversal via SIBLING_WORKTREES_JSON.
# Tests: bin/worktree-write-notes.js
# Tags: worktree, sibling, security, scope:issue-specific

. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

# ---- SW-CLI-NonArrayJson: SIBLING_WORKTREES_JSON is valid JSON but not an array ----
# NOTE: expected to FAIL until implementation validates the JSON type.
test_SWCLINonArrayJson_non_array_json_rejected() {
    require_bin "test_SWCLINonArrayJson_non_array_json_rejected" || return
    local main; main="$(setup_main_repo "swclinonarr-main")"
    local wt;   wt="$(setup_worktree_dest "swclinonarr-wt")"
    local main_node; main_node="$(node_path "$main")"

    local code
    SIBLING_WORKTREES_JSON='{}' \
        run_bin "$main_node" "$wt" "feature/swclinonarr" "" '{"copied":[]}' >/dev/null 2>&1
    code=$?

    local notes_file="$TMPDIR_BASE/swclinonarr-wt/WORKTREE_NOTES.md"
    if [ "$code" != "0" ]; then
        pass "SW-CLI-NonArrayJson: SIBLING_WORKTREES_JSON='{}' (object) → CLI exits non-zero (rejected)"
        return
    fi
    # Exit 0 path: must fall back to '- (none)' (not render object properties as entries)
    local section; section="$(awk '/^## SiblingWorktrees/{f=1;next} f && /^## /{f=0} f{print}' "$notes_file" 2>/dev/null)"
    if echo "$section" | grep -q "^- (none)$" && ! echo "$section" | grep -qE "^- repo:"; then
        pass "SW-CLI-NonArrayJson: SIBLING_WORKTREES_JSON='{}' → exit 0 with fallback '- (none)' (graceful)"
    else
        fail "SW-CLI-NonArrayJson: object JSON not rejected and did not fall back to '- (none)' (code=$code section: $section)"
    fi
}

# ---- SW-CLI-EmptyArray: SIBLING_WORKTREES_JSON='[]' (valid empty array) → (none) ----
# NOTE: expected to FAIL until implementation handles empty array correctly.
test_SWCLIEmptyArray_empty_array_renders_none() {
    require_bin "test_SWCLIEmptyArray_empty_array_renders_none" || return
    local main; main="$(setup_main_repo "swcliempty-main")"
    local wt;   wt="$(setup_worktree_dest "swcliempty-wt")"
    local main_node; main_node="$(node_path "$main")"

    local code
    SIBLING_WORKTREES_JSON='[]' \
        run_bin "$main_node" "$wt" "feature/swcliempty" "" '{"copied":[]}' >/dev/null 2>&1
    code=$?

    local notes_file="$TMPDIR_BASE/swcliempty-wt/WORKTREE_NOTES.md"
    if [ "$code" = "0" ] \
       && grep -q "^## SiblingWorktrees$" "$notes_file" 2>/dev/null \
       && grep -q "^- (none)$" "$notes_file" 2>/dev/null; then
        pass "SW-CLI-EmptyArray: SIBLING_WORKTREES_JSON='[]' → exit 0, '## SiblingWorktrees\n- (none)'"
    else
        fail "SW-CLI-EmptyArray: expected exit 0 + section with (none), got code=$code (content: $(cat "$notes_file" 2>/dev/null))"
    fi
}

# ---- SW-CLI-Sec2: path traversal in worktree_path via SIBLING_WORKTREES_JSON ----
# NOTE: expected to FAIL until implementation validates worktree_path traversal at CLI level.
test_SWCLISec2_path_traversal_in_json_path() {
    require_bin "test_SWCLISec2_path_traversal_in_json_path" || return
    local main; main="$(setup_main_repo "swclisec2-main")"
    local wt;   wt="$(setup_worktree_dest "swclisec2-wt")"
    local main_node; main_node="$(node_path "$main")"

    local payload='[{"repo":"owner/r","worktree_path":"../../sensitive"}]'

    local code
    SIBLING_WORKTREES_JSON="$payload" \
        run_bin "$main_node" "$wt" "feature/swclisec2" "" '{"copied":[]}' >/dev/null 2>&1
    code=$?

    local notes_file="$TMPDIR_BASE/swclisec2-wt/WORKTREE_NOTES.md"
    if [ "$code" != "0" ]; then
        pass "SW-CLI-Sec2: worktree_path='../../sensitive' via env → CLI exits non-zero (rejected)"
        return
    fi
    # Exit 0 path: traversal path must NOT appear in SiblingWorktrees section
    local section; section="$(awk '/^## SiblingWorktrees/{f=1;next} f && /^## /{f=0} f{print}' "$notes_file" 2>/dev/null)"
    if echo "$section" | grep -q "../../sensitive"; then
        fail "SW-CLI-Sec2: traversal path '../../sensitive' leaked into SiblingWorktrees section (unsanitized)"
    else
        fail "SW-CLI-Sec2: CLI exited 0 but traversal path not in section — no validation error raised (code=$code)"
    fi
}

# ============ Run all ============
test_SWCLINonArrayJson_non_array_json_rejected
test_SWCLIEmptyArray_empty_array_renders_none
test_SWCLISec2_path_traversal_in_json_path
echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $FAIL
