#!/usr/bin/env bash
# phase5-investigator-security.sh — GATED until Phase 5
# After Phase 5: review-code-security SKILL.md must delegate to investigator.
# When mode=security_scan, investigator must NOT call WebSearch/WebFetch.
: "${FEATURE_644_PHASE:=0}"
if [ "$FEATURE_644_PHASE" -lt 5 ]; then
  echo "SKIP: requires FEATURE_644_PHASE>=5 (currently $FEATURE_644_PHASE)" >&2; exit 77
fi
set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORKER="$AGENTS_DIR/agents/investigator.md"
SKILL="$AGENTS_DIR/skills/review-code-security/SKILL.md"
PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

[ -f "$WORKER" ] || { fail "$WORKER not found"; exit 1; }
[ -f "$SKILL" ] || { fail "$SKILL not found"; exit 1; }

# review-code-security SKILL must call investigator
if grep -q 'investigator' "$SKILL"; then
  pass "review-code-security SKILL.md delegates to investigator"
else
  fail "review-code-security SKILL.md missing delegation to investigator"
fi

# investigator must describe security_scan mode restriction
if grep -qE 'security_scan|mode.*security' "$WORKER"; then
  pass "investigator defines security_scan mode"
else
  fail "investigator missing security_scan mode definition"
fi

# Worker must note that WebSearch is not used in security_scan mode
if grep -qE 'security_scan.*WebSearch|WebSearch.*security_scan|mode.*security.*no.*web|security.*scan.*web.*not' "$WORKER"; then
  pass "investigator restricts WebSearch in security_scan mode"
else
  # Softer check: mode constraint mentioned
  if grep -qE 'prompt.*制約|mode.*制約|mode constraint' "$WORKER"; then
    pass "investigator references mode constraint for WebSearch restriction"
  else
    fail "investigator missing WebSearch restriction for security_scan mode"
  fi
fi

echo "Results: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
