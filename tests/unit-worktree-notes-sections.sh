#!/bin/bash
# tests/unit-worktree-notes-sections.sh
#
# Unit tests for hooks/lib/worktree-notes-sections.js (shared library).
#
# Expected exports: { extractSection, parseSectionEntries, markEntryPromoted }
#
# Test-first: the lib does not yet exist. Tests are SKIP-graceful — they emit
# SKIP (not FAIL) when the lib is absent so the workflow can land tests before
# implementation without showing red.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
LIB_JS="${_AGENTS_DIR_NODE}/hooks/lib/worktree-notes-sections.js"

PASS=0; FAIL=0; SKIP=0

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

require_lib() {
    if [ ! -f "$LIB_JS" ]; then
        skip "$1 (hooks/lib/worktree-notes-sections.js not implemented yet)"
        return 1
    fi
    return 0
}

# Run a Node snippet requiring the lib. The snippet receives `lib` in scope.
# Extra args become process.argv[2..N].
# Usage: lib_eval "<js snippet>" [arg1 arg2 ...]
lib_eval() {
    local snippet="$1"; shift
    run_with_timeout 30 node -e "
        const lib = require('${LIB_JS}');
        ${snippet}
    " -- "$@"
}

# ============ Tests ============

# ---- U1: extractSection — 1-entry section returns bullet text ----
test_U1_extractSection_one_entry() {
    require_lib "U1: extractSection — 1-entry section" || return
    local out
    out="$(lib_eval "
        const text = [
            '# Notes',
            '',
            '## BugsFound',
            '- only bug',
            '',
            '## RelatedTasks',
            '- (none)',
            ''
        ].join('\n');
        process.stdout.write(lib.extractSection(text, 'BugsFound'));
    " 2>/dev/null)"

    if [ "$out" = "- only bug" ]; then
        pass "U1: extractSection returns single bullet text"
    else
        fail "U1: expected '- only bug', got: $out"
    fi
}

# ---- U2: extractSection — "- (none)" only returns "(none)" ----
test_U2_extractSection_none_only() {
    require_lib "U2: extractSection — '(none)' only" || return
    local out
    out="$(lib_eval "
        const text = [
            '## BugsFound',
            '- (none)',
            '',
            '## RelatedTasks',
            '- foo'
        ].join('\n');
        process.stdout.write(lib.extractSection(text, 'BugsFound'));
    " 2>/dev/null)"

    if [ "$out" = "(none)" ]; then
        pass "U2: extractSection '- (none)' only returns '(none)'"
    else
        fail "U2: expected '(none)', got: $out"
    fi
}

# ---- U3: extractSection — missing section returns "(none)" ----
test_U3_extractSection_missing() {
    require_lib "U3: extractSection — missing section" || return
    local out
    out="$(lib_eval "
        const text = '# Notes\n\n## OtherSection\n- thing\n';
        process.stdout.write(lib.extractSection(text, 'BugsFound'));
    " 2>/dev/null)"

    if [ "$out" = "(none)" ]; then
        pass "U3: extractSection missing section returns '(none)'"
    else
        fail "U3: expected '(none)', got: $out"
    fi
}

# ---- U4: parseSectionEntries — returns structs with correct lineNumbers ----
test_U4_parseSectionEntries_line_numbers() {
    require_lib "U4: parseSectionEntries lineNumbers" || return
    local out
    out="$(lib_eval "
        const text = [
            '# Worktree Notes',
            'Branch: foo',
            '',
            '## BugsFound',
            '- first bug',
            '- second bug',
            '',
            '## RelatedTasks',
            '- (none)'
        ].join('\n');
        const entries = lib.parseSectionEntries(text, 'BugsFound');
        process.stdout.write(JSON.stringify(entries));
    " 2>/dev/null)"

    # Expected: 2 entries, with lineNumbers 5 and 6 (1-indexed).
    local len
    len="$(node -e "
        try {
            const j = JSON.parse(process.argv[1]);
            process.stdout.write(String(j.length));
        } catch (e) { process.stdout.write('ERR'); }
    " -- "$out" 2>/dev/null)"

    local ln1 ln2 raw1
    ln1="$(node -e "
        try { const j = JSON.parse(process.argv[1]); process.stdout.write(String(j[0].lineNumber)); }
        catch (e) { process.stdout.write('ERR'); }
    " -- "$out" 2>/dev/null)"
    ln2="$(node -e "
        try { const j = JSON.parse(process.argv[1]); process.stdout.write(String(j[1].lineNumber)); }
        catch (e) { process.stdout.write('ERR'); }
    " -- "$out" 2>/dev/null)"
    raw1="$(node -e "
        try { const j = JSON.parse(process.argv[1]); process.stdout.write(j[0].raw); }
        catch (e) { process.stdout.write('ERR'); }
    " -- "$out" 2>/dev/null)"

    if [ "$len" = "2" ] && [ "$ln1" = "5" ] && [ "$ln2" = "6" ] && [ "$raw1" = "- first bug" ]; then
        pass "U4: parseSectionEntries returns correct lineNumbers (5, 6) and raw"
    else
        fail "U4: len=$len ln1=$ln1 ln2=$ln2 raw1=$raw1 (out=$out)"
    fi
}

