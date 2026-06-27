# Mock factory: setup_mock, CANONICAL_BODY, teardown_mock
# ---------------------------------------------------------------------------
# Inline gh mock factory — creates a self-contained mock in $TMP/mock-bin/gh
# per test so each test gets its own args log and env vars.
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
    echo "Token scopes: 'gist', 'project', 'read:org', 'repo'"
    exit 0 ;;
  issue\ create\ *)
    # Default: same NUM for every create (back-compat with single-create tests).
    # Opt-in counter mode for bulk: when GH_MOCK_ISSUE_NUMS is a comma list, each
    # successive `issue create` consumes the next number in manifest order via a
    # file-based cursor (the mock runs once per gh call, so state must persist).
    if [ -n "${GH_MOCK_ISSUE_NUMS:-}" ]; then
        CURSOR_FILE="${GH_MOCK_CREATE_CURSOR:-/tmp/gh-mock-create-cursor}"
        IDX=0
        [ -f "$CURSOR_FILE" ] && IDX=$(cat "$CURSOR_FILE")
        IFS=',' read -ra NUMS <<< "$GH_MOCK_ISSUE_NUMS"
        NUM="${NUMS[$IDX]:-9999}"
        echo $((IDX + 1)) > "$CURSOR_FILE"
    else
        NUM="${GH_MOCK_NEW_ISSUE_NUM:-9999}"
    fi
    echo "https://github.com/nirecom/agents/issues/${NUM}"
    exit 0 ;;
  project\ item-add\ *)
    if [ "${GH_MOCK_PROJECT_FAIL:-0}" = "1" ]; then
        echo "error: project attach failed" >&2
        exit 1
    fi
    echo "PVTI_mock_item_id_9999"
    exit 0 ;;
  issue\ view\ *createdAt*)
    if [ "${GH_MOCK_CREATEDAT_EMPTY:-0}" = "1" ]; then
        echo ""; exit 0
    fi
    echo "2026-05-15"
    exit 0 ;;
  project\ item-edit\ *)
    if [ "${GH_MOCK_ITEM_EDIT_FAIL:-0}" = "1" ]; then
        echo "error: item-edit failed" >&2; exit 1
    fi
    exit 0 ;;
  issue\ reopen\ *)
    RNUM=$(echo "$ARGS" | awk '{print $3}')
    eval "RFAIL=\${GH_MOCK_REOPEN_FAIL_${RNUM}:-0}"
    if [ "$RFAIL" = "1" ]; then
        echo "error: cannot reopen issue $RNUM" >&2
        exit 1
    fi
    exit 0 ;;
  api\ repos/*/issues/*\ --jq*)
    # parent-ancestor-reopen.sh: api repos/<owner>/<repo>/issues/<N> --jq .parent.number // empty
    INUM=$(echo "$ARGS" | awk '{print $2}' | awk -F/ '{print $NF}')
    eval "ABSENT=\${GH_MOCK_PARENT_ABSENT_${INUM}:-0}"
    if [ "$ABSENT" = "1" ]; then
        echo ""; exit 0
    fi
    eval "PNUM=\${GH_MOCK_PARENT_NUM_${INUM}:-}"
    echo "$PNUM"
    exit 0 ;;
  issue\ view\ *--json\ id*)
    # Extract issue number from args (positional after "issue view")
    NUM=$(echo "$ARGS" | awk '{print $3}')
    echo "I_kwDOmock${NUM}"
    exit 0 ;;
  api\ graphql\ *databaseId*)
    # Fix #713: dispatch now fetches databaseId via GraphQL API instead of gh issue view.
    # Extract issue number from the query string (issue(number: N)) and return a
    # deterministic integer derived from it. The caller uses --jq so return just the value.
    if [ "${GH_MOCK_GRAPHQL_DBID_FAIL:-0}" = "1" ]; then
        echo "error: graphql request failed" >&2
        exit 1
    fi
    NUM=$(echo "$ARGS" | sed 's/.*issue(number: \([0-9]*\)).*/\1/')
    echo "${NUM}000"
    exit 0 ;;
  issue\ view\ *--json\ state*)
    NUM=$(echo "$ARGS" | awk '{print $3}')
    eval "STATE=\${GH_MOCK_ISSUE_STATE_${NUM}:-OPEN}"
    echo "$STATE"
    exit 0 ;;
  issue\ comment\ *)
    exit 0 ;;
  api\ *-X\ POST*sub_issues*)
    if [ "${GH_MOCK_SUBISSUE_API_FAIL:-0}" = "1" ]; then
      echo "error: sub-issue attach failed" >&2
      exit 1
    fi
    # Opt-in per-attach failure: GH_MOCK_SUBISSUE_FAIL_FROM=N fails the Nth (and
    # later) sub_issues POST while letting earlier ones succeed. File-based cursor
    # counts attaches across the per-call mock processes.
    if [ -n "${GH_MOCK_SUBISSUE_FAIL_FROM:-}" ]; then
      ATTACH_CURSOR="${GH_MOCK_SUBISSUE_CURSOR:-/tmp/gh-mock-subissue-cursor}"
      ACOUNT=0
      [ -f "$ATTACH_CURSOR" ] && ACOUNT=$(cat "$ATTACH_CURSOR")
      ACOUNT=$((ACOUNT + 1))
      echo "$ACOUNT" > "$ATTACH_CURSOR"
      if [ "$ACOUNT" -ge "$GH_MOCK_SUBISSUE_FAIL_FROM" ]; then
        echo "error: sub-issue attach #${ACOUNT} failed" >&2
        exit 1
      fi
    fi
    exit 0 ;;
  repo\ view\ *nameWithOwner*)
    echo "nirecom/agents"
    exit 0 ;;
  repo\ view\ *--json\ owner,name*)
    echo "nirecom/agents"
    exit 0 ;;
  issue\ view\ *--json\ url*)
    NUM=$(echo "$ARGS" | awk '{print $3}')
    echo "https://github.com/nirecom/agents/issues/${NUM}"
    exit 0 ;;
  api\ graphql\ *projectsV2*)
    case "$ARGS" in
      *"| length"*) echo "1"; exit 0 ;;
      *) printf '{"id":"PVT_kwHOAMF_jc4BXf9E","number":1,"ownerLogin":"nirecom"}\n'; exit 0 ;;
    esac ;;
  api\ graphql\ *fields*|api\ graphql\ *projectId*)
    case "$ARGS" in
      *"hasNextPage"*) echo "false"; exit 0 ;;
      *"endCursor"*)   echo ""; exit 0 ;;
      *) echo "PVTF_lAHOAMF_jc4BXf9EzhSsYwA"; exit 0 ;;
    esac ;;
  api\ graphql\ *projectItems*)
    echo ""; exit 0 ;;
  *)
    echo "MOCK GH: no match for args=$ARGS" >&2
    exit 2 ;;
