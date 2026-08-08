#!/usr/bin/env bash
# tests/fix-488-ensure-project-ready-link-repo.sh
# Tests: bin/github-issues/lib/ensure-project-ready.sh, bin/github-issues/migration/link-project.sh
# Tags: github-issues, issue-setup, ensure-project-ready, link-project, scope:issue-specific
#
# Regression test for #488 (reopened): the /issue-setup path
# (bin/github-issues/lib/ensure-project-ready.sh) creates or reuses a Projects v2
# board but never links it to the repository. The sibling migration path
# (migration/create-project.sh) was already fixed via link_project_to_repo();
# this file is the missing coverage for the /issue-setup path, and mirrors
# tests/fix-488-create-project-link-repo.sh (its L1/L2/L3/L5 → LNK-1..LNK-4).
# The migration test's L4 (dry-run) is NOT ported: ensure_project_ready() has no
# dry-run mode.
#
# TL3 gap (what this test does NOT catch):
# - Whether the real GitHub GraphQL API's linkProjectV2ToRepository mutation
#   actually attaches the board to the repository (this is a mocked gh CLI).
# - Whether repeated link calls are truly server-side idempotent — LNK-4 only
#   proves the client re-issues the mutation, not that GitHub tolerates it.
# - Whether the repo node_id returned by `gh api repos/<o>/<r> --jq .node_id` is
#   the id shape linkProjectV2ToRepository accepts.
# Closest-to-action mitigation: none of bin/check-verification-gate.sh's risk
# categories (hook-registration, installer, pwsh-required, skill-orchestration,
# merge-base-suspect) fires for this change's bin/ + tests/ file set — verified
# empirically by running the classifier over those paths, which emits no
# CATEGORY line. So the USER_VERIFIED preflight will NOT ask about this gap.
# The closer is therefore explicit: run with RUN_TL4=on, or manually invoke
# /issue-setup twice against a scratch repo and confirm on github.com that the
# board appears under the repo's Projects tab after both runs.

# shellcheck source=feature-1340-issue-setup/_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/feature-1340-issue-setup/_lib.sh"
# shellcheck source=feature-1340-issue-setup/_mock-ensure-project-ready.sh
. "$(dirname "${BASH_SOURCE[0]}")/feature-1340-issue-setup/_mock-ensure-project-ready.sh"

TARGET="$AGENTS_DIR/bin/github-issues/lib/ensure-project-ready.sh"
export TARGET

if [ ! -f "$TARGET" ]; then
    echo "FAIL: bin/github-issues/lib/ensure-project-ready.sh not found"
    echo ""
    echo "Results: 0 passed, 4 failed"
    exit 1
fi

TMP=""

setup_mock() {
    TMP="$(mktemp -d)"
    mkdir -p "$TMP/mock-bin"
    write_epr_gh_mock "$TMP/mock-bin/gh"
    export PATH="$TMP/mock-bin:$PATH"
    export MOCK_LOG="$TMP/mock.log"
    : > "$MOCK_LOG"
    export WORKFLOW_PLANS_DIR="$TMP/plans"
    # Pin every knob explicitly (test-design.md "Config-dependent branches").
    export GH_MOCK_AUTH_HAS_PROJECT=1
    export GH_MOCK_STATUS_FIELD_EXISTS=1
    export GH_MOCK_FINGERPRINT_FIELD_EXISTS=1
    export GH_MOCK_FINGERPRINT_CREATE_FAIL=0
    export GH_MOCK_LINK_FAILS=0
}

teardown_mock() {
    if [ -n "${TMP:-}" ] && [ -d "$TMP" ]; then
        rm -rf "$TMP" 2>/dev/null || true
    fi
    TMP=""
    unset MOCK_LOG WORKFLOW_PLANS_DIR \
          GH_MOCK_AUTH_HAS_PROJECT GH_MOCK_PROJECT_EXISTS GH_MOCK_PROJECT_LIST_FAIL \
          GH_MOCK_STATUS_FIELD_EXISTS GH_MOCK_FINGERPRINT_FIELD_EXISTS \
          GH_MOCK_FINGERPRINT_CREATE_FAIL GH_MOCK_LINK_FAILS \
          EPR_PROJECT_ID EPR_PROJECT_NUM EPR_PROJECT_OWNER \
          EPR_CONTENT_DATE_FIELD_ID EPR_STATUS_FIELD_ID EPR_TODO_OPTION_ID \
          EPR_IN_PROGRESS_OPTION_ID EPR_DONE_OPTION_ID \
          EPR_FINGERPRINT_FIELD_ID 2>/dev/null || true
}

