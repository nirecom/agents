#!/bin/bash
# bin/github-issues/wip-state.sh — WIP signaling for issue #N via Projects v2.
#
# Verbs:
#   set <N>:   write fingerprint THEN Status=In Progress; then write lock file.
#   check <N>: print same|other|none on stdout.
#   clear <N>: Status=Done + clear fingerprint + delete lock (idempotent).
#   setup:     one-shot field/option ID discovery; append to $AGENTS_CONFIG_DIR/.env.
#
# Fingerprint: sha256(session_id + ":" + N)[:8]. Issue-salted. Collision risk
# for N parallel sessions ≈ N²/2^33 (N=1000: <0.001%). Practical N=1–3.
#
# GraphQL usage: writes via `gh project item-edit` only (no mutations).
# Reads use `gh api graphql` queries because `gh project item-list` does not
# reliably surface both a single-select Status value AND a custom text field
# value for a given item in one call.
#
# Run from inside the target repo's worktree (gh uses cwd-based repo resolution).

set -uo pipefail

CMD="${1:-}"
shift 2>/dev/null || true

usage() {
    sed -n '2,18p' "$0" >&2
    exit "${1:-2}"
}

case "$CMD" in
    set|check|clear|setup) ;;
    -h|--help) usage 0 ;;
    *) echo "Error: usage: wip-state.sh {set|check|clear|setup} [<N>]" >&2; exit 2 ;;
esac

# ---------------------------------------------------------------------------
# .env auto-source. Claude Code's Bash subprocess shell does not propagate
# .env automatically, so a `setup`-written WIP_STATE_*_ID would still be
# invisible to a same-session `set`/`check`/`clear`. Source defensively.
# ---------------------------------------------------------------------------
load_env_file() {
    [ -z "${AGENTS_CONFIG_DIR:-}" ] && return 0
    local envfile="$AGENTS_CONFIG_DIR/.env"
    [ ! -r "$envfile" ] && return 0
    set -a
    # shellcheck disable=SC1090
    . "$envfile" 2>/dev/null || echo "warn: failed to source $envfile (continuing)" >&2
    set +a
    return 0
}
load_env_file

# shellcheck source=../lib/resolve-session-id.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/resolve-session-id.sh"

if [ -z "${AGENTS_CONFIG_DIR:-}" ]; then
    echo "Error: AGENTS_CONFIG_DIR not set" >&2
    exit 2
fi

PROJECT_ID="${ISSUE_CREATE_PROJECT_ID:-PVT_kwHOAMF_jc4BXf9E}"
OWNER="${ISSUE_CREATE_OWNER:-nirecom}"
PROJECT_NUM="${ISSUE_CREATE_PROJECT_NUM:-1}"

# Per-verb preflight: only required env vars actually consumed by the verb.
preflight_field_ids() {
    local missing=()
    case "$CMD" in
        set)
            [ -z "${WIP_STATE_STATUS_FIELD_ID:-}" ]      && missing+=("WIP_STATE_STATUS_FIELD_ID")
            [ -z "${WIP_STATE_IN_PROGRESS_OPTION_ID:-}" ] && missing+=("WIP_STATE_IN_PROGRESS_OPTION_ID")
            [ -z "${WIP_STATE_FINGERPRINT_FIELD_ID:-}" ] && missing+=("WIP_STATE_FINGERPRINT_FIELD_ID")
            ;;
        check)
            [ -z "${WIP_STATE_STATUS_FIELD_ID:-}" ]      && missing+=("WIP_STATE_STATUS_FIELD_ID")
            [ -z "${WIP_STATE_FINGERPRINT_FIELD_ID:-}" ] && missing+=("WIP_STATE_FINGERPRINT_FIELD_ID")
            ;;
        clear)
            [ -z "${WIP_STATE_STATUS_FIELD_ID:-}" ]      && missing+=("WIP_STATE_STATUS_FIELD_ID")
            [ -z "${WIP_STATE_DONE_OPTION_ID:-}" ]       && missing+=("WIP_STATE_DONE_OPTION_ID")
            [ -z "${WIP_STATE_FINGERPRINT_FIELD_ID:-}" ] && missing+=("WIP_STATE_FINGERPRINT_FIELD_ID")
            ;;
    esac
    if [ "${#missing[@]}" -gt 0 ]; then
        echo "Error: missing required env vars for '$CMD': ${missing[*]}" >&2
        echo "Hint: run 'bash $0 setup' to discover and persist them in .env" >&2
        exit 2
    fi
}

validate_n() {
    [[ "${1:-}" =~ ^[0-9]+$ ]] || { echo "Error: issue number must be a positive integer, got: '${1:-}'" >&2; exit 2; }
}

