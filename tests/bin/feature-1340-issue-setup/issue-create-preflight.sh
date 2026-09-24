#!/bin/bash
# tests/feature-1340-issue-setup/issue-create-preflight.sh
# Tests: bin/github-issues/issue-create-preflight.sh
# Tags: issue-setup, issue-create-preflight, github-issues, scope:issue-specific
# N/A: secret-leakage — checks read public label/project structure, not secrets; gh owns tokens.
# N/A (C5): --repo=VALUE GNU-equals form + flexible flag ordering — the script uses space-separated flags; equals-form is not a supported surface.
#
# Tests for issue-create-preflight.sh (new file, step 6 of #1340).
# L2: --check-labels with type:task present → rc=0; absent → rc=1;
#     --check-project resolver rc=0 → rc=0; resolver rc=1 → rc=1;
#     label result independent of project result; --repo injection matrix.
# L1: --repo accepted by both flags.
#
# L3 gap (what this test does NOT catch):
# - Whether preflight correctly calls live GitHub API for label/project checks.
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: skill-orchestration.

# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

# pass / fail / AGENTS_DIR provided by _lib.sh.
TARGET="$AGENTS_DIR/bin/github-issues/issue-create-preflight.sh"
export TARGET AGENTS_DIR

# Early-exit: file does not exist yet (RED-clean)
if [ ! -f "$TARGET" ]; then
    echo "FAIL: bin/github-issues/issue-create-preflight.sh not found (implementation missing — expected RED)"
    echo ""
    echo "Results: 0 passed, 29 failed"
    exit 1
fi

TMP=""

setup_mock() {
    TMP="$(mktemp -d)"
    mkdir -p "$TMP/mock-bin"

    cat > "$TMP/mock-bin/gh" <<'MOCK_EOF'
#!/bin/bash
ARGS="$*"
if [ -n "${MOCK_LOG:-}" ]; then
    printf '%s\n' "gh $ARGS" >> "$MOCK_LOG"
fi
case "$ARGS" in
  label\ list*)
    # Hard-fail path: gh itself errors (network/auth) — distinct from a
    # successful list that merely lacks type:task.
    if [ "${GH_MOCK_LABEL_LIST_FAIL:-0}" = "1" ]; then
        echo "error: gh label list failed (simulated)" >&2
        exit 1
    fi
    if [ "${GH_MOCK_LABELS_HAVE_TASK:-1}" = "1" ]; then
        printf 'type:task\ntype:incident\n'
    else
        printf 'type:incident\n'
    fi
    exit 0
    ;;
  repo\ view\ *--json\ owner,name*)
    echo "${GH_MOCK_OWNER_REPO:-nirecom/agents}"
    exit 0
    ;;
  api\ graphql\ *projectsV2*)
    if [ "${GH_MOCK_RESOLVER_FAIL:-0}" = "1" ]; then
        echo "error: graphql failed" >&2; exit 1
    fi
    case "$ARGS" in
      *"length == 0 then empty"*|*"{id, number, ownerLogin"*)
        printf '{"id":"PVT_mock","number":1,"ownerLogin":"nirecom"}\n'
        exit 0
        ;;
      *)
        echo "1"; exit 0
        ;;
    esac
    ;;
  api\ graphql*)
    if [ "${GH_MOCK_RESOLVER_FAIL:-0}" = "1" ]; then
        echo "error: graphql failed" >&2; exit 1
    fi
    case "$ARGS" in
      *"hasNextPage"*) echo "false" ;;
      *"endCursor"*)   echo "" ;;
      *)               echo "PVTF_mock_content_date" ;;
    esac
    exit 0
    ;;
  *)
    echo "MOCK GH: no match: $ARGS" >&2; exit 2
    ;;
esac
MOCK_EOF
    chmod +x "$TMP/mock-bin/gh"

    export PATH="$TMP/mock-bin:$PATH"
    export MOCK_LOG="$TMP/mock.log"
    : > "$MOCK_LOG"
    export WORKFLOW_PLANS_DIR="$TMP/plans"
    export AGENTS_CONFIG_DIR="$TMP/agents-config"
    mkdir -p "$AGENTS_CONFIG_DIR"
}

teardown_mock() {
    if [ -n "${TMP:-}" ] && [ -d "$TMP" ]; then
        rm -rf "$TMP" 2>/dev/null || true
    fi
    TMP=""
    unset MOCK_LOG WORKFLOW_PLANS_DIR AGENTS_CONFIG_DIR \
          GH_MOCK_LABELS_HAVE_TASK GH_MOCK_RESOLVER_FAIL \
          GH_MOCK_LABEL_LIST_FAIL GH_MOCK_OWNER_REPO 2>/dev/null || true
}

