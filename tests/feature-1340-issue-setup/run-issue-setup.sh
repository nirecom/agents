#!/bin/bash
# tests/feature-1340-issue-setup/run-issue-setup.sh
# Tests: skills/issue-setup/scripts/run-issue-setup.sh
# Tags: issue-setup, run-issue-setup, github-issues, scope:issue-specific
# N/A: prompt-injection/AskUserQuestion — repo-confirm prompt is interactive (SKILL.md orchestration), covered by the skill-orchestration verification-gate at user_verification, not L2-testable.
#
# Tests for skills/issue-setup/scripts/run-issue-setup.sh (new, step 5 of #1340).
# L2: --step labels dispatches to sync-labels (with --repo threaded);
#     --step check-project dispatches to preflight --check-project;
#     --step ensure-project invokes ensure-project-ready; --repo injection matrix.
# L1: arg parse (--step value validation, --repo format).
#
# L3 gap (what this test does NOT catch):
# - Whether /issue-setup skill correctly invokes run-issue-setup.sh in a live
#   Claude Code session, or whether the AskUserQuestion for repo confirmation
#   fires and resolves correctly.
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: skill-orchestration.

# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

# pass / fail / AGENTS_DIR provided by _lib.sh.
TARGET="$AGENTS_DIR/skills/issue-setup/scripts/run-issue-setup.sh"
export TARGET AGENTS_DIR

# Early-exit: file does not exist yet (RED-clean)
if [ ! -f "$TARGET" ]; then
    echo "FAIL: skills/issue-setup/scripts/run-issue-setup.sh not found (implementation missing — expected RED)"
    echo ""
    echo "Results: 0 passed, 25 failed"
    exit 1
fi

TMP=""

setup_mock() {
    TMP="$(mktemp -d)"
    mkdir -p "$TMP/mock-bin"

    # Mock sync-labels.sh in agents config
    export AGENTS_CONFIG_DIR="$TMP/agents-config"
    mkdir -p "$AGENTS_CONFIG_DIR/bin/github-issues" \
             "$AGENTS_CONFIG_DIR/bin/github-issues/lib" \
             "$AGENTS_CONFIG_DIR/.github"
    touch "$AGENTS_CONFIG_DIR/.github/labels.yml"

    cat > "$TMP/mock-bin/sync-labels-dispatch" <<'SYNC_EOF'
#!/bin/bash
if [ -n "${MOCK_LOG:-}" ]; then
    printf 'sync-labels: %s\n' "$*" >> "$MOCK_LOG"
fi
exit "${GH_MOCK_SYNC_FAIL:-0}"
SYNC_EOF
    chmod +x "$TMP/mock-bin/sync-labels-dispatch"

    # Create mock sync-labels.sh at the expected location
    cat > "$AGENTS_CONFIG_DIR/bin/github-issues/sync-labels.sh" <<'SYNC_EOF'
#!/bin/bash
if [ -n "${MOCK_LOG:-}" ]; then
    printf 'sync-labels: %s\n' "$*" >> "$MOCK_LOG"
fi
exit "${GH_MOCK_SYNC_FAIL:-0}"
SYNC_EOF
    chmod +x "$AGENTS_CONFIG_DIR/bin/github-issues/sync-labels.sh"

    # Create mock issue-create-preflight.sh
    cat > "$AGENTS_CONFIG_DIR/bin/github-issues/issue-create-preflight.sh" <<'PREFLIGHT_EOF'
#!/bin/bash
if [ -n "${MOCK_LOG:-}" ]; then
    printf 'preflight: %s\n' "$*" >> "$MOCK_LOG"
fi
case "$*" in
  *--check-project*)
    exit "${GH_MOCK_PROJECT_RC:-0}"
    ;;
  *--check-labels*)
    exit "${GH_MOCK_LABELS_RC:-0}"
    ;;
  *)
    exit 2
    ;;
esac
PREFLIGHT_EOF
    chmod +x "$AGENTS_CONFIG_DIR/bin/github-issues/issue-create-preflight.sh"

    # Create mock ensure-project-ready.sh lib
    cat > "$AGENTS_CONFIG_DIR/bin/github-issues/lib/ensure-project-ready.sh" <<'EPR_EOF'
