#!/usr/bin/env bash
# tests/bin/fix-488-ensure-project-ready-link-repo.sh
# Tests: bin/github-issues/lib/ensure-project-ready.sh, bin/github-issues/migration/link-project.sh
# Tags: github-issues, migrate-tracker, ensure-project-ready, link-project, scope:issue-specific, projects-v2, session-id
#
# Regression test for #488 (reopened): /migrate-tracker path never linked its
# Projects v2 board to the repo. Mirrors tests/bin/fix-488-create-project-link-repo.sh
# (LNK-1..LNK-4); no dry-run case (ensure_project_ready() has none).
# #2925 epr-session-id-* cases (E1-E6) below. TL3 gap: mocked gh CLI — real link mutation, idempotency, view config unverified.
# Closer: RUN_TL4=on, or manually confirm the board on github.com after /migrate-tracker.

# shellcheck source=feature-1340-issue-setup/_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/feature-1340-issue-setup/_lib.sh"
# shellcheck source=feature-1340-issue-setup/_mock-ensure-project-ready.sh
. "$(dirname "${BASH_SOURCE[0]}")/feature-1340-issue-setup/_mock-ensure-project-ready.sh"
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

TARGET="$__LIB_SCRIPT_CHECKOUT_ROOT/bin/github-issues/lib/ensure-project-ready.sh"
export TARGET

if [ ! -f "$TARGET" ]; then
    echo "FAIL: bin/github-issues/lib/ensure-project-ready.sh not found"
    echo ""
    echo "Results: 0 passed, 4 failed"
    exit 1
fi

TMPROOT="$(mktemp -d)"
readonly TMPROOT
trap 'rm -rf "$TMPROOT"' EXIT
harness_isolate "$TMPROOT"
unset CLAUDE_CODE_SESSION_ID
ORIG_PATH="$PATH"
TMP=""

setup_mock() {
    TMP="$(mktemp -d)"
    mkdir -p "$TMP/mock-bin"
    write_epr_gh_mock "$TMP/mock-bin/gh"
    export PATH="$TMP/mock-bin:$PATH"
    export MOCK_LOG="$TMP/mock.log"
    : > "$MOCK_LOG"
    # Pin every knob explicitly (test-design.md "Config-dependent branches").
    export GH_MOCK_AUTH_HAS_PROJECT=1
    export GH_MOCK_STATUS_FIELD_EXISTS=1
    export GH_MOCK_SESSION_ID_FIELD_EXISTS=1
    export GH_MOCK_SESSION_ID_CREATE_FAIL=0
    export GH_MOCK_LINK_FAILS=0
}

