#!/bin/bash
# tests/unit-worktree-notes-append.sh
#
# Unit tests for bin/worktree-notes-append.js (issue #622).
#
# CLI signature:
#   node bin/worktree-notes-append.js \
#     --notes-path <absolute-path-to-WORKTREE_NOTES.md> \
#     --issue-number <N> \
#     --title "<short title>" \
#     [--label <label> [--label ...]] \
#     [--skip-if-main]
#
# Test-first: the helper does not yet exist. Tests are SKIP-graceful — they
# emit SKIP (not FAIL) when the helper is absent so the workflow can land
# tests before implementation without showing red.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
HELPER_JS="${_AGENTS_DIR_NODE}/bin/worktree-notes-append.js"
TRIAGE_JS="${_AGENTS_DIR_NODE}/bin/worktree-notes-triage.js"

PASS=0; FAIL=0; SKIP=0
TMP=""

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout "$1" "${@:2}"
    elif command -v perl >/dev/null 2>&1; then
        perl -e 'alarm shift; exec @ARGV' "$@"
    else
        "${@:2}"
    fi
}

require_helper() {
    if [ ! -f "$HELPER_JS" ]; then
        skip "$1 (bin/worktree-notes-append.js not implemented yet)"
        return 1
    fi
    return 0
}

setup_tmp() {
    TMP="$(mktemp -d)"
    if command -v cygpath >/dev/null 2>&1; then
        TMP="$(cygpath -m "$TMP")"
    fi
}

cleanup_tmp() {
    if [ -n "${TMP:-}" ] && [ -d "$TMP" ]; then
        rm -rf "$TMP"
    fi
    TMP=""
}

# ============ Tests ============

# ---- A1: type:task + absent WORKTREE_NOTES.md → creates file with ## RelatedTasks ----
test_A1_type_task_absent_file() {
    require_helper "A1: type:task + absent file" || return
    setup_tmp
    local notes="$TMP/WORKTREE_NOTES.md"
    run_with_timeout 30 node "$HELPER_JS" \
        --notes-path "$notes" \
        --issue-number 42 \
        --title "Fix foo" \
        --label "type:task" >/dev/null 2>&1
    local rc=$?
    if [ "$rc" -eq 0 ] && [ -f "$notes" ] \
       && grep -q "## RelatedTasks" "$notes" 2>/dev/null \
       && grep -qF "Fix foo (#42)" "$notes" 2>/dev/null \
       && grep -qF "<!-- promoted: #42 -->" "$notes" 2>/dev/null; then
        pass "A1: type:task creates file with ## RelatedTasks + marker"
    else
        fail "A1: rc=$rc file=$([ -f "$notes" ] && echo yes || echo no) content=$(cat "$notes" 2>/dev/null)"
    fi
    cleanup_tmp
}

# ---- A2: type:incident → ## BugsFound ----
test_A2_type_incident() {
    require_helper "A2: type:incident → ## BugsFound" || return
    setup_tmp
    local notes="$TMP/WORKTREE_NOTES.md"
    run_with_timeout 30 node "$HELPER_JS" \
        --notes-path "$notes" \
        --issue-number 43 \
        --title "Crash on boot" \
        --label "type:incident" >/dev/null 2>&1
    local rc=$?
    if [ "$rc" -eq 0 ] && [ -f "$notes" ] \
       && grep -q "## BugsFound" "$notes" 2>/dev/null \
       && grep -qF "Crash on boot (#43)" "$notes" 2>/dev/null \
       && grep -qF "<!-- promoted: #43 -->" "$notes" 2>/dev/null; then
        pass "A2: type:incident → ## BugsFound with marker"
    else
        fail "A2: rc=$rc content=$(cat "$notes" 2>/dev/null)"
    fi
    cleanup_tmp
}

# ---- A3: existing file with ## BugsFound but no ## RelatedTasks → appends section ----
test_A3_appends_missing_section() {
    require_helper "A3: appends missing section at EOF" || return
    setup_tmp
    local notes="$TMP/WORKTREE_NOTES.md"
    printf '# Worktree Notes\n\n## BugsFound\n- (none)\n' > "$notes"
    local before_bugs
    before_bugs="$(grep -c "## BugsFound" "$notes" 2>/dev/null || echo 0)"
    run_with_timeout 30 node "$HELPER_JS" \
        --notes-path "$notes" \
        --issue-number 44 \
        --title "Add baz" \
        --label "type:task" >/dev/null 2>&1
    local rc=$?
    local after_bugs after_related
    after_bugs="$(grep -c "## BugsFound" "$notes" 2>/dev/null || echo 0)"
    after_related="$(grep -c "## RelatedTasks" "$notes" 2>/dev/null || echo 0)"
    if [ "$rc" -eq 0 ] \
       && [ "$after_bugs" = "$before_bugs" ] \
       && [ "$after_related" -ge 1 ] \
       && grep -qF "Add baz (#44)" "$notes" 2>/dev/null \
       && grep -qF "<!-- promoted: #44 -->" "$notes" 2>/dev/null; then
        pass "A3: appends ## RelatedTasks; ## BugsFound unchanged"
    else
        fail "A3: rc=$rc before_bugs=$before_bugs after_bugs=$after_bugs after_related=$after_related content=$(cat "$notes" 2>/dev/null)"
    fi
    cleanup_tmp
}

