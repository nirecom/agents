#!/bin/bash
# Tests: skills/clarify-intent/SKILL.md, skills/_shared/complexity-and-outline-skip.md
# Tags: skill, static, complexity-evaluation, scope:issue-specific
#
# Issue #1350/#1427 — clarify-intent's CI-C1b must invoke the record-complexity-and-skip
# wrapper before the branching logic, and the WORKFLOW_OUTLINE_NOT_NEEDED sentinel plus
# the skip-verifier subagent launch must stay in agent (prompt) context, never delegated
# into the wrapper script. CI-C1b may own that procedure inline or delegate it to
# skills/_shared/complexity-and-outline-skip.md; CI-COMP-0 resolves which file owns it and
# the remaining checks follow that reference. Assertions do not abort the script.
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
CI_SHARED_REL="skills/_shared/complexity-and-outline-skip.md"
CI_SHARED="$REPO_ROOT/$CI_SHARED_REL"

# CI-COMP-0: resolve which file owns the CI-C1b procedure. When CI-C1b delegates to the
# shared file, CI-COMP-1/3/4/5 follow that reference; otherwise they stay on SKILL.md.
# Losing the reference line without re-inlining the procedure therefore still fails.
CI_PROC=""
CI_PROC_LABEL=""
echo "=== CI-COMP-0: locate the owner of the CI-C1b complexity/outline-skip procedure ==="
if require_file "$CI_SKILL"; then
  if has_re "CI-C1b.*$CI_SHARED_REL" "$CI_SKILL"; then
    if require_file "$CI_SHARED"; then
      CI_PROC="$CI_SHARED"
      CI_PROC_LABEL="$CI_SHARED_REL"
      pass "CI-COMP-0. CI-C1b delegates to $CI_SHARED_REL; checks follow the reference"
    fi
  else
    CI_PROC="$CI_SKILL"
    CI_PROC_LABEL="clarify-intent/SKILL.md"
    pass "CI-COMP-0. CI-C1b owns the procedure inline; checks target SKILL.md"
  fi
fi

# CI-COMP-1: record-complexity-and-skip appears in the procedure owner in executable
# command context — the wrapper (not record-complexity-evaluation directly) is invoked
# via a bash/bin path.
echo "=== CI-COMP-1: procedure owner invokes record-complexity-and-skip (command context) ==="
if [ -n "$CI_PROC" ]; then
  if ! has_fixed "record-complexity-and-skip" "$CI_PROC"; then
    fail "CI-COMP-1. $CI_PROC_LABEL missing 'record-complexity-and-skip'"
  elif has_re '(bash|bin/workflow/)[^`]*record-complexity-and-skip' "$CI_PROC"; then
    pass "CI-COMP-1. record-complexity-and-skip appears in an executable command context in $CI_PROC_LABEL"
  else
    fail "CI-COMP-1. record-complexity-and-skip present in $CI_PROC_LABEL but not in bash/bin invocation context"
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

# CI-COMP-3: record-complexity-and-skip runs before the CI-C1c-equivalent branching, so the
# persisted verdict exists for every downstream reader. The branch is anchored by its own
# label at line start (CI-C1c) or, in the shared procedure, by the skip-verifier dispatch it
# performs — never by a header cross-reference that merely names those labels.
echo "=== CI-COMP-3: record-complexity-and-skip precedes the branching logic ==="
if [ -n "$CI_PROC" ]; then
  line_rcs=$(grep -n "record-complexity-and-skip" "$CI_PROC" 2>/dev/null | head -1 | cut -d: -f1)
  line_branch=$(grep -nE '^\**CI-C1c|subagent_type=`?skip-verifier' "$CI_PROC" 2>/dev/null | head -1 | cut -d: -f1)
  if [ -z "$line_rcs" ] || [ -z "$line_branch" ]; then
    fail "CI-COMP-3. could not find both anchors in $CI_PROC_LABEL (record-complexity-and-skip=$line_rcs, branch=$line_branch)"
  elif [ "$line_rcs" -lt "$line_branch" ]; then
    pass "CI-COMP-3. record-complexity-and-skip (L$line_rcs) precedes the branching logic (L$line_branch) in $CI_PROC_LABEL"
  else
    fail "CI-COMP-3. ordering wrong in $CI_PROC_LABEL: record-complexity-and-skip=L$line_rcs, branch=L$line_branch"
  fi
fi

# CI-COMP-4: WORKFLOW_OUTLINE_NOT_NEEDED sentinel remains in the procedure prompt.
# Regression guard: the sentinel must fire from agent context, NOT be delegated to a script.
echo "=== CI-COMP-4: WORKFLOW_OUTLINE_NOT_NEEDED remains in the procedure prompt ==="
if [ -n "$CI_PROC" ]; then
  if has_fixed "WORKFLOW_OUTLINE_NOT_NEEDED" "$CI_PROC"; then
    pass "CI-COMP-4. WORKFLOW_OUTLINE_NOT_NEEDED sentinel present in $CI_PROC_LABEL"
  else
    fail "CI-COMP-4. WORKFLOW_OUTLINE_NOT_NEEDED missing from $CI_PROC_LABEL (sentinel must stay in agent context)"
  fi
fi

# CI-COMP-5: skip-verifier subagent reference remains in the procedure prompt.
# Regression guard: the skip-verifier Agent launch must stay in agent context.
echo "=== CI-COMP-5: skip-verifier reference remains in the procedure prompt ==="
if [ -n "$CI_PROC" ]; then
  if has_fixed "skip-verifier" "$CI_PROC"; then
    pass "CI-COMP-5. skip-verifier reference present in $CI_PROC_LABEL"
  else
    fail "CI-COMP-5. skip-verifier missing from $CI_PROC_LABEL (must stay in agent context)"
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