teardown_mock() {
    if [ -n "${TMP:-}" ] && [ -d "$TMP" ]; then
        rm -rf "$TMP" 2>/dev/null || true
    fi
    TMP=""
    unset MOCK_LOG \
          GH_MOCK_AUTH_HAS_PROJECT GH_MOCK_PROJECT_EXISTS GH_MOCK_PROJECT_LIST_FAIL \
          GH_MOCK_STATUS_FIELD_EXISTS GH_MOCK_SESSION_ID_FIELD_EXISTS \
          GH_MOCK_SESSION_ID_CREATE_FAIL GH_MOCK_LINK_FAILS \
          EPR_PROJECT_ID EPR_PROJECT_NUM EPR_PROJECT_OWNER \
          EPR_CONTENT_DATE_FIELD_ID EPR_STATUS_FIELD_ID EPR_TODO_OPTION_ID \
          EPR_IN_PROGRESS_OPTION_ID EPR_DONE_OPTION_ID \
          EPR_SESSION_ID_FIELD_ID 2>/dev/null || true
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
        printf 'EPR_SESSION_ID_FIELD_ID=%s\n'  \"\${EPR_SESSION_ID_FIELD_ID:-}\"
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
case_begin "create-path-links-repo" "bin/github-issues/migration/link-project.sh"
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
case_end

# ===========================================================================
# LNK-2: existing-project (reuse) path → board is linked to the repo too.
# CPR-ORTH counterpart of LNK-1: both convergence paths must link.
# ===========================================================================
case_begin "reuse-path-links-repo" "bin/github-issues/lib/ensure-project-ready.sh"
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
case_end

# ===========================================================================
# LNK-3: link failure is NON-FATAL — ensure_project_ready still returns 0 and
# still exports the downstream EPR_* contract.
# The link call must be ASSERTED PRESENT as a precondition: without it, "no link
# failure occurred" would spuriously satisfy the non-fatality claim (this case
# has to be RED on the unfixed source too, not accidentally green).
# ===========================================================================
case_begin "link-failure-non-fatal" "bin/github-issues/lib/ensure-project-ready.sh"
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
R_FINGER=$(get_field "$OUT" EPR_SESSION_ID_FIELD_ID)
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
   && [ "$R_FINGER" = "PVTF_existing_sid" ]; then
    pass "LNK-3: link mutation attempted and failed → rc=0 and full EPR_* contract intact (non-fatal)"
else
    fail "LNK-3: link_attempted=$LINK_ATTEMPTED rc=$RC pid=$R_PID pnum=$R_PNUM powner=$R_POWNER status=$R_STATUS todo=$R_TODO inprog=$R_INPROG done=$R_DONE finger=$R_FINGER log=$(cat "$MOCK_LOG" 2>/dev/null)"
fi
teardown_mock
case_end

# ===========================================================================
# LNK-4: STATELESS — two runs issue the link mutation TWICE.
# Deliberate INVERSION of the migration-path test's L5 ("second run skips link
# mutation when repo_linked=true"): that contract exists only because
# create-project.sh persists .migration-state.json. ensure-project-ready.sh was
# extracted with all .migration-state.json dependencies removed, so it has no
# memory of a prior link and MUST re-issue the mutation (GitHub treats the link
# as idempotent server-side). A dedupe here would be the bug, not the fix.
# ===========================================================================
case_begin "stateless-two-runs-link-twice" "bin/github-issues/lib/ensure-project-ready.sh"
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
case_end

# ===========================================================================
# #2925 E1-E6: session-id TEXT field is created (legacy session-fingerprint never renamed),
# found on any page, not created when the paged list fails, re-listed when the create answers
# without an id; BOARD views get it best-effort. Paged list carries `after:` (detail Step 2).
# ===========================================================================
N=0
setup_case() {
    N=$((N + 1))
    CASE_DIR="$TMPROOT/c$N"; mkdir -p "$CASE_DIR/mock-bin"
    write_epr_gh_mock "$CASE_DIR/mock-bin/gh"
    export PATH="$CASE_DIR/mock-bin:$ORIG_PATH"
    export MOCK_LOG="$CASE_DIR/mock.log" GH_MOCK_FIELDS_LOG="$CASE_DIR/fields.log"
    : > "$MOCK_LOG"; : > "$GH_MOCK_FIELDS_LOG"
    unset GH_MOCK_SID_FIELD GH_MOCK_FIELD_PAGES GH_MOCK_FIELD_LIST_FAIL GH_MOCK_FIELDS_STATE \
          GH_MOCK_CREATE_NO_ID GH_MOCK_FAIL GH_MOCK_VIEWS GH_MOCK_VIEW_PAGES GH_MOCK_VIEW_FIELDS_TRUNCATED
    export GH_MOCK_AUTH_HAS_PROJECT=1 GH_MOCK_PROJECT_EXISTS=1 GH_MOCK_STATUS_FIELD_EXISTS=1 \
           GH_MOCK_SESSION_ID_FIELD_EXISTS=0 GH_MOCK_SESSION_ID_CREATE_FAIL=0 GH_MOCK_LINK_FAILS=0
}

# run_epr — sets RC and SID_ID (EPR_SESSION_ID_FIELD_ID) from one ensure_project_ready run.
run_epr() {
    local out
    out="$(run_ensure 'testowner/testrepo' "$CASE_DIR/stderr.log")"
    RC="$(get_field "$out" RC)"
    SID_ID="$(get_field "$out" EPR_SESSION_ID_FIELD_ID)"
}
n_op() { grep -c "^$1" "$GH_MOCK_FIELDS_LOG" 2>/dev/null || true; }
n_rename() { grep -E 'updateProjectV2Field' "$MOCK_LOG" 2>/dev/null | grep -vc 'singleSelectOptions' || true; }
ops() { tr '\n' '|' < "$GH_MOCK_FIELDS_LOG" | cut -c1-400; }

# E1: only the legacy-named field exists → a new session-id field is created; no rename.
case_begin "epr-session-id-legacy-only-creates" "bin/github-issues/lib/ensure-project-ready.sh"
setup_case
export GH_MOCK_SID_FIELD=legacy
run_epr
if [ "$RC" = "0" ] && [ "$SID_ID" = "PVTF_new_sid" ] && [ "$(n_op create)" = "1" ] && [ "$(n_rename)" = "0" ]; then
    pass "E1: legacy-only project → session-id created (PVTF_new_sid), legacy field not renamed"
else
    fail "E1: rc=$RC sid=$SID_ID creates=$(n_op create) renames=$(n_rename) ops=$(ops)"
fi
case_end

# E2: session-id sits on page 2 of the field list → found, no create.
case_begin "epr-session-id-found-on-page-2" "bin/github-issues/lib/ensure-project-ready.sh"
setup_case
export GH_MOCK_SID_FIELD=present GH_MOCK_FIELD_PAGES=2
run_epr
if [ "$RC" = "0" ] && [ "$SID_ID" = "PVTF_existing_sid" ] && [ "$(n_op create)" = "0" ]; then
    pass "E2: session-id on page 2 → reused (PVTF_existing_sid), no create"
else
    fail "E2: rc=$RC sid=$SID_ID creates=$(n_op create) ops=$(ops)"
fi
case_end

# E3: the paged field list fails → no create (a blind create could duplicate), rc 1, error line.
case_begin "epr-session-id-list-fails-no-create" "bin/github-issues/lib/ensure-project-ready.sh"
setup_case
export GH_MOCK_SID_FIELD=absent GH_MOCK_FIELD_LIST_FAIL=paged
run_epr
if [ "$RC" = "1" ] && [ "$(n_op create)" = "0" ] && grep -q '^error:' "$CASE_DIR/stderr.log"; then
    pass "E3: field-list failure → rc 1, no create, error line"
else
    fail "E3: rc=$RC creates=$(n_op create) stderr=[$(head -n 2 "$CASE_DIR/stderr.log")] ops=$(ops)"
fi
case_end

# E4: the create answers without an id → the list is read again and the new id is picked up.
case_begin "epr-session-id-create-no-id-relists" "bin/github-issues/lib/ensure-project-ready.sh"
setup_case
export GH_MOCK_SID_FIELD=absent GH_MOCK_CREATE_NO_ID=1 GH_MOCK_FIELDS_STATE="$CASE_DIR/fields.state"
run_epr
RELIST="$(sed -n '/^create/,$p' "$GH_MOCK_FIELDS_LOG" | grep -c '^list-fields' || true)"
if [ "$RC" = "0" ] && [ "$SID_ID" = "PVTF_new_sid" ] && [ "$(n_op create)" = "1" ] && [ "$RELIST" -ge 1 ]; then
    pass "E4: create without id → re-list resolves PVTF_new_sid"
else
    fail "E4: rc=$RC sid=$SID_ID creates=$(n_op create) relist=$RELIST ops=$(ops)"
fi
case_end

# E5: the BOARD view update fails → still rc 0 with the field id (best-effort), update attempted.
case_begin "epr-session-id-view-update-fails-rc0" "bin/github-issues/lib/ensure-project-ready.sh"
setup_case
export GH_MOCK_SID_FIELD=absent GH_MOCK_FAIL=view-update GH_MOCK_VIEWS="PVTV_b1:BOARD_LAYOUT:PVTF_title"
run_epr
if [ "$RC" = "0" ] && [ "$SID_ID" = "PVTF_new_sid" ] && [ "$(n_op view-update)" -ge 1 ]; then
    pass "E5: view-update failure → rc 0, EPR_SESSION_ID_FIELD_ID kept"
else
    fail "E5: rc=$RC sid=$SID_ID view_updates=$(n_op view-update) ops=$(ops)"
fi
case_end

# E6: only a BOARD view lacking session-id is updated, with its full field list plus the new id.
case_begin "epr-session-id-board-view-full-list" "bin/github-issues/lib/ensure-project-ready.sh"
setup_case
export GH_MOCK_SID_FIELD=absent \
       GH_MOCK_VIEWS="PVTV_b1:BOARD_LAYOUT:PVTF_title,PVTF_existing_status;PVTV_t1:TABLE_LAYOUT:PVTF_title;PVTV_b2:BOARD_LAYOUT:PVTF_title,PVTF_new_sid"
run_epr
VU="$( { grep 'updateProjectV2View' "$MOCK_LOG"; grep '^view-update' "$GH_MOCK_FIELDS_LOG"; } 2>/dev/null | tr '\n' ' ')"
FULL=1
for want in PVTV_b1 PVTF_title PVTF_existing_status PVTF_new_sid; do
    case "$VU" in *"$want"*) ;; *) FULL=0 ;; esac
