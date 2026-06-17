#!/bin/bash
# tests/feature-885-block-predicates.sh
# Tests: hooks/lib/block-predicates.js
# Tags: block-predicates, inline-skill-re, ssot, feature-885
# Tests for issue #885 — INLINE_SKILL_RE moves to hooks/lib/block-predicates.js
# as SSOT. enforce-issue-close.js will require() it from this new module.
#
# Test verifies the regex exported from the future module matches the same
# shape currently inlined in enforce-issue-close.js (lines 73-74):
#   /^[ \t]*ISSUE_CLOSE_SKILL=1[ \t]+gh[ \t]+issue[ \t]+close[ \t]+\d+[ \t]+--reason[ \t]+completed[ \t]*$/

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

MODULE="$AGENTS_DIR/hooks/lib/block-predicates.js"
MODULE_NODE="$_AGENTS_DIR_NODE/hooks/lib/block-predicates.js"

PASS=0
FAIL=0
SKIP=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

if [ ! -f "$MODULE" ]; then
    skip "B1: block-predicates.js not present yet (TDD red phase)"
    skip "B2: block-predicates.js not present yet (TDD red phase)"
    skip "B3: block-predicates.js not present yet (TDD red phase)"
    skip "B4: block-predicates.js not present yet (TDD red phase)"
    skip "B5: block-predicates.js not present yet (TDD red phase)"
    skip "B6: block-predicates.js not present yet (TDD red phase)"
    echo ""
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    [ "$FAIL" -gt 0 ] && exit 1
    exit 0
fi

# expect_match <label> <command-string-js> <expected: yes|no>
expect_match() {
    local label="$1" cmd_js="$2" expected="$3"
    local out rc
    out=$(run_with_timeout 5 node -e "
const m = require('$MODULE_NODE');
if (!(m.INLINE_SKILL_RE instanceof RegExp)) { console.error('INLINE_SKILL_RE not a RegExp'); process.exit(2); }
const cmd = $cmd_js;
const matched = m.INLINE_SKILL_RE.test(cmd);
const expected = ('$expected' === 'yes');
if (matched !== expected) { console.error('expected '+expected+', got '+matched); process.exit(3); }
console.log('OK');
" 2>&1)
    rc=$?
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then
        pass "$label"
    else
        fail "$label (rc=$rc, out=$out)"
    fi
}

# --- B1: inline-skill form matches -------------------------------------------
expect_match "B1: 'ISSUE_CLOSE_SKILL=1 gh issue close 123 --reason completed' matches" \
"'ISSUE_CLOSE_SKILL=1 gh issue close 123 --reason completed'" "yes"

# --- B2: bare gh issue close does NOT match ----------------------------------
expect_match "B2: 'gh issue close 123' does NOT match" \
"'gh issue close 123'" "no"

# --- B3: non-numeric issue id does NOT match (regex uses \d+) ---------------
expect_match "B3: 'ISSUE_CLOSE_SKILL=1 gh issue close abc --reason completed' does NOT match" \
"'ISSUE_CLOSE_SKILL=1 gh issue close abc --reason completed'" "no"

# --- B4: empty string does NOT match -----------------------------------------
expect_match "B4: empty string does NOT match" "''" "no"

# --- B5: trailing-space-no-number does NOT match -----------------------------
expect_match "B5: 'ISSUE_CLOSE_SKILL=1 gh issue close ' does NOT match" \
"'ISSUE_CLOSE_SKILL=1 gh issue close '" "no"

# --- B6: missing --reason completed does NOT match ---------------------------
expect_match "B6: 'ISSUE_CLOSE_SKILL=1 gh issue close 123' (no --reason) does NOT match" \
"'ISSUE_CLOSE_SKILL=1 gh issue close 123'" "no"

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
