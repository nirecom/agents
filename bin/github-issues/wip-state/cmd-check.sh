#!/bin/bash
# bin/github-issues/wip-state/cmd-check.sh — Verb: check <N>.
# Sourced by ../wip-state.sh; not executable standalone.
# Globals consumed: PROJECT_ID, WIP_STATE_* (env).
# Functions consumed: validate_n, preflight_field_ids, ensure_resolved,
#   effective_session_id, resolve_item_id. Value compared: the raw session id.

# ---------------------------------------------------------------------------
# Verb: check <N>
#   Prints same|other|none on stdout. Exit 1 on gh read failure (stdout empty).
#   Filters by field IDs (env-driven); field names are not referenced.
# ---------------------------------------------------------------------------
cmd_check() {
    local n="$1"
    validate_n "$n"
    ensure_wip_field_ids
    preflight_field_ids

    # check is non-fatal: a missing project resolves to "none" (no signal).
    if ! ensure_resolved; then
        echo none
        exit 0
    fi

    local sid
    if ! sid=$(effective_session_id); then
        exit 2
    fi

    local item_id
    if ! item_id=$(resolve_item_id "$n"); then
        echo "warn: gh api graphql failed for #$n check" >&2
        exit 1
    fi
    if [ -z "$item_id" ]; then
        echo none
        exit 0
    fi

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

    if [ "$status" != "In Progress" ]; then
        echo none
        exit 0
    fi

    # In Progress without a session-id field: the holder cannot be shown to be us → other.
    # Never creates or renames the field (only `set` recovers it).
    if [ -z "${WIP_STATE_SESSION_ID_FIELD_ID:-}" ]; then
        echo other
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
    if [ -n "$holder" ] && [ "$holder" = "$sid" ]; then
        echo same
    else
        echo other
    fi
    exit 0
}