done
OTHER=0
case "$VU" in *PVTV_t1*|*PVTV_b2*) OTHER=1 ;; esac
if [ "$RC" = "0" ] && [ "$(n_op view-update)" = "1" ] && [ "$FULL" = "1" ] && [ "$OTHER" = "0" ]; then
    pass "E6: BOARD view without session-id → one update with the full id list + PVTF_new_sid"
else
    fail "E6: rc=$RC view_updates=$(n_op view-update) full=$FULL other=$OTHER vu=[${VU:0:400}]"
fi
case_end

# E7: a BOARD view whose fields connection has more pages is never updated (a truncated
# visibleFieldIds list would drop fields); a warn names the view, rc stays 0.
case_begin "epr-session-id-truncated-view-fields-skipped" "bin/github-issues/lib/session-id-field.sh"
setup_case
export GH_MOCK_SID_FIELD=absent GH_MOCK_VIEWS="PVTV_big:BOARD_LAYOUT:PVTF_title,PVTF_existing_status" GH_MOCK_VIEW_FIELDS_TRUNCATED="PVTV_big"
run_epr
if [ "$RC" = "0" ] && [ "$(n_op view-update)" = "0" ] && ! grep -q 'updateProjectV2View' "$MOCK_LOG" \
   && grep -E '^warn:.*PVTV_big' "$CASE_DIR/stderr.log" >/dev/null; then
    pass "E7: truncated view fields → no updateProjectV2View, warn names PVTV_big, rc 0"
else
    fail "E7: rc=$RC view_updates=$(n_op view-update) stderr=[$(head -n 3 "$CASE_DIR/stderr.log")] ops=$(ops)"
fi
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
