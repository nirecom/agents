#!/usr/bin/env bash
# Migrate model:* labels to reporter-model:* / model-scope:* taxonomy.
# Usage: migrate-model-labels.sh [--dry-run] [--repo OWNER/REPO]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DRY_RUN=0
REPO=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --repo)
      REPO="$2"
      shift 2
      ;;
    --repo=*)
      REPO="${1#--repo=}"
      shift
      ;;
    *)
      echo "Unknown flag: $1" >&2
      exit 1
      ;;
  esac
done

if ! command -v gh &>/dev/null; then
  echo "Error: gh CLI not found. Install it from https://cli.github.com/" >&2
  exit 1
fi

if [[ -z "$REPO" ]]; then
  REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
fi

if ! [[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  echo "Error: invalid --repo value: $REPO" >&2
  exit 2
fi

echo "Repository: $REPO"
[[ "$DRY_RUN" -eq 1 ]] && echo "[DRY-RUN mode — no GitHub API writes will occur]"

# ---------------------------------------------------------------------------
# Phase 1 — RENAME model:* → reporter-model:*
# ---------------------------------------------------------------------------
echo ""
echo "=== Phase 1: Rename model:* → reporter-model:* ==="

declare -A RENAMES=(
  ["model:fable"]="reporter-model:fable"
  ["model:opus"]="reporter-model:opus"
  ["model:sonnet"]="reporter-model:sonnet"
  ["model:ds4"]="reporter-model:ds4"
)

for OLD in "model:fable" "model:opus" "model:sonnet" "model:ds4"; do
  NEW="${RENAMES[$OLD]}"
  EXISTING="$(gh label list --repo "$REPO" --search "$OLD" --json name --jq '.[0].name // empty' 2>/dev/null || true)"
  NEW_EXISTS="$(gh label list --repo "$REPO" --search "$NEW" --json name \
    --jq '.[0].name // empty' 2>/dev/null || true)"
  if [[ "$NEW_EXISTS" == "$NEW" ]]; then
    NEW_COUNT="$(gh issue list --label "$NEW" --state all --limit 1 \
      --repo "$REPO" --json number --jq 'length' 2>/dev/null || echo "0")"
    if [[ "$NEW_COUNT" -eq 0 ]]; then
      if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "[DRY-RUN] Would DELETE $NEW (exists, 0 issues) before renaming $OLD → $NEW"
      else
        gh label delete "$NEW" --repo "$REPO" --yes
        echo "PRE-DELETED: $NEW (0 issues, cleared for rename)"
      fi
    else
      echo "WARN: $NEW already exists with $NEW_COUNT issue(s) — skipping rename of $OLD"
      continue
    fi
  fi
  if [[ "$EXISTING" == "$OLD" ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      echo "[DRY-RUN] Would RENAME $OLD → $NEW"
    else
      gh label edit "$OLD" --name "$NEW" --repo "$REPO"
      echo "RENAMED: $OLD → $NEW"
    fi
  else
    echo "SKIP: $OLD not found (already renamed or never existed)"
  fi
done

# ---------------------------------------------------------------------------
# Phase 2 — CREATE new labels via sync-labels.sh
# ---------------------------------------------------------------------------
echo ""
echo "=== Phase 2: Create new labels (devstral, qwen-coder, model-scope:*) ==="

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[DRY-RUN] Would run sync-labels.sh --repo $REPO"
else
  bash "$SCRIPT_DIR/sync-labels.sh" --repo "$REPO"
  echo "sync-labels.sh completed"
fi

# ---------------------------------------------------------------------------
# Phase 3 — model:others cleanup
# ---------------------------------------------------------------------------
echo ""
echo "=== Phase 3: Handle model:others ==="

COUNT="$(gh issue list --label "model:others" --state all --limit 100 --repo "$REPO" --json number --jq 'length' 2>/dev/null || echo "0")"

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[DRY-RUN] model:others has $COUNT issue(s)"
  if [[ "$COUNT" -eq 0 ]]; then
    echo "[DRY-RUN] Would DELETE label model:others (no issues)"
  else
    echo "[DRY-RUN] Would WARN: $COUNT issue(s) still use model:others — manual action required"
  fi
else
  if [[ "$COUNT" -eq 0 ]]; then
    gh label delete "model:others" --repo "$REPO" --yes
    echo "DELETED: model:others (no issues were using it)"
  else
    echo "WARNING: $COUNT issue(s) still carry the 'model:others' label."
    echo "  Manual action required — choose one of:"
    echo "    1. Delete the label only (issues lose the label automatically)"
    echo "    2. Reassign each issue to a reporter-model:* label, then delete model:others"
    echo "    3. Rename model:others to reporter-model:others, then handle individually"
  fi
fi

# ---------------------------------------------------------------------------
# Phase 4 — #1488 title fix
# ---------------------------------------------------------------------------
echo ""
echo "=== Phase 4: Strip [ds4] prefix from issue #1488 ==="

TITLE="$(gh issue view 1488 --repo "$REPO" --json title --jq .title 2>/dev/null || true)"

if [[ "$TITLE" == \[ds4\]* ]]; then
  NEW_TITLE="${TITLE#\[ds4\] }"
  # Handle case with no space after [ds4]
  if [[ "$NEW_TITLE" == "$TITLE" ]]; then
    NEW_TITLE="${TITLE#\[ds4\]}"
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] Would strip [ds4] prefix from #1488 and add model-scope:ds4"
    echo "[DRY-RUN] New title would be: $NEW_TITLE"
  else
    gh issue edit 1488 --repo "$REPO" --title "$NEW_TITLE" --add-label "model-scope:ds4"
    echo "FIXED: #1488 title updated to: $NEW_TITLE"
    echo "ADDED: model-scope:ds4 label to #1488"
  fi
else
  echo "SKIP: #1488 title does not start with [ds4] (current: $TITLE)"
fi

echo ""
echo "Migration complete."
