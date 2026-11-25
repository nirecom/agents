#!/usr/bin/env bash
# list-missing.sh [--repo <owner/repo>] — open issues with no card on the repo's resolved Projects v2 board.
# Prints one issue number per line (feeds `backfill-board-cards.sh --from-file -`). The board comes from
# resolve-project.sh; the open issues are walked 100 per page with their first 20 projectItems. An issue
# whose first 20 items miss the board but have more is "unknown": reported on stderr, never listed.
# Exit: 0 listed (possibly nothing); 1 board not resolved or an issue page failed; 2 usage.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../../lib"
# shellcheck source=../../lib/board-card.sh
. "$LIB_DIR/board-card.sh"
# shellcheck source=../../lib/resolve-project.sh
. "$LIB_DIR/resolve-project.sh"

OWNER_REPO=""
case "${1:-}" in
    --repo) OWNER_REPO="${2:-}" ;;
    "") ;;
    *) echo "usage: list-missing.sh [--repo <owner/repo>]" >&2; exit 2 ;;
esac
if [[ -z "$OWNER_REPO" ]]; then
    OWNER_REPO="$(resolve_owner_repo)" || { echo "error: list-missing: cannot resolve owner/repo from origin" >&2; exit 1; }
fi

if ! resolve_project_for_repo --repo "$OWNER_REPO"; then
    echo "error: list-missing: no board for $OWNER_REPO ($RESOLVED_STATUS)" >&2
    exit 1
fi
PID="$RESOLVED_PROJECT_ID"
if [[ ! "$PID" =~ ^[A-Za-z0-9_-]+$ ]]; then
    echo "error: list-missing: unexpected project id '$PID'" >&2
    exit 1
fi

# shellcheck disable=SC2016  # $owner/$repo/$after are GraphQL variables, not shell expansions.
QUERY='query($owner: String!, $repo: String!, $after: String) {
  repository(owner: $owner, name: $repo) {
    issues(first: 100, after: $after, states: [OPEN]) {
      nodes { number projectItems(first: 20) { nodes { project { id } } pageInfo { hasNextPage } } }
      pageInfo { hasNextPage endCursor }
    }
  }
}'
# One line per issue ("issue <n> <on-board> <more-items>"), then "page <hasNextPage> <endCursor>".
JQ='(.data.repository.issues.nodes[] | "issue \(.number) \(any(.projectItems.nodes[]; .project.id == "'"$PID"'")) \(.projectItems.pageInfo.hasNextPage)"), (.data.repository.issues.pageInfo | "page \(.hasNextPage) \(.endCursor // "")")'

cursor="" unknown=0 guard=0
while [[ "$guard" -lt 1000 ]]; do
    guard=$((guard + 1))
    after_args=()
    [[ -n "$cursor" ]] && after_args=(-F after="$cursor")
    if ! out="$(gh api graphql -F owner="${OWNER_REPO%/*}" -F repo="${OWNER_REPO#*/}" \
            ${after_args[@]+"${after_args[@]}"} --jq "$JQ" -f query="$QUERY")"; then
        echo "error: list-missing: issue page query failed for $OWNER_REPO" >&2
        exit 1
    fi
    more=false cursor=""
    while read -r kind a b c; do
        case "$kind" in
            issue)
                [[ "$b" == "true" ]] && continue
                if [[ "$c" == "true" ]]; then
                    echo "[list-missing] unknown #$a: more than 20 project items, the board may be among the rest" >&2
                    unknown=$((unknown + 1))
                else
                    printf '%s\n' "$a"
                fi
                ;;
            page) more="$a" cursor="$b" ;;
        esac
    done <<<"${out//$'\r'/}"
    [[ "$more" == "true" && -n "$cursor" ]] || break
done

if [[ "$unknown" -gt 0 ]]; then
    echo "[list-missing] $unknown issue(s) unknown (listed above): add them to the --from-file list by hand; ensure-board-card skips an issue already on the board" >&2
fi
exit 0