#!/bin/bash
# Sourced lib — define ensure_project_ready function
ensure_project_ready() {
    if [ -n "${MOCK_LOG:-}" ]; then
        printf 'ensure-project-ready: %s\n' "$1" >> "$MOCK_LOG"
    fi
    EPR_PROJECT_ID="PVT_mock"
    EPR_STATUS_FIELD_ID="PVTF_mock_status"
    EPR_TODO_OPTION_ID="opt_mock_todo"
    EPR_IN_PROGRESS_OPTION_ID="opt_mock_inprog"
    EPR_DONE_OPTION_ID="opt_mock_done"
    EPR_FINGERPRINT_FIELD_ID="PVTF_mock_finger"
    return "${GH_MOCK_EPR_RC:-0}"
}
EPR_EOF

    # Mock gh
    cat > "$TMP/mock-bin/gh" <<'GH_MOCK_EOF'
#!/bin/bash
ARGS="$*"
if [ -n "${MOCK_LOG:-}" ]; then
    printf '%s\n' "gh $ARGS" >> "$MOCK_LOG"
fi
case "$ARGS" in
  repo\ view\ *--json\ owner,name*)
    echo "nirecom/agents"; exit 0
    ;;
  api\ graphql\ *projectsV2*)
    printf '{"id":"PVT_mock","number":1,"ownerLogin":"nirecom"}\n'; exit 0
    ;;
  api\ graphql*)
    echo "false"; exit 0
    ;;
  label\ list*) printf 'type:task\n'; exit 0 ;;
  label\ create*) exit 0 ;;
  *)
    echo "MOCK GH: no match: $ARGS" >&2; exit 0
    ;;
esac
GH_MOCK_EOF
    chmod +x "$TMP/mock-bin/gh"

    export PATH="$TMP/mock-bin:$PATH"
    export MOCK_LOG="$TMP/mock.log"
    : > "$MOCK_LOG"
    export WORKFLOW_PLANS_DIR="$TMP/plans"
}

teardown_mock() {
    if [ -n "${TMP:-}" ] && [ -d "$TMP" ]; then
        rm -rf "$TMP" 2>/dev/null || true
    fi
    TMP=""
    unset MOCK_LOG WORKFLOW_PLANS_DIR AGENTS_CONFIG_DIR \
          GH_MOCK_SYNC_FAIL GH_MOCK_PROJECT_RC GH_MOCK_LABELS_RC \
          GH_MOCK_EPR_RC 2>/dev/null || true
}

# ===========================================================================
# TRIS-1 (L2): --step labels dispatches to sync-labels with --repo threaded
# ===========================================================================
setup_mock
export GH_MOCK_SYNC_FAIL=0
RC=0
bash "$TARGET" --step labels --repo "myorg/myrepo" 2>/dev/null || RC=$?
SYNC_CALLED=0
grep -q "sync-labels:.*--repo myorg/myrepo\|sync-labels: --repo myorg/myrepo" "$MOCK_LOG" 2>/dev/null && SYNC_CALLED=1
if [ "$RC" = "0" ] && [ "$SYNC_CALLED" = "1" ]; then
    pass "TRIS-1 (L2): --step labels → sync-labels called with --repo myorg/myrepo"
else
    fail "TRIS-1 (L2): rc=$RC sync_called=$SYNC_CALLED log=$(cat "$MOCK_LOG" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# TRIS-2 (L2): --step check-project dispatches to preflight --check-project
# ===========================================================================
setup_mock
export GH_MOCK_PROJECT_RC=0
RC=0
bash "$TARGET" --step check-project --repo "myorg/myrepo" 2>/dev/null || RC=$?
PREFLIGHT_CALLED=0
grep -q "preflight:.*--check-project" "$MOCK_LOG" 2>/dev/null && PREFLIGHT_CALLED=1
if [ "$RC" = "0" ] && [ "$PREFLIGHT_CALLED" = "1" ]; then
    pass "TRIS-2 (L2): --step check-project → preflight --check-project called"
else
    fail "TRIS-2 (L2): rc=$RC preflight_called=$PREFLIGHT_CALLED log=$(cat "$MOCK_LOG" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# TRIS-3 (L2): --step check-project rc=1 (no project) → script returns rc=1
# ===========================================================================
setup_mock
export GH_MOCK_PROJECT_RC=1
RC=0
bash "$TARGET" --step check-project --repo "myorg/myrepo" 2>/dev/null || RC=$?
if [ "$RC" = "1" ]; then
    pass "TRIS-3 (L2): --step check-project → rc=1 when no project found"
else
    fail "TRIS-3 (L2): expected rc=1 when no project; got rc=$RC"
fi
teardown_mock

