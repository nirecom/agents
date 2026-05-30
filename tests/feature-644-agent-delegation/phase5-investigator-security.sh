#!/usr/bin/env bash
# phase5-investigator-security.sh — GATED until Phase 5
# After Phase 5: review-code-security SKILL.md must delegate to security-scanner.
# security-scanner must NOT list WebSearch/WebFetch in tools (structural enforcement).
: "${FEATURE_644_PHASE:=0}"
if [ "$FEATURE_644_PHASE" -lt 5 ]; then
  echo "SKIP: requires FEATURE_644_PHASE>=5 (currently $FEATURE_644_PHASE)" >&2; exit 77
fi
set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORKER="$AGENTS_DIR/agents/security-scanner.md"
SKILL="$AGENTS_DIR/skills/review-code-security/SKILL.md"
PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

[ -f "$WORKER" ] || { fail "$WORKER not found"; exit 1; }
[ -f "$SKILL" ] || { fail "$SKILL not found"; exit 1; }

# review-code-security SKILL must call security-scanner
if grep -q 'security-scanner' "$SKILL"; then
  pass "review-code-security SKILL.md delegates to security-scanner"
else
  fail "review-code-security SKILL.md missing delegation to security-scanner"
fi

# security-scanner tools frontmatter must NOT include WebSearch or WebFetch
if grep -qE '^tools:' "$WORKER"; then
  if grep -E '^tools:' "$WORKER" | grep -qE 'WebSearch|WebFetch'; then
    fail "security-scanner tools frontmatter includes WebSearch/WebFetch (must be excluded)"
  else
    pass "security-scanner tools frontmatter excludes WebSearch and WebFetch"
  fi
else
  fail "security-scanner missing tools frontmatter"
fi

# security-scanner must declare no-web constraint in rules
if grep -qE 'No WebSearch|no WebSearch|WebSearch.*not|local.*code.*only|code.*analysis.*only' "$WORKER"; then
  pass "security-scanner declares no-web constraint in rules"
else
  fail "security-scanner missing no-web constraint"
fi

# security-scanner must not modify files (read-only)
if grep -qiE 'never.*modif|read.only|no.*write' "$WORKER"; then
  pass "security-scanner declares read-only constraint"
else
  fail "security-scanner missing read-only constraint"
fi

echo "Results: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
