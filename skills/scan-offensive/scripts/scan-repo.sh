#!/usr/bin/env bash
# scan-repo.sh — scan a GitHub repo's issues and comments for offensive content.
#
# Usage:
#   scan-repo.sh <owner>/<repo> [--dry-run] [--apply --manifest-path FILE --confirm-ids IDs]
#                [--since YYYY-MM-DD] [--until YYYY-MM-DD]
#                [--from-issue N] [--to-issue N]
#                [--limit N] [--include-private]
#                [--manifest-out PATH]
#                [--canary-skip]
#
# Default mode is dry-run: produces a JSONL manifest (preamble record + item records).
# --apply requires --manifest-path (previously produced manifest) and --confirm-ids.
# Stale-content check: SHA-256 of live body vs manifest; exits 5 on mismatch (STALE).
# Canary semantics: with multiple --confirm-ids, redacts first item and exits 0.

set -euo pipefail

REPO=""
APPLY=0
SINCE=""
UNTIL=""
FROM_ISSUE=""
TO_ISSUE=""
LIMIT=0
INCLUDE_PRIVATE=0
MANIFEST_OUT=""
MANIFEST_PATH=""
CONFIRM_IDS=""
CANARY_SKIP=0

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --dry-run) APPLY=0; shift ;;
    --since)
      case "$2" in
        [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
        *) echo "scan-repo: --since requires YYYY-MM-DD, got: $2" >&2; exit 3 ;;
      esac
      SINCE="$2"; shift 2 ;;
    --until)
      case "$2" in
        [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
        *) echo "scan-repo: --until requires YYYY-MM-DD, got: $2" >&2; exit 3 ;;
      esac
      UNTIL="$2"; shift 2 ;;
    --from-issue)
      case "$2" in
        ''|*[!0-9]*) echo "scan-repo: --from-issue requires an integer, got: $2" >&2; exit 3 ;;
      esac
      FROM_ISSUE="$2"; shift 2 ;;
    --to-issue)
      case "$2" in
        ''|*[!0-9]*) echo "scan-repo: --to-issue requires an integer, got: $2" >&2; exit 3 ;;
      esac
      TO_ISSUE="$2"; shift 2 ;;
    --limit) LIMIT="$2"; shift 2 ;;
    --include-private) INCLUDE_PRIVATE=1; shift ;;
    --manifest-out) MANIFEST_OUT="$2"; shift 2 ;;
    --manifest-path) MANIFEST_PATH="$2"; shift 2 ;;
    --confirm-ids) CONFIRM_IDS="$2"; shift 2 ;;
    --canary-skip) CANARY_SKIP=1; shift ;;
    -h|--help)
      sed -n '2,15p' "$0"; exit 0 ;;
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

# Always resolve scanner relative to this script so tests in worktrees find
# the worktree's scanner rather than whatever AGENTS_CONFIG_DIR points to.
CFG_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
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

# --apply mode: validate required flags
if [ "$APPLY" = "1" ]; then
  if [ -z "$MANIFEST_PATH" ] || [ -z "$CONFIRM_IDS" ]; then
    echo "scan-repo: --apply requires --manifest-path FILE --confirm-ids ID1[,ID2,...]" >&2
    exit 3
  fi
fi

# Manifest output helper: writes a JSONL line to stdout or --manifest-out file
emit_manifest_line() {
  if [ -n "$MANIFEST_OUT" ]; then
    printf '%s\n' "$1" >> "$MANIFEST_OUT"
  else
    printf '%s\n' "$1"
  fi
}

# Human-readable progress goes to stderr only
echo "scan-repo: scanning $REPO (mode=$([ "$APPLY" = "1" ] && echo apply || echo dry-run))" >&2

# Capture standing instruction from CLI (single invocation per batch — SSOT)
INSTRUCTION="$(node "$SCANNER" --print-standing-instruction)"

# Build jq filter predicates for range filtering (client-side)
NUM_FILTER="true"
UNTIL_FILTER="true"
if [ -n "$FROM_ISSUE" ] && [ -n "$TO_ISSUE" ]; then
  NUM_FILTER=".number >= ${FROM_ISSUE} and .number <= ${TO_ISSUE}"
elif [ -n "$FROM_ISSUE" ]; then
  NUM_FILTER=".number >= ${FROM_ISSUE}"