# ===========================================================================
# TICP-1 (L2): --check-labels with type:task PRESENT → rc=0
# ===========================================================================
setup_mock
export GH_MOCK_LABELS_HAVE_TASK=1
RC=0
bash "$TARGET" --check-labels 2>/dev/null || RC=$?
if [ "$RC" = "0" ]; then
    pass "TICP-1 (L2): --check-labels with type:task present → rc=0"
else
    fail "TICP-1 (L2): expected rc=0 when type:task present; got rc=$RC"
fi
teardown_mock

# ===========================================================================
# TICP-2 (L2): --check-labels with type:task ABSENT → rc=1
# ===========================================================================
setup_mock
export GH_MOCK_LABELS_HAVE_TASK=0
RC=0
bash "$TARGET" --check-labels 2>/dev/null || RC=$?
if [ "$RC" = "1" ]; then
    pass "TICP-2 (L2): --check-labels with type:task absent → rc=1"
else
    fail "TICP-2 (L2): expected rc=1 when type:task absent; got rc=$RC"
fi
teardown_mock

# ===========================================================================
# TICP-2b (C6): --check-labels fail-closed — gh label list HARD-FAILS (exit 1)
# → preflight must NOT return rc=0, and must distinguish the gh error from the
# rc=1 "type:task absent" verdict (so a transient gh failure is never misread
# as "label absent" → spurious sync). Assert rc != 0 AND rc != 1.
# ===========================================================================
setup_mock
export GH_MOCK_LABEL_LIST_FAIL=1
RC=0
bash "$TARGET" --check-labels 2>/dev/null || RC=$?
if [ "$RC" != "0" ] && [ "$RC" != "1" ]; then
    pass "TICP-2b (C6): gh label list hard-fail → fail-closed with distinct rc=$RC (not 0, not 1)"
elif [ "$RC" != "0" ]; then
    fail "TICP-2b (C6): non-zero rc=$RC but NOT distinct from 'label absent' (rc=1) — cannot tell gh error from absent verdict"
else
    fail "TICP-2b (C6): gh label list hard-fail but preflight returned rc=0 (fail-open — must fail-closed)"
fi
teardown_mock

# ===========================================================================
# TICP-3 (L2): --check-project with resolver rc=0 (project found) → rc=0
# ===========================================================================
setup_mock
export GH_MOCK_RESOLVER_FAIL=0
RC=0
bash "$TARGET" --check-project 2>/dev/null || RC=$?
if [ "$RC" = "0" ]; then
    pass "TICP-3 (L2): --check-project with project found → rc=0"
else
    fail "TICP-3 (L2): expected rc=0 when project found; got rc=$RC"
fi
teardown_mock

# ===========================================================================
# TICP-4 (L2): --check-project with resolver rc=1 (no project) → rc=1
# ===========================================================================
setup_mock
export GH_MOCK_RESOLVER_FAIL=1
RC=0
bash "$TARGET" --check-project 2>/dev/null || RC=$?
if [ "$RC" = "1" ]; then
    pass "TICP-4 (L2): --check-project with no project → rc=1"
else
    fail "TICP-4 (L2): expected rc=1 when no project; got rc=$RC"
fi
teardown_mock

# ===========================================================================
# TICP-5 (L2): label check result independent of project result (both fail → both rc=1)
# ===========================================================================
setup_mock
export GH_MOCK_LABELS_HAVE_TASK=0
export GH_MOCK_RESOLVER_FAIL=1
RC_LABELS=0
bash "$TARGET" --check-labels 2>/dev/null || RC_LABELS=$?
RC_PROJECT=0
bash "$TARGET" --check-project 2>/dev/null || RC_PROJECT=$?
if [ "$RC_LABELS" = "1" ] && [ "$RC_PROJECT" = "1" ]; then
    pass "TICP-5 (L2): label and project checks are independent (both absent → both rc=1)"
else
    fail "TICP-5 (L2): expected both rc=1; labels_rc=$RC_LABELS project_rc=$RC_PROJECT"
fi
teardown_mock

# ===========================================================================
# TICP-6 (L2): label check present + project absent → label rc=0, project rc=1
# ===========================================================================
setup_mock
export GH_MOCK_LABELS_HAVE_TASK=1
export GH_MOCK_RESOLVER_FAIL=1
RC_LABELS=0
bash "$TARGET" --check-labels 2>/dev/null || RC_LABELS=$?
RC_PROJECT=0
bash "$TARGET" --check-project 2>/dev/null || RC_PROJECT=$?
if [ "$RC_LABELS" = "0" ] && [ "$RC_PROJECT" = "1" ]; then
    pass "TICP-6 (L2): labels present + project absent → labels rc=0, project rc=1 (independent)"
