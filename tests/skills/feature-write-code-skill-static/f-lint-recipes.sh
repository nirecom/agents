#!/bin/bash
# Tests: skills/write-code/SKILL.md
# Tags: skill, static, lint, eslint, run-eslint, scope:issue-specific
# Fragment of tests/skills/feature-write-code-skill-static.sh, sourced after _lib.sh (not
# standalone): the JavaScript/TypeScript lint recipes go through bin/run-eslint (#2739).

# x. A bare `npx eslint` exits 2 without a repo config and is skipped by the absence policy,
# so the recipe rows must call the wrapper; TypeScript keeps its type check.
echo "=== x. JS/TS lint recipes use bin/run-eslint ==="
if require_file "$WRITE_CODE_SKILL"; then
    js_row=$(grep -E '^\| *JavaScript *\|' "$WRITE_CODE_SKILL" | head -1)
    ts_row=$(grep -E '^\| *TypeScript *\|' "$WRITE_CODE_SKILL" | head -1)
    [ -n "$js_row" ] && pass "x. JavaScript recipe row present" || fail "x. JavaScript recipe row missing"
    [ -n "$ts_row" ] && pass "x. TypeScript recipe row present" || fail "x. TypeScript recipe row missing"
    printf '%s\n' "$js_row" | grep -qF 'bin/run-eslint' \
        && pass "x. JavaScript row calls bin/run-eslint" \
        || fail "x. JavaScript row does not call bin/run-eslint: $js_row"
    printf '%s\n' "$ts_row" | grep -qF 'bin/run-eslint' \
        && pass "x. TypeScript row calls bin/run-eslint" \
        || fail "x. TypeScript row does not call bin/run-eslint: $ts_row"
    printf '%s\n' "$ts_row" | grep -qF 'npx tsc --noEmit' \
        && pass "x. TypeScript row keeps npx tsc --noEmit" \
        || fail "x. TypeScript row lost npx tsc --noEmit: $ts_row"
    if has_fixed 'npx eslint' "$WRITE_CODE_SKILL"; then
        fail "x. SKILL.md still contains 'npx eslint'"
    else
        pass "x. SKILL.md no longer contains 'npx eslint'"
    fi
fi