elif [ -n "$TO_ISSUE" ]; then
  NUM_FILTER=".number <= ${TO_ISSUE}"
fi
if [ -n "$UNTIL" ]; then
  UNTIL_FILTER=".updated_at <= \"${UNTIL}T23:59:59Z\""
fi

# Fetch issues (excluding PRs). Apply --since filter server-side if given.
ISSUE_QUERY="repos/${REPO}/issues?state=all&per_page=100"
if [ -n "$SINCE" ]; then
  ISSUE_QUERY="${ISSUE_QUERY}&since=${SINCE}T00:00:00Z"
fi

# --apply mode: read manifest and apply redactions
if [ "$APPLY" = "1" ]; then
  # Build id→record map from manifest
  declare -A MANIFEST_SHA
  declare -A MANIFEST_SOURCE
  while IFS= read -r mline; do
    [ -z "$mline" ] && continue
    mtype="$(jq -r '.type // ""' <<< "$mline" 2>/dev/null || true)"
    [ "$mtype" = "preamble" ] && continue
    mid="$(jq -r '.id // ""' <<< "$mline" 2>/dev/null || true)"
    [ -z "$mid" ] && continue
    msha="$(jq -r '.content_sha256 // ""' <<< "$mline" 2>/dev/null || true)"
    msource="$(jq -c '.source // {}' <<< "$mline" 2>/dev/null || true)"
    MANIFEST_SHA["$mid"]="$msha"
    MANIFEST_SOURCE["$mid"]="$msource"
  done < "$MANIFEST_PATH"

  # Parse confirm IDs (comma-separated)
  IFS=',' read -ra CONFIRM_ID_LIST <<< "$CONFIRM_IDS"
  FIRST=1
  for cid in "${CONFIRM_ID_LIST[@]}"; do
    cid="${cid// /}"  # trim spaces
    if [ -z "${MANIFEST_SHA[$cid]+_}" ]; then
      echo "scan-repo: unknown id: $cid" >&2
      exit 3
    fi
    expected_sha="${MANIFEST_SHA[$cid]}"
    csource="${MANIFEST_SOURCE[$cid]}"
    # Re-fetch live body
    ckind="$(jq -r '.kind // ""' <<< "$csource" 2>/dev/null || true)"
    crepo="$(jq -r '.repo // ""' <<< "$csource" 2>/dev/null || true)"
    cissue="$(jq -r '.issue // ""' <<< "$csource" 2>/dev/null || true)"
    ccomment="$(jq -r '.comment_id // ""' <<< "$csource" 2>/dev/null || true)"
    if [ "$ckind" = "issue-body" ] && [ -n "$cissue" ] && [ -n "$crepo" ]; then
      live_body="$(gh api "repos/${crepo}/issues/${cissue}" --jq '.body // ""' 2>/dev/null || true)"
    elif [ "$ckind" = "issue-comment" ] && [ -n "$ccomment" ] && [ -n "$crepo" ]; then
      live_body="$(gh api "repos/${crepo}/issues/comments/${ccomment}" --jq '.body // ""' 2>/dev/null || true)"
    else
      echo "scan-repo: cannot re-fetch source for id: $cid" >&2
      exit 3
    fi
    live_sha="$(printf '%s' "$live_body" | node -e "
const chunks=[]; process.stdin.on('data',c=>chunks.push(c)); process.stdin.on('end',()=>{
  const crypto=require('crypto');
  process.stdout.write(crypto.createHash('sha256').update(Buffer.concat(chunks)).digest('hex'));
});")"
    if [ "$live_sha" != "$expected_sha" ]; then
      echo "scan-repo: STALE: $cid (content changed since scan)" >&2
      exit 5
    fi
    # Apply redaction
    if [ "$ckind" = "issue-body" ]; then
      gh issue edit "$cissue" --repo "$crepo" --body "[redacted by content-scan]" >/dev/null
      echo "  redacted: $cid"
    elif [ "$ckind" = "issue-comment" ]; then
      gh api -X PATCH "repos/${crepo}/issues/comments/${ccomment}" -f body="[redacted by content-scan]" >/dev/null
      echo "  redacted: $cid"
    fi
    # Canary: after first item, stop unless --canary-skip
    if [ "$FIRST" = "1" ] && [ "${#CONFIRM_ID_LIST[@]}" -gt 1 ] && [ "$CANARY_SKIP" = "0" ]; then
      echo "scan-repo: canary stop after first redaction (re-invoke with --canary-skip for remaining)"
      exit 0
    fi
    FIRST=0
  done
  exit 0
