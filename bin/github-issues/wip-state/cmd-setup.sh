#!/bin/bash
# bin/github-issues/wip-state/cmd-setup.sh — Verb: setup.
# Sourced by ../wip-state.sh; not executable standalone.
# Globals consumed: PROJECT_ID, OWNER, PROJECT_NUM, AGENTS_CONFIG_DIR.
# Functions consumed: ensure_resolved.

# ---------------------------------------------------------------------------
# Verb: setup
#   One-shot ID discovery via gh api graphql. Append to $AGENTS_CONFIG_DIR/.env
#   (skips lines already present). Field names ("Status", "session-fingerprint")
#   are referenced HERE ONLY — runtime check/set/clear use field IDs.
# ---------------------------------------------------------------------------
cmd_setup() {
    if ! gh auth status 2>&1 | grep -q "'project'"; then
        echo "Error: gh token lacks 'project' scope — run: gh auth refresh -s project" >&2
        exit 1
    fi

    # setup is a configuration step — fail loudly when no Projects v2 is linked
    # so the user can correct the situation before any IDs are appended to .env.
    if ! ensure_resolved; then
        echo "Error: cannot resolve Projects v2 config for this repo — no linked Projects v2 found via 'gh repo view'" >&2
        echo "Hint: link a Projects v2 to the repo first (Settings → Projects), or set ISSUE_CREATE_PROJECT_ID/OWNER/PROJECT_NUM manually" >&2
        exit 1
    fi

    local query='query($projectId: ID!) {
  node(id: $projectId) {
    ... on ProjectV2 {
      fields(first: 50) {
        nodes {
          __typename
          ... on ProjectV2FieldCommon { id name }
          ... on ProjectV2SingleSelectField {
            id name
            options { id name }
          }
        }
      }
    }
  }
}'

    local status_field_id todo_opt inprog_opt done_opt fp_field_id
    status_field_id=$(gh api graphql -F projectId="$PROJECT_ID" \
        --jq '[.data.node.fields.nodes[]? | select(.__typename == "ProjectV2SingleSelectField" and .name == "Status") | .id] | first // ""' \
        -f query="$query" 2>/dev/null) || status_field_id=""
    todo_opt=$(gh api graphql -F projectId="$PROJECT_ID" \
        --jq '[.data.node.fields.nodes[]? | select(.name == "Status") | .options[]? | select(.name == "Todo") | .id] | first // ""' \
        -f query="$query" 2>/dev/null) || todo_opt=""
    inprog_opt=$(gh api graphql -F projectId="$PROJECT_ID" \
        --jq '[.data.node.fields.nodes[]? | select(.name == "Status") | .options[]? | select(.name == "In Progress") | .id] | first // ""' \
        -f query="$query" 2>/dev/null) || inprog_opt=""
    done_opt=$(gh api graphql -F projectId="$PROJECT_ID" \
        --jq '[.data.node.fields.nodes[]? | select(.name == "Status") | .options[]? | select(.name == "Done") | .id] | first // ""' \
        -f query="$query" 2>/dev/null) || done_opt=""
    fp_field_id=$(gh api graphql -F projectId="$PROJECT_ID" \
        --jq '[.data.node.fields.nodes[]? | select(.name == "session-fingerprint") | .id] | first // ""' \
        -f query="$query" 2>/dev/null) || fp_field_id=""

    ensure_field() {
        local name="$1" dtype="$2" current="$3" auto="$4" hint="${5:-}"
        case "$name" in *[!a-zA-Z0-9\ _-]*) echo "Error: field name '$name' contains invalid characters" >&2; exit 1 ;; esac
        if [ -n "$current" ]; then
            ENSURE_FIELD_RESULT="$current"
            return 0
        fi
        if [ "$auto" != "1" ]; then
            if [ -n "$hint" ]; then
                echo "Error: '$name' field not found in project — $hint" >&2
            else
                echo "Error: '$name' field not found in project" >&2
            fi
            exit 1
        fi
        local mut_id
        mut_id=$(gh api graphql \
            -F projectId="$PROJECT_ID" \
            -F name="$name" \
            -F dataType="$dtype" \
            --jq '.data.createProjectV2Field.projectV2Field.id' \
            -f query='mutation($projectId:ID!,$name:String!,$dataType:ProjectV2CustomFieldType!){createProjectV2Field(input:{projectId:$projectId,name:$name,dataType:$dataType}){projectV2Field{...on ProjectV2FieldCommon{id name}}}}' \
            2>/dev/null) || mut_id=""
        mut_id=$(printf '%s' "$mut_id" | tr -d '\r' | head -1)
        local rediscovered
        rediscovered=$(gh api graphql -F projectId="$PROJECT_ID" \
            --jq "[.data.node.fields.nodes[]? | select(.name == \"$name\") | .id] | first // \"\"" \
            -f query="$query" 2>/dev/null) || rediscovered=""
        rediscovered=$(printf '%s' "$rediscovered" | tr -d '\r' | head -1)
        if [ -z "$rediscovered" ] && [ -n "$mut_id" ]; then
            rediscovered="$mut_id"
        fi
        if [ -z "$rediscovered" ]; then
            echo "Error: failed to auto-create '$name' field (createProjectV2Field mutation produced no ID)" >&2
            exit 1
        fi
        ENSURE_FIELD_RESULT="$rediscovered"
    }

    ensure_field "Status" SINGLE_SELECT "$status_field_id" 0 \
        "create it in the Projects v2 UI (options: Todo / In Progress / Done)"
    status_field_id="$ENSURE_FIELD_RESULT"
    ensure_field "session-fingerprint" TEXT "$fp_field_id" 1
    fp_field_id="$ENSURE_FIELD_RESULT"

    local envfile="$AGENTS_CONFIG_DIR/.env"
    touch "$envfile" 2>/dev/null || true

    append_if_missing() {
        local key="$1" val="$2"
        [ -z "$val" ] && return 0
        if grep -qE "^${key}=" "$envfile" 2>/dev/null; then
            return 0
        fi
        printf '%s=%s\n' "$key" "$val" >> "$envfile"
    }

    append_if_missing WIP_STATE_STATUS_FIELD_ID       "$status_field_id"
    append_if_missing WIP_STATE_TODO_OPTION_ID        "$todo_opt"
    append_if_missing WIP_STATE_IN_PROGRESS_OPTION_ID "$inprog_opt"
    append_if_missing WIP_STATE_DONE_OPTION_ID        "$done_opt"
    append_if_missing WIP_STATE_FINGERPRINT_FIELD_ID  "$fp_field_id"

    cat <<EOF
WIP_STATE_STATUS_FIELD_ID=$status_field_id
WIP_STATE_TODO_OPTION_ID=$todo_opt
WIP_STATE_IN_PROGRESS_OPTION_ID=$inprog_opt
WIP_STATE_DONE_OPTION_ID=$done_opt
WIP_STATE_FINGERPRINT_FIELD_ID=$fp_field_id
EOF
    exit 0
}
