#!/bin/bash
# tests/feature-1340-issue-setup/ensure-project-ready.sh
# Tests: bin/github-issues/lib/ensure-project-ready.sh
# Tags: issue-setup, ensure-project-ready, github-issues, scope:issue-specific
# N/A: secret-leakage — created field IDs are project-structure identifiers, not secrets; gh owns token handling.
# N/A (C5 option-repair): Status-exists-but-options-missing/malformed — plan defines create-if-missing only, not option repair; out of scope.
# N/A (C1/C5 failure perms): deep per-mutation failure matrix (createProjectV2 board-create + updateProjectV2Field option-update permutations) deferred — core create + idempotency + partial-retry covered by TEP-1/6/7; one project-list hard-fail representative kept (TEP-9).
#
# Tests for ensure-project-ready.sh (new lib, step 2 of #1340).
# L2: project exists + Status field missing → createProjectV2Field + updateProjectV2Field called;
#     project exists + Status field present → create mutations NOT called (idempotent);
#     fingerprint field missing → createProjectV2Field (TEXT) called;
#     partial-failure idempotency-retry (TEXT fails then retried, Status created once);
#     gh auth missing project scope → error + hint + rc=1.
#
# L3 gap (what this test does NOT catch):
# - Whether GitHub Projects API actually creates fields with the correct options
#   (real network, live GraphQL mutations).
# - Whether the returned option IDs are stable after creation.
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: skill-orchestration.

# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
# shellcheck source=_mock-ensure-project-ready.sh
. "$(dirname "${BASH_SOURCE[0]}")/_mock-ensure-project-ready.sh"

TARGET="$AGENTS_DIR/bin/github-issues/lib/ensure-project-ready.sh"
export TARGET

# Early-exit: file does not exist yet (RED-clean)
if [ ! -f "$TARGET" ]; then
    echo "FAIL: bin/github-issues/lib/ensure-project-ready.sh not found (implementation missing — expected RED)"
    echo ""
    echo "Results: 0 passed, 18 failed"
    exit 1
fi

TMP=""

setup_mock() {
    TMP="$(mktemp -d)"
    mkdir -p "$TMP/mock-bin"

    # Default mock knobs
    : "${GH_MOCK_AUTH_HAS_PROJECT:=1}"
    : "${GH_MOCK_PROJECT_EXISTS:=1}"
    : "${GH_MOCK_STATUS_FIELD_EXISTS:=0}"
    : "${GH_MOCK_FINGERPRINT_FIELD_EXISTS:=0}"

    # File-specific gh mock (defined in _mock-ensure-project-ready.sh).
    write_epr_gh_mock "$TMP/mock-bin/gh"
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
    unset MOCK_LOG WORKFLOW_PLANS_DIR \
          GH_MOCK_AUTH_HAS_PROJECT GH_MOCK_PROJECT_EXISTS GH_MOCK_PROJECT_LIST_FAIL \
          GH_MOCK_STATUS_FIELD_EXISTS GH_MOCK_FINGERPRINT_FIELD_EXISTS \
          GH_MOCK_FINGERPRINT_CREATE_FAIL \
          EPR_PROJECT_ID EPR_PROJECT_NUM EPR_PROJECT_OWNER \
          EPR_STATUS_FIELD_ID EPR_TODO_OPTION_ID EPR_IN_PROGRESS_OPTION_ID \
          EPR_DONE_OPTION_ID EPR_FINGERPRINT_FIELD_ID 2>/dev/null || true
}

