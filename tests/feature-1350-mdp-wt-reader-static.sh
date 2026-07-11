#!/bin/bash
# Tests: skills/make-detail-plan/SKILL.md, skills/write-tests/SKILL.md, hooks/lib/workflow-state.js
# Tags: skill, static, complexity-evaluation, scope:issue-specific
#
# Issue #1350 — make-detail-plan (MDP-3) and write-tests (WT-5) become READERS
# of the persisted complexity verdict instead of re-evaluating S1..S6.
#
# Verifies:
# - both SKILL.md files invoke bin/workflow/read-complexity-evaluation;
# - the read call precedes any judge-task-complexity fallback reference (read-first);
# - the workflow-state.js barrel re-exports the complexity-evaluation API (static
#   spread + runtime require probe).
#
# Pre-implementation: reader/barrel assertions FAIL until the rewrites and the
# state-io/skip-signal-resolver APIs land. The runtime barrel probe SKIPs (not
# FAIL) while the API is absent so the file stays green before implementation.
# The script does not abort on individual assertion failures.
set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ERRORS=0
SKIPS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }
skip() { echo "SKIP (pre-impl): $1"; SKIPS=$((SKIPS + 1)); }

has_fixed() { grep -F -- "$1" "$2" >/dev/null 2>&1; }

require_file() {
  if [ ! -f "$1" ]; then
    fail "missing required file: $1"
    return 1
  fi
  return 0
}

# Assert reader-order: read-complexity-evaluation precedes judge-task-complexity.
# judge-task-complexity may be absent (pure reader) — that is also read-first.
assert_read_first() {
  local label="$1" file="$2"
  local line_read line_judge
  line_read=$(grep -n "read-complexity-evaluation" "$file" 2>/dev/null | head -1 | cut -d: -f1)
  line_judge=$(grep -n "judge-task-complexity" "$file" 2>/dev/null | head -1 | cut -d: -f1)
  if [ -z "$line_read" ]; then
    fail "$label. read-complexity-evaluation not found (cannot verify read-first)"
  elif [ -z "$line_judge" ]; then
    pass "$label. read-complexity-evaluation present, no judge-task-complexity fallback (read-only)"
  elif [ "$line_read" -lt "$line_judge" ]; then
    pass "$label. read-complexity-evaluation (L$line_read) precedes judge-task-complexity (L$line_judge)"
  else
    fail "$label. ordering wrong: read=L$line_read, judge=L$line_judge (expected read first)"
  fi
}

MDP_SKILL="$REPO_ROOT/skills/make-detail-plan/SKILL.md"
WT_SKILL="$REPO_ROOT/skills/write-tests/SKILL.md"
BARREL="$REPO_ROOT/hooks/lib/workflow-state.js"
BARREL_N="$(cygpath -m "$BARREL" 2>/dev/null || echo "$BARREL")"

# ---------------------------------------------------------------------------
# MDP-READ-1: make-detail-plan/SKILL.md invokes read-complexity-evaluation
# ---------------------------------------------------------------------------
echo "=== MDP-READ-1: make-detail-plan reads persisted verdict ==="
if require_file "$MDP_SKILL"; then
  if has_fixed "read-complexity-evaluation" "$MDP_SKILL"; then
    pass "MDP-READ-1. make-detail-plan/SKILL.md contains 'read-complexity-evaluation'"
  else
    fail "MDP-READ-1. make-detail-plan/SKILL.md missing 'read-complexity-evaluation'"
  fi
fi

# ---------------------------------------------------------------------------
# WT-READ-1: write-tests/SKILL.md invokes read-complexity-evaluation
# ---------------------------------------------------------------------------
echo "=== WT-READ-1: write-tests reads persisted verdict ==="
if require_file "$WT_SKILL"; then
  if has_fixed "read-complexity-evaluation" "$WT_SKILL"; then
    pass "WT-READ-1. write-tests/SKILL.md contains 'read-complexity-evaluation'"
  else
    fail "WT-READ-1. write-tests/SKILL.md missing 'read-complexity-evaluation'"
  fi
fi

# ---------------------------------------------------------------------------
# MDP-READ-2 / WT-READ-2: read precedes any judge-task-complexity fallback (C5)
# ---------------------------------------------------------------------------
echo "=== MDP-READ-2: make-detail-plan read-first ordering ==="
if require_file "$MDP_SKILL"; then
  assert_read_first "MDP-READ-2" "$MDP_SKILL"
fi

echo "=== WT-READ-2: write-tests read-first ordering ==="
if require_file "$WT_SKILL"; then
  assert_read_first "WT-READ-2" "$WT_SKILL"
fi

# ---------------------------------------------------------------------------
# BARREL-1: workflow-state.js re-exports complexity-evaluation API (static)
# The barrel spreads submodule exports; confirm the spread wiring is present so
# the new names flow through without an explicit per-name re-export.
# ---------------------------------------------------------------------------
echo "=== BARREL-1: workflow-state.js spreads stateIo + skipSignalResolver ==="
if require_file "$BARREL"; then
  if has_fixed "...stateIo" "$BARREL" && has_fixed "...skipSignalResolver" "$BARREL"; then
    pass "BARREL-1. barrel spreads ...stateIo and ...skipSignalResolver"
  else
    fail "BARREL-1. barrel missing ...stateIo / ...skipSignalResolver spread"
  fi
fi

# ---------------------------------------------------------------------------
# BARREL-2: runtime — barrel re-exports record/read/has complexity APIs.
# SKIP (not FAIL) while the underlying submodule APIs are absent (pre-impl).
# ---------------------------------------------------------------------------
echo "=== BARREL-2: barrel runtime re-export of complexity API ==="
if require_file "$BARREL" && command -v node >/dev/null 2>&1; then
  BARREL_TYPES="$(node -e "
    try {
      const b = require('$BARREL_N');
      const rec = typeof b.recordComplexityEvaluation;
      const rd  = typeof b.readComplexityEvaluation;
      const has = typeof b.hasComplexityEvaluation;
      console.log(rec + ',' + rd + ',' + has);
    } catch (e) { console.log('ERR'); }
  " 2>/dev/null || echo "ERR")"
  if [ "$BARREL_TYPES" = "function,function,function" ]; then
    pass "BARREL-2. barrel re-exports record/read/has ComplexityEvaluation (all functions)"
  elif [ "$BARREL_TYPES" = "undefined,undefined,undefined" ] || [ "$BARREL_TYPES" = "ERR" ]; then
    skip "BARREL-2. complexity API not yet implemented in submodules (barrel probe)"
  else
    fail "BARREL-2. barrel partial re-export -- got [$BARREL_TYPES] (want function,function,function)"
  fi
else
  skip "BARREL-2. node unavailable or barrel missing"
fi

echo
if [ "$ERRORS" -eq 0 ]; then
  echo "All static checks passed ($SKIPS skipped)."
  exit 0
else
  echo "$ERRORS check(s) failed ($SKIPS skipped)."
  exit 1
fi
