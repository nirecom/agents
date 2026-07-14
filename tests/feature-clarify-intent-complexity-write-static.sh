#!/bin/bash
# Tests: skills/clarify-intent/SKILL.md, bin/workflow/record-complexity-and-skip
# Tags: skill, static, complexity-evaluation, scope:issue-specific
#
# Issue #1350/#1427 — clarify-intent invokes the shared record-complexity-and-skip
# wrapper (which internally records the complexity evaluation) at CI-C1b.
#
# After the #1427 refactor, the SKILL.md no longer calls record-complexity-evaluation
# directly; it calls the wrapper 'record-complexity-and-skip', which owns the
# record-complexity-evaluation call. The wrapper must be invoked before CI-C1c so the
# persisted verdict exists for all downstream readers. Regression guards CI-COMP-4/5
# assert that the WORKFLOW_OUTLINE_NOT_NEEDED sentinel and the skip-verifier subagent
# launch remain in SKILL.md (agent context), NOT delegated into the shared script.
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

# CI-COMP-1: record-complexity-and-skip appears in SKILL.md in executable command context.
# After refactor, the SKILL.md calls 'record-complexity-and-skip' (the wrapper) instead of
# 'record-complexity-evaluation' directly. The wrapper is invoked via bash/bin path.
echo "=== CI-COMP-1: SKILL.md invokes record-complexity-and-skip (command context) ==="
if require_file "$CI_SKILL"; then
  if ! has_fixed "record-complexity-and-skip" "$CI_SKILL"; then
    fail "CI-COMP-1. clarify-intent/SKILL.md missing 'record-complexity-and-skip'"
  elif has_re '(bash|bin/workflow/)[^`]*record-complexity-and-skip' "$CI_SKILL"; then
    pass "CI-COMP-1. record-complexity-and-skip appears in an executable command context"
  else
    fail "CI-COMP-1. record-complexity-and-skip present but not in bash/bin invocation context"
  fi
fi

# CI-COMP-2: CI-C1b label present AND anchored to record-complexity-and-skip call.
echo "=== CI-COMP-2: CI-C1b label present and owns the record-complexity-and-skip call ==="
if require_file "$CI_SKILL"; then
  if ! has_fixed "CI-C1b" "$CI_SKILL"; then
    fail "CI-COMP-2. clarify-intent/SKILL.md missing 'CI-C1b'"
  else
    line_c1b=$(grep -n "CI-C1b" "$CI_SKILL" 2>/dev/null | head -1 | cut -d: -f1)
    line_rcs=$(grep -n "record-complexity-and-skip" "$CI_SKILL" 2>/dev/null | head -1 | cut -d: -f1)
    if [ -z "$line_rcs" ]; then
      fail "CI-COMP-2. CI-C1b present but no record-complexity-and-skip to anchor it"
    elif [ "$line_c1b" -le "$line_rcs" ]; then
      pass "CI-COMP-2. CI-C1b (L$line_c1b) heads the record-complexity-and-skip call (L$line_rcs)"
    else
      fail "CI-COMP-2. CI-C1b (L$line_c1b) appears after record-complexity-and-skip (L$line_rcs)"
    fi
  fi
fi

# CI-COMP-3: record-complexity-and-skip appears before CI-C1c.
echo "=== CI-COMP-3: record-complexity-and-skip precedes CI-C1c ==="
if require_file "$CI_SKILL"; then
  line_rcs=$(grep -n "record-complexity-and-skip" "$CI_SKILL" 2>/dev/null | head -1 | cut -d: -f1)
  line_c1c=$(grep -n "CI-C1c" "$CI_SKILL" 2>/dev/null | head -1 | cut -d: -f1)
  if [ -z "$line_rcs" ] || [ -z "$line_c1c" ]; then
    fail "CI-COMP-3. could not find both anchors (record-complexity-and-skip=$line_rcs, CI-C1c=$line_c1c)"
  elif [ "$line_rcs" -lt "$line_c1c" ]; then
    pass "CI-COMP-3. record-complexity-and-skip (L$line_rcs) precedes CI-C1c (L$line_c1c)"
  else
    fail "CI-COMP-3. ordering wrong: record-complexity-and-skip=L$line_rcs, CI-C1c=L$line_c1c"
  fi
fi

# CI-COMP-4: WORKFLOW_OUTLINE_NOT_NEEDED sentinel remains in SKILL.md.
# Regression guard: the sentinel must fire from SKILL.md (agent context), NOT delegated to script.
echo "=== CI-COMP-4: WORKFLOW_OUTLINE_NOT_NEEDED remains in SKILL.md ==="
if require_file "$CI_SKILL"; then
  if has_fixed "WORKFLOW_OUTLINE_NOT_NEEDED" "$CI_SKILL"; then
    pass "CI-COMP-4. WORKFLOW_OUTLINE_NOT_NEEDED sentinel present in SKILL.md"
  else
    fail "CI-COMP-4. WORKFLOW_OUTLINE_NOT_NEEDED missing from SKILL.md (sentinel must stay in agent context)"
  fi
fi

# CI-COMP-5: skip-verifier subagent reference remains in SKILL.md.
# Regression guard: the skip-verifier Agent launch must stay in SKILL.md.
echo "=== CI-COMP-5: skip-verifier reference remains in SKILL.md ==="
if require_file "$CI_SKILL"; then
  if has_fixed "skip-verifier" "$CI_SKILL"; then
    pass "CI-COMP-5. skip-verifier reference present in SKILL.md"
  else
    fail "CI-COMP-5. skip-verifier missing from SKILL.md (must stay in agent context)"
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
