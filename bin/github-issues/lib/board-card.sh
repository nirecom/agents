# board-card.sh — shared helpers for Projects v2 board card lookups.
#
# Contract:
#   resolve_owner_repo            -> echoes "owner/repo"
#   resolve_item_id <issue-number> -> echoes Projects v2 item id (empty if not on board)
#     REQUIRES: caller has set shell variable PROJECT_ID (GraphQL project node id)
#     BEFORE invocation. resolve_item_id does NOT accept it as an argument
#     (preserves existing wip-state.sh call sites unchanged).
#
# This file is sourced (not executed). It has no env-var dependency of its own.

# Resolve owner/repo from the current working directory (gh uses cwd-based
# repo resolution for all `gh issue`/`gh repo` calls). Return non-zero on
# failure so callers can propagate read errors distinctly from empty results.
resolve_owner_repo() {
    local out
    if ! out=$(gh repo view --json owner,name --jq '.owner.login + "/" + .name' 2>/dev/null); then
        return 1
    fi
    out=$(printf '%s' "$out" | tr -d '\r' | head -1)
    [[ -z "$out" ]] && return 1
    printf '%s' "$out"
}

# Returns the ProjectV2Item id for issue <N> in our project. Distinguishes:
#   - gh failure → return 1 (caller may exit 1)
#   - gh success, no membership → return 0 with empty stdout
resolve_item_id() {
    local n="$1"
    local ownerrepo
    if ! ownerrepo=$(resolve_owner_repo); then
        return 1
    fi
    local owner_part="${ownerrepo%/*}"
    local name_part="${ownerrepo#*/}"
    local out
    if ! out=$(gh api graphql \
            -F owner="$owner_part" \
            -F repo="$name_part" \
            -F number="$n" \
            --jq ".data.repository.issue.projectItems.nodes[]? | select(.project.id == \"$PROJECT_ID\") | .id" \
            -f query='
                query($owner: String!, $repo: String!, $number: Int!) {
                  repository(owner: $owner, name: $repo) {
                    issue(number: $number) {
                      projectItems(first: 50) {
                        nodes { id project { id } }
                      }
                    }
                  }
                }' 2>/dev/null); then
        return 1
    fi
    printf '%s' "$out" | head -1
    return 0
}