# ---- A3.b: existing file WITHOUT trailing newline → heading not glued onto prior line ----
test_A3b_no_trailing_newline() {
    require_helper "A3.b: no trailing newline" || return
    setup_tmp
    local notes="$TMP/WORKTREE_NOTES.md"
    # Use printf without trailing \n
    printf '# Worktree Notes\n\n## BugsFound\n- (none)' > "$notes"
    run_with_timeout 30 node "$HELPER_JS" \
        --notes-path "$notes" \
        --issue-number 45 \
        --title "No newline" \
        --label "type:task" >/dev/null 2>&1
    local rc=$?
    # Check that "- (none)## RelatedTasks" does NOT appear (no gluing).
    if [ "$rc" -eq 0 ] \
       && ! grep -qF "(none)## RelatedTasks" "$notes" 2>/dev/null \
       && ! grep -qE "(none)##" "$notes" 2>/dev/null \
       && grep -q "## RelatedTasks" "$notes" 2>/dev/null \
       && grep -qF "No newline (#45)" "$notes" 2>/dev/null; then
        pass "A3.b: heading separated by newline (no gluing)"
    else
        fail "A3.b: rc=$rc content=$(cat "$notes" 2>/dev/null)"
    fi
    cleanup_tmp
}

# ---- A4: ## RelatedTasks containing - (none) → replaces placeholder ----
test_A4_replaces_none_placeholder() {
    require_helper "A4: replaces - (none) placeholder" || return
    setup_tmp
    local notes="$TMP/WORKTREE_NOTES.md"
    printf '# Worktree Notes\n\n## RelatedTasks\n- (none)\n' > "$notes"
    run_with_timeout 30 node "$HELPER_JS" \
        --notes-path "$notes" \
        --issue-number 46 \
        --title "Replace placeholder" \
        --label "type:task" >/dev/null 2>&1
    local rc=$?
    if [ "$rc" -eq 0 ] \
       && ! grep -qF "- (none)" "$notes" 2>/dev/null \
       && grep -qF "Replace placeholder (#46)" "$notes" 2>/dev/null \
       && grep -qF "<!-- promoted: #46 -->" "$notes" 2>/dev/null; then
        pass "A4: '- (none)' replaced with new entry"
    else
        fail "A4: rc=$rc content=$(cat "$notes" 2>/dev/null)"
    fi
    cleanup_tmp
}

# ---- A5: Re-promotion guard via triage list ----
test_A5_triage_list_filters_promoted() {
    require_helper "A5: triage filters promoted entries" || return
    if [ ! -f "$TRIAGE_JS" ]; then
        skip "A5: triage filters (bin/worktree-notes-triage.js not present)"
        return
    fi
    setup_tmp
    local notes="$TMP/WORKTREE_NOTES.md"
    run_with_timeout 30 node "$HELPER_JS" \
        --notes-path "$notes" \
        --issue-number 47 \
        --title "Filter me" \
        --label "type:task" >/dev/null 2>&1
    local rc_h=$?
    if [ "$rc_h" -ne 0 ]; then
        fail "A5: helper failed rc=$rc_h"
        cleanup_tmp
        return
    fi
    local triage_out
    triage_out="$(run_with_timeout 30 node "$TRIAGE_JS" list "$notes" 2>/dev/null)"
    # Trim whitespace
    triage_out="$(printf '%s' "$triage_out" | tr -d '[:space:]')"
    if [ "$triage_out" = "[]" ]; then
        pass "A5: triage list returns [] (promoted entry filtered out)"
    else
        fail "A5: expected '[]', got: '$triage_out'"
    fi
    cleanup_tmp
}

# ---- A6: Atomicity — no .tmp file left after success ----
test_A6_no_tmp_left() {
    require_helper "A6: no .tmp left after success" || return
    setup_tmp
    local notes="$TMP/WORKTREE_NOTES.md"
    run_with_timeout 30 node "$HELPER_JS" \
        --notes-path "$notes" \
        --issue-number 48 \
        --title "Atomic" \
        --label "type:task" >/dev/null 2>&1
    local rc=$?
    local tmp_count
    tmp_count="$(find "$TMP" -maxdepth 1 -name 'WORKTREE_NOTES.md.tmp*' 2>/dev/null | wc -l | tr -d '[:space:]')"
    if [ "$rc" -eq 0 ] && [ "$tmp_count" = "0" ]; then
        pass "A6: no .tmp file left after success"
    else
        fail "A6: rc=$rc tmp_count=$tmp_count"
    fi
    cleanup_tmp
}

