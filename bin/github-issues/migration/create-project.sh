#!/usr/bin/env bash
# Create (or reuse) a Projects v2 board for the target repo and ensure the
# "Content Date" DATE field exists. Persists project number, node id, and field
# ids into .migration-state.json for downstream scripts.
#
# Usage:
#   bin/github-issues/migration/create-project.sh <repo_dir> [--dry-run]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/state.sh"

REPO_DIR="${1:?usage: create-project.sh <repo_dir> [--dry-run]}"
DRY_RUN=0
shift
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done
REPO_DIR="$(cd "$REPO_DIR" && pwd)"

if [ "$DRY_RUN" -eq 1 ]; then
  echo "[dry-run] would create Projects v2 board for target repo"
  exit 0
fi

state_load "$REPO_DIR"

OWNER=$(cd "$REPO_DIR" && gh repo view --json owner --jq .owner.login)
REPO_NAME=$(cd "$REPO_DIR" && gh repo view --json name --jq .name)

gh auth status --hostname github.com 2>&1 | grep -q 'project' || {
  echo "ERROR: gh missing 'project' scope. Run: gh auth refresh -s project" >&2
  exit 1
}

existing_num=$(gh project list --owner "$OWNER" --format json \
  | jq -r --arg t "$REPO_NAME migration" '.projects[] | select(.title==$t) | .number // empty' \
  | head -1)

if [ -n "$existing_num" ]; then
  echo "Using existing project #$existing_num"
  field_ids_json=$(gh project field-list "$existing_num" --owner "$OWNER" --format json \
    | jq '[.fields[] | {key:.name,value:.id}] | from_entries')
  if ! echo "$field_ids_json" | jq -e '."Content Date"' >/dev/null 2>&1; then
    new_fid=$(gh project field-create "$existing_num" --owner "$OWNER" \
      --name "Content Date" --data-type DATE --format json | jq -r '.id')
    field_ids_json=$(echo "$field_ids_json" | jq --arg id "$new_fid" '."Content Date" = $id')
  fi
  project_num="$existing_num"
  node_id=$(gh project view "$existing_num" --owner "$OWNER" --format json | jq -r '.id')
else
  owner_id=$(gh api graphql -f query="{viewer{id}}" --jq '.data.viewer.id' 2>/dev/null || \
             gh api graphql -f query="{user(login:\"$OWNER\"){id}}" --jq '.data.user.id' 2>/dev/null || \
             gh api graphql -f query="{organization(login:\"$OWNER\"){id}}" --jq '.data.organization.id')
  result=$(gh api graphql \
    -f query='mutation($o:ID!,$t:String!){createProjectV2(input:{ownerId:$o,title:$t}){projectV2{id number}}}' \
    -f o="$owner_id" -f t="$REPO_NAME migration")
  project_num=$(echo "$result" | jq -r '.data.createProjectV2.projectV2.number')
  node_id=$(echo "$result" | jq -r '.data.createProjectV2.projectV2.id')
  field_result=$(gh api graphql \
    -f query='mutation($p:ID!){createProjectV2Field(input:{projectId:$p,dataType:DATE,name:"Content Date"}){projectV2Field{... on ProjectV2Field{id}}}}' \
    -f p="$node_id")
  new_fid=$(echo "$field_result" | jq -r '.data.createProjectV2Field.projectV2Field.id')
  field_ids_json=$(jq -n --arg id "$new_fid" '{"Content Date":$id}')
fi

state_set_project "$project_num" "$node_id" "$field_ids_json"
echo "Project #$project_num created/found. Field IDs saved to state."
