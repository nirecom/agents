
# ===========================================================================
# Helper: mint a unified mock for the resolver-integration cases (#641).
# Honors GH_MOCK_LINKED_COUNT for the projectsV2 length filter.
# ===========================================================================
mint_resolver_mock() {
    cat > "$TMP/mock-bin/gh" <<'MOCK_EOF'
#!/bin/bash
ARGS="$*"
if [ -n "${GH_MOCK_ARGS_LOG:-}" ]; then
    printf '%s\n' "$ARGS" >> "$GH_MOCK_ARGS_LOG"
fi
case "$ARGS" in
  auth\ status*)
    if [ "${GH_MOCK_MISSING_PROJECT_SCOPE:-}" = "1" ]; then
        echo "Token scopes: 'repo'"
    else
        echo "Token scopes: 'project', 'repo'"
    fi
    exit 0 ;;
  repo\ view\ *--json\ owner,name*|repo\ view\ *)
    echo "${GH_MOCK_OWNER_REPO:-nirecom/agents}"; exit 0 ;;
  api\ graphql\ *projectsV2*)
    case "$ARGS" in
      *"| length"*) echo "${GH_MOCK_LINKED_COUNT:-1}"; exit 0 ;;
      *)
        if [ "${GH_MOCK_LINKED_COUNT:-1}" -eq 0 ]; then
            echo ""
        else
            printf '{"id":"PVT_resolved","number":1,"ownerLogin":"nirecom"}\n'
        fi
        exit 0
        ;;
    esac
    ;;
  api\ graphql\ *fields*|api\ graphql\ *projectId*)
    case "$ARGS" in
      *"hasNextPage"*) echo "false"; exit 0 ;;
      *"endCursor"*)   echo ""; exit 0 ;;
      *) echo "PVTF_resolved_content_date"; exit 0 ;;
    esac
    ;;
  api\ graphql\ *createProjectV2Field*)
    echo "${GH_MOCK_NEW_FIELD_ID:-PVTF_fp_new}"; exit 0 ;;
  api\ graphql\ *projectItems*)
    printf '%s\n' "${GH_MOCK_PROJECT_ITEM_ID:-}"; exit 0 ;;
  api\ graphql\ *)
    case "$ARGS" in
      *"select(.field.id"*".name"*|*"\"Status\""*) echo "${GH_MOCK_STATUS:-In Progress}"; exit 0 ;;
      *"select(.field.id"*".text"*) echo "${GH_MOCK_FINGERPRINT:-}"; exit 0 ;;
      *) echo ""; exit 0 ;;
    esac
    ;;
  project\ item-add\ *) echo "${GH_MOCK_ITEM_ADD_ID:-PVTI_added}"; exit 0 ;;
  project\ item-edit\ *) exit 0 ;;
  issue\ view\ *)
    echo "${GH_MOCK_ISSUE_URL:-https://github.com/nirecom/agents/issues/42}"; exit 0 ;;
  *) echo "MOCK GH: no match $ARGS" >&2; exit 2 ;;
esac
MOCK_EOF
    chmod +x "$TMP/mock-bin/gh"
}

# ===========================================================================
# R-resolver-set (#641): ISSUE_CREATE_* unset + graphql mock → set <N> uses RESOLVED_PROJECT_ID.
# ===========================================================================
setup_mock
unset ISSUE_CREATE_PROJECT_ID ISSUE_CREATE_PROJECT_NUM ISSUE_CREATE_OWNER 2>/dev/null
mint_resolver_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
export WORKFLOW_PLANS_DIR_RESOLVER="$TMP/resolver-plans"
# NOTE: setup_mock already set WORKFLOW_PLANS_DIR via its own logic implicitly via
# the workflow-plans-dir stub. Resolver uses WORKFLOW_PLANS_DIR env directly.
export WORKFLOW_PLANS_DIR="$TMP/resolver-plans"
mkdir -p "$WORKFLOW_PLANS_DIR"
run_with_timeout 60 bash "$TARGET" set 42 >/dev/null 2>&1
RC=$?
HAS_RESOLVED_PROJECT_ID=0
grep -q "PVT_resolved" "$GH_MOCK_ARGS_LOG" 2>/dev/null && HAS_RESOLVED_PROJECT_ID=1
if [ "$RC" -eq 0 ] && [ "$HAS_RESOLVED_PROJECT_ID" -eq 1 ]; then
    pass "R-resolver-set: ISSUE_CREATE_* unset → set uses resolved PROJECT_ID (PVT_resolved)"
else
    fail "R-resolver-set: rc=$RC project_id_resolved=$HAS_RESOLVED_PROJECT_ID log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null)"
fi
unset WORKFLOW_PLANS_DIR
teardown_mock

