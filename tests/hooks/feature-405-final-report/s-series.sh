#!/bin/bash
# S-series: worktree-notes.js buildNotesBody schema extension
# Tests: hooks/lib/worktree-notes.js
# Tags: scope:common
#
# Sourced helpers: feature-405-final-report/helpers.sh

. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

notes_body_eval() {
    run_with_timeout 120 node -e "
        const m = require('${NOTES_JS}');
        const body = m.buildNotesBody({
            branch: 'feature/x',
            createdDate: '2024-01-15',
            resolvedPath: '/tmp/wt',
            baseDir: null,
            copiedFiles: []
        });
        process.stdout.write(body);
    " 2>/dev/null
}

test_S1_three_sections_present() {
    require_notes_lib "S1_three_sections_present" || return
    local body; body="$(notes_body_eval)"
    if echo "$body" | grep -q "^## BugsFound$" \
       && echo "$body" | grep -q "^## RelatedTasks$" \
       && echo "$body" | grep -q "^## NextTasks$"; then
        pass "S1: BugsFound / RelatedTasks / NextTasks sections present"
    else
        fail "S1: one or more new sections missing
$body"
    fi
}

test_S2_section_order() {
    require_notes_lib "S2_section_order" || return
    local body; body="$(notes_body_eval)"
    local ln_copied ln_bugs ln_related ln_next
    ln_copied="$(echo "$body" | grep -n "^## Gitignored files copied from main$" | head -1 | cut -d: -f1)"
    ln_bugs="$(echo "$body" | grep -n "^## BugsFound$" | head -1 | cut -d: -f1)"
    ln_related="$(echo "$body" | grep -n "^## RelatedTasks$" | head -1 | cut -d: -f1)"
    ln_next="$(echo "$body" | grep -n "^## NextTasks$" | head -1 | cut -d: -f1)"

    if [ -n "$ln_copied" ] && [ -n "$ln_bugs" ] && [ -n "$ln_related" ] && [ -n "$ln_next" ] \
       && [ "$ln_copied" -lt "$ln_bugs" ] \
       && [ "$ln_bugs" -lt "$ln_related" ] \
       && [ "$ln_related" -lt "$ln_next" ]; then
        pass "S2: section order Gitignored < BugsFound < RelatedTasks < NextTasks"
    else
        fail "S2: order wrong (copied=$ln_copied bugs=$ln_bugs related=$ln_related next=$ln_next)"
    fi
}

test_S3_byte_exact_new_sections() {
    require_notes_lib "S3_byte_exact_new_sections" || return
    local body; body="$(notes_body_eval)"
    local expected_tail
    expected_tail="$(printf '%s\n' \
        '' \
        '## BugsFound' \
        '- (none)' \
        '' \
        '## RelatedTasks' \
        '- (none)' \
        '' \
        '## NextTasks' \
        '- (none)')"
    if echo "$body" | grep -qF "$expected_tail"; then
        pass "S3: byte-exact 3-section block with '- (none)' bullets + blank line separators"
    else
        fail "S3: exact tail block not found
--- body ---
$body
--- expected tail ---
$expected_tail"
    fi
}

# ============ Run all ============

test_S1_three_sections_present
test_S2_section_order
test_S3_byte_exact_new_sections

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit $FAIL
