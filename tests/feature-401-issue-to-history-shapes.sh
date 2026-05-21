#!/bin/bash
set -u
AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$AGENTS_DIR/bin/github-issues/lib/extract-field.sh"
if [ ! -f "$LIB" ]; then
    echo "FAIL: precondition missing — $LIB"
    echo ""
    echo "Results: 0 passed, 1 failed"
    exit 1
fi
source "$LIB"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

assert_eq() {
    local field="$1"; local body="$2"; local expected="$3"; local label="$4"
    local got; got="$(BODY="$body" extract_field "$field")"
    if [ "$got" = "$expected" ]; then pass "$label"; else fail "$label (expected='$expected' got='$got')"; fi
}

# S1: inline label
assert_eq Background $'Background: foo bar\nChanges: baz' "foo bar" "S1 inline label"
# S2: H2 header
assert_eq Background $'## Background\n\nfoo bar\n\n## Changes\n\nbaz' "foo bar" "S2 H2 header"
# S3: H3 header multiline
assert_eq Background $'### Background\n\nfoo\nbar\n\n### Changes\n\nbaz' "foo bar" "S3 H3 multiline"
# S4: lowercase inline
assert_eq Background $'background: lower' "lower" "S4 lowercase inline"
# S5: lowercase H2
assert_eq Background $'## background\nfoo' "foo" "S5 lowercase H2"
# S6: wrong field name
assert_eq Background $'Changes: only-changes' "" "S6 wrong field"
# S7: changes field with sub-heading before it
assert_eq Changes $'## Background\nfirst\n## Sub\nirrelevant\n## Changes\nbaz' "baz" "S7 changes with sub-heading"
# S8: inline Cause
assert_eq Cause $'Cause: x\nFix: y' "x" "S8 cause inline"
# S9: H2 Fix
assert_eq Fix $'## Cause\n\nx\n\n## Fix\n\ny' "y" "S9 fix H2"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