# ---- U5: parseSectionEntries — hasMarker=true for marked entry ----
test_U5_parseSectionEntries_hasMarker() {
    require_lib "U5: parseSectionEntries hasMarker" || return
    local out
    out="$(lib_eval "
        const text = [
            '## BugsFound',
            '- unmarked bug',
            '- marked bug <!-- promoted: #123 -->'
        ].join('\n');
        const entries = lib.parseSectionEntries(text, 'BugsFound');
        process.stdout.write(JSON.stringify(entries));
    " 2>/dev/null)"

    local hm0 hm1
    hm0="$(node -e "
        try { const j = JSON.parse(process.argv[1]); process.stdout.write(String(j[0].hasMarker)); }
        catch (e) { process.stdout.write('ERR'); }
    " -- "$out" 2>/dev/null)"
    hm1="$(node -e "
        try { const j = JSON.parse(process.argv[1]); process.stdout.write(String(j[1].hasMarker)); }
        catch (e) { process.stdout.write('ERR'); }
    " -- "$out" 2>/dev/null)"

    if [ "$hm0" = "false" ] && [ "$hm1" = "true" ]; then
        pass "U5: parseSectionEntries hasMarker (false, true)"
    else
        fail "U5: hm0=$hm0 hm1=$hm1 (out=$out)"
    fi
}

# ---- U6: parseSectionEntries — returns [] for "- (none)" section ----
test_U6_parseSectionEntries_none_returns_empty() {
    require_lib "U6: parseSectionEntries '- (none)' returns []" || return
    local out
    out="$(lib_eval "
        const text = [
            '## BugsFound',
            '- (none)',
            '',
            '## RelatedTasks',
            '- something'
        ].join('\n');
        const entries = lib.parseSectionEntries(text, 'BugsFound');
        process.stdout.write(JSON.stringify(entries));
    " 2>/dev/null)"

    if [ "$out" = "[]" ]; then
        pass "U6: parseSectionEntries '- (none)' returns []"
    else
        fail "U6: expected '[]', got: $out"
    fi
}

# ---- U7: markEntryPromoted — appends marker; CRLF round-trip preserved ----
test_U7_markEntryPromoted_crlf_preserved() {
    require_lib "U7: markEntryPromoted CRLF round-trip" || return

    # Build CRLF text via Node, mark line 2, verify result has CRLF and marker appended.
    local result
    result="$(lib_eval "
        const text = '## BugsFound\r\n- a bug\r\n- another\r\n';
        const out = lib.markEntryPromoted(text, 2, 456);
        // Encode as JSON so CRLF is visible.
        process.stdout.write(JSON.stringify(out));
    " 2>/dev/null)"

    # Expected JSON: \"## BugsFound\\r\\n- a bug <!-- promoted: #456 -->\\r\\n- another\\r\\n\"
    local expected='"## BugsFound\r\n- a bug <!-- promoted: #456 -->\r\n- another\r\n"'

    if [ "$result" = "$expected" ]; then
        pass "U7: markEntryPromoted appends marker, preserves CRLF"
    else
        fail "U7:
expected=$expected
actual=$result"
    fi
}

# ---- U8: extractSection — stops at next ## heading ----
test_U8_extractSection_stops_at_next_heading() {
    require_lib "U8: extractSection stops at next ##" || return
    local out
    out="$(lib_eval "
        const text = [
            '## BugsFound',
            '- bug1',
            '- bug2',
            '## RelatedTasks',
            '- related',
            '## NextTasks',
            '- next'
        ].join('\n');
        process.stdout.write(lib.extractSection(text, 'BugsFound'));
    " 2>/dev/null)"

    local expected="- bug1
- bug2"
    if [ "$out" = "$expected" ]; then
        pass "U8: extractSection stops at next '## ' heading"
    else
        fail "U8: expected '$expected', got: $out"
    fi
}

# ---- U9: parseSectionEntries — returns [] for missing section ----
test_U9_parseSectionEntries_missing() {
    require_lib "U9: parseSectionEntries missing section" || return
    local out
    out="$(lib_eval "
        const text = '# Notes\n\n## Other\n- thing\n';
        const entries = lib.parseSectionEntries(text, 'BugsFound');
        process.stdout.write(JSON.stringify(entries));
    " 2>/dev/null)"

    if [ "$out" = "[]" ]; then
        pass "U9: parseSectionEntries missing section returns []"
    else
        fail "U9: expected '[]', got: $out"
    fi
}

# ---- U10: markEntryPromoted — lineNumber out of range → text unchanged (no crash) ----
test_U10_markEntryPromoted_out_of_range() {
    require_lib "U10: markEntryPromoted out-of-range" || return
    local out
    out="$(lib_eval "
        try {
            const text = '## BugsFound\n- a bug\n';
            const result = lib.markEntryPromoted(text, 999, 7);
            // Acceptable: returns unchanged text.
            process.stdout.write('OK:' + (result === text ? 'unchanged' : 'changed'));
        } catch (e) {
            // Acceptable alternate behavior: throws cleanly. We accept either.
            process.stdout.write('THROW:' + e.message);
        }
    " 2>/dev/null)"

    case "$out" in
        OK:unchanged|THROW:*)
            pass "U10: markEntryPromoted out-of-range handled (got: $out)"
            ;;
        *)
            fail "U10: unexpected behavior (got: $out)"
            ;;
    esac
}

# ============ Run all ============

test_U1_extractSection_one_entry
test_U2_extractSection_none_only
test_U3_extractSection_missing
test_U4_parseSectionEntries_line_numbers
test_U5_parseSectionEntries_hasMarker
test_U6_parseSectionEntries_none_returns_empty
test_U7_markEntryPromoted_crlf_preserved
test_U8_extractSection_stops_at_next_heading
test_U9_parseSectionEntries_missing
test_U10_markEntryPromoted_out_of_range

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"

exit $FAIL
