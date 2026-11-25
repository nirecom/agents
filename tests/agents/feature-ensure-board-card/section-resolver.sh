# R-integration / R-resolver-fail (#641): ensure-board-card.sh with the board resolver running via graphql.
# Tests: bin/github-issues/ensure-board-card.sh
# Tags: github, issues, agent, bin, tests, scope:issue-specific
# Sourced by tests/agents/feature-ensure-board-card.sh (needs its setup_mock / teardown_mock, TARGET, pins).

# ===========================================================================
# R-integration (#641): ISSUE_CREATE_* env vars all unset, resolver runs via graphql.
# Verify item-add called with RESOLVED_OWNER and RESOLVED_PROJECT_NUM.
# ===========================================================================
setup_mock
unset "${!_ISSUE_CREATE_INTERNAL_@}" 2>/dev/null  # drop the short-circuit env so the resolver's graphql path runs
# Replace mock with one that handles both `*projectsV2*` (resolver Query A) and
# `*projectItems*` (resolve_item_id).
cat > "$TMP/mock-bin/gh" <<'MOCK_EOF'
#!/bin/bash
ARGS="$*"
if [ -n "${GH_MOCK_ARGS_LOG:-}" ]; then
    printf '%s\n' "$ARGS" >> "$GH_MOCK_ARGS_LOG"
fi
case "$ARGS" in
  auth\ status*)
    echo "Token scopes: 'project', 'repo'"; exit 0 ;;
  repo\ view\ *--json\ owner,name*|repo\ view\ *)
    echo "${GH_MOCK_OWNER_REPO:-nirecom/agents}"; exit 0 ;;
  api\ graphql\ *projectsV2*)
    case "$ARGS" in
      *"| length"*) echo "1"; exit 0 ;;
      *) printf '{"id":"PVT_resolved","number":1,"ownerLogin":"nirecom"}\n'; exit 0 ;;
    esac
    ;;
  api\ graphql\ *fields*|api\ graphql\ *projectId*)
    case "$ARGS" in
      *"hasNextPage"*) echo "false"; exit 0 ;;
      *"endCursor"*)   echo ""; exit 0 ;;
      *) echo "PVTF_resolved_content_date"; exit 0 ;;
    esac
    ;;
  api\ graphql\ *projectItems*)
    printf '%s\n' "${GH_MOCK_PROJECT_ITEM_ID:-}"; exit 0 ;;
  api\ graphql\ *)
    # Fallback (resolve_item_id without --jq-distinguishing token).
    printf '%s\n' "${GH_MOCK_PROJECT_ITEM_ID:-}"; exit 0 ;;
  project\ item-add\ *)
    echo "${GH_MOCK_ITEM_ADD_ID:-PVTI_added}"; exit 0 ;;
  project\ item-edit\ *) exit 0 ;;
  issue\ view\ *--json\ createdAt*) echo "2024-01-15"; exit 0 ;;
  issue\ view\ *--json\ url*|issue\ view\ *)
    echo "${GH_MOCK_ISSUE_URL:-https://github.com/nirecom/agents/issues/42}"; exit 0 ;;
  *) echo "MOCK GH: no match $ARGS" >&2; exit 2 ;;
