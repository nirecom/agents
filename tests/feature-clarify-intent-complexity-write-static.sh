#!/bin/bash
# Tests: skills/clarify-intent/SKILL.md
# Tags: skill, static, complexity-evaluation, scope:issue-specific
#
# Issue #1350 — clarify-intent gains the one-time complexity-evaluation WRITE.
#
# Verifies clarify-intent/SKILL.md invokes bin/workflow/record-complexity-evaluation
# at the new CI-C1b step, and that the write is emitted before CI-C1c (so the
# persisted verdict exists for all downstream readers).
#
# Pre-implementation: assertions are expected to FAIL until the skill is
# rewritten. The script does not abort on individual assertion failures.
set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

has_fixed() { grep -F -- "$1" "$2" >/dev/null 2>&1; }
has_re() { grep -E -- "$1" "$2" >/dev/null 2>&1; }

require_file() {
  if [ ! -f "$1" ]; then
    fail "missing required file: $1"
    return 1
  fi
  return 0
}

CI_SKILL="$REPO_ROOT/skills/clarify-intent/SKILL.md"

# ---------------------------------------------------------------------------
# CI-COMP-1: record-complexity-evaluation appears in an EXECUTABLE command
# context, not merely a prose/comment mention. The write point is a Bash call:
# `node ".../bin/workflow/record-complexity-evaluation" ...`. Require the token
# to co-occur on a line with an invocation shape (node/bash/path-to-bin).
# ---------------------------------------------------------------------------
echo "=== CI-COMP-1: SKILL.md invokes record-complexity-evaluation (command context) ==="
if require_file "$CI_SKILL"; then
  if ! has_fixed "record-complexity-evaluation" "$CI_SKILL"; then
    fail "CI-COMP-1. clarify-intent/SKILL.md missing 'record-complexity-evaluation'"
  elif has_re '(node|bash|bin/workflow/)[^`]*record-complexity-evaluation' "$CI_SKILL"; then
    pass "CI-COMP-1. record-complexity-evaluation appears in an executable command context"
  else
    fail "CI-COMP-1. record-complexity-evaluation present but not in a node/bash/bin invocation context"
  fi
fi

# ---------------------------------------------------------------------------
# CI-COMP-2: CI-C1b label present AND anchored to the complexity-write step.
# The record call must appear at/after the CI-C1b label and before CI-C1c, so
# CI-C1b is genuinely the complexity-write step (not just a stray label).
# ---------------------------------------------------------------------------
echo "=== CI-COMP-2: CI-C1b label present and owns the complexity write ==="
if require_file "$CI_SKILL"; then
  if ! has_fixed "CI-C1b" "$CI_SKILL"; then
    fail "CI-COMP-2. clarify-intent/SKILL.md missing 'CI-C1b'"
  else
    line_c1b=$(grep -n "CI-C1b" "$CI_SKILL" 2>/dev/null | head -1 | cut -d: -f1)
    line_rec=$(grep -n "record-complexity-evaluation" "$CI_SKILL" 2>/dev/null | head -1 | cut -d: -f1)
    if [ -z "$line_rec" ]; then
      fail "CI-COMP-2. CI-C1b present but no record-complexity-evaluation to anchor it"
    elif [ "$line_c1b" -le "$line_rec" ]; then
      pass "CI-COMP-2. CI-C1b (L$line_c1b) heads the complexity write (record at L$line_rec)"
    else
      fail "CI-COMP-2. CI-C1b (L$line_c1b) appears after the record call (L$line_rec) — label not anchoring the write"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# CI-COMP-3: record-complexity-evaluation appears before CI-C1c
# ---------------------------------------------------------------------------
echo "=== CI-COMP-3: record-complexity-evaluation precedes CI-C1c ==="
if require_file "$CI_SKILL"; then
  line_record=$(grep -n "record-complexity-evaluation" "$CI_SKILL" 2>/dev/null | head -1 | cut -d: -f1)
  line_c1c=$(grep -n "CI-C1c" "$CI_SKILL" 2>/dev/null | head -1 | cut -d: -f1)
  if [ -z "$line_record" ] || [ -z "$line_c1c" ]; then
    fail "CI-COMP-3. could not find both anchors (record-complexity-evaluation=$line_record, CI-C1c=$line_c1c)"
  elif [ "$line_record" -lt "$line_c1c" ]; then
    pass "CI-COMP-3. record-complexity-evaluation (L$line_record) precedes CI-C1c (L$line_c1c)"
  else
    fail "CI-COMP-3. ordering wrong: record-complexity-evaluation=L$line_record, CI-C1c=L$line_c1c (expected record first)"
  fi
fi

echo
if [ "$ERRORS" -eq 0 ]; then
  echo "All static checks passed."
  exit 0
else
  echo "$ERRORS check(s) failed."
  exit 1
fi
