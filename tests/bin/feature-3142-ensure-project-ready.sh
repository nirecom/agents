#!/usr/bin/env bash
# Tests: bin/github-issues/lib/ensure-project-ready.sh, bin/github-issues/lib/board-create.sh
# Tags: scope:issue-specific, feature-3142, ensure-project-ready, projects-v2, TL2
# TL3 gap: gh is the ensure-project-ready mock; a real createProjectV2 / link / delete against GitHub is not run.
#
# #3142 Step 4: ensure_project_ready picks the board by the repo's open linked boards (resolver, no cache
# read or write), never by title. linked → reuse, no create, no link; no-link → create + link; a failed
# lookup or two open boards → rc 1 with no create; a failed link after create deletes the new board, or
# prints the manual link / delete steps when the delete fails too. EPR_PROJECT_OWNER is the project owner.

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
# shellcheck source=feature-1340-issue-setup/_mock-ensure-project-ready.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-1340-issue-setup/_mock-ensure-project-ready.sh"

set -uo pipefail

readonly TMP_ROOT="$(make_tmp)"
trap 'rm -rf "$TMP_ROOT"' EXIT
export HOME="$TMP_ROOT/home"
export WORKFLOW_STATE_DIR="$TMP_ROOT/state" WORKFLOW_PLANS_DIR="$TMP_ROOT/plans"
mkdir -p "$HOME" "$WORKFLOW_STATE_DIR" "$WORKFLOW_PLANS_DIR" "$TMP_ROOT/mock-bin"
unset _ISSUE_CREATE_INTERNAL_OWNER _ISSUE_CREATE_INTERNAL_PROJECT_NUM _ISSUE_CREATE_INTERNAL_PROJECT_ID

TARGET="$SCRIPT_CHECKOUT_ROOT/bin/github-issues/lib/ensure-project-ready.sh"
BOARD_CREATE="$SCRIPT_CHECKOUT_ROOT/bin/github-issues/lib/board-create.sh"
write_epr_gh_mock "$TMP_ROOT/mock-bin/gh"
export PATH="$TMP_ROOT/mock-bin:$PATH"
export MOCK_LOG="$TMP_ROOT/mock.log"
cd "$TMP_ROOT" || exit 1
CACHE_DIR="$WORKFLOW_STATE_DIR/cache"

# knobs <k=v...> — pins every mock knob, then applies the case's overrides.
knobs() {
  export GH_MOCK_AUTH_HAS_PROJECT=1 GH_MOCK_PROJECT_EXISTS=1 GH_MOCK_PROJECT_LIST_FAIL=0 GH_MOCK_PROJECT_OWNER=testowner \
    GH_MOCK_LINKED_EXTRA_OPEN=0 GH_MOCK_DELETE_FAILS=0 GH_MOCK_LINK_FAILS=0 GH_MOCK_STATUS_FIELD_EXISTS=1 \
    GH_MOCK_SESSION_ID_FIELD_EXISTS=1 GH_MOCK_SESSION_ID_CREATE_FAIL=0
  local kv
  for kv in "$@"; do export "${kv?}"; done
  : >"$MOCK_LOG"
}
# epr — one ensure_project_ready testowner/testrepo; sets RC PID NUM OWNER ERR.
epr() {
  run_with_timeout 120 bash -c '. "$1" >/dev/null 2>&1 || { echo RC=99; exit 0; }
    ensure_project_ready testowner/testrepo; rc=$?
    printf "RC=%s\nPID=%s\nNUM=%s\nOWNER=%s\n" "$rc" "${EPR_PROJECT_ID:-}" "${EPR_PROJECT_NUM:-}" "${EPR_PROJECT_OWNER:-}"' \
    _ "$TARGET" >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"
  local o; o="$(tr -d '\r' <"$TMP_ROOT/out")"
  RC="$(sed -n 's/^RC=//p' <<<"$o")"; PID="$(sed -n 's/^PID=//p' <<<"$o")"
  NUM="$(sed -n 's/^NUM=//p' <<<"$o")"; OWNER="$(sed -n 's/^OWNER=//p' <<<"$o")"
  ERR="$(cat "$TMP_ROOT/err")"
}
logged() { grep -qE "$1" "$MOCK_LOG"; }
expect_log() { if logged "$2"; then pass "$1"; else fail "$1" "no [$2] in: $(head -c 600 "$MOCK_LOG")"; fi; }
expect_no_log() { if logged "$2"; then fail "$1" "unexpected [$2]: $(grep -E "$2" "$MOCK_LOG" | head -c 300)"; else pass "$1"; fi; }
expect_in() { if [[ "$3" == *"$2"* ]]; then pass "$1"; else fail "$1" "missing [$2] in: $3"; fi; }