esac
MOCK_EOF
chmod +x "$TMP/mock-bin/gh"
# A fresh per-case state dir: an empty resolver cache, so the mock (not a prior case) answers.
export WORKFLOW_PLANS_DIR="$TMP/plans" WORKFLOW_STATE_DIR="$TMP/state"
# GH_MOCK_PROJECT_ITEM_ID unset → triggers item-add path.
run_with_timeout 30 bash "$TARGET" 42 >/dev/null 2>&1
RC=$?
HAS_ITEM_ADD_RESOLVED=0; HAS_GRAPHQL_RESOLVED_PROJECTID=0; HAS_CONTENT_DATE_FIELD=0
grep -qE "project item-add (--owner nirecom --num 1|1 --owner nirecom)" "$GH_MOCK_ARGS_LOG" 2>/dev/null && HAS_ITEM_ADD_RESOLVED=1
grep -q "PVT_resolved" "$GH_MOCK_ARGS_LOG" 2>/dev/null && HAS_GRAPHQL_RESOLVED_PROJECTID=1
grep -q "PVTF_resolved_content_date" "$GH_MOCK_ARGS_LOG" 2>/dev/null && HAS_CONTENT_DATE_FIELD=1
if [ "$RC" -eq 0 ] \
   && [ "$HAS_ITEM_ADD_RESOLVED" -eq 1 ] \
   && [ "$HAS_GRAPHQL_RESOLVED_PROJECTID" -eq 1 ] \
   && [ "$HAS_CONTENT_DATE_FIELD" -eq 1 ]; then
    pass "R-integration: resolver values reach item-add (--owner/--num) + item-edit (project_id, field_id)"
else
    fail "R-integration: rc=$RC item_add=$HAS_ITEM_ADD_RESOLVED project_id=$HAS_GRAPHQL_RESOLVED_PROJECTID field_id=$HAS_CONTENT_DATE_FIELD log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null)"
fi
export WORKFLOW_PLANS_DIR="$F3142_PIN_ROOT/wf-plans" WORKFLOW_STATE_DIR="$F3142_PIN_ROOT/wf-state"
teardown_mock

# ===========================================================================
# R-resolver-fail (#641): resolver returns 1 (0 linked) → exit 0 + warn, no item-add.
# ===========================================================================
setup_mock
unset "${!_ISSUE_CREATE_INTERNAL_@}" 2>/dev/null
cat > "$TMP/mock-bin/gh" <<'MOCK_EOF'
#!/bin/bash
ARGS="$*"
[ -n "${GH_MOCK_ARGS_LOG:-}" ] && printf '%s\n' "$ARGS" >> "$GH_MOCK_ARGS_LOG"
case "$ARGS" in
  auth\ status*) echo "Token scopes: 'project'"; exit 0 ;;
  repo\ view\ *) echo "nirecom/agents"; exit 0 ;;
  api\ graphql\ *projectsV2*)
    case "$ARGS" in
      *"| length"*) echo "0"; exit 0 ;;
      *) echo ""; exit 0 ;;
    esac
    ;;
  api\ graphql\ *) echo ""; exit 0 ;;
  project\ item-add\ *) echo "PVTI_added"; exit 0 ;;
  project\ item-edit\ *) exit 0 ;;
  issue\ view\ *) echo "https://github.com/nirecom/agents/issues/42"; exit 0 ;;
  *) echo "MOCK GH: no match $ARGS" >&2; exit 2 ;;
esac
MOCK_EOF
chmod +x "$TMP/mock-bin/gh"
export WORKFLOW_PLANS_DIR="$TMP/plans" WORKFLOW_STATE_DIR="$TMP/state"
STDERR_FILE="$TMP/r-fail-stderr.log"
run_with_timeout 30 bash "$TARGET" 42 >/dev/null 2>"$STDERR_FILE"
RC=$?
HAS_ITEM_ADD=0
grep -q "project item-add" "$GH_MOCK_ARGS_LOG" 2>/dev/null && HAS_ITEM_ADD=1
if [ "$RC" -eq 0 ] && [ "$HAS_ITEM_ADD" -eq 0 ] && [ -s "$STDERR_FILE" ]; then
    pass "R-resolver-fail: 0 linked projects → exit 0 + warn, item-add NOT called"
else
    fail "R-resolver-fail: rc=$RC item_add=$HAS_ITEM_ADD stderr=$(cat "$STDERR_FILE" 2>/dev/null)"
fi
export WORKFLOW_PLANS_DIR="$F3142_PIN_ROOT/wf-plans" WORKFLOW_STATE_DIR="$F3142_PIN_ROOT/wf-state"
teardown_mock
