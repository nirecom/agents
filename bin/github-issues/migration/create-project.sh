#!/usr/bin/env bash
# Reuse the target repo's only open linked Projects v2 board (resolve-project.sh, never by title), or create
# one titled by project_board_title and link it, then ensure the "Content Date" DATE field. Persists the
# project number, node id, and field ids into .migration-state.json for downstream scripts.
# A new board is linked before state is written; a failed link deletes it (board-create.sh) and exits 1.
# An ambiguous or failed board lookup exits 1 before creating anything.
#
# Usage:
#   bin/github-issues/migration/create-project.sh <repo_dir> [--dry-run]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/state.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/link-project.sh"
# shellcheck source=../lib/resolve-project.sh
source "$SCRIPT_DIR/../lib/resolve-project.sh"
# shellcheck source=../lib/board-create.sh
source "$SCRIPT_DIR/../lib/board-create.sh"

TARGET_CHECKOUT_ROOT="${1:?usage: create-project.sh <repo_dir> [--dry-run]}"
DRY_RUN=0
shift
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done
TARGET_CHECKOUT_ROOT="$(cd "$TARGET_CHECKOUT_ROOT" && pwd)"

# shellcheck source=../lib/host-adapter.sh
source "$SCRIPT_DIR/../lib/host-adapter.sh"
if [ "$(hia_host "$TARGET_CHECKOUT_ROOT")" = gitlab ]; then
  echo "GitLab origin: no Projects v2 board to create — skipped (the issue board is /migrate-tracker's)"
  exit 0
fi

if [ "$DRY_RUN" -eq 1 ]; then
  echo "[dry-run] would create Projects v2 board for target repo"
  exit 0
fi

state_load "$TARGET_CHECKOUT_ROOT"

OWNER=$(cd "$TARGET_CHECKOUT_ROOT" && gh repo view --json owner --jq .owner.login)
REPO_NAME=$(cd "$TARGET_CHECKOUT_ROOT" && gh repo view --json name --jq .name)

gh auth status --hostname github.com 2>&1 | grep -q 'project' || {
  echo "ERROR: gh missing 'project' scope. Run: gh auth refresh -s project" >&2
  exit 1
}

resolve_rc=0
resolve_project_for_repo --repo "$OWNER/$REPO_NAME" --no-cache-read --no-cache-write || resolve_rc=$?

case "${RESOLVED_STATUS:-fetch-failed}/$resolve_rc" in
  resolved/0)
    project_num="$RESOLVED_PROJECT_NUM"
    node_id="$RESOLVED_PROJECT_ID"
    echo "Using the linked project #$project_num"
    field_ids_json=$(gh project field-list "$project_num" --owner "$RESOLVED_OWNER" --format json \
      | jq '[.fields[] | {key:.name,value:.id}] | from_entries')
    if ! echo "$field_ids_json" | jq -e '."Content Date"' >/dev/null 2>&1; then
      new_fid=$(gh project field-create "$project_num" --owner "$RESOLVED_OWNER" \
        --name "Content Date" --data-type DATE --format json | jq_text '.id')
      field_ids_json=$(echo "$field_ids_json" | jq --arg id "$new_fid" '."Content Date" = $id')
    fi
    ;;
  no-link/*)
    owner_id=$(gh api graphql -f query="{viewer{id}}" --jq '.data.viewer.id' 2>/dev/null || \
               gh api graphql -f query="{user(login:\"$OWNER\"){id}}" --jq '.data.user.id' 2>/dev/null || \
               gh api graphql -f query="{organization(login:\"$OWNER\"){id}}" --jq '.data.organization.id')
    result=$(gh api graphql \
      -f query='mutation($o:ID!,$t:String!){createProjectV2(input:{ownerId:$o,title:$t}){projectV2{id number owner{... on User{login} ... on Organization{login}}}}}' \
      -f o="$owner_id" -f t="$(project_board_title "$OWNER/$REPO_NAME")")
    project_num=$(echo "$result" | jq_text '.data.createProjectV2.projectV2.number')
    node_id=$(echo "$result" | jq_text '.data.createProjectV2.projectV2.id')
    project_owner=$(echo "$result" | jq_text '.data.createProjectV2.projectV2.owner.login // empty')
    if ! link_project_to_repo "$node_id" "$OWNER" "$REPO_NAME"; then
      project_board_discard_unlinked "${project_owner:-$OWNER}" "$project_num" "$OWNER/$REPO_NAME" || true
      exit 1
    fi
    field_result=$(gh api graphql \
      -f query='mutation($p:ID!){createProjectV2Field(input:{projectId:$p,dataType:DATE,name:"Content Date"}){projectV2Field{... on ProjectV2Field{id}}}}' \
      -f p="$node_id")
    new_fid=$(echo "$field_result" | jq_text '.data.createProjectV2Field.projectV2Field.id')
    field_ids_json=$(jq -n --arg id "$new_fid" '{"Content Date":$id}')
    ;;
  *)
    echo "ERROR: no board for ${OWNER}/${REPO_NAME}: the linked-board lookup is ${RESOLVED_STATUS:-fetch-failed}${RESOLVED_CANDIDATES:+ (${RESOLVED_CANDIDATES})}; nothing created" >&2
    exit 1
    ;;
esac

state_set_project "$project_num" "$node_id" "$field_ids_json"
state_set_repo_linked true

echo "Project #$project_num created/found. Field IDs saved to state."