# Resolution order:
#   1. $CLAUDE_ENV_FILE (readable) → grep CLAUDE_SESSION_ID — keeps native CLI
#      behavior where the env file is the canonical source.
#   2. ${CLAUDE_SESSION_ID:-} non-empty → use directly. VS Code Claude Code
#      does not propagate $CLAUDE_ENV_FILE to Bash subprocesses but does
#      propagate $CLAUDE_SESSION_ID, so this fallback restores WIP signaling
#      in that environment (#440). This convention is already established in
#      skills/issue-close-finalize/SKILL.md (--from-session uses the same
#      "file first, env fallback" order).
#   3. JSONL scan: mtime-newest ~/.claude/projects/<encoded-cwd>/*.jsonl basename.
#   4. None available → rc=2.
resolve_session_id() {
    local sid
    if [ -n "${CLAUDE_ENV_FILE:-}" ] && [ -r "${CLAUDE_ENV_FILE}" ]; then
        sid=$(grep -E '^CLAUDE_SESSION_ID=' "$CLAUDE_ENV_FILE" 2>/dev/null \
                | head -1 | cut -d= -f2- | tr -d '\r"' )
        if [ -n "$sid" ]; then
            printf '%s' "$sid"
            return 0
        fi
    fi
    if [ -n "${CLAUDE_SESSION_ID:-}" ]; then
        sid=$(printf '%s' "${CLAUDE_SESSION_ID:-}" | tr -d '\r"')
        if [ -n "$sid" ]; then
            printf '%s' "$sid"
            return 0
        fi
    fi
    # 3. JSONL scan fallback — VS Code Claude Code does not export CLAUDE_SESSION_ID
    #    nor reliably propagate CLAUDE_ENV_FILE to Bash subprocesses (#519).
    if sid=$(resolve_session_id_from_jsonl); then
        sid=$(printf '%s' "$sid" | tr -d '\r"')
        if [ -n "$sid" ]; then
            printf '%s' "$sid"
            return 0
        fi
    fi
    echo "Error: CLAUDE_SESSION_ID not resolvable (neither \$CLAUDE_ENV_FILE nor \$CLAUDE_SESSION_ID is usable)" >&2
    return 2
}

resolve_plans_dir() {
    if [ -x "$AGENTS_CONFIG_DIR/bin/workflow-plans-dir" ]; then
        bash "$AGENTS_CONFIG_DIR/bin/workflow-plans-dir" 2>/dev/null \
            || printf '%s' "${WORKFLOW_PLANS_DIR:-$HOME/.workflow-plans}"
    else
        printf '%s' "${WORKFLOW_PLANS_DIR:-$HOME/.workflow-plans}"
    fi
}

compute_fingerprint() {
    printf '%s:%s' "$1" "$2" | sha256sum | cut -c1-8
}

# Resolve owner/repo from the current working directory (gh uses cwd-based
# repo resolution for all `gh issue`/`gh repo` calls). Return non-zero on
# failure so callers can propagate read errors distinctly from empty results.
resolve_owner_repo() {
    local out
    if ! out=$(gh repo view --json owner,name --jq '.owner.login + "/" + .name' 2>/dev/null); then
        return 1
    fi
    out=$(printf '%s' "$out" | tr -d '\r' | head -1)
    [ -z "$out" ] && return 1
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

write_lock_file() {
    local n="$1"
    local sid="$2"
    local plans
    plans=$(resolve_plans_dir)
    [ -z "$plans" ] && return 1
    mkdir -p "$plans" 2>/dev/null || return 1
    local started
    started=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date)
    {
        printf 'issue: %s\n' "$n"
        printf 'session-id: %s\n' "$sid"
        printf 'started: %s\n' "$started"
    } > "$plans/wip-lock-$n.md" 2>/dev/null
}