# ===========================================================================
# R-resolver-check (#641): ISSUE_CREATE_* unset → check <N> outputs valid status.
# ===========================================================================
setup_mock
unset ISSUE_CREATE_PROJECT_ID ISSUE_CREATE_PROJECT_NUM ISSUE_CREATE_OWNER 2>/dev/null
mint_resolver_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
export GH_MOCK_STATUS="In Progress"
EXPECTED_FP=$(printf '%s:%s' "test-sid-fixture" "42" | sha256sum | cut -c1-8)
export GH_MOCK_FINGERPRINT="$EXPECTED_FP"
export WORKFLOW_PLANS_DIR="$TMP/resolver-plans"
mkdir -p "$WORKFLOW_PLANS_DIR"
OUT=$(run_with_timeout 60 bash "$TARGET" check 42 2>/dev/null)
RC=$?
case "$OUT" in
  same|other|none)
    if [ "$RC" -eq 0 ]; then
        pass "R-resolver-check: ISSUE_CREATE_* unset → check outputs valid '$OUT'"
    else
        fail "R-resolver-check: rc=$RC out='$OUT'"
    fi
    ;;
  *)
    fail "R-resolver-check: rc=$RC out='$OUT' — expected same|other|none"
    ;;
esac
unset WORKFLOW_PLANS_DIR
teardown_mock

# ===========================================================================
# R-resolver-preflight-fail (#641): resolver returns 0 linked → setup fails with hint.
# ===========================================================================
setup_mock
unset ISSUE_CREATE_PROJECT_ID ISSUE_CREATE_PROJECT_NUM ISSUE_CREATE_OWNER 2>/dev/null
mint_resolver_mock
export GH_MOCK_LINKED_COUNT=0
export WORKFLOW_PLANS_DIR="$TMP/resolver-plans"
mkdir -p "$WORKFLOW_PLANS_DIR"
STDERR_FILE="$TMP/r-preflight-stderr.log"
run_with_timeout 60 bash "$TARGET" setup >/dev/null 2>"$STDERR_FILE"
RC=$?
HAS_HINT=0
grep -qiE "linked|Projects v2|PROJECT_ID" "$STDERR_FILE" 2>/dev/null && HAS_HINT=1
if [ "$RC" -ne 0 ] && [ "$HAS_HINT" -eq 1 ]; then
    pass "R-resolver-preflight-fail: 0 linked → setup exits non-zero + hint on stderr"
else
    fail "R-resolver-preflight-fail: rc=$RC hint=$HAS_HINT stderr=$(cat "$STDERR_FILE" 2>/dev/null)"
fi
unset WORKFLOW_PLANS_DIR GH_MOCK_LINKED_COUNT
teardown_mock

# ===========================================================================
# R-setup-no-project (#641): alias for above — explicit "setup fails on resolver miss".
# ===========================================================================
setup_mock
unset ISSUE_CREATE_PROJECT_ID ISSUE_CREATE_PROJECT_NUM ISSUE_CREATE_OWNER 2>/dev/null
mint_resolver_mock
export GH_MOCK_LINKED_COUNT=0
export WORKFLOW_PLANS_DIR="$TMP/resolver-plans"
mkdir -p "$WORKFLOW_PLANS_DIR"
STDERR_FILE="$TMP/r-setup-noproj-stderr.log"
run_with_timeout 60 bash "$TARGET" setup >/dev/null 2>"$STDERR_FILE"
RC=$?
if [ "$RC" -ne 0 ] && [ -s "$STDERR_FILE" ]; then
    pass "R-setup-no-project: setup fails when resolver finds no linked project"
else
    fail "R-setup-no-project: rc=$RC stderr=$(cat "$STDERR_FILE" 2>/dev/null)"
fi
unset WORKFLOW_PLANS_DIR GH_MOCK_LINKED_COUNT
teardown_mock

# ===========================================================================
# R-resolver-clear (#641): ISSUE_CREATE_* unset → clear <N> succeeds.
# Demonstrates non-fatal posture (clear should succeed when resolver works).
# ===========================================================================
setup_mock
unset ISSUE_CREATE_PROJECT_ID ISSUE_CREATE_PROJECT_NUM ISSUE_CREATE_OWNER 2>/dev/null
mint_resolver_mock
export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing"
export WORKFLOW_PLANS_DIR="$TMP/resolver-plans"
mkdir -p "$WORKFLOW_PLANS_DIR"
run_with_timeout 60 bash "$TARGET" clear 42 >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 0 ]; then
    pass "R-resolver-clear: ISSUE_CREATE_* unset → clear succeeds via resolver"
else
    fail "R-resolver-clear: rc=$RC log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null)"
fi
unset WORKFLOW_PLANS_DIR
teardown_mock