esac
MOCK_EOF
    chmod +x "$TMP/mock-bin/gh"
    export PATH="$TMP/mock-bin:$PATH"
    export GH_MOCK_ARGS_LOG="$TMP/gh-args.log"
    : > "$GH_MOCK_ARGS_LOG"
}

# Canonical body for tests that don't specifically exercise schema validation
# but still pass through the validation block (S2/S4/S5/S6). Tests that exit
# before validation (S3/S7-S11) don't need this.
CANONICAL_BODY="Background: test\nChanges: test"

teardown_mock() {
    if [ -n "${TMP:-}" ] && [ -d "$TMP" ]; then
        rm -rf "$TMP"
    fi
    TMP=""
    unset GH_MOCK_ARGS_LOG GH_MOCK_PROJECT_FAIL GH_MOCK_CREATEDAT_EMPTY GH_MOCK_ITEM_EDIT_FAIL 2>/dev/null || true
    unset GH_MOCK_SUBISSUE_API_FAIL GH_MOCK_NEW_ISSUE_NUM GH_MOCK_ISSUE_STATE_42 GH_MOCK_ISSUE_STATE_43 GH_MOCK_ISSUE_STATE_100 2>/dev/null || true
    unset GH_MOCK_PARENT_NUM_200 GH_MOCK_PARENT_ABSENT_100 GH_MOCK_REOPEN_FAIL_100 GH_MOCK_GRAPHQL_DBID_FAIL 2>/dev/null || true
    unset GH_MOCK_ISSUE_NUMS GH_MOCK_CREATE_CURSOR GH_MOCK_SUBISSUE_FAIL_FROM GH_MOCK_SUBISSUE_CURSOR 2>/dev/null || true
}