else
    fail "TICP-6 (L2): labels_rc=$RC_LABELS project_rc=$RC_PROJECT (expected 0 and 1)"
fi
teardown_mock

# ===========================================================================
# TICP-7 (L1): --repo accepted by --check-labels
# ===========================================================================
setup_mock
export GH_MOCK_LABELS_HAVE_TASK=1
RC=0
bash "$TARGET" --check-labels --repo "myorg/myrepo" 2>/dev/null || RC=$?
if [ "$RC" = "0" ]; then
    pass "TICP-7 (L1): --repo accepted by --check-labels"
else
    fail "TICP-7 (L1): --repo rejected or caused error with --check-labels; rc=$RC"
fi
teardown_mock

# ===========================================================================
# TICP-8 (L1): --repo accepted by --check-project
# ===========================================================================
setup_mock
export GH_MOCK_RESOLVER_FAIL=0
RC=0
bash "$TARGET" --check-project --repo "myorg/myrepo" 2>/dev/null || RC=$?
if [ "$RC" = "0" ]; then
    pass "TICP-8 (L1): --repo accepted by --check-project"
else
    fail "TICP-8 (L1): --repo rejected or caused error with --check-project; rc=$RC"
fi
teardown_mock

# ===========================================================================
# TICP-inj: table-driven --repo injection/format matrix (exercised via --check-labels).
# Contract: each invalid payload → non-zero exit AND never reaches the gh mock;
# valid owner/repo → rc=0 and gh IS called. RED until --repo validation lands.
# ===========================================================================
run_preflight_repo_case() {
    # $1=payload → sets RC, PAYLOAD_IN_LOG, GH_CALLED
    local payload="$1"
    RC=0
    bash "$TARGET" --check-labels --repo "$payload" >/dev/null 2>&1 || RC=$?
    GH_CALLED=0
    [ -s "$MOCK_LOG" ] && grep -q "^gh " "$MOCK_LOG" 2>/dev/null && GH_CALLED=1
    PAYLOAD_IN_LOG=0
    if [ -n "$payload" ] && [ -s "$MOCK_LOG" ] \
       && grep -Fq -- "$payload" "$MOCK_LOG" 2>/dev/null; then
        PAYLOAD_IN_LOG=1
    fi
}