# ===========================================================================
# TRIS-4 (L2): --step ensure-project → invokes ensure-project-ready
# ===========================================================================
setup_mock
export GH_MOCK_EPR_RC=0
RC=0
bash "$TARGET" --step ensure-project --repo "myorg/myrepo" 2>/dev/null || RC=$?
EPR_CALLED=0
grep -q "ensure-project-ready: myorg/myrepo" "$MOCK_LOG" 2>/dev/null && EPR_CALLED=1
if [ "$RC" = "0" ] && [ "$EPR_CALLED" = "1" ]; then
    pass "TRIS-4 (L2): --step ensure-project → ensure_project_ready called"
else
    fail "TRIS-4 (L2): rc=$RC epr_called=$EPR_CALLED log=$(cat "$MOCK_LOG" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# TRIS-4b (C6): --step labels error propagation — sync-labels.sh exits non-zero
# → run-issue-setup returns the SAME non-zero rc (does not swallow to 0).
# ===========================================================================
setup_mock
export GH_MOCK_SYNC_FAIL=3
RC=0
bash "$TARGET" --step labels --repo "myorg/myrepo" 2>/dev/null || RC=$?
if [ "$RC" = "3" ]; then
    pass "TRIS-4b (C6): --step labels → sync-labels rc=3 propagated (exact rc)"
elif [ "$RC" != "0" ]; then
    pass "TRIS-4b (C6): --step labels → sync-labels failure propagated (non-zero rc=$RC)"
else
    fail "TRIS-4b (C6): sync-labels failed but run-issue-setup returned 0 (error swallowed)"
fi
teardown_mock

# ===========================================================================
# TRIS-4c (C6): --step ensure-project error propagation — ensure_project_ready
# fails → run-issue-setup returns failure (non-zero).
# ===========================================================================
setup_mock
export GH_MOCK_EPR_RC=1
RC=0
bash "$TARGET" --step ensure-project --repo "myorg/myrepo" 2>/dev/null || RC=$?
if [ "$RC" != "0" ]; then
    pass "TRIS-4c (C6): --step ensure-project → ensure_project_ready failure propagated (rc=$RC)"
else
    fail "TRIS-4c (C6): ensure_project_ready failed but run-issue-setup returned 0 (error swallowed)"
fi
teardown_mock

# ===========================================================================
# TRIS-5 (L1): unknown --step value → non-zero BEFORE dispatch (no downstream
# sync-labels/preflight/ensure-project-ready call reaches the mock).
# ===========================================================================
setup_mock
RC=0
bash "$TARGET" --step invalid-step --repo "myorg/myrepo" 2>/dev/null || RC=$?
DISPATCHED=0
[ -s "$MOCK_LOG" ] && grep -qE "^sync-labels:|^preflight:|^ensure-project-ready:" "$MOCK_LOG" 2>/dev/null && DISPATCHED=1
if [ "$RC" != "0" ] && [ "$DISPATCHED" = "0" ]; then
    pass "TRIS-5 (L1): unknown --step value → non-zero, no dispatch"
else
    fail "TRIS-5 (L1): rc=$RC dispatched=$DISPATCHED (expect non-zero + no dispatch)"
fi
teardown_mock

# ===========================================================================
# TRIS-5b (C9 fail-closed): --step with no value → non-zero, no dispatch.
# ===========================================================================
setup_mock
RC=0
bash "$TARGET" --step 2>/dev/null || RC=$?
DISPATCHED=0
[ -s "$MOCK_LOG" ] && grep -qE "^sync-labels:|^preflight:|^ensure-project-ready:" "$MOCK_LOG" 2>/dev/null && DISPATCHED=1
if [ "$RC" != "0" ] && [ "$DISPATCHED" = "0" ]; then
    pass "TRIS-5b (C9): --step with no value → non-zero, no dispatch (fail-closed)"
else
    fail "TRIS-5b (C9): rc=$RC dispatched=$DISPATCHED (expect non-zero + no dispatch)"
fi
teardown_mock

# ===========================================================================
# TRIS-5c (C9 fail-closed): --repo with no value → non-zero, no dispatch.
# ===========================================================================
setup_mock
RC=0
bash "$TARGET" --step labels --repo 2>/dev/null || RC=$?
DISPATCHED=0
[ -s "$MOCK_LOG" ] && grep -qE "^sync-labels:|^preflight:|^ensure-project-ready:" "$MOCK_LOG" 2>/dev/null && DISPATCHED=1
if [ "$RC" != "0" ] && [ "$DISPATCHED" = "0" ]; then
    pass "TRIS-5c (C9): --repo with no value → non-zero, no dispatch (fail-closed)"
else
    fail "TRIS-5c (C9): rc=$RC dispatched=$DISPATCHED (expect non-zero + no dispatch)"
fi
teardown_mock

