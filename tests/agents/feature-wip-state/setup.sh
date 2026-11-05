
# ---------------------------------------------------------------------------
# Inline gh mock factory (per test: own log + env). Mocks project item-edit/item-add,
# issue view --json url, and api graphql. Env knobs:
#   GH_MOCK_PROJECT_ITEM_ID / GH_MOCK_ITEM_ADD_ID (default PVTI_added)  item ids
#   GH_MOCK_STATUS / GH_MOCK_FINGERPRINT   Status name / session-id text (GH_MOCK_FP_BY_FIELD "id=text;id=text": per field id)
#   GH_MOCK_FAIL   item-edit-status|item-edit-fp|item-edit-sid-once|graphql|item-add|issue-view
#   GH_MOCK_STRICT_TEXT_FIELD=1   --text edit fails unless --field-id is a modelled TEXT field
#   GH_MOCK_ARGS_LOG / GH_MOCK_FIELDS_LOG   gh call log / field-model op log
# Field lists, field/view mutations: tests/lib/gh-projectv2-fields-mock.sh.
# ---------------------------------------------------------------------------

TMP=""
GH_FIELDS_MOCK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../lib" && pwd)/gh-projectv2-fields-mock.sh"
export GH_FIELDS_MOCK

setup_mock() {
    TMP="$(mktemp -d)"
    mkdir -p "$TMP/mock-bin"
    cat > "$TMP/mock-bin/gh" <<'MOCK_EOF'
#!/bin/bash
ARGS="$*"
if [ -n "${GH_MOCK_ARGS_LOG:-}" ]; then
    printf '%s\n' "$ARGS" >> "$GH_MOCK_ARGS_LOG"
fi
case "$ARGS" in
  auth\ status*)
    if [ "${GH_MOCK_MISSING_PROJECT_SCOPE:-}" = "1" ]; then
        echo "Token scopes: 'gist', 'read:org', 'repo'"
    else
        echo "Token scopes: 'gist', 'project', 'read:org', 'repo'"
    fi
    exit 0 ;;
  repo\ view\ *--json\ owner,name*|repo\ view\ *)
    # Default: nirecom/agents. resolve_owner_repo --jq produces "owner/name".
    echo "${GH_MOCK_OWNER_REPO:-nirecom/agents}"
    exit 0 ;;
  project\ item-add\ *)
    if [ "${GH_MOCK_FAIL:-}" = "item-add" ]; then
        echo "error: item-add failed" >&2
        exit 1
    fi
    echo "${GH_MOCK_ITEM_ADD_ID:-PVTI_added}"
    exit 0 ;;
  project\ item-edit\ *--single-select-option-id*)
    if [ "${GH_MOCK_FAIL:-}" = "item-edit-status" ]; then
        echo "error: status item-edit failed" >&2
        exit 1
    fi
    exit 0 ;;
  project\ item-edit\ *--text*)
    if [ "${GH_MOCK_FAIL:-}" = "item-edit-fp" ]; then
        echo "error: session-id item-edit failed" >&2
        exit 1
    fi
    if [ "${GH_MOCK_FAIL:-}" = "item-edit-sid-once" ] && [ ! -f "$GH_MOCK_COUNTER_DIR/sid-edit-failed" ]; then
        : > "$GH_MOCK_COUNTER_DIR/sid-edit-failed"
        echo "error: session-id item-edit failed (once)" >&2
        exit 1
    fi
    if [ "${GH_MOCK_STRICT_TEXT_FIELD:-}" = "1" ]; then
        fid=""; prev=""
        for a in "$@"; do [ "$prev" = "--field-id" ] && fid="$a"; prev="$a"; done
        known=$(GH_MOCK_FIELDS_LOG="" GH_MOCK_FIELD_LIST_FAIL="" bash "$GH_FIELDS_MOCK" api graphql --paginate \
            -f query='fields(' --jq '.data.node.fields.nodes[] | select(.dataType == "TEXT") | .id')
        if ! printf '%s\n' "$known" | grep -qxF -- "$fid"; then
            echo "error: field $fid not found" >&2
            exit 1
        fi
    fi
    exit 0 ;;
  issue\ view\ *--json\ state*)
    echo "CLOSED"
    exit 0 ;;
  issue\ view\ *--json\ url*)
    if [ "${GH_MOCK_FAIL:-}" = "issue-view" ]; then
        echo "error: gh issue view failed" >&2
        exit 1
    fi
    echo "${GH_MOCK_ISSUE_URL:-https://github.com/nirecom/agents/issues/42}"
    exit 0 ;;
  api\ graphql\ *createProjectV2Field*|api\ graphql\ *updateProjectV2Field*|api\ graphql\ *updateProjectV2View*|api\ graphql\ *"views("*|api\ graphql\ *"fields("*)
    # Field/view lists and field/view mutations: the JSON model (tests/lib/gh-projectv2-fields-mock.sh).
    exec bash "$GH_FIELDS_MOCK" "$@"
    ;;
  api\ graphql\ *projectsV2*)
    # resolve-project.sh Query A: linked Projects v2 count + first-node.
    # Honors GH_MOCK_LINKED_COUNT (default 1). count filter uses `| length`.
    # Note: GH_MOCK_FAIL=graphql scopes to the cmd_check read queries only (below),
    # NOT the resolver queries, so resolution still succeeds and the check-read
    # failure path is what gets exercised.
    case "$ARGS" in
      *"| length"*) echo "${GH_MOCK_LINKED_COUNT:-1}"; exit 0 ;;
      *)
        if [ "${GH_MOCK_LINKED_COUNT:-1}" -eq 0 ]; then
            echo ""
        else
            printf '{"id":"%s","number":%s,"ownerLogin":"%s"}\n' \
                "${GH_MOCK_RESOLVED_PROJECT_ID:-PVT_resolved}" \
                "${GH_MOCK_RESOLVED_PROJECT_NUM:-1}" \
                "${GH_MOCK_RESOLVED_OWNER:-nirecom}"
        fi
        exit 0
        ;;
    esac
    ;;
  api\ graphql\ *)
    # Source uses `gh --jq` so mock emits the pre-filtered value.
    # Distinguish by --jq filter content (each query has a unique key token).
    case "$ARGS" in
      *projectItems*)
        # resolve_item_id query — print just the item id (or empty if no membership).
        printf '%s\n' "${GH_MOCK_PROJECT_ITEM_ID:-}"
        exit 0
        ;;
      *"select(.field.id"*".name"*|*".field.id"*"\")"*"| .name"*)
        # cmd_check: status read (single-select .name).
        if [ "${GH_MOCK_FAIL:-}" = "graphql" ]; then
            echo "error: graphql failed" >&2
            exit 1
        fi
        printf '%s\n' "${GH_MOCK_STATUS:-In Progress}"
        exit 0
        ;;
      *"select(.field.id"*".text"*|*".field.id"*"\")"*"| .text"*)
        # cmd_check: fingerprint read.
        if [ "${GH_MOCK_FAIL:-}" = "graphql" ]; then
            echo "error: graphql failed" >&2
            exit 1
        fi
        if [ -n "${GH_MOCK_FP_BY_FIELD:-}" ]; then
            # Per-field values ("id=value;id=value"): answer only for the field id the --jq filter selects.
            qfid=$(printf '%s' "$ARGS" | sed -nE 's/.*select\(\.field\.id == "([^"]+)"\).*/\1/p')
            val=""
            IFS=';' read -r -a pairs <<<"$GH_MOCK_FP_BY_FIELD"
            for pr in "${pairs[@]}"; do
                [ "${pr%%=*}" = "$qfid" ] && val="${pr#*=}"
            done
            printf '%s\n' "$val"
            exit 0
        fi
        printf '%s\n' "${GH_MOCK_FINGERPRINT:-}"
        exit 0
        ;;
      *)
        # Fallback: generic empty.
        echo ""
        exit 0
        ;;
    esac
    ;;
  issue\ view\ *)
    if [ "${GH_MOCK_FAIL:-}" = "issue-view" ]; then
        echo "error: gh issue view failed" >&2
        exit 1
    fi
    echo "${GH_MOCK_ISSUE_URL:-https://github.com/nirecom/agents/issues/42}"
    exit 0 ;;
  *)
    echo "MOCK GH: no match for args=$ARGS" >&2
    exit 2 ;;
