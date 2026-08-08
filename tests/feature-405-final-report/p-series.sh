#!/bin/bash
# P-series: parse-closes-issues.js
# Tests: hooks/lib/parse-closes-issues.js
#
# Sourced helpers: feature-405-final-report/helpers.sh

. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

# Run the parser; print JSON-stringified result to stdout.
parse_eval() {
    local intent_node; intent_node="$(node_path "$1")"
    run_with_timeout 120 node -e "
        const { parseClosesIssues } = require('${PARSE_JS}');
        const r = parseClosesIssues(process.argv[1]);
        process.stdout.write(JSON.stringify(r));
    " -- "$intent_node" 2>/dev/null
}

test_P1_happy_single() {
    require_parser "P1_happy_single" || return
    local f="$TMPDIR_BASE/p1-intent.md"
    printf '## closes_issues\n- 405\n' > "$f"
    local out; out="$(parse_eval "$f")"
    if [ "$out" = "[405]" ]; then
        pass "P1: single issue '- 405' → [405]"
    else
        fail "P1: expected [405], got $out"
    fi
}

test_P2_happy_multi() {
    require_parser "P2_happy_multi" || return
    local f="$TMPDIR_BASE/p2-intent.md"
    printf '## closes_issues\n- 100\n- 200\n- 300\n' > "$f"
    local out; out="$(parse_eval "$f")"
    if [ "$out" = "[100,200,300]" ]; then
        pass "P2: multi '- 100/- 200/- 300' → [100,200,300]"
    else
        fail "P2: expected [100,200,300], got $out"
    fi
}

test_P3_empty_literal() {
    require_parser "P3_empty_literal" || return
    local f="$TMPDIR_BASE/p3-intent.md"
    printf '## closes_issues\n(empty)\n' > "$f"
    local out; out="$(parse_eval "$f")"
    if [ "$out" = "[]" ]; then
        pass "P3: literal '(empty)' → []"
    else
        fail "P3: expected [], got $out"
    fi
}

test_P4_missing_section() {
    require_parser "P4_missing_section" || return
    local f="$TMPDIR_BASE/p4-intent.md"
    printf '# Intent\nSomething else.\n' > "$f"
    local out; out="$(parse_eval "$f")"
    if [ "$out" = "[]" ]; then
        pass "P4: no ## closes_issues section → []"
    else
        fail "P4: expected [], got $out"
    fi
}

test_P5_missing_file() {
    require_parser "P5_missing_file" || return
    local f="$TMPDIR_BASE/p5-nonexistent.md"
    local out; out="$(parse_eval "$f")"
    local intent_node; intent_node="$(node_path "$f")"
    run_with_timeout 120 node -e "
        const { parseClosesIssues } = require('${PARSE_JS}');
        parseClosesIssues(process.argv[1]);
    " -- "$intent_node" >/dev/null 2>&1
    local code=$?
    if [ "$out" = "[]" ] && [ "$code" = "0" ]; then
        pass "P5: non-existent file → [] (exit 0)"
    else
        fail "P5: expected [] & exit 0, got out=$out code=$code"
    fi
}

test_P6_non_integer_skipped() {
    require_parser "P6_non_integer_skipped" || return
    local f="$TMPDIR_BASE/p6-intent.md"
    printf '## closes_issues\n- 405\n- foo\n- 410\n' > "$f"
    local out; out="$(parse_eval "$f")"
    if [ "$out" = "[405,410]" ]; then
        pass "P6: '- foo' skipped; integers preserved → [405,410]"
    else
        fail "P6: expected [405,410], got $out"
    fi
}

test_P7_trailing_section_stops_parse() {
    require_parser "P7_trailing_section_stops_parse" || return
    local f="$TMPDIR_BASE/p7-intent.md"
    printf '## closes_issues\n- 405\n## other section\n- 999\n' > "$f"
    local out; out="$(parse_eval "$f")"
    if [ "$out" = "[405]" ]; then
        pass "P7: trailing ## section stops parse → [405]"
    else
        fail "P7: expected [405], got $out"
    fi
}

test_P8_inline_comment_skipped() {
    require_parser "P8_inline_comment_skipped" || return
    local f="$TMPDIR_BASE/p8-intent.md"
    printf '## closes_issues\n- 405 # comment\n' > "$f"
    local out; out="$(parse_eval "$f")"
    if [ "$out" = "[]" ]; then
        pass "P8: '- 405 # comment' is skipped (strict regex) → []"
    else
        fail "P8: expected [] (strict regex skips inline-comment), got $out"
    fi
}

# ============ Run all ============

test_P1_happy_single
test_P2_happy_multi
test_P3_empty_literal
test_P4_missing_section
test_P5_missing_file
test_P6_non_integer_skipped
test_P7_trailing_section_stops_parse
test_P8_inline_comment_skipped

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit $FAIL
