#!/usr/bin/env bash
# phase5-investigator-web.sh — GATED until Phase 5
# After Phase 5: investigator agent must exist with WebSearch in tools,
# and deep-research SKILL.md must delegate to it.
: "${FEATURE_644_PHASE:=0}"
if [ "$FEATURE_644_PHASE" -lt 5 ]; then
  echo "SKIP: requires FEATURE_644_PHASE>=5 (currently $FEATURE_644_PHASE)" >&2; exit 77
fi
set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORKER="$AGENTS_DIR/agents/investigator.md"
SKILL="$AGENTS_DIR/skills/deep-research/SKILL.md"
PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

[ -f "$WORKER" ] || { fail "$WORKER not found"; exit 1; }
[ -f "$SKILL" ] || { fail "$SKILL not found"; exit 1; }

# investigator must list WebSearch in tools frontmatter
if grep -qE '^tools:.*WebSearch|WebSearch' "$WORKER" | head -5 | grep -q 'WebSearch'; then
  pass "investigator has WebSearch in tools"
else
  # Try grep directly
  if grep -q 'WebSearch' "$WORKER"; then
    pass "investigator references WebSearch"
  else
    fail "investigator missing WebSearch tool"
  fi
fi

# deep-research SKILL must call investigator
if grep -q 'investigator' "$SKILL"; then
  pass "deep-research SKILL.md delegates to investigator"
else
  fail "deep-research SKILL.md missing delegation to investigator"
fi

# investigator must not modify files (read-only)
if grep -qiE 'never.*modif|read.only|no.*write|ファイル変更禁止' "$WORKER"; then
  pass "investigator declares read-only constraint"
else
  fail "investigator missing read-only constraint"
fi

echo "Results: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
