#!/bin/bash
# tests/fix-1591-intent-to-issue.sh
# Tests: bin/github-issues/lib/intent-to-issue.sh intent_extract_title / intent_extract_body
# Tags: intent, github, issues, scan-outbound, scope:issue-specific, layer:TL2
#
# Issue #1591 — extract a clean Title + Body from a session intent.md for issue
# creation. intent_extract_title reads the **Title:** line (H1-derived fallback).
# intent_extract_body extracts ONLY exact-match Background/Scope H2 sections, and
# must NOT pick up confusable headings (prefix matches) or internal sections.
#
# RED until /write-code creates bin/github-issues/lib/intent-to-issue.sh.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$AGENTS_DIR/bin/github-issues/lib/intent-to-issue.sh"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

TMP=""
setup() { TMP="$(mktemp -d)"; }
teardown() { [ -n "${TMP:-}" ] && [ -d "$TMP" ] && rm -rf "$TMP" 2>/dev/null || true; TMP=""; }

title_of() { source "$LIB"; intent_extract_title "$1"; }
body_of()  { source "$LIB"; intent_extract_body  "$1"; }

if [ ! -f "$LIB" ]; then
    fail "T-ALL: bin/github-issues/lib/intent-to-issue.sh not yet present (expected RED before /write-code)"
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

run_with_timeout 20 true

# T-1: intent_extract_title returns the **Title:** line value (trimmed).
setup
F="$TMP/intent.md"
cat > "$F" <<'EOF'
# Tracking issue — sid-abc123

**Title:** Add fail-closed outbound scan guard

## Issues
- closes #1591

## Background / Motivation
scan-outbound.js is blind to gh calls inside wrapper subprocesses.

## Scope
Wrap gh free-text calls with a shared guard.
EOF
T="$(title_of "$F")"
if [ "$T" = "Add fail-closed outbound scan guard" ]; then
    pass "T-1: intent_extract_title returns the **Title:** value"
else
    fail "T-1: expected exact title; got '$T'"
fi
teardown

# T-2: fallback — no **Title:** line -> H1 text stripped of '— <sid>' suffix.
setup
F="$TMP/intent.md"
cat > "$F" <<'EOF'
# Add outbound scan guard — sid-abc123

## Background
body
EOF
T="$(title_of "$F")"
if [ "$T" = "Add outbound scan guard" ]; then
    pass "T-2: fallback H1 title with '— <sid>' suffix stripped"
else
    fail "T-2: expected 'Add outbound scan guard'; got '$T'"
fi
teardown

# T-3: body includes Background + Scope content, excludes internal sections.
setup
F="$TMP/intent.md"
cat > "$F" <<'EOF'
# T — sid

**Title:** X

## Background / Motivation
BACKGROUND_MARKER text here.

## Scope
SCOPE_MARKER text here.

## Accepted Tradeoffs
TRADEOFF_MARKER should be excluded.

## Class members
CLASSMEMBER_MARKER should be excluded.

## Interview Log
INTERVIEW_MARKER should be excluded.
EOF
B="$(body_of "$F")"
if echo "$B" | grep -q "BACKGROUND_MARKER" \
    && echo "$B" | grep -q "SCOPE_MARKER" \
    && ! echo "$B" | grep -q "TRADEOFF_MARKER" \
    && ! echo "$B" | grep -q "CLASSMEMBER_MARKER" \
    && ! echo "$B" | grep -q "INTERVIEW_MARKER"; then
    pass "T-3: body has Background+Scope, excludes Tradeoffs/Class members/Interview Log"
else
    fail "T-3: body extraction wrong; got:
$B"
fi
teardown

# T-4: heading-variant coverage — no-space forms are recognized.
setup
F="$TMP/intent.md"
cat > "$F" <<'EOF'
# T — sid

**Title:** X

## Background/Motivation
NOSPACE_BG_MARKER

## Scope/Constraints
NOSPACE_SCOPE_MARKER
EOF
B="$(body_of "$F")"
if echo "$B" | grep -q "NOSPACE_BG_MARKER" && echo "$B" | grep -q "NOSPACE_SCOPE_MARKER"; then
    pass "T-4: no-space heading variants (Background/Motivation, Scope/Constraints) included"
else
    fail "T-4: expected both no-space markers; got:
$B"
fi
teardown

# T-5: confusable-heading regression — prefix matches must NOT be included.
# 'Background – Internal Notes' and 'Scope Decision Log' are exact-mismatch.
setup
F="$TMP/intent.md"
cat > "$F" <<'EOF'
# T — sid

**Title:** X

## Background – Internal Notes
CONFUSABLE_BG_MARKER must be excluded.

## Scope Decision Log
CONFUSABLE_SCOPE_MARKER must be excluded.

## Scope
REAL_SCOPE_MARKER included.
EOF
B="$(body_of "$F")"
if echo "$B" | grep -q "REAL_SCOPE_MARKER" \
    && ! echo "$B" | grep -q "CONFUSABLE_BG_MARKER" \
    && ! echo "$B" | grep -q "CONFUSABLE_SCOPE_MARKER"; then
    pass "T-5: confusable prefix headings excluded (exact-match allowlist only)"
else
    fail "T-5: confusable headings leaked; got:
$B"
fi
teardown

# T-6: 'Constraints' alone (not 'Scope / Constraints') must be excluded.
setup
F="$TMP/intent.md"
cat > "$F" <<'EOF'
# T — sid

**Title:** X

## Constraints
BARE_CONSTRAINTS_MARKER must be excluded.

## Scope
SCOPE_OK_MARKER included.
EOF
B="$(body_of "$F")"
if echo "$B" | grep -q "SCOPE_OK_MARKER" && ! echo "$B" | grep -q "BARE_CONSTRAINTS_MARKER"; then
    pass "T-6: bare '## Constraints' excluded; '## Scope' included"
else
    fail "T-6: bare Constraints leaked or Scope missing; got:
$B"
fi
teardown

echo ""
echo "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0 ? 1 : 0))