delete_lock_file() {
    local n="$1"
    local plans
    plans=$(resolve_plans_dir)
    [ -z "$plans" ] && return 0
    rm -f "$plans/wip-lock-$n.md" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Verb: set <N>
#   Ordering invariant: fingerprint write BEFORE Status set. Both hard-fail
#   (exit 1) on gh error. Lock file is sync-visibility only — warn-and-continue.
# ---------------------------------------------------------------------------
cmd_set() {
    local n="$1"
    validate_n "$n"
    preflight_field_ids

    local sid
    if ! sid=$(resolve_session_id); then
        exit 2
    fi
    local fp
    fp=$(compute_fingerprint "$sid" "$n")

    local item_id
    item_id=$(resolve_item_id "$n") || item_id=""

    if [ -z "$item_id" ]; then
        # Issue not in project — add it.
        local url
        if ! url=$(gh issue view "$n" --json url --jq '.url' 2>/dev/null); then
            echo "Error: cannot resolve URL for issue #$n (check repo context / gh auth)" >&2
            exit 1
        fi
        url=$(printf '%s' "$url" | tr -d '\r' | head -1)
        if [ -z "$url" ]; then
            echo "Error: gh issue view returned empty URL for #$n" >&2
            exit 1
        fi
        local add_out
        if add_out=$(gh project item-add "$PROJECT_NUM" --owner "$OWNER" --url "$url" \
                --format json --jq '.id' 2>&1); then
            item_id="$add_out"
        else
            # Duplicate-add race: refetch once.
            item_id=$(resolve_item_id "$n") || item_id=""
            if [ -z "$item_id" ]; then
                echo "Error: project item-add failed and refetch empty for #$n" >&2
                exit 1
            fi
        fi
    fi

    # Fingerprint write (hard-fail; precedes Status).
    if ! gh project item-edit --id "$item_id" \
            --field-id "$WIP_STATE_FINGERPRINT_FIELD_ID" \
            --project-id "$PROJECT_ID" \
            --text "$fp" >/dev/null 2>&1; then
        echo "[wip-state: fingerprint write failed for #$n]" >&2
        exit 1
    fi

    # Status set (hard-fail).
    if ! gh project item-edit --id "$item_id" \
            --field-id "$WIP_STATE_STATUS_FIELD_ID" \
            --project-id "$PROJECT_ID" \
            --single-select-option-id "$WIP_STATE_IN_PROGRESS_OPTION_ID" >/dev/null 2>&1; then
        echo "[wip-state: Status set failed for #$n]" >&2
        exit 1
    fi

    # Lock file (warn-and-continue — non-canonical per intent.md §1a).
    if ! write_lock_file "$n" "$sid"; then
        echo "[wip-state: lock-file write failed for #$n (continuing)]" >&2
    fi

    exit 0
}

# ---------------------------------------------------------------------------
# Verb: check <N>
#   Prints same|other|none on stdout. Exit 1 on gh read failure (stdout empty).
#   Filters by field IDs (env-driven); field names are not referenced.
# ---------------------------------------------------------------------------
cmd_check() {
    local n="$1"
    validate_n "$n"
    preflight_field_ids

    local sid
    if ! sid=$(resolve_session_id); then
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

    local fingerprint
    if ! fingerprint=$(gh api graphql \
            -F itemId="$item_id" \
            --jq "[.data.node.fieldValues.nodes[]? | select(.field.id == \"$WIP_STATE_FINGERPRINT_FIELD_ID\") | .text] | first // \"\"" \
            -f query="$query" 2>/dev/null); then
        echo "warn: gh api graphql failed for #$n fingerprint read" >&2
        exit 1
    fi

    local expected
    expected=$(compute_fingerprint "$sid" "$n")
    if [ "$fingerprint" = "$expected" ]; then
        echo same
    else
        echo other
    fi
    exit 0
}

# ---------------------------------------------------------------------------
# Verb: clear <N>
#   Status=Done + clear fingerprint + delete lock. Uniformly warn-and-continue
#   on gh failures (canonical close already happened upstream).
# ---------------------------------------------------------------------------
cmd_clear() {
    local n="$1"
    validate_n "$n"
    preflight_field_ids

    local item_id
    if ! item_id=$(resolve_item_id "$n"); then
        item_id=""
    fi
    if [ -z "$item_id" ]; then
        delete_lock_file "$n"
        exit 0
    fi

    if ! gh project item-edit --id "$item_id" \
            --field-id "$WIP_STATE_STATUS_FIELD_ID" \
            --project-id "$PROJECT_ID" \
            --single-select-option-id "$WIP_STATE_DONE_OPTION_ID" >/dev/null 2>&1; then
        echo "[wip-state: Status=Done set failed for #$n (continuing)]" >&2
    fi

    # When the fingerprint field is already empty, gh project item-edit
    # --text "" returns rc=1 with stderr "no changes to make for the
    # item-edit". That is the expected no-op outcome — suppress the warning.
    # Success path (rc=0) is the normal case (field had a fingerprint to
    # clear) and falls through silently.
    local fp_clear_err
    fp_clear_err=$(gh project item-edit --id "$item_id" \
            --field-id "$WIP_STATE_FINGERPRINT_FIELD_ID" \
            --project-id "$PROJECT_ID" \
            --text "" 2>&1 >/dev/null)
    local fp_clear_rc=$?
    if [ "$fp_clear_rc" -eq 0 ]; then
        : # fingerprint cleared successfully (normal path)
    elif printf '%s' "$fp_clear_err" | grep -q "no changes to make"; then
        : # field was already empty — canonical gh no-op signal
    else
        echo "[wip-state: fingerprint clear failed for #$n (continuing)]" >&2
    fi

    delete_lock_file "$n"
    exit 0
}

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

case "$CMD" in
    set)   cmd_set   "${1:-}" ;;
    check) cmd_check "${1:-}" ;;
    clear) cmd_clear "${1:-}" ;;
    setup) cmd_setup ;;
esac
