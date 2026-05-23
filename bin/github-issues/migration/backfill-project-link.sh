#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/link-project.sh"

PROJECT_NODE_ID=""; OWNER=""; REPO=""
while [ $# -gt 0 ]; do
  case "$1" in
    --project-node-id) PROJECT_NODE_ID="$2"; shift 2 ;;
    --owner)           OWNER="$2"; shift 2 ;;
    --repo)            REPO="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: backfill-project-link.sh --project-node-id <PVT_...> --owner <owner> --repo <name>" >&2
      exit 0 ;;
    *) echo "ERROR: unknown arg: $1" >&2; exit 2 ;;
  esac
done

[ -n "$PROJECT_NODE_ID" ] || { echo "ERROR: --project-node-id required" >&2; exit 2; }
[ -n "$OWNER" ]           || { echo "ERROR: --owner required" >&2; exit 2; }
[ -n "$REPO" ]            || { echo "ERROR: --repo required" >&2; exit 2; }

link_project_to_repo "$PROJECT_NODE_ID" "$OWNER" "$REPO"
echo "Linked project $PROJECT_NODE_ID to ${OWNER}/${REPO}"