# ---- A7: No label → defaults to ## RelatedTasks ----
test_A7_no_label_defaults_to_related() {
    require_helper "A7: no label defaults to ## RelatedTasks" || return
    setup_tmp
    local notes="$TMP/WORKTREE_NOTES.md"
    run_with_timeout 30 node "$HELPER_JS" \
        --notes-path "$notes" \
        --issue-number 49 \
        --title "No label" >/dev/null 2>&1
    local rc=$?
    if [ "$rc" -eq 0 ] && [ -f "$notes" ] \
       && grep -q "## RelatedTasks" "$notes" 2>/dev/null \
       && grep -qF "No label (#49)" "$notes" 2>/dev/null; then
        pass "A7: no label → ## RelatedTasks default"
    else
        fail "A7: rc=$rc content=$(cat "$notes" 2>/dev/null)"
    fi
    cleanup_tmp
}

# ---- A8: Invalid --notes-path (basename not WORKTREE_NOTES.md) → exit non-zero, no write ----
test_A8_invalid_basename() {
    require_helper "A8: invalid basename" || return
    setup_tmp
    local bad="$TMP/other-notes.md"
    run_with_timeout 30 node "$HELPER_JS" \
        --notes-path "$bad" \
        --issue-number 50 \
        --title "Bad path" \
        --label "type:task" >/dev/null 2>&1
    local rc=$?
    if [ "$rc" -ne 0 ] && [ ! -f "$bad" ]; then
        pass "A8: invalid basename → exit non-zero, no write"
    else
        fail "A8: rc=$rc file_exists=$([ -f "$bad" ] && echo yes || echo no)"
    fi
    cleanup_tmp
}

# ---- A9: Path traversal (..) → exit non-zero, no write ----
test_A9_path_traversal() {
    require_helper "A9: path traversal" || return
    setup_tmp
    # Use a path with .. that resolves outside.
    local traversal="$TMP/../WORKTREE_NOTES.md"
    # Record list of files before
    local parent="$(dirname "$TMP")"
    run_with_timeout 30 node "$HELPER_JS" \
        --notes-path "$traversal" \
        --issue-number 51 \
        --title "Traversal" \
        --label "type:task" >/dev/null 2>&1
    local rc=$?
    # We don't want a file written outside $TMP.
    if [ "$rc" -ne 0 ] && [ ! -f "$parent/WORKTREE_NOTES.md" ]; then
        pass "A9: path traversal → exit non-zero, no write"
    else
        # Clean up if accidentally written
        [ -f "$parent/WORKTREE_NOTES.md" ] && rm -f "$parent/WORKTREE_NOTES.md"
        fail "A9: rc=$rc"
    fi
    cleanup_tmp
}