esac
MOCK_EOF
    chmod +x "$TMP/mock-bin/gh"
    # A gitlab.com origin routes to glab; the mock keeps the real glab (and the run-all command guard) out.
    printf '%s\n' '#!/bin/bash' 'echo "MOCK GLAB: not available" >&2' 'exit 1' > "$TMP/mock-bin/glab"
    chmod +x "$TMP/mock-bin/glab"
    export PATH="$TMP/mock-bin:$PATH"
    export GH_MOCK_ARGS_LOG="$TMP/gh-args.log"
    : > "$GH_MOCK_ARGS_LOG"
    export GH_MOCK_FIELDS_LOG="$TMP/gh-fields.log"
    : > "$GH_MOCK_FIELDS_LOG"
    export GH_MOCK_FIELDS_STATE="$TMP/gh-fields.state"
    export GH_MOCK_COUNTER_DIR="$TMP"

    # Required env vars for the helper.
    export AGENTS_MAIN_ROOT="$TMP/agents-config"
    mkdir -p "$AGENTS_MAIN_ROOT"
    export PLANS_DIR="$TMP/plans"
    mkdir -p "$PLANS_DIR"
    # Isolate resolve-project.sh's cache from the real user cache.
    # resolve-project.sh reads ${WORKFLOW_PLANS_DIR:-$HOME/.workflow-plans}/cache/project-resolve.tsv
    # directly (NOT via the workflow-plans-dir bin), so we must export it here.
    export WORKFLOW_PLANS_DIR="$PLANS_DIR"
    mkdir -p "$WORKFLOW_PLANS_DIR/cache"
    # resolve-project.sh's project-resolve.tsv cache lives under WORKFLOW_STATE_DIR
    # (default: the real ~/.claude/projects/workflow); dual-pin it to the fixture.
    export WORKFLOW_STATE_DIR="$TMP/wf-state"
    mkdir -p "$WORKFLOW_STATE_DIR/cache"

    # Deterministic session id via the CLAUDE_CODE_SESSION_ID env tier.
    # Overriding it also stops a runner inside a live Claude Code session from
    # leaking its own sid into the helper, which would break any test that
    # expects the "test-sid-fixture" session-id value.
    export CLAUDE_CODE_SESSION_ID="test-sid-fixture"

    # WIP_STATE_* env vars (Status ones are preflight-required; the session-id field is not).
    export WIP_STATE_STATUS_FIELD_ID="PVTSSF_status"
    export WIP_STATE_IN_PROGRESS_OPTION_ID="OPT_inprog"
    export WIP_STATE_DONE_OPTION_ID="OPT_done"
    export WIP_STATE_TODO_OPTION_ID="OPT_todo"
    export WIP_STATE_SESSION_ID_FIELD_ID="PVTF_fp"

    # Reuse from issue-create.sh convention.
    export ISSUE_CREATE_PROJECT_ID="PVT_kwHOAMF_jc4BXf9E"
    export ISSUE_CREATE_PROJECT_NUM="1"
    export ISSUE_CREATE_OWNER="nirecom"
}