# Helper: run ensure_project_ready in a subshell and capture EPR_* + RC.
# NB: default form is ${1-...} (no colon) — defaults ONLY on UNSET, not on an
# empty string. The TEP-10[empty] case passes "" deliberately so the empty
# owner_repo actually reaches ensure_project_ready and is rejected by the source.
run_ensure() {
    local owner_repo="${1-testowner/testrepo}"
    local stderr_file="${2:-/dev/null}"
    bash -c "
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

# get_field / pass / fail / AGENTS_DIR provided by _lib.sh.

# ===========================================================================
# TEP-1: project exists + Status field MISSING → createProjectV2Field + updateProjectV2Field called
# ===========================================================================
setup_mock
export GH_MOCK_AUTH_HAS_PROJECT=1
export GH_MOCK_PROJECT_EXISTS=1
export GH_MOCK_STATUS_FIELD_EXISTS=0
export GH_MOCK_FINGERPRINT_FIELD_EXISTS=0
STDERR_FILE="$TMP/tep1-stderr.log"
OUT=$(bash -c "$(declare -f run_ensure get_field); run_ensure 'testowner/testrepo' '$STDERR_FILE'")
RC=$(get_field "$OUT" RC)
R_STATUS=$(get_field "$OUT" EPR_STATUS_FIELD_ID)
R_TODO=$(get_field "$OUT" EPR_TODO_OPTION_ID)
R_INPROG=$(get_field "$OUT" EPR_IN_PROGRESS_OPTION_ID)
R_DONE=$(get_field "$OUT" EPR_DONE_OPTION_ID)
CREATE_SINGLE_SELECT=0
UPDATE_OPTIONS=0
grep -E "createProjectV2Field.*SINGLE_SELECT|SINGLE_SELECT.*createProjectV2Field" "$MOCK_LOG" 2>/dev/null && CREATE_SINGLE_SELECT=1
grep -E "updateProjectV2Field.*singleSelectOptions|singleSelectOptions.*updateProjectV2Field" "$MOCK_LOG" 2>/dev/null && UPDATE_OPTIONS=1
if [ "$RC" = "0" ] \
   && [ -n "$R_STATUS" ] \
   && [ -n "$R_TODO" ] \
   && [ -n "$R_INPROG" ] \
   && [ -n "$R_DONE" ] \
   && [ "$CREATE_SINGLE_SELECT" = "1" ] \
   && [ "$UPDATE_OPTIONS" = "1" ]; then
    pass "TEP-1: Status field missing → createProjectV2Field + updateProjectV2Field called; EPR_* set"
else
    fail "TEP-1: rc=$RC status=$R_STATUS todo=$R_TODO inprog=$R_INPROG done=$R_DONE create_ss=$CREATE_SINGLE_SELECT update_opts=$UPDATE_OPTIONS log=$(cat "$MOCK_LOG" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# TEP-2: project exists + Status field PRESENT → create mutations NOT called (idempotent)
# ===========================================================================
setup_mock
export GH_MOCK_AUTH_HAS_PROJECT=1
export GH_MOCK_PROJECT_EXISTS=1
export GH_MOCK_STATUS_FIELD_EXISTS=1
export GH_MOCK_FINGERPRINT_FIELD_EXISTS=1
STDERR_FILE="$TMP/tep2-stderr.log"
OUT=$(bash -c "$(declare -f run_ensure get_field); run_ensure 'testowner/testrepo' '$STDERR_FILE'")
RC=$(get_field "$OUT" RC)
R_STATUS=$(get_field "$OUT" EPR_STATUS_FIELD_ID)
CREATE_CALLED=0
grep -E "createProjectV2Field.*SINGLE_SELECT" "$MOCK_LOG" 2>/dev/null && CREATE_CALLED=1
if [ "$RC" = "0" ] \
   && [ -n "$R_STATUS" ] \
   && [ "$CREATE_CALLED" = "0" ]; then
    pass "TEP-2: Status field already present → create mutation NOT called (idempotent)"
else
    fail "TEP-2: rc=$RC status=$R_STATUS create_called=$CREATE_CALLED log=$(cat "$MOCK_LOG" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# TEP-3: fingerprint field MISSING → createProjectV2Field (TEXT) called; EPR_FINGERPRINT_FIELD_ID set
# ===========================================================================
setup_mock
export GH_MOCK_AUTH_HAS_PROJECT=1
export GH_MOCK_PROJECT_EXISTS=1
export GH_MOCK_STATUS_FIELD_EXISTS=1
export GH_MOCK_FINGERPRINT_FIELD_EXISTS=0
STDERR_FILE="$TMP/tep3-stderr.log"
OUT=$(bash -c "$(declare -f run_ensure get_field); run_ensure 'testowner/testrepo' '$STDERR_FILE'")
RC=$(get_field "$OUT" RC)
R_FINGER=$(get_field "$OUT" EPR_FINGERPRINT_FIELD_ID)
CREATE_TEXT=0
grep -E "createProjectV2Field.*TEXT|TEXT.*createProjectV2Field" "$MOCK_LOG" 2>/dev/null && CREATE_TEXT=1
if [ "$RC" = "0" ] \
   && [ -n "$R_FINGER" ] \
   && [ "$CREATE_TEXT" = "1" ]; then
    pass "TEP-3: fingerprint field missing → createProjectV2Field (TEXT) called; EPR_FINGERPRINT_FIELD_ID set"
else
    fail "TEP-3: rc=$RC finger=$R_FINGER create_text=$CREATE_TEXT log=$(cat "$MOCK_LOG" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# TEP-4: gh auth missing project scope → error + gh auth refresh hint + rc=1
# ===========================================================================
setup_mock
export GH_MOCK_AUTH_HAS_PROJECT=0
STDERR_FILE="$TMP/tep4-stderr.log"
OUT=$(bash -c "$(declare -f run_ensure get_field); run_ensure 'testowner/testrepo' '$STDERR_FILE'")
RC=$(get_field "$OUT" RC)
STDERR_CONTENT=$(cat "$STDERR_FILE" 2>/dev/null)
HAS_HINT=0
echo "$STDERR_CONTENT" | grep -qi "auth refresh\|project.*scope\|gh auth" && HAS_HINT=1
if [ "$RC" = "1" ] && [ "$HAS_HINT" = "1" ]; then
    pass "TEP-4: gh auth missing project scope → rc=1 + refresh hint on stderr"
else
    fail "TEP-4: rc=$RC has_hint=$HAS_HINT stderr=$STDERR_CONTENT"
fi
teardown_mock

# ===========================================================================
# TEP-5 (C4): reuse existing board → EPR_PROJECT_* set to EXACT expected values.
# owner_repo=testowner/testrepo matches the mock's project title, so the reuse
# path returns id=PVT_existing, number=1; EPR_PROJECT_OWNER is the owner half of
# the owner_repo split (testowner). Assert each exactly (not merely non-empty).
# ===========================================================================
setup_mock
export GH_MOCK_AUTH_HAS_PROJECT=1
export GH_MOCK_PROJECT_EXISTS=1
export GH_MOCK_STATUS_FIELD_EXISTS=1
export GH_MOCK_FINGERPRINT_FIELD_EXISTS=1
STDERR_FILE="$TMP/tep5-stderr.log"
OUT=$(bash -c "$(declare -f run_ensure get_field); run_ensure 'testowner/testrepo' '$STDERR_FILE'")
RC=$(get_field "$OUT" RC)
R_PID=$(get_field "$OUT" EPR_PROJECT_ID)
R_PNUM=$(get_field "$OUT" EPR_PROJECT_NUM)
R_POWNER=$(get_field "$OUT" EPR_PROJECT_OWNER)
if [ "$RC" = "0" ] \
   && [ "$R_PID" = "PVT_existing" ] \
   && [ "$R_PNUM" = "1" ] \
   && [ "$R_POWNER" = "testowner" ]; then
    pass "TEP-5 (C4): reuse board → EPR_PROJECT_ID=PVT_existing, NUM=1, OWNER=testowner (exact)"
else
    fail "TEP-5 (C4): rc=$RC pid=$R_PID pnum=$R_PNUM powner=$R_POWNER (expected exact PVT_existing/1/testowner) stderr=$(cat "$STDERR_FILE" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# TEP-8 (C4): malformed owner_repo (no slash) → non-zero AND no gh project list.
# ===========================================================================
setup_mock
export GH_MOCK_AUTH_HAS_PROJECT=1
STDERR_FILE="$TMP/tep8-stderr.log"
OUT=$(bash -c "$(declare -f run_ensure get_field); run_ensure 'noslash' '$STDERR_FILE'")
RC=$(get_field "$OUT" RC)
LIST_CALLED=0
grep -q "project list" "$MOCK_LOG" 2>/dev/null && LIST_CALLED=1
if [ "$RC" != "0" ] && [ "$LIST_CALLED" = "0" ]; then
    pass "TEP-8 (C4): malformed owner_repo (no slash) → non-zero, no gh project list"
else
    fail "TEP-8 (C4): rc=$RC list_called=$LIST_CALLED (expected non-zero + no project list)"
fi
teardown_mock

# ===========================================================================
# TEP-9 (C5): gh project list HARD-FAILS → ensure_project_ready returns non-zero
# and does NOT proceed to field creation (no createProjectV2Field mutation).
# (N/A this pass: board-create-failure and update-options-failure permutations —
# core create + idempotency + partial-retry are already covered by TEP-1/6/7.)
# ===========================================================================
setup_mock
export GH_MOCK_AUTH_HAS_PROJECT=1
export GH_MOCK_PROJECT_EXISTS=1
export GH_MOCK_PROJECT_LIST_FAIL=1
STDERR_FILE="$TMP/tep9-stderr.log"
OUT=$(bash -c "$(declare -f run_ensure get_field); run_ensure 'testowner/testrepo' '$STDERR_FILE'")
RC=$(get_field "$OUT" RC)
FIELD_CREATE=0
grep -qE "createProjectV2Field" "$MOCK_LOG" 2>/dev/null && FIELD_CREATE=1
if [ "$RC" != "0" ] && [ "$FIELD_CREATE" = "0" ]; then
    pass "TEP-9 (C5): gh project list hard-fail → non-zero, no field creation"
else
    fail "TEP-9 (C5): rc=$RC field_create=$FIELD_CREATE (expected non-zero + no createProjectV2Field)"
fi
teardown_mock

# ===========================================================================
# TEP-10 (C6): owner_repo injection/format-rejection matrix (mirrors the --repo
# matrix). Each invalid owner_repo → non-zero AND no gh project list / GraphQL
# call reaches the mock. One valid owner/repo is accepted (rc=0).
# ===========================================================================
run_epr_case() {
    # $1=owner_repo → sets EPR_RC, EPR_OWNER_IN_LOG (did the payload reach gh?)
    local owner_repo="$1"
    setup_mock
    export GH_MOCK_AUTH_HAS_PROJECT=1
    export GH_MOCK_PROJECT_EXISTS=1
    export GH_MOCK_STATUS_FIELD_EXISTS=1
    export GH_MOCK_FINGERPRINT_FIELD_EXISTS=1
    local out
    out=$(bash -c "$(declare -f run_ensure get_field); run_ensure '$owner_repo' '/dev/null'")
    EPR_RC=$(printf '%s\n' "$out" | grep "^RC=" | head -1 | cut -d= -f2-)
    GH_REACHED=0
    grep -qE "project list|api graphql" "$MOCK_LOG" 2>/dev/null && GH_REACHED=1
    PAYLOAD_REACHED=0
    if [ -n "$owner_repo" ] && grep -Fq -- "$owner_repo" "$MOCK_LOG" 2>/dev/null; then
        PAYLOAD_REACHED=1
    fi
}

while IFS='|' read -r name payload; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"
    payload="${payload#"${payload%%[![:space:]]*}"}"; payload="${payload%"${payload##*[![:space:]]}"}"
    run_epr_case "$payload"
    if [ "$EPR_RC" != "0" ] && [ "$PAYLOAD_REACHED" = "0" ]; then
        pass "TEP-10[$name]: owner_repo rejected (rc=$EPR_RC), payload never reached gh"
    else
        fail "TEP-10[$name]: rc=$EPR_RC payload_reached=$PAYLOAD_REACHED (expect non-zero + payload absent)"
    fi
    teardown_mock
done <<TABLE
path-traversal | ../x
leading-dash   | -x/y
shell-semicolon| a/b;c
command-subst  | a/b\$(id)
embedded-space | a b/c
single-segment | noslash
three-segments | a/b/c
TABLE

# Empty owner_repo (separate — trimming would drop it from the table).
run_epr_case ""
if [ "$EPR_RC" != "0" ] && [ "$GH_REACHED" = "0" ]; then
    pass "TEP-10[empty]: empty owner_repo rejected (rc=$EPR_RC), no gh reached"
else
    fail "TEP-10[empty]: rc=$EPR_RC gh_reached=$GH_REACHED (expect non-zero + no gh)"
fi
teardown_mock

# Valid owner/repo accepted.
run_epr_case "testowner/testrepo"
if [ "$EPR_RC" = "0" ] && [ "$GH_REACHED" = "1" ]; then
    pass "TEP-10[valid]: testowner/testrepo accepted (rc=0), gh reached"
else
    fail "TEP-10[valid]: rc=$EPR_RC gh_reached=$GH_REACHED (expected rc=0 + gh reached)"
fi
teardown_mock

# ===========================================================================
# TEP-6: partial-failure idempotency-retry.
# Run 1: Status field created OK, fingerprint (TEXT) creation FAILS →
#        ensure_project_ready returns non-zero.
# Run 2 (same project; Status now exists, fingerprint still missing, TEXT now
#        succeeds): Status field is NOT re-created (no duplicate SINGLE_SELECT
#        createProjectV2Field), and the fingerprint (TEXT) field IS re-attempted.
# Both runs share one MOCK_LOG so create counts accumulate across runs.
# ===========================================================================
setup_mock
export GH_MOCK_AUTH_HAS_PROJECT=1
export GH_MOCK_PROJECT_EXISTS=1

# --- Run 1: Status absent, fingerprint absent, TEXT creation fails ---
export GH_MOCK_STATUS_FIELD_EXISTS=0
export GH_MOCK_FINGERPRINT_FIELD_EXISTS=0
export GH_MOCK_FINGERPRINT_CREATE_FAIL=1
STDERR_FILE="$TMP/tep6-run1-stderr.log"
OUT1=$(bash -c "$(declare -f run_ensure get_field); run_ensure 'testowner/testrepo' '$STDERR_FILE'")
RC1=$(get_field "$OUT1" RC)

# --- Run 2: Status now exists, fingerprint still missing, TEXT now succeeds ---
export GH_MOCK_STATUS_FIELD_EXISTS=1
export GH_MOCK_FINGERPRINT_FIELD_EXISTS=0
export GH_MOCK_FINGERPRINT_CREATE_FAIL=0
STDERR_FILE2="$TMP/tep6-run2-stderr.log"
OUT2=$(bash -c "$(declare -f run_ensure get_field); run_ensure 'testowner/testrepo' '$STDERR_FILE2'")
RC2=$(get_field "$OUT2" RC)
R2_FINGER=$(get_field "$OUT2" EPR_FINGERPRINT_FIELD_ID)

# Count Status SINGLE_SELECT creations across BOTH runs — must be exactly 1
# (created in run 1, NOT re-created in run 2).
STATUS_CREATE_COUNT=$(grep -cE "createProjectV2Field.*SINGLE_SELECT" "$MOCK_LOG" 2>/dev/null || echo 0)
# Count fingerprint TEXT creation attempts — must be >= 2 (attempted both runs).
TEXT_CREATE_COUNT=$(grep -cE "createProjectV2Field.*TEXT" "$MOCK_LOG" 2>/dev/null || echo 0)

if [ "$RC1" != "0" ] \
   && [ "$RC2" = "0" ] \
   && [ "$STATUS_CREATE_COUNT" = "1" ] \
   && [ "$TEXT_CREATE_COUNT" -ge 2 ] \
   && [ -n "$R2_FINGER" ]; then
    pass "TEP-6: partial-failure retry — run1 rc!=0, run2 rc=0, Status created once, TEXT retried"
else
    fail "TEP-6: rc1=$RC1 rc2=$RC2 status_creates=$STATUS_CREATE_COUNT text_creates=$TEXT_CREATE_COUNT finger=$R2_FINGER log=$(cat "$MOCK_LOG" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# TEP-7 (C4): board ABSENCE — no existing project (gh project list empty) →
# createProjectV2 board mutation is called, EPR_PROJECT_ID/OWNER/NUM get set,
# and Status + session-fingerprint field creation then proceeds (both fields
# absent on the brand-new board).
# ===========================================================================
setup_mock
export GH_MOCK_AUTH_HAS_PROJECT=1
export GH_MOCK_PROJECT_EXISTS=0        # no board exists → must be created
export GH_MOCK_STATUS_FIELD_EXISTS=0
export GH_MOCK_FINGERPRINT_FIELD_EXISTS=0
export GH_MOCK_FINGERPRINT_CREATE_FAIL=0
STDERR_FILE="$TMP/tep7-stderr.log"
OUT=$(bash -c "$(declare -f run_ensure get_field); run_ensure 'testowner/testrepo' '$STDERR_FILE'")
RC=$(get_field "$OUT" RC)
R_PID=$(get_field "$OUT" EPR_PROJECT_ID)
R_PNUM=$(get_field "$OUT" EPR_PROJECT_NUM)
R_POWNER=$(get_field "$OUT" EPR_PROJECT_OWNER)
R_STATUS=$(get_field "$OUT" EPR_STATUS_FIELD_ID)
R_FINGER=$(get_field "$OUT" EPR_FINGERPRINT_FIELD_ID)
BOARD_CREATE=0
grep -qE "createProjectV2\(input" "$MOCK_LOG" 2>/dev/null && BOARD_CREATE=1
STATUS_CREATE=0
grep -qE "createProjectV2Field.*SINGLE_SELECT" "$MOCK_LOG" 2>/dev/null && STATUS_CREATE=1
FINGER_CREATE=0
grep -qE "createProjectV2Field.*TEXT" "$MOCK_LOG" 2>/dev/null && FINGER_CREATE=1
if [ "$RC" = "0" ] \
   && [ "$BOARD_CREATE" = "1" ] \
   && [ -n "$R_PID" ] && [ -n "$R_PNUM" ] && [ -n "$R_POWNER" ] \
   && [ "$STATUS_CREATE" = "1" ] && [ "$FINGER_CREATE" = "1" ] \
   && [ -n "$R_STATUS" ] && [ -n "$R_FINGER" ]; then
    pass "TEP-7: board absent → createProjectV2 called; EPR_PROJECT_* set; Status+fingerprint created"
else
    fail "TEP-7: rc=$RC board_create=$BOARD_CREATE pid=$R_PID pnum=$R_PNUM powner=$R_POWNER status_create=$STATUS_CREATE finger_create=$FINGER_CREATE log=$(cat "$MOCK_LOG" 2>/dev/null)"
fi
teardown_mock

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