fi

# Dry-run mode: emit JSONL manifest

# Init --manifest-out file (truncate)
if [ -n "$MANIFEST_OUT" ]; then
  : > "$MANIFEST_OUT"
fi

# Preamble record (first JSONL line)
GENERATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"
PREAMBLE="$(jq -nc \
  --arg instruction "$INSTRUCTION" \
  --arg repo "$REPO" \
  --arg since "${SINCE:-}" \
  --arg until "${UNTIL:-}" \
  --argjson from_issue "$([ -n "$FROM_ISSUE" ] && printf '%s' "$FROM_ISSUE" || printf 'null')" \
  --argjson to_issue "$([ -n "$TO_ISSUE" ] && printf '%s' "$TO_ISSUE" || printf 'null')" \
  --arg generated_at "$GENERATED_AT" \
  '{
    type: "preamble",
    schema: "scan-offensive/skill-manifest/v1",
    instruction: $instruction,
    scan: {
      repo: $repo,
      since: (if $since == "" then null else $since end),
      until: (if $until == "" then null else $until end),
      from_issue: $from_issue,
      to_issue: $to_issue,
      generated_at: $generated_at
    }
  }')"
emit_manifest_line "$PREAMBLE"

# Human-readable banner to stderr
echo "# scan-offensive/skill-manifest/v1 — $GENERATED_AT — scanning $REPO" >&2

ISSUE_COUNT=0

ISSUES_JSON="$(gh api "$ISSUE_QUERY" --paginate | jq -c "[.[] | select(.pull_request == null) | select(${NUM_FILTER}) | select(${UNTIL_FILTER})] | .[]")"

while IFS= read -r obj; do
  [ -z "$obj" ] && continue
  ISSUE_COUNT=$((ISSUE_COUNT + 1))
  if [ "$LIMIT" -gt 0 ] && [ "$ISSUE_COUNT" -gt "$LIMIT" ]; then
    break
  fi

  N="$(jq -r '.number' <<< "$obj")"
  BODY="$(jq -r '.body // ""' <<< "$obj")"

  # Build source JSON for issue body
  source_json="$(jq -nc \
    --arg k "issue-body" \
    --arg r "$REPO" \
    --argjson i "$N" \
    '{kind:$k, repo:$r, issue:$i, comment_id:null, url:("https://github.com/"+$r+"/issues/"+($i|tostring))}')"

  label="issue#${N}/body"
  MANIFEST_LINE="$(printf '%s' "$BODY" | SCAN_OFFENSIVE_SOURCE_JSON="$source_json" node $SCANNER --stdin --skill-mode "$label")"
  emit_manifest_line "$MANIFEST_LINE"

  # Scan comments
  COMMENTS_JSON="$(gh api "repos/${REPO}/issues/${N}/comments?per_page=100" --paginate | jq -c '.[]' 2>/dev/null || true)"
  while IFS= read -r cobj; do
    [ -z "$cobj" ] && continue
    CID="$(jq -r '.id' <<< "$cobj")"
    CBODY="$(jq -r '.body // ""' <<< "$cobj")"
    source_json="$(jq -nc \
      --arg k "issue-comment" \
      --arg r "$REPO" \
      --argjson i "$N" \
      --argjson c "$CID" \
      '{kind:$k, repo:$r, issue:$i, comment_id:$c, url:("https://github.com/"+$r+"/issues/"+($i|tostring)+"#issuecomment-"+($c|tostring))}')"
    clabel="issue#${N}/comment#${CID}"
    MANIFEST_LINE="$(printf '%s' "$CBODY" | SCAN_OFFENSIVE_SOURCE_JSON="$source_json" node $SCANNER --stdin --skill-mode "$clabel")"
    emit_manifest_line "$MANIFEST_LINE"
  done <<< "$COMMENTS_JSON"
done <<< "$ISSUES_JSON"

echo "scan-repo: done. issues scanned=$ISSUE_COUNT" >&2
