#!/bin/bash
# verify-renumber-sweep.sh — Detect legacy step-label references after the
# #613/#614 SKILL renumber sweep (WI/WE/ICF/MDP schemes).
#
# Scope: all tracked files EXCEPT
#   - tests/**           (test fixtures retain legacy labels by design)
#   - docs/history.md    (append-only history; historical entries preserved)
#   - docs/history/**    (archived history; historical entries preserved)
#   - docs/history/index.md
#   - CHANGELOG.md       (append-only changelog; historical entries preserved)
#   - rules/docs/history.md (blocked by block-history-direct.js hook; follow-up)
#
# Exit codes:
#   0 — no legacy references detected
#   1 — legacy references detected (printed to stdout)
#
# Patterns checked:
#   - "Step 0.5" / "Step 4" / "Step 5" / "Step 5.5" / "Step 6[a-i]"  (workflow-init / worktree-end legacy)
#   - "Step G.5" / "Step G.5-1" / "Step G.5-2" / "Step G.5-3"        (issue-close-finalize legacy)
#   - "Step A.5" / "Step B" / "Step G" / "Step H" / "Step J" / "Step K" / "Step L" — too generic; skipped
#
# Usage: bash bin/verify-renumber-sweep.sh

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

EXCLUDES=(
  --glob '!tests/**'
  --glob '!docs/history.md'
  --glob '!docs/history/**'
  --glob '!CHANGELOG.md'
  --glob '!rules/docs/history.md'
  --glob '!bin/verify-renumber-sweep.sh'
)

PATTERNS=(
  'Step 0\.5\b'
  'Step 5\.5\b'
  'Step 6[a-i]\b'
  'Step G\.5(-[123])?\b'
)

FOUND=0
for pat in "${PATTERNS[@]}"; do
  if out="$(rg -n --no-heading "${EXCLUDES[@]}" "$pat" 2>/dev/null)"; then
    if [[ -n "$out" ]]; then
      printf 'Legacy reference found for pattern: %s\n' "$pat"
      printf '%s\n\n' "$out"
      FOUND=1
    fi
  fi
done

# --- CI/MOP legacy: ### Step 0 heading in those two SKILL.md files ---
for _f in \
    "$REPO_ROOT/skills/clarify-intent/SKILL.md" \
    "$REPO_ROOT/skills/make-outline-plan/SKILL.md"; do
  if [ -f "$_f" ]; then
    if out="$(rg -n --no-heading '### Step 0' "$_f" 2>/dev/null)"; then
      if [[ -n "$out" ]]; then
        rel="${_f#$REPO_ROOT/}"
        printf 'Legacy reference found in %s for pattern: ### Step 0\n' "$rel"
        printf '%s\n\n' "$out"
        FOUND=1
      fi
    fi
  fi
done

# --- SC legacy: ## Step [digit] in session-close/SKILL.md ---
SC_SKILL="$REPO_ROOT/skills/session-close/SKILL.md"
if [ -f "$SC_SKILL" ]; then
  if out="$(rg -n --no-heading '## Step [0-9]' "$SC_SKILL" 2>/dev/null)"; then
    if [[ -n "$out" ]]; then
      printf 'Legacy reference found in skills/session-close/SKILL.md for pattern: ## Step [0-9]\n'
      printf '%s\n\n' "$out"
      FOUND=1
    fi
  fi
fi

if [[ "$FOUND" -ne 0 ]]; then
  printf 'verify-renumber-sweep: FAIL — legacy step references remain (see above)\n' >&2
  exit 1
fi

printf 'verify-renumber-sweep: PASS — no legacy step references found\n'
exit 0