case_begin "linked-board-is-reused-without-create-or-link" "bin/github-issues/lib/ensure-project-ready.sh"
knobs GH_MOCK_PROJECT_OWNER=boardorg
epr
assert_eq "$RC/$PID/$NUM" "0/PVT_existing/1"
assert_eq "project owner: $OWNER" "project owner: boardorg"
expect_log "board looked up by the repo's linked boards" 'projectsV2'
expect_no_log "no title lookup" '^gh project list'
expect_no_log "no board created" 'createProjectV2\(input'
expect_no_log "an already linked board is not linked again" 'linkProjectV2ToRepository'
if [ -z "$(ls -A "$CACHE_DIR" 2>/dev/null)" ]; then pass "no resolver cache written"; else fail "no resolver cache written" "$(ls -A "$CACHE_DIR")"; fi
case_end

case_begin "no-linked-board-is-created-and-linked" "bin/github-issues/lib/ensure-project-ready.sh"
knobs GH_MOCK_PROJECT_EXISTS=0
epr
assert_eq "$RC/$PID" "0/PVT_new"
expect_log "board looked up by the repo's linked boards" 'projectsV2'
expect_log "board created" 'createProjectV2\(input'
expect_log "new board linked" 'linkProjectV2ToRepository'
expect_no_log "no title lookup" '^gh project list'
case_end

case_begin "lookup-failure-creates-nothing" "bin/github-issues/lib/ensure-project-ready.sh"
knobs GH_MOCK_PROJECT_EXISTS=0 GH_MOCK_PROJECT_LIST_FAIL=1
epr
assert_eq "rc=$RC pid=$PID" "rc=1 pid="
expect_log "the failed lookup was the linked-board query" 'projectsV2'
expect_no_log "no board created on a failed lookup" 'createProjectV2'
case_end

case_begin "two-open-boards-create-nothing" "bin/github-issues/lib/ensure-project-ready.sh"
knobs GH_MOCK_LINKED_EXTRA_OPEN=1
epr
assert_eq "rc=$RC pid=$PID" "rc=1 pid="
expect_no_log "no board created when ambiguous" 'createProjectV2'
expect_in "resolver refusal reaches stderr" "refusing to pick one" "$ERR"
case_end

case_begin "link-failure-deletes-the-new-board" "bin/github-issues/lib/board-create.sh"
knobs GH_MOCK_PROJECT_EXISTS=0 GH_MOCK_LINK_FAILS=1
epr
assert_eq "rc=$RC pid=$PID" "rc=1 pid="
expect_log "created board #2 deleted" '^gh project delete (.* )?2( |$)'
expect_log "delete names the project owner" '^gh project delete .*--owner testowner'
expect_no_log "no field preparation after the failed link" 'createProjectV2Field'
case_end

case_begin "delete-failure-prints-manual-steps" "bin/github-issues/lib/board-create.sh"
knobs GH_MOCK_PROJECT_EXISTS=0 GH_MOCK_LINK_FAILS=1 GH_MOCK_DELETE_FAILS=1
epr
assert_eq "rc=$RC" "rc=1"
expect_in "manual link step" "gh project link 2 --owner testowner --repo testowner/testrepo" "$ERR"
expect_in "manual delete step" "gh project delete 2 --owner testowner" "$ERR"
case_end

case_begin "board-title-helper" "bin/github-issues/lib/board-create.sh"
if [ -f "$BOARD_CREATE" ]; then
  t="$(bash -c '. "$1" && project_board_title testowner/testrepo' _ "$BOARD_CREATE" 2>&1 | tr -d '\r')"
  assert_eq "$t" "testowner/testrepo — Issue Timeline"
else
  fail "board-create.sh exists" "bin/github-issues/lib/board-create.sh not found (implementation missing)"
fi
case_end

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ] || exit 1