while IFS='|' read -r name payload; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"
    payload="${payload#"${payload%%[![:space:]]*}"}"   # ltrim
    payload="${payload%"${payload##*[![:space:]]}"}"   # rtrim
    setup_mock
    export GH_MOCK_LABELS_HAVE_TASK=1
    run_preflight_repo_case "$payload"
    if [ "$RC" != "0" ] && [ "$PAYLOAD_IN_LOG" = "0" ]; then
        pass "TICP-inj[$name]: payload rejected (rc=$RC) and never reached gh mock"
    else
        fail "TICP-inj[$name]: rc=$RC payload_in_log=$PAYLOAD_IN_LOG — expect rc!=0 + payload absent"
    fi
    teardown_mock
done <<TABLE
path-traversal    | ../../etc
leading-dash      | -rf
shell-semicolon   | a/b;rm -rf c
command-subst     | a/b\$(id)
pipe-metachar     | a/b|c
and-metachar      | a/b&&c
embedded-space    | a b/c
single-segment    | noslash
trailing-slash    | owner/
leading-slash     | /repo
TABLE

# Embedded-newline payload.
setup_mock
export GH_MOCK_LABELS_HAVE_TASK=1
run_preflight_repo_case "$(printf 'a\nb/c')"
if [ "$RC" != "0" ] && [ "$PAYLOAD_IN_LOG" = "0" ]; then
    pass "TICP-inj[embedded-newline]: newline payload rejected and never reached gh mock"
else
    fail "TICP-inj[embedded-newline]: rc=$RC payload_in_log=$PAYLOAD_IN_LOG — expect rc!=0 + payload absent"
fi
teardown_mock

# Empty-string payload.
setup_mock
export GH_MOCK_LABELS_HAVE_TASK=1
RC=0
bash "$TARGET" --check-labels --repo "" >/dev/null 2>&1 || RC=$?
if [ "$RC" != "0" ]; then
    pass "TICP-inj[empty-string]: empty --repo rejected (rc=$RC)"
else
    fail "TICP-inj[empty-string]: rc=$RC — expect rc!=0"
fi
teardown_mock

# Valid case: owner/repo accepted, gh IS called.
setup_mock
export GH_MOCK_LABELS_HAVE_TASK=1
run_preflight_repo_case "owner/repo"
if [ "$RC" = "0" ] && [ "$GH_CALLED" = "1" ]; then
    pass "TICP-inj[valid]: owner/repo accepted and reaches gh mock"
else
    fail "TICP-inj[valid]: rc=$RC gh_called=$GH_CALLED — expected valid --repo passes through"
fi
teardown_mock

# ===========================================================================
# TICP-nomode (C2 fail-closed): no mode flag (neither --check-labels nor
# --check-project) → non-zero usage error AND gh not called.
# (Both flags together is out of scope — the two checks are independent.)
# ===========================================================================
setup_mock
RC=0
bash "$TARGET" 2>/dev/null || RC=$?
GH_CALLED=0
[ -s "$MOCK_LOG" ] && grep -q "^gh " "$MOCK_LOG" 2>/dev/null && GH_CALLED=1
if [ "$RC" != "0" ] && [ "$GH_CALLED" = "0" ]; then
    pass "TICP-nomode (C2): no mode flag → non-zero usage error, gh not called"
else
    fail "TICP-nomode (C2): rc=$RC gh_called=$GH_CALLED (expect non-zero + gh not called)"
fi
teardown_mock

# ===========================================================================
# TICP-noval (C2 fail-closed): --repo with no value → non-zero exit, gh not called.
# ===========================================================================
setup_mock
export GH_MOCK_LABELS_HAVE_TASK=1
RC=0
bash "$TARGET" --check-labels --repo >/dev/null 2>&1 || RC=$?
GH_CALLED=0
[ -s "$MOCK_LOG" ] && grep -q "^gh " "$MOCK_LOG" 2>/dev/null && GH_CALLED=1
if [ "$RC" != "0" ] && [ "$GH_CALLED" = "0" ]; then
    pass "TICP-noval (C2): --repo with no value → non-zero exit, gh not called (fail-closed)"
else
    fail "TICP-noval (C2): rc=$RC gh_called=$GH_CALLED (expect non-zero + gh not called)"
fi
teardown_mock

# ===========================================================================
# TICP-proj-inj (C4): --repo propagation for --check-project (mirrors the
# --check-labels matrix). Each invalid --repo → non-zero AND the payload never
# reaches the resolver/gh (no gh call carries it). RED until --repo validation
# lands on the --check-project path.
# ===========================================================================
run_project_repo_case() {
    # $1=payload → sets RC, PAYLOAD_IN_LOG, GH_CALLED
    local payload="$1"
    RC=0
    bash "$TARGET" --check-project --repo "$payload" >/dev/null 2>&1 || RC=$?
    GH_CALLED=0
    [ -s "$MOCK_LOG" ] && grep -q "^gh " "$MOCK_LOG" 2>/dev/null && GH_CALLED=1
    PAYLOAD_IN_LOG=0
    if [ -n "$payload" ] && [ -s "$MOCK_LOG" ] \
       && grep -Fq -- "$payload" "$MOCK_LOG" 2>/dev/null; then
        PAYLOAD_IN_LOG=1
    fi
}

while IFS='|' read -r name payload; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"
    payload="${payload#"${payload%%[![:space:]]*}"}"; payload="${payload%"${payload##*[![:space:]]}"}"
    setup_mock
    export GH_MOCK_RESOLVER_FAIL=0
    run_project_repo_case "$payload"
    if [ "$RC" != "0" ] && [ "$PAYLOAD_IN_LOG" = "0" ]; then
        pass "TICP-proj-inj[$name]: --check-project payload rejected (rc=$RC), never reached resolver/gh"
    else
        fail "TICP-proj-inj[$name]: rc=$RC payload_in_log=$PAYLOAD_IN_LOG — expect rc!=0 + payload absent"
    fi
    teardown_mock
done <<TABLE
path-traversal | ../../etc
leading-dash   | -rf
shell-semicolon| a/b;rm -rf c
command-subst  | a/b\$(id)
TABLE

# Valid --repo threaded into project resolution: the override owner/repo reaches
# the resolver's GraphQL call (BOARD_CARD_REPO_OVERRIDE short-circuit).
setup_mock
export GH_MOCK_RESOLVER_FAIL=0
run_project_repo_case "myorg/myrepo"
OWNER_THREADED=0
grep -Fq "myorg" "$MOCK_LOG" 2>/dev/null && grep -Fq "myrepo" "$MOCK_LOG" 2>/dev/null && OWNER_THREADED=1
if [ "$RC" = "0" ] && [ "$GH_CALLED" = "1" ] && [ "$OWNER_THREADED" = "1" ]; then
    pass "TICP-proj-inj[valid]: --check-project --repo myorg/myrepo threaded into resolver"
else
    fail "TICP-proj-inj[valid]: rc=$RC gh_called=$GH_CALLED owner_threaded=$OWNER_THREADED — expected valid --repo threaded"
fi
teardown_mock

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
