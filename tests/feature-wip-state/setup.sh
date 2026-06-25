
# ---------------------------------------------------------------------------
# Inline gh mock factory — written per test so each test gets its own log
# and env vars. Mock supports:
#   - project item-edit (records args; can fail per GH_MOCK_FAIL value)
#   - project item-add (returns GH_MOCK_ITEM_ADD_ID or fails)
#   - issue view --json url (URL resolve)
#   - api graphql (returns mock fieldValues / item id / setup metadata)
#
# Env knobs:
#   GH_MOCK_PROJECT_ITEM_ID    item id returned by resolve_item_id graphql query
#   GH_MOCK_ITEM_ADD_ID        item id returned by item-add (default: PVTI_added)
#   GH_MOCK_STATUS             status name returned by check graphql (e.g. "In Progress")
#   GH_MOCK_FINGERPRINT        fingerprint text returned by check graphql
#   GH_MOCK_FAIL               one of: item-edit-status|item-edit-fp|graphql|item-add|issue-view
#   GH_MOCK_ISSUE_URL          URL returned by `gh issue view --json url`
#   GH_MOCK_PAGINATED_PAGES    if "1", check returns two graphql JSON pages (status on p1, fp on p2)
#   GH_MOCK_ARGS_LOG           append-only call log (one line per gh invocation)
# ---------------------------------------------------------------------------

TMP=""

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
        echo "error: fingerprint item-edit failed" >&2
        exit 1
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
  api\ graphql\ *createProjectV2Field*)
    missing=""
    case "$ARGS" in *"-F projectId="*) ;; *) missing="$missing projectId" ;; esac
    case "$ARGS" in *"-F name=session-fingerprint"*) ;; *) missing="$missing name" ;; esac
    case "$ARGS" in *"-F dataType=TEXT"*) ;; *) missing="$missing dataType" ;; esac
    if [ -n "$missing" ]; then
        echo "MOCK GH: malformed createProjectV2Field call — missing:$missing" >&2
        exit 1
    fi
    if [ "${GH_MOCK_FAIL:-}" = "create-field" ]; then
        echo "error: createProjectV2Field denied" >&2
        exit 1
    fi
    echo "${GH_MOCK_NEW_FIELD_ID:-PVTF_fp_new}"
    exit 0
    ;;
  api\ graphql\ *)
    if [ "${GH_MOCK_FAIL:-}" = "graphql" ]; then
        echo "error: graphql failed" >&2
        exit 1
    fi
    # Source uses `gh --jq` so mock emits the pre-filtered value.
    # Distinguish by --jq filter content (each query has a unique key token).
    case "$ARGS" in
      *projectItems*)
        # resolve_item_id query — print just the item id (or empty if no membership).
        printf '%s\n' "${GH_MOCK_PROJECT_ITEM_ID:-}"
        exit 0
        ;;
      *".name == \"Status\""*)
        # cmd_setup: STATUS-related --jq filter.
        case "$ARGS" in
          *"select(.__typename == \"ProjectV2SingleSelectField\""*) echo "PVTSSF_status" ;;
          *"select(.name == \"Todo\")"*)         echo "OPT_todo" ;;
          *"select(.name == \"In Progress\")"*)  echo "OPT_inprog" ;;
          *"select(.name == \"Done\")"*)         echo "OPT_done" ;;
          *) echo "" ;;
        esac
        exit 0
        ;;
      *".name == \"session-fingerprint\""*)
        # cmd_setup: fingerprint field id.
        if [ -n "${GH_MOCK_FP_DISCOVERY_COUNTER:-}" ]; then
            N=$(cat "$GH_MOCK_FP_DISCOVERY_COUNTER" 2>/dev/null || echo 0)
            N=$((N + 1)); echo "$N" > "$GH_MOCK_FP_DISCOVERY_COUNTER"
            if [ "$N" -le 1 ] && [ "${GH_MOCK_FP_INITIALLY_MISSING:-}" = "1" ]; then
                echo ""
            else
                echo "${GH_MOCK_FP_REDISCOVERED_ID-PVTF_fp_rediscovered}"
            fi
            exit 0
        fi
        echo "PVTF_fp"
        exit 0
        ;;
      *"select(.field.id"*".name"*|*".field.id"*"\")"*"| .name"*)
        # cmd_check: status read (single-select .name).
        printf '%s\n' "${GH_MOCK_STATUS:-In Progress}"
        exit 0
        ;;
      *"select(.field.id"*".text"*|*".field.id"*"\")"*"| .text"*)
        # cmd_check: fingerprint read.
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
    export PATH="$TMP/mock-bin:$PATH"
    export GH_MOCK_ARGS_LOG="$TMP/gh-args.log"
    : > "$GH_MOCK_ARGS_LOG"

    # Required env vars for the helper.
    export AGENTS_CONFIG_DIR="$TMP/agents-config"
    mkdir -p "$AGENTS_CONFIG_DIR"
    # Fake plans dir resolver: a stub bin/workflow-plans-dir that prints $PLANS_DIR.
    mkdir -p "$AGENTS_CONFIG_DIR/bin"
    export PLANS_DIR="$TMP/plans"
    mkdir -p "$PLANS_DIR"
    cat > "$AGENTS_CONFIG_DIR/bin/workflow-plans-dir" <<EOF
#!/bin/bash
echo "$PLANS_DIR"
EOF
    chmod +x "$AGENTS_CONFIG_DIR/bin/workflow-plans-dir"

    # CLAUDE_ENV_FILE with a deterministic session id.
    export CLAUDE_ENV_FILE="$TMP/claude-env"
    echo "CLAUDE_SESSION_ID=test-sid-fixture" > "$CLAUDE_ENV_FILE"

    # WIP_STATE_* env vars (preflight-required).
    export WIP_STATE_STATUS_FIELD_ID="PVTSSF_status"
    export WIP_STATE_IN_PROGRESS_OPTION_ID="OPT_inprog"
    export WIP_STATE_DONE_OPTION_ID="OPT_done"
    export WIP_STATE_TODO_OPTION_ID="OPT_todo"
    export WIP_STATE_FINGERPRINT_FIELD_ID="PVTF_fp"

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
          GH_MOCK_STATUS GH_MOCK_FINGERPRINT GH_MOCK_FAIL GH_MOCK_ISSUE_URL \
          GH_MOCK_PAGINATED_PAGES GH_MOCK_MISSING_PROJECT_SCOPE \
          GH_MOCK_FP_INITIALLY_MISSING GH_MOCK_FP_REDISCOVERED_ID \
          GH_MOCK_FP_DISCOVERY_COUNTER GH_MOCK_NEW_FIELD_ID 2>/dev/null || true
    unset AGENTS_CONFIG_DIR CLAUDE_ENV_FILE CLAUDE_CODE_SESSION_ID PLANS_DIR \
          WIP_STATE_STATUS_FIELD_ID WIP_STATE_IN_PROGRESS_OPTION_ID \
          WIP_STATE_DONE_OPTION_ID WIP_STATE_TODO_OPTION_ID \
          WIP_STATE_FINGERPRINT_FIELD_ID \
          ISSUE_CREATE_PROJECT_ID ISSUE_CREATE_PROJECT_NUM ISSUE_CREATE_OWNER \
          _ISSUE_CREATE_INTERNAL_OWNER _ISSUE_CREATE_INTERNAL_PROJECT_NUM \
          _ISSUE_CREATE_INTERNAL_PROJECT_ID _ISSUE_CREATE_INTERNAL_FIELD_ID 2>/dev/null || true
}
