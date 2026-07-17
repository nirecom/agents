#!/usr/bin/env bash
# sourceable helper — do NOT add set -e (sourced by set -euo pipefail callers)
# Exposes: link_project_to_repo <project_node_id> <owner> <repo>
# Returns: 0 on success, 1 on failure (prints WARN to stderr — canonical WARN producer)

link_project_to_repo() {
  local project_node_id="${1:?project_node_id required}"
  local owner="${2:?owner required}"
  local repo="${3:?repo required}"

  local repo_node_id
  repo_node_id=$(gh api "repos/${owner}/${repo}" --jq .node_id 2>/dev/null | tr -d '\r') || {
    echo "WARN: failed to resolve node_id for ${owner}/${repo}" >&2
    return 1
  }
  [ -n "$repo_node_id" ] || {
    echo "WARN: empty node_id for ${owner}/${repo}" >&2
    return 1
  }

  gh api graphql \
    -f query='mutation($p:ID!,$r:ID!){linkProjectV2ToRepository(input:{projectId:$p,repositoryId:$r}){repository{id}}}' \
    -f p="$project_node_id" \
    -f r="$repo_node_id" >/dev/null || {
      echo "WARN: linkProjectV2ToRepository failed for project=$project_node_id repo=${owner}/${repo}. Re-run: backfill-project-link.sh --project-node-id $project_node_id --owner $owner --repo $repo" >&2
      return 1
    }
  return 0
}