# ---- A10: Idempotency — second invocation is no-op ----
test_A10_idempotent() {
    require_helper "A10: idempotency" || return
    setup_tmp
    local notes="$TMP/WORKTREE_NOTES.md"
    run_with_timeout 30 node "$HELPER_JS" \
        --notes-path "$notes" \
        --issue-number 42 \
        --title "Idempotent" \
        --label "type:task" >/dev/null 2>&1
    local rc1=$?
    if [ "$rc1" -ne 0 ]; then
        fail "A10: first call failed rc=$rc1"
        cleanup_tmp
        return
    fi
    local hash1
    hash1="$(sha256sum "$notes" 2>/dev/null | awk '{print $1}')"
    run_with_timeout 30 node "$HELPER_JS" \
        --notes-path "$notes" \
        --issue-number 42 \
        --title "Idempotent" \
        --label "type:task" >/dev/null 2>&1
    local rc2=$?
    local hash2
    hash2="$(sha256sum "$notes" 2>/dev/null | awk '{print $1}')"
    local count42
    count42="$(grep -c "(#42)" "$notes" 2>/dev/null || echo 0)"
    if [ "$rc2" -eq 0 ] && [ "$hash1" = "$hash2" ] && [ "$count42" = "1" ]; then
        pass "A10: idempotent — file byte-identical, count(#42)=1"
    else
        fail "A10: rc2=$rc2 hash_match=$([ "$hash1" = "$hash2" ] && echo yes || echo no) count42=$count42"
    fi
    cleanup_tmp
}

# ---- A11: Multi-label type:task + area:hooks → ## RelatedTasks ----
test_A11_multi_label() {
    require_helper "A11: multi-label" || return
    setup_tmp
    local notes="$TMP/WORKTREE_NOTES.md"
    run_with_timeout 30 node "$HELPER_JS" \
        --notes-path "$notes" \
        --issue-number 52 \
        --title "Multi label" \
        --label "type:task" \
        --label "area:hooks" >/dev/null 2>&1
    local rc=$?
    if [ "$rc" -eq 0 ] && [ -f "$notes" ] \
       && grep -q "## RelatedTasks" "$notes" 2>/dev/null \
       && grep -qF "Multi label (#52)" "$notes" 2>/dev/null; then
        pass "A11: multi-label type:task + area:hooks → ## RelatedTasks"
    else
        fail "A11: rc=$rc content=$(cat "$notes" 2>/dev/null)"
    fi
    cleanup_tmp
}

# ---- A12: Title containing <!-- → exit 2, no write ----
test_A12_title_has_marker_syntax() {
    require_helper "A12: title with <!--" || return
    setup_tmp
    local notes="$TMP/WORKTREE_NOTES.md"
    run_with_timeout 30 node "$HELPER_JS" \
        --notes-path "$notes" \
        --issue-number 53 \
        --title "bad <!-- title" \
        --label "type:task" >/dev/null 2>&1
    local rc=$?
    if [ "$rc" -eq 2 ] && [ ! -f "$notes" ]; then
        pass "A12: title with '<!--' → exit 2, no write"
    else
        fail "A12: rc=$rc file_exists=$([ -f "$notes" ] && echo yes || echo no)"
    fi
    cleanup_tmp
}

# ---- A12b: Title containing newline → exit 2, no write ----
test_A12b_title_has_newline() {
    require_helper "A12b: title with newline" || return
    setup_tmp
    local notes="$TMP/WORKTREE_NOTES.md"
    local title_with_nl
    title_with_nl="$(printf 'bad\nnewline')"
    run_with_timeout 30 node "$HELPER_JS" \
        --notes-path "$notes" \
        --issue-number 54 \
        --title "$title_with_nl" \
        --label "type:task" >/dev/null 2>&1
    local rc=$?
    if [ "$rc" -eq 2 ] && [ ! -f "$notes" ]; then
        pass "A12b: title with newline → exit 2, no write"
    else
        fail "A12b: rc=$rc file_exists=$([ -f "$notes" ] && echo yes || echo no)"
    fi
    cleanup_tmp
}

# ---- A13: --skip-if-main from non-git tmpdir → graceful (happy path or silent) ----
test_A13_skip_if_main_in_tmpdir() {
    require_helper "A13: --skip-if-main in tmpdir" || return
    setup_tmp
    local notes="$TMP/WORKTREE_NOTES.md"
    # Run from tmpdir (which isn't a git repo).
    run_with_timeout 30 sh -c "cd '$TMP' && node '$HELPER_JS' \
        --notes-path '$notes' \
        --issue-number 55 \
        --title 'Skip main test' \
        --label 'type:task' \
        --skip-if-main" >/dev/null 2>&1
    local rc=$?
    # Accept exit 0 regardless of whether file was written (skip-if-main is
    # advisory; either silent-skip or write is acceptable when not in main).
    if [ "$rc" -eq 0 ]; then
        pass "A13: --skip-if-main in non-git tmpdir → exit 0"
    else
        fail "A13: rc=$rc"
    fi
    cleanup_tmp
}

# ---- A14: Label precedence type:incident + type:task → ## BugsFound ----
test_A14_label_precedence_incident_wins() {
    require_helper "A14: label precedence" || return
    setup_tmp
    local notes="$TMP/WORKTREE_NOTES.md"
    run_with_timeout 30 node "$HELPER_JS" \
        --notes-path "$notes" \
        --issue-number 56 \
        --title "Both labels" \
        --label "type:incident" \
        --label "type:task" >/dev/null 2>&1
    local rc=$?
    if [ "$rc" -eq 0 ] && [ -f "$notes" ] \
       && grep -q "## BugsFound" "$notes" 2>/dev/null \
       && grep -qF "Both labels (#56)" "$notes" 2>/dev/null; then
        pass "A14: incident+task → ## BugsFound (incident takes priority)"
    else
        fail "A14: rc=$rc content=$(cat "$notes" 2>/dev/null)"
    fi
    cleanup_tmp
}

# ============ Run all ============

test_A1_type_task_absent_file
test_A2_type_incident
test_A3_appends_missing_section
test_A3b_no_trailing_newline
test_A4_replaces_none_placeholder
test_A5_triage_list_filters_promoted
test_A6_no_tmp_left
test_A7_no_label_defaults_to_related
test_A8_invalid_basename
test_A9_path_traversal
test_A10_idempotent
test_A11_multi_label
test_A12_title_has_marker_syntax
test_A12b_title_has_newline
test_A13_skip_if_main_in_tmpdir
test_A14_label_precedence_incident_wins

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"

exit $FAIL