# ===========================================================================
# TRIS-6 (L1): missing --step → exit non-zero
# ===========================================================================
setup_mock
RC=0
bash "$TARGET" --repo "myorg/myrepo" 2>/dev/null || RC=$?
if [ "$RC" != "0" ]; then
    pass "TRIS-6 (L1): missing --step → exit non-zero"
else
    fail "TRIS-6 (L1): expected non-zero exit for missing --step; got rc=$RC"
fi
teardown_mock

# ===========================================================================
# TRIS-7 (L1): invalid --repo format → exit non-zero
# ===========================================================================
setup_mock
RC=0
bash "$TARGET" --step labels --repo "no-slash-here" 2>/dev/null || RC=$?
if [ "$RC" != "0" ]; then
    pass "TRIS-7 (L1): invalid --repo format (no slash) → exit non-zero"
else
    fail "TRIS-7 (L1): expected non-zero exit for invalid --repo; got rc=$RC"
fi
teardown_mock

# ===========================================================================
# TRIS-8 (L1): --repo is required for all steps → missing --repo exits non-zero
# ===========================================================================
setup_mock
RC=0
bash "$TARGET" --step labels 2>/dev/null || RC=$?
if [ "$RC" != "0" ]; then
    pass "TRIS-8 (L1): missing --repo → exit non-zero"
else
    fail "TRIS-8 (L1): expected non-zero exit for missing --repo; got rc=$RC"
fi
teardown_mock

# ===========================================================================
# TRIS-inj: table-driven --repo injection/format matrix (via --step labels).
# Contract: each invalid payload → non-zero exit AND run-issue-setup rejects it
# BEFORE dispatching downstream, so the payload NEVER appears in MOCK_LOG
# (no sync-labels:/preflight:/ensure-project-ready: line carries it).
# Valid owner/repo → rc=0 and IS threaded to sync-labels. RED until validation lands.
# ===========================================================================
run_setup_repo_case() {
    # $1=payload → sets RC, PAYLOAD_IN_LOG, DISPATCHED
    local payload="$1"
    RC=0
    bash "$TARGET" --step labels --repo "$payload" >/dev/null 2>&1 || RC=$?
    DISPATCHED=0
    [ -s "$MOCK_LOG" ] && grep -q "^sync-labels:" "$MOCK_LOG" 2>/dev/null && DISPATCHED=1
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
    export GH_MOCK_SYNC_FAIL=0
    run_setup_repo_case "$payload"
    if [ "$RC" != "0" ] && [ "$PAYLOAD_IN_LOG" = "0" ]; then
        pass "TRIS-inj[$name]: payload rejected (rc=$RC) and never dispatched downstream"
    else
        fail "TRIS-inj[$name]: rc=$RC payload_in_log=$PAYLOAD_IN_LOG — expect rc!=0 + payload absent from MOCK_LOG"
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
export GH_MOCK_SYNC_FAIL=0
run_setup_repo_case "$(printf 'a\nb/c')"
if [ "$RC" != "0" ] && [ "$PAYLOAD_IN_LOG" = "0" ]; then
    pass "TRIS-inj[embedded-newline]: newline payload rejected and never dispatched"
else
    fail "TRIS-inj[embedded-newline]: rc=$RC payload_in_log=$PAYLOAD_IN_LOG — expect rc!=0 + payload absent"
fi
teardown_mock

# Empty-string payload.
setup_mock
export GH_MOCK_SYNC_FAIL=0
RC=0
bash "$TARGET" --step labels --repo "" >/dev/null 2>&1 || RC=$?
DISPATCHED=0
[ -s "$MOCK_LOG" ] && grep -q "^sync-labels:" "$MOCK_LOG" 2>/dev/null && DISPATCHED=1
if [ "$RC" != "0" ] && [ "$DISPATCHED" = "0" ]; then
    pass "TRIS-inj[empty-string]: empty --repo rejected and never dispatched"
else
    fail "TRIS-inj[empty-string]: rc=$RC dispatched=$DISPATCHED — expect rc!=0 + no dispatch"
fi
teardown_mock

# Valid case: owner/repo accepted, threaded to sync-labels.
setup_mock
export GH_MOCK_SYNC_FAIL=0
run_setup_repo_case "owner/repo"
if [ "$RC" = "0" ] && [ "$DISPATCHED" = "1" ] && [ "$PAYLOAD_IN_LOG" = "1" ]; then
    pass "TRIS-inj[valid]: owner/repo accepted and threaded to sync-labels"
else
    fail "TRIS-inj[valid]: rc=$RC dispatched=$DISPATCHED payload_in_log=$PAYLOAD_IN_LOG — expected valid --repo threaded"
fi
teardown_mock

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
