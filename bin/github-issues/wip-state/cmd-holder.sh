#!/bin/bash
# bin/github-issues/wip-state/cmd-holder.sh — Verb: holder <N> (#2668).
# Sourced by ../wip-state.sh; not executable standalone. Read-only; needs no session id.
# Prints the raw WIP holder session id of an In Progress item (empty when there is none).
# Exit 1 on a gh read failure (stdout empty). Query shape shared with cmd-check.sh.

cmd_holder() {
    local n="$1"
    validate_n "$n"
    ensure_wip_field_ids
    preflight_field_ids

    # No resolvable project means no board, so no holder.
    if ! ensure_resolved; then
        exit 0
    fi

    local item_id
    if ! item_id=$(resolve_item_id "$n"); then
        echo "warn: gh api graphql failed for #$n holder" >&2
        exit 1
    fi
    [ -z "$item_id" ] && exit 0

    local query
    query='query($itemId: ID!) {
  node(id: $itemId) {
    ... on ProjectV2Item {
      fieldValues(first: 50) {
        nodes {
          __typename
          ... on ProjectV2ItemFieldSingleSelectValue {
            name
            field { ... on ProjectV2SingleSelectField { id } }
          }
          ... on ProjectV2ItemFieldTextValue {
            text
            field { ... on ProjectV2FieldCommon { id } }
          }
        }
      }
    }
  }
}'

    local status
    if ! status=$(gh api graphql \
            -F itemId="$item_id" \
            --jq "[.data.node.fieldValues.nodes[]? | select(.field.id == \"$WIP_STATE_STATUS_FIELD_ID\") | .name] | first // \"\"" \
            -f query="$query" 2>/dev/null); then
        echo "warn: gh api graphql failed for #$n status read" >&2
        exit 1
    fi
    if [ "$status" != "In Progress" ] || [ -z "${WIP_STATE_SESSION_ID_FIELD_ID:-}" ]; then
        exit 0
    fi

    local holder
    if ! holder=$(gh api graphql \
            -F itemId="$item_id" \
            --jq "[.data.node.fieldValues.nodes[]? | select(.field.id == \"$WIP_STATE_SESSION_ID_FIELD_ID\") | .text] | first // \"\"" \
            -f query="$query" 2>/dev/null); then
        echo "warn: gh api graphql failed for #$n session-id read" >&2
        exit 1
    fi
    holder=$(printf '%s' "$holder" | tr -d '\r' | head -1)
    [ -n "$holder" ] && printf '%s\n' "$holder"
    exit 0
}