# Run ensure_project_ready in a subshell; echo the EPR_* round-trip block + RC.
run_ensure() {
    local owner_repo="${1-testowner/testrepo}"
    local stderr_file="${2:-/dev/null}"
    run_with_timeout 120 bash -c "
        source '$TARGET' >/dev/null 2>&1 || { echo 'RC=99'; exit 99; }
        if ensure_project_ready '$owner_repo'; then RC=0; else RC=\$?; fi
        printf 'EPR_PROJECT_ID=%s\n'            \"\${EPR_PROJECT_ID:-}\"
        printf 'EPR_PROJECT_NUM=%s\n'           \"\${EPR_PROJECT_NUM:-}\"
        printf 'EPR_PROJECT_OWNER=%s\n'         \"\${EPR_PROJECT_OWNER:-}\"
        printf 'EPR_STATUS_FIELD_ID=%s\n'       \"\${EPR_STATUS_FIELD_ID:-}\"
        printf 'EPR_TODO_OPTION_ID=%s\n'        \"\${EPR_TODO_OPTION_ID:-}\"
        printf 'EPR_IN_PROGRESS_OPTION_ID=%s\n' \"\${EPR_IN_PROGRESS_OPTION_ID:-}\"
        printf 'EPR_DONE_OPTION_ID=%s\n'        \"\${EPR_DONE_OPTION_ID:-}\"
        printf 'EPR_FINGERPRINT_FIELD_ID=%s\n'  \"\${EPR_FINGERPRINT_FIELD_ID:-}\"
        printf 'RC=%s\n' \"\$RC\"
    " 2>"$stderr_file"
}

# Isolate the single log line carrying the link mutation, so argument-wiring
# assertions (-f p= / -f r=) are made against THAT call and cannot be satisfied
# by `-f p=` appearing on some other mutation's line.
link_line() {
    grep -F 'linkProjectV2ToRepository' "$MOCK_LOG" 2>/dev/null | head -1
}

REPO_NODE_ID="R_kgDOmockrepo"   # what the mock's `api repos/*` arm emits

# ===========================================================================
# LNK-1: new-project (create) path → board is linked to the repo.
# ===========================================================================
setup_mock
export GH_MOCK_PROJECT_EXISTS=0    # no board → createProjectV2 → id PVT_new
STDERR_FILE="$TMP/lnk1-stderr.log"
OUT=$(run_ensure 'testowner/testrepo' "$STDERR_FILE")
RC=$(get_field "$OUT" RC)
R_PID=$(get_field "$OUT" EPR_PROJECT_ID)
NODE_LOOKUP=0
grep -Fq 'gh api repos/testowner/testrepo' "$MOCK_LOG" 2>/dev/null && NODE_LOOKUP=1
LINK_LINE="$(link_line)"
LINK_P=0
LINK_R=0
[ -n "$LINK_LINE" ] && printf '%s' "$LINK_LINE" | grep -Fq -- "-f p=$R_PID" && LINK_P=1
[ -n "$LINK_LINE" ] && printf '%s' "$LINK_LINE" | grep -Fq -- "-f r=$REPO_NODE_ID" && LINK_R=1
if [ "$RC" = "0" ] \
   && [ "$R_PID" = "PVT_new" ] \
   && [ "$NODE_LOOKUP" = "1" ] \
   && [ -n "$LINK_LINE" ] \
   && [ "$LINK_P" = "1" ] \
   && [ "$LINK_R" = "1" ]; then
    pass "LNK-1: create path → repo node_id looked up + linkProjectV2ToRepository wired (p=$R_PID r=$REPO_NODE_ID)"
else
    fail "LNK-1: rc=$RC pid=$R_PID node_lookup=$NODE_LOOKUP link_line='$LINK_LINE' link_p=$LINK_P link_r=$LINK_R log=$(cat "$MOCK_LOG" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# LNK-2: existing-project (reuse) path → board is linked to the repo too.
# CPR-ORTH counterpart of LNK-1: both convergence paths must link.
# ===========================================================================
setup_mock
export GH_MOCK_PROJECT_EXISTS=1    # board exists → reuse → id PVT_existing
STDERR_FILE="$TMP/lnk2-stderr.log"
OUT=$(run_ensure 'testowner/testrepo' "$STDERR_FILE")
RC=$(get_field "$OUT" RC)
R_PID=$(get_field "$OUT" EPR_PROJECT_ID)
NODE_LOOKUP=0
grep -Fq 'gh api repos/testowner/testrepo' "$MOCK_LOG" 2>/dev/null && NODE_LOOKUP=1
LINK_LINE="$(link_line)"
LINK_P=0
LINK_R=0
[ -n "$LINK_LINE" ] && printf '%s' "$LINK_LINE" | grep -Fq -- "-f p=$R_PID" && LINK_P=1
[ -n "$LINK_LINE" ] && printf '%s' "$LINK_LINE" | grep -Fq -- "-f r=$REPO_NODE_ID" && LINK_R=1
if [ "$RC" = "0" ] \
   && [ "$R_PID" = "PVT_existing" ] \
   && [ "$NODE_LOOKUP" = "1" ] \
   && [ -n "$LINK_LINE" ] \
   && [ "$LINK_P" = "1" ] \
   && [ "$LINK_R" = "1" ]; then
    pass "LNK-2: reuse path → repo node_id looked up + linkProjectV2ToRepository wired (p=$R_PID r=$REPO_NODE_ID)"
