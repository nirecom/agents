#!/usr/bin/env bash
# phase5-investigator-web.sh — GATED until Phase 5
# After Phase 5: web-researcher agent must exist with WebSearch in tools,
# and deep-research SKILL.md must delegate to it.
: "${FEATURE_644_PHASE:=0}"
if [ "$FEATURE_644_PHASE" -lt 5 ]; then
  echo "SKIP: requires FEATURE_644_PHASE>=5 (currently $FEATURE_644_PHASE)" >&2; exit 77
fi
set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORKER="$AGENTS_DIR/agents/web-researcher.md"
SKILL="$AGENTS_DIR/skills/deep-research/SKILL.md"
PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

[ -f "$WORKER" ] || { fail "$WORKER not found"; exit 1; }
[ -f "$SKILL" ] || { fail "$SKILL not found"; exit 1; }

# web-researcher must list WebSearch in tools frontmatter
if grep -q 'WebSearch' "$WORKER"; then
  pass "web-researcher has WebSearch in tools"
else
  fail "web-researcher missing WebSearch tool"
fi

# deep-research SKILL must call web-researcher
if grep -q 'web-researcher' "$SKILL"; then
  pass "deep-research SKILL.md delegates to web-researcher"
else
  fail "deep-research SKILL.md missing delegation to web-researcher"
fi

# web-researcher must not modify files (read-only)
if grep -qiE 'never.*modif|read.only|no.*write' "$WORKER"; then
  pass "web-researcher declares read-only constraint"
else
  fail "web-researcher missing read-only constraint"
fi

echo "Results: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
