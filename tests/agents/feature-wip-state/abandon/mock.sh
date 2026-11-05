# Sourced by tests/agents/feature-wip-state/abandon.sh — not executed directly (no shebang).
# Tests: bin/github-issues/wip-state.sh, bin/github-issues/wip-state/cmd-abandon.sh
# Tags: wip-state, github, scope:issue-specific
# abandon <N>: OPEN → Status=Todo + session-id="" + delete lock; CLOSED/gh-error → exit 1.
# L3 gap: `gh` is stubbed — the live item-edit API and auto-close semantics need a real board.
# Knobs: GH_MOCK_STATE, GH_MOCK_STATE_CHECK_FAIL, GH_MOCK_FAIL=item-edit-status|item-edit-fp,
#   GH_MOCK_FP_NO_CHANGES, GH_MOCK_PROJECT_ITEM_ID; field lists/mutations → $GH_FIELDS_MOCK.
mint_abandon_mock() {
    cat > "$TMP/mock-bin/gh" <<'MOCK_EOF'
#!/bin/bash
ARGS="$*"
if [ -n "${GH_MOCK_ARGS_LOG:-}" ]; then
    printf '%s\n' "$ARGS" >> "$GH_MOCK_ARGS_LOG"
fi
case "$ARGS" in
  issue\ view\ *--json\ state*)
    if [ "${GH_MOCK_STATE_CHECK_FAIL:-}" = "1" ]; then
        exit 1
    fi
    echo "${GH_MOCK_STATE:-OPEN}"
    exit 0 ;;
  auth\ status*)
    if [ "${GH_MOCK_MISSING_PROJECT_SCOPE:-}" = "1" ]; then
      echo "Token scopes: 'repo'"
    else
      echo "Token scopes: 'project', 'repo'"
    fi
    exit 0 ;;
  repo\ view\ *) echo "${GH_MOCK_OWNER_REPO:-nirecom/agents}"; exit 0 ;;
  api\ graphql\ *projectsV2*)
    case "$ARGS" in
      *"| length"*) echo "${GH_MOCK_LINKED_COUNT:-1}"; exit 0 ;;
      *) printf '{"id":"PVT_resolved","number":1,"ownerLogin":"nirecom"}\n'; exit 0 ;;
    esac
    ;;
  api\ graphql\ *createProjectV2Field*|api\ graphql\ *updateProjectV2Field*|api\ graphql\ *updateProjectV2View*|api\ graphql\ *"views("*|api\ graphql\ *"fields("*)
    exec bash "$GH_FIELDS_MOCK" "$@" ;;
  api\ graphql\ *) printf '%s\n' "${GH_MOCK_PROJECT_ITEM_ID-PVTI_existing}"; exit 0 ;;
  project\ item-edit\ *--single-select-option-id*)
    if [ "${GH_MOCK_FAIL:-}" = "item-edit-status" ]; then
        echo "error: status item-edit failed" >&2
        exit 1
    fi
    exit 0 ;;
  project\ item-edit\ *--text*)
    if [ "${GH_MOCK_FP_NO_CHANGES:-}" = "1" ]; then
        echo "no changes to make for the item-edit" >&2
        exit 1
    fi
    if [ "${GH_MOCK_FAIL:-}" = "item-edit-fp" ]; then
        echo "error: fingerprint item-edit failed" >&2
        exit 1
    fi
    if [ "${GH_MOCK_STRICT_TEXT_FIELD:-}" = "1" ]; then
        fid=""; prev=""
        for a in "$@"; do [ "$prev" = "--field-id" ] && fid="$a"; prev="$a"; done
        known=$(GH_MOCK_FIELDS_LOG="" GH_MOCK_FIELD_LIST_FAIL="" bash "$GH_FIELDS_MOCK" api graphql --paginate \
            -f query='fields(' --jq '.data.node.fields.nodes[] | select(.dataType == "TEXT") | .id')
        printf '%s\n' "$known" | grep -qxF -- "$fid" || { echo "error: field $fid not found" >&2; exit 1; }
    fi
    exit 0 ;;
  *) echo "MOCK GH: no match $ARGS" >&2; exit 2 ;;
esac
MOCK_EOF
    chmod +x "$TMP/mock-bin/gh"
}