else
    fail "LNK-2: rc=$RC pid=$R_PID node_lookup=$NODE_LOOKUP link_line='$LINK_LINE' link_p=$LINK_P link_r=$LINK_R log=$(cat "$MOCK_LOG" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# LNK-3: link failure is NON-FATAL — ensure_project_ready still returns 0 and
# still exports the downstream EPR_* contract.
# The link call must be ASSERTED PRESENT as a precondition: without it, "no link
# failure occurred" would spuriously satisfy the non-fatality claim (this case
# has to be RED on the unfixed source too, not accidentally green).
# ===========================================================================
setup_mock
export GH_MOCK_PROJECT_EXISTS=1
export GH_MOCK_LINK_FAILS=1
STDERR_FILE="$TMP/lnk3-stderr.log"
OUT=$(run_ensure 'testowner/testrepo' "$STDERR_FILE")
RC=$(get_field "$OUT" RC)
R_PID=$(get_field "$OUT" EPR_PROJECT_ID)
R_PNUM=$(get_field "$OUT" EPR_PROJECT_NUM)
R_POWNER=$(get_field "$OUT" EPR_PROJECT_OWNER)
R_STATUS=$(get_field "$OUT" EPR_STATUS_FIELD_ID)
R_TODO=$(get_field "$OUT" EPR_TODO_OPTION_ID)
R_INPROG=$(get_field "$OUT" EPR_IN_PROGRESS_OPTION_ID)
R_DONE=$(get_field "$OUT" EPR_DONE_OPTION_ID)
R_FINGER=$(get_field "$OUT" EPR_FINGERPRINT_FIELD_ID)
LINK_ATTEMPTED=0
[ -n "$(link_line)" ] && LINK_ATTEMPTED=1
if [ "$LINK_ATTEMPTED" = "1" ] \
   && [ "$RC" = "0" ] \
   && [ "$R_PID" = "PVT_existing" ] \
   && [ "$R_PNUM" = "1" ] \
   && [ "$R_POWNER" = "testowner" ] \
   && [ "$R_STATUS" = "PVTF_existing_status" ] \
   && [ "$R_TODO" = "opt_todo" ] \
   && [ "$R_INPROG" = "opt_inprog" ] \
   && [ "$R_DONE" = "opt_done" ] \
   && [ "$R_FINGER" = "PVTF_existing_finger" ]; then
    pass "LNK-3: link mutation attempted and failed → rc=0 and full EPR_* contract intact (non-fatal)"
else
    fail "LNK-3: link_attempted=$LINK_ATTEMPTED rc=$RC pid=$R_PID pnum=$R_PNUM powner=$R_POWNER status=$R_STATUS todo=$R_TODO inprog=$R_INPROG done=$R_DONE finger=$R_FINGER log=$(cat "$MOCK_LOG" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# LNK-4: STATELESS — two runs issue the link mutation TWICE.
# Deliberate INVERSION of the migration-path test's L5 ("second run skips link
# mutation when repo_linked=true"): that contract exists only because
# create-project.sh persists .migration-state.json. ensure-project-ready.sh was
# extracted with all .migration-state.json dependencies removed, so it has no
# memory of a prior link and MUST re-issue the mutation (GitHub treats the link
# as idempotent server-side). A dedupe here would be the bug, not the fix.
# ===========================================================================
setup_mock
export GH_MOCK_PROJECT_EXISTS=1
STDERR_FILE="$TMP/lnk4-stderr.log"
OUT1=$(run_ensure 'testowner/testrepo' "$STDERR_FILE")
RC1=$(get_field "$OUT1" RC)
OUT2=$(run_ensure 'testowner/testrepo' "$STDERR_FILE")   # same MOCK_LOG accumulates
RC2=$(get_field "$OUT2" RC)
# NB: `grep -c` already prints 0 on no-match (exit 1) — `|| true`, never
# `|| echo 0`, or the variable becomes the two-line string "0\n0".
LINK_COUNT=$(grep -cF 'linkProjectV2ToRepository' "$MOCK_LOG" 2>/dev/null || true)
NODE_LOOKUP_COUNT=$(grep -cF 'gh api repos/testowner/testrepo' "$MOCK_LOG" 2>/dev/null || true)
if [ "$RC1" = "0" ] \
   && [ "$RC2" = "0" ] \
   && [ "$LINK_COUNT" = "2" ] \
   && [ "$NODE_LOOKUP_COUNT" = "2" ]; then
    pass "LNK-4: stateless — 2 runs → 2 link mutations + 2 node-id lookups (no dedupe, by design)"
else
    fail "LNK-4: rc1=$RC1 rc2=$RC2 link_count=$LINK_COUNT node_lookup_count=$NODE_LOOKUP_COUNT (expected 0/0/2/2) log=$(cat "$MOCK_LOG" 2>/dev/null)"
fi
teardown_mock

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
