#!/usr/bin/env bash
# Tests: bin/parse-closes-issues, skills/issue-create/SKILL.md, skills/worktree-end/SKILL.md
# Tags: issue-create, github, worktree, end, cleanup
# Tests for issue #521: reverse mid-workflow finding capture design
#   CLAUDE.md                         — ## Mid-workflow finding capture section rewrite
#   skills/issue-create/SKILL.md      — ## Mid-workflow gate section between Pre-flight and Procedure
#   skills/worktree-end/SKILL.md      — Step 5.5(a.5) relabeled as fallback path
#   bin/parse-closes-issues           — new CLI wrapper (Node.js, extensionless)
#
# RED: this suite fails clean until source changes are applied.

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
pass=0; fail=0
check() {
  local desc="$1"; shift
  if "$@" 2>/dev/null; then
    echo "PASS: $desc"; pass=$((pass + 1))
  else
    echo "FAIL: $desc"; fail=$((fail + 1))
  fi
}

# ---------------------------------------------------------------------------
# 1. CLAUDE.md mid-workflow section mentions /issue-create as primary path
# ---------------------------------------------------------------------------
check "CLAUDE.md mid-workflow section mentions /issue-create as primary path" \
  bash -c '
    awk "/^## Mid-workflow finding capture/{found=1; next} found{print; count++; if(count>=15) exit}" \
      "$1/CLAUDE.md" \
    | grep -qE "primary|main path|immediately|directly"
  ' -- "$REPO_ROOT"

# ---------------------------------------------------------------------------
# 2. CLAUDE.md mid-workflow section mentions WORKTREE_NOTES.md as fallback
# ---------------------------------------------------------------------------
check "CLAUDE.md mid-workflow section mentions WORKTREE_NOTES.md as fallback" \
  bash -c '
    awk "/^## Mid-workflow finding capture/{found=1; next} found{print; count++; if(count>=20) exit}" \
      "$1/CLAUDE.md" \
    | grep -qi "fallback"
  ' -- "$REPO_ROOT"

# ---------------------------------------------------------------------------
# 3. CLAUDE.md does not contain stale "later findings go to" phrase
# ---------------------------------------------------------------------------
check "CLAUDE.md does not contain stale 'later findings go to' phrase" \
  bash -c '! grep -qF "later findings go to" "$1/CLAUDE.md"' -- "$REPO_ROOT"

# ---------------------------------------------------------------------------
# 4. issue-create SKILL.md has ## Mid-workflow gate between Pre-flight and Procedure
# ---------------------------------------------------------------------------
check "issue-create SKILL.md has ## Mid-workflow gate between Pre-flight and Procedure" \
  bash -c '
    awk "
      /^## Pre-flight/{p=1}
      /^## Mid-workflow gate/{m=1; if(p)ok=1}
      /^## Procedure/{exit}
      END{exit ok?0:1}
    " "$1/skills/issue-create/SKILL.md"
  ' -- "$REPO_ROOT"

# ---------------------------------------------------------------------------
# 5. issue-create Mid-workflow gate section references closes_issues or intent.md
# ---------------------------------------------------------------------------
check "issue-create Mid-workflow gate section references closes_issues or intent.md" \
  bash -c '
    awk "
      /^## Mid-workflow gate/{in_section=1; next}
      /^## /{if(in_section) exit}
      in_section{print}
    " "$1/skills/issue-create/SKILL.md" \
    | grep -qE "closes_issues|intent\.md|workflow-plans"
  ' -- "$REPO_ROOT"

# ---------------------------------------------------------------------------
# 6. worktree-end SKILL.md Step WE-10 mentions fallback (formerly Step 5.5(a.5))
# ---------------------------------------------------------------------------
check "worktree-end SKILL.md Step WE-10 mentions fallback" \
  bash -c '
    grep "### Step WE-10" "$1/skills/worktree-end/SKILL.md" \
    | grep -qi "fallback"
  ' -- "$REPO_ROOT"

# ---------------------------------------------------------------------------
# 7. bin/parse-closes-issues exists
# ---------------------------------------------------------------------------
check "bin/parse-closes-issues exists" \
  bash -c '[ -f "$1/bin/parse-closes-issues" ]' -- "$REPO_ROOT"

# ---------------------------------------------------------------------------
# 8. bin/parse-closes-issues prints [] with no argument
# ---------------------------------------------------------------------------
check "bin/parse-closes-issues prints [] with no argument" \
  bash -c '
    actual=$(node "$1/bin/parse-closes-issues")
    [ "$actual" = "[]" ]
  ' -- "$REPO_ROOT"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
