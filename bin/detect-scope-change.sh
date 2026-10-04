#!/usr/bin/env bash
# Detect significant scope changes between outline and detail stages.
# Exits 0 when a notifiable change is detected; exits 1 when no change.
# Stdout: one-line description of the detected change (exit 0 only).
#
# Usage: detect-scope-change.sh <outline_path> <detail_plan_draft>
#   outline_path   — path to <session-id>-outline.md
#   detail_draft   — path to the current detail plan draft (raw planner output)
set -euo pipefail

OUTLINE="${1:-}"
DETAIL_DRAFT="${2:-}"

if [[ -z "$OUTLINE" || -z "$DETAIL_DRAFT" ]]; then
  echo "Usage: detect-scope-change.sh <outline_path> <detail_draft_path>" >&2
  exit 2
fi

if [[ ! -f "$OUTLINE" ]]; then
  echo "detect-scope-change: outline not found: $OUTLINE" >&2
  exit 1
fi

if [[ ! -f "$DETAIL_DRAFT" ]]; then
  echo "detect-scope-change: detail draft not found: $DETAIL_DRAFT" >&2
  exit 1
fi

# Check 1: Class member disposition changed (MUST → OPTIONAL/NA or vice-versa)
# Extract class member lines from outline
outline_members="$(grep -E '^\s*-.*triage:\s*(MUST|OPTIONAL|NA)' "$OUTLINE" 2>/dev/null || true)"
detail_members="$(grep -E '^\s*-.*triage:\s*(MUST|OPTIONAL|NA)' "$DETAIL_DRAFT" 2>/dev/null || true)"
if [[ -n "$outline_members" && "$outline_members" != "$detail_members" ]]; then
  echo "class member disposition changed between outline and detail"
  exit 0
fi

# Check 2: Phase split added (new ## Phase or ### Phase section in detail not in outline)
# grep -c prints its own count and exits 1 on zero matches; `|| true` swallows the
# nonzero exit without appending a second line (a stray `echo 0` would break arithmetic).
detail_phases="$(grep -c '^##* Phase' "$DETAIL_DRAFT" 2>/dev/null || true)"
outline_phases="$(grep -c '^##* Phase' "$OUTLINE" 2>/dev/null || true)"
detail_phases="${detail_phases:-0}"
outline_phases="${outline_phases:-0}"
if [[ "$detail_phases" -gt "$outline_phases" ]]; then
  echo "phase split detected: detail has more phases than outline"
  exit 0
fi

# Check 3: Approach changed (different approach name in detail vs outline)
outline_approach="$(grep -m1 '^## Adopted approach\|^## アプローチ' "$OUTLINE" 2>/dev/null | head -1 || true)"
detail_approach="$(grep -m1 '^## Adopted approach\|^## アプローチ' "$DETAIL_DRAFT" 2>/dev/null | head -1 || true)"
if [[ -n "$outline_approach" && -n "$detail_approach" && "$outline_approach" != "$detail_approach" ]]; then
  echo "approach changed between outline and detail"
  exit 0
fi

# No significant change detected
exit 1