teardown_mock() {
    if [ -n "${TMP:-}" ] && [ -d "$TMP" ]; then
        rm -rf "$TMP" 2>/dev/null || true
    fi
    TMP=""
    unset GH_MOCK_ARGS_LOG GH_MOCK_PROJECT_ITEM_ID GH_MOCK_ITEM_ADD_ID \
          GH_MOCK_STATUS GH_MOCK_FINGERPRINT GH_MOCK_FP_BY_FIELD GH_MOCK_FAIL GH_MOCK_ISSUE_URL \
          GH_MOCK_PAGINATED_PAGES GH_MOCK_MISSING_PROJECT_SCOPE \
          GH_MOCK_STATE_CHECK_FAIL GH_MOCK_FP_NO_CHANGES GH_MOCK_NEW_FIELD_ID \
          GH_MOCK_LINKED_COUNT GH_MOCK_RESOLVED_PROJECT_ID \
          GH_MOCK_RESOLVED_PROJECT_NUM GH_MOCK_RESOLVED_OWNER \
          GH_MOCK_RESOLVED_CONTENT_DATE_ID GH_MOCK_OWNER_REPO \
          GH_MOCK_FIELDS_LOG GH_MOCK_FIELDS_STATE GH_MOCK_COUNTER_DIR GH_MOCK_STRICT_TEXT_FIELD \
          GH_MOCK_SID_FIELD GH_MOCK_SID_FIELD_ID GH_MOCK_LEGACY_FIELD_ID GH_MOCK_CREATE_NO_ID \
          GH_MOCK_FIELD_PAGES GH_MOCK_STATUS_FIELD GH_MOCK_FIELD_LIST_FAIL \
          GH_MOCK_VIEWS GH_MOCK_VIEW_PAGES GH_MOCK_VIEW_LIST_FAIL 2>/dev/null || true
    unset AGENTS_MAIN_ROOT CLAUDE_CODE_SESSION_ID PLANS_DIR WORKFLOW_PLANS_DIR \
          WIP_STATE_STATUS_FIELD_ID WIP_STATE_IN_PROGRESS_OPTION_ID \
          WIP_STATE_DONE_OPTION_ID WIP_STATE_TODO_OPTION_ID \
          WIP_STATE_SESSION_ID_FIELD_ID WIP_STATE_FINGERPRINT_FIELD_ID \
          ISSUE_CREATE_PROJECT_ID ISSUE_CREATE_PROJECT_NUM ISSUE_CREATE_OWNER \
          _ISSUE_CREATE_INTERNAL_OWNER _ISSUE_CREATE_INTERNAL_PROJECT_NUM \
          _ISSUE_CREATE_INTERNAL_PROJECT_ID _ISSUE_CREATE_INTERNAL_FIELD_ID \
          _ISSUE_CREATE_INTERNAL_SESSION_ID_FIELD_ID 2>/dev/null || true
}
