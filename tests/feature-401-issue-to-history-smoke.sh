#!/bin/bash
set -u
AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$AGENTS_DIR/bin/github-issues/lib/extract-field.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# Smoke 1: lib itself is sourceable and extract_field works end-to-end via lib
if [ -f "$LIB" ]; then
    out="$(BODY=$'## Background\n\nsmoke-bg\n\n## Changes\n\nsmoke-ch' \
        bash -c "source '$LIB'; extract_field Background" 2>&1)"
    if [ "$out" = "smoke-bg" ]; then pass "smoke-lib: H2 Background"; else fail "smoke-lib: got='$out'"; fi
else
    fail "smoke-lib: $LIB missing"
fi

# Smoke 2: execute issue-to-history.sh end-to-end with a synthetic H2-header issue body
SCRIPT="$AGENTS_DIR/bin/github-issues/issue-to-history.sh"
if [ -x "$SCRIPT" ]; then
    smoke_body=$'## Background\n\nsmoke-exec-bg\n\n## Changes\n\nsmoke-exec-ch'
    smoke_out="$(ISSUE_BODY="$smoke_body" ISSUE_CATEGORY=FEATURE \
        ISSUE_NUMBER=0 ISSUE_TITLE="smoke" DRY_RUN=1 \
        bash "$SCRIPT" 2>&1)"
    if echo "$smoke_out" | grep -q 'smoke-exec-bg'; then
        pass "smoke-script: issue-to-history.sh extracts H2 Background end-to-end"
    else
        fail "smoke-script: H2 Background not found in output (got='$smoke_out')"
    fi
else
    fail "smoke-script: $SCRIPT missing or not executable"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
