#!/usr/bin/env bash
# scan-repo.sh — scan a GitHub repo's issues and comments for offensive content.
#
# Usage:
#   scan-repo.sh <owner>/<repo> [--apply] [--since YYYY-MM-DD] [--limit N] [--include-private]
#
# Default mode is dry-run. --apply edits matched content to "[redacted by content-scan]".
# In --apply mode the FIRST finding is redacted as a canary; subsequent findings are
# handled by the caller after user confirmation.

set -euo pipefail

REPO=""
APPLY=0
SINCE=""
LIMIT=0
INCLUDE_PRIVATE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --dry-run) APPLY=0; shift ;;
    --since) SINCE="$2"; shift 2 ;;
    --limit) LIMIT="$2"; shift 2 ;;
    --include-private) INCLUDE_PRIVATE=1; shift ;;
    -h|--help)
      sed -n '2,10p' "$0"; exit 0 ;;
    -*)
      echo "scan-repo: unknown flag: $1" >&2; exit 3 ;;
    *)
      if [ -z "$REPO" ]; then REPO="$1"; else echo "scan-repo: too many positional args" >&2; exit 3; fi
      shift ;;
  esac
done

if [ -z "$REPO" ]; then
  REPO="$(gh repo view --json owner,name --jq '.owner.login + "/" + .name')"
fi
if [ -z "$REPO" ]; then
  echo "scan-repo: failed to resolve repo" >&2
  exit 3
fi

CFG_DIR="${AGENTS_CONFIG_DIR:-}"
if [ -z "$CFG_DIR" ]; then
  CFG_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
fi
SCANNER="$CFG_DIR/bin/scan-offensive"
if [ ! -x "$SCANNER" ] && [ ! -f "$SCANNER" ]; then
  echo "scan-repo: scanner not found: $SCANNER" >&2
  exit 3
fi

# Skip private repos unless --include-private
if [ "$INCLUDE_PRIVATE" = "0" ]; then
  IS_PRIVATE="$(gh api "repos/$REPO" --jq .private 2>/dev/null || true)"
  if [ "$IS_PRIVATE" = "true" ]; then
    echo "scan-repo: $REPO is private; pass --include-private to scan it" >&2
    exit 0
  fi
fi

# Fetch issues (excluding PRs). Apply --since filter if given.
ISSUE_QUERY="repos/${REPO}/issues?state=all&per_page=100"
if [ -n "$SINCE" ]; then
  ISSUE_QUERY="${ISSUE_QUERY}&since=${SINCE}T00:00:00Z"
fi

MODE="dry-run"
if [ "$APPLY" = "1" ]; then MODE="apply"; fi
echo "scan-repo: scanning $REPO (mode=$MODE)"

FINDING_COUNT=0
ISSUE_COUNT=0

# Use jq -c to emit one JSON object per line; extract fields per-object.
ISSUES_JSON="$(gh api "$ISSUE_QUERY" --paginate | jq -c '[.[] | select(.pull_request == null)] | .[]')"

run_scanner() {
  local label="$1"
  local body="$2"
  printf '%s' "$body" | node "$SCANNER" --stdin "$label" 2>&1
}

while IFS= read -r obj; do
  [ -z "$obj" ] && continue
  ISSUE_COUNT=$((ISSUE_COUNT + 1))
  if [ "$LIMIT" -gt 0 ] && [ "$ISSUE_COUNT" -gt "$LIMIT" ]; then
    break
  fi

  N="$(jq -r '.number' <<< "$obj")"
  BODY="$(jq -r '.body // ""' <<< "$obj")"

  # Scan issue body
  rc=0
  SCAN_OUT="$(run_scanner "issue#${N}/body" "$BODY")" || rc=$?
  if [ "$rc" = "1" ] || [ "$rc" = "2" ]; then
    FINDING_COUNT=$((FINDING_COUNT + 1))
    echo "FINDING: issue#${N}/body (rc=$rc)"
    [ -n "$SCAN_OUT" ] && printf '%s\n' "$SCAN_OUT"
    if [ "$APPLY" = "1" ]; then
      gh issue edit "$N" --repo "$REPO" --body "[redacted by content-scan]" >/dev/null
      echo "  redacted: issue#${N}/body"
      echo "scan-repo: canary stop after first redaction"
      exit 0
    fi
  elif [ "$rc" != "0" ]; then
    echo "scan-repo: scanner unexpected rc=$rc on issue#${N}/body" >&2
  fi

  # Scan comments
  COMMENTS_JSON="$(gh api "repos/${REPO}/issues/${N}/comments?per_page=100" --paginate | jq -c '.[]' 2>/dev/null || true)"
  while IFS= read -r cobj; do
    [ -z "$cobj" ] && continue
    CID="$(jq -r '.id' <<< "$cobj")"
    CBODY="$(jq -r '.body // ""' <<< "$cobj")"
    rc=0
    SCAN_OUT="$(run_scanner "issue#${N}/comment#${CID}" "$CBODY")" || rc=$?
    if [ "$rc" = "1" ] || [ "$rc" = "2" ]; then
      FINDING_COUNT=$((FINDING_COUNT + 1))
      echo "FINDING: issue#${N}/comment#${CID} (rc=$rc)"
      [ -n "$SCAN_OUT" ] && printf '%s\n' "$SCAN_OUT"
      if [ "$APPLY" = "1" ]; then
        gh api -X PATCH "repos/${REPO}/issues/comments/${CID}" -f body="[redacted by content-scan]" >/dev/null
        echo "  redacted: issue#${N}/comment#${CID}"
        echo "scan-repo: canary stop after first redaction"
        exit 0
      fi
    elif [ "$rc" != "0" ]; then
      echo "scan-repo: scanner unexpected rc=$rc on issue#${N}/comment#${CID}" >&2
    fi
  done <<< "$COMMENTS_JSON"
done <<< "$ISSUES_JSON"

echo "scan-repo: done. issues scanned=$ISSUE_COUNT, findings=$FINDING_COUNT"
