#!/usr/bin/env bash
# Tests: bin/github-issues/migration/create-project.sh, bin/github-issues/migration/state.sh
# Tags: github, issues, bin, shell, env, scope:issue-specific
# Tests for fix #529 / #3142: create-project.sh titles a new board "<owner/repo> — Issue Timeline" (U+2014),
# picks the board by the repo's open linked boards (never by title), links before writing state, and deletes
# the new board (or prints the manual steps) when the link fails.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
STATE_SCRIPT="$REPO_ROOT/bin/github-issues/migration/state.sh"
CREATE_SCRIPT="$REPO_ROOT/bin/github-issues/migration/create-project.sh"
GH_MOCK="$REPO_ROOT/tests/fixtures/migration/gh-mock.sh"
# shellcheck source=../lib/harness.sh
. "$REPO_ROOT/tests/lib/harness.sh"

# The resolver behind create-project.sh must never reach the real cache or state store.
readonly PIN_ROOT="$(mktemp -d)"
trap 'rm -rf "$PIN_ROOT"' EXIT
export HOME="$PIN_ROOT/home" WORKFLOW_STATE_DIR="$PIN_ROOT/state" WORKFLOW_PLANS_DIR="$PIN_ROOT/plans"
mkdir -p "$HOME" "$WORKFLOW_STATE_DIR" "$WORKFLOW_PLANS_DIR"
unset CLAUDE_CODE_SESSION_ID _ISSUE_CREATE_INTERNAL_OWNER _ISSUE_CREATE_INTERNAL_PROJECT_NUM _ISSUE_CREATE_INTERNAL_PROJECT_ID

run_with_timeout() {
  if command -v timeout >/dev/null 2>&1; then timeout 30 "$@"
  else perl -e 'alarm 30; exec @ARGV' -- "$@"; fi
}

TMPROOT=""; REPO=""
setup_fixture() {
    local has_existing="${1:-0}"
    TMPROOT="$(mktemp -d)"
    REPO="$TMPROOT/repo"
    mkdir -p "$REPO"
    # shellcheck disable=SC1090
    source "$STATE_SCRIPT"
    state_init "$REPO" >/dev/null 2>&1
    mkdir -p "$TMPROOT/bin"
    printf '#!/bin/bash\nexec "%s" "$@"\n' "$GH_MOCK" > "$TMPROOT/bin/gh"
    chmod +x "$TMPROOT/bin/gh"
    export PATH="$TMPROOT/bin:$PATH"
    export MOCK_LOG="$TMPROOT/gh-mock.log"
    export MOCK_COUNTER="$TMPROOT/gh-mock-counter"
    : > "$MOCK_LOG"
    unset MOCK_LINKED MOCK_LINKED_QUERY_FAILS MOCK_PROJECT_LIST_JSON MOCK_LINK_FAILS MOCK_DELETE_FAILS \
      MOCK_LINKED_OWNER MOCK_PROJECT_LIST_FAILS MOCK_CREATED_OWNER 2>/dev/null || true
    if [ "$has_existing" = "1" ]; then export MOCK_HAS_EXISTING_PROJECT="1"
    else unset MOCK_HAS_EXISTING_PROJECT 2>/dev/null || true; fi
}
teardown_fixture() {
    rm -rf "$TMPROOT"
    unset MOCK_LOG MOCK_COUNTER MOCK_HAS_EXISTING_PROJECT MOCK_LINK_FAILS MOCK_DELETE_FAILS \
      MOCK_LINKED MOCK_LINKED_QUERY_FAILS MOCK_PROJECT_LIST_JSON MOCK_LINKED_OWNER MOCK_PROJECT_LIST_FAILS \
      MOCK_CREATED_OWNER 2>/dev/null || true
    TMPROOT=""; REPO=""
}
# run_create — one create-project.sh run; sets _rc, stderr in $TMPROOT/err.
run_create() {
    _rc=0
    run_with_timeout bash "$CREATE_SCRIPT" "$REPO" >/dev/null 2>"$TMPROOT/err" || _rc=$?
}

assert() { local n="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$n"; else fail "$n"; fi; }

# T1: no linked board → a new board titled "<owner/repo> — Issue Timeline"
case_begin "new-board-title" "bin/github-issues/migration/create-project.sh"
setup_fixture 0
run_create
assert "T1 create-project exits 0" [ "$_rc" = "0" ]
assert "T1 board looked up by the repo's linked boards" grep -qF 'projectsV2' "$MOCK_LOG"
assert "T1 MOCK_LOG contains the owner/repo em dash title" grep -qF 'mockowner/mockrepo — Issue Timeline' "$MOCK_LOG"
assert "T1 MOCK_LOG does not contain old 'migration' title" bash -c '! grep -qF "migration" "$1"' _ "$MOCK_LOG"
teardown_fixture
case_end

# T2: the linked board #99 is reused; it belongs to another owner, so the field calls use the board's owner
case_begin "linked-board-reused" "bin/github-issues/migration/create-project.sh"
setup_fixture 1
export MOCK_LINKED_OWNER=boardorg
run_create
assert "T2 field-list names the board owner" grep -qF 'gh project field-list 99 --owner boardorg' "$MOCK_LOG"
assert "T2 no field-list / field-create names the repo owner" bash -c '! grep -E "^gh project field-(list|create)" "$1" | grep -qF -- "--owner mockowner"' _ "$MOCK_LOG"
assert "T2 create-project exits 0" [ "$_rc" = "0" ]
assert "T2 project number 99 in state (reused)" bash -c '[ "$(jq -r .project.number "$1/.migration-state.json")" = "99" ]' _ "$REPO"
assert "T2 MOCK_LOG does NOT contain createProjectV2 mutation" bash -c '! grep -qF "createProjectV2" "$1"' _ "$MOCK_LOG"
assert "T2 board looked up by the repo's linked boards, not by title" bash -c 'grep -qF projectsV2 "$1" && ! grep -q "^gh project list" "$1"' _ "$MOCK_LOG"
teardown_fixture

# T3: a linked board is reused even when its title differs from the generated one
setup_fixture 1
export MOCK_PROJECT_LIST_JSON='{"projects":[{"number":88,"title":"mockrepo migration","id":"PVT_kwDOold"}]}'
run_create
assert "T3 create-project exits 0" [ "$_rc" = "0" ]
assert "T3 linked #99 reused, not the listed #88" bash -c '[ "$(jq -r .project.number "$1/.migration-state.json")" = "99" ]' _ "$REPO"
assert "T3 no new board created" bash -c '! grep -qF "createProjectV2(input" "$1"' _ "$MOCK_LOG"
teardown_fixture
case_end

# T4: em dash integrity — title contains U+2014 (0xe2 0x80 0x94), not ASCII hyphen
case_begin "em-dash-title" "bin/github-issues/migration/create-project.sh"
setup_fixture 0
run_create
assert "T4 MOCK_LOG contains U+2014 em dash (not ASCII hyphen)" grep -qF $'\xe2\x80\x94' "$MOCK_LOG"
assert "T4 MOCK_LOG does not contain ' - ' (space-hyphen-space)" bash -c '! grep -qF " - " "$1"' _ "$MOCK_LOG"
assert "T4 MOCK_LOG does not contain double-hyphen '--'" bash -c '! grep -qF -- "-- " "$1"' _ "$MOCK_LOG"
teardown_fixture
case_end

# T5: a same-titled unlinked board is never selected, and it blocks a duplicate create (exit 1, link guidance)
case_begin "unlinked-same-title-not-matched" "bin/github-issues/migration/create-project.sh"
setup_fixture 0
# Both the old and the new title format are listed; neither may be picked as the board.
export MOCK_PROJECT_LIST_JSON='{"projects":[{"number":77,"title":"mockowner/mockrepo — Issue Timeline","id":"PVT_kwDOsame"},{"number":77,"title":"mockrepo — Issue Timeline","id":"PVT_kwDOsame"}]}'
run_create
assert "T5 create-project exits 1" [ "$_rc" = "1" ]
assert "T5 no duplicate board created" bash -c '! grep -qF "createProjectV2(input" "$1"' _ "$MOCK_LOG"
assert "T5 the same-titled #77 is not written to state" bash -c '[ "$(jq -r ".project.number // \"none\"" "$1/.migration-state.json")" = "none" ]' _ "$REPO"
assert "T5 the unlinked #77 is not linked silently" bash -c '! grep -qF "linkProjectV2ToRepository" "$1"' _ "$MOCK_LOG"
assert "T5 stderr names the link to run" grep -qF 'gh project link 77 --owner mockowner --repo mockowner/mockrepo' "$TMPROOT/err"
teardown_fixture
case_end

# T6: link failure after create → the new board is deleted, no project in state, exit 1
case_begin "link-failure-rolls-back" "bin/github-issues/migration/create-project.sh"
setup_fixture 0
export MOCK_LINK_FAILS=1
run_create
assert "T6 create-project exits 1" [ "$_rc" = "1" ]
assert "T6 created board #99 deleted" grep -qE '^gh project delete (.* )?99( |$)' "$MOCK_LOG"
assert "T6 delete names the board owner" grep -qE '^gh project delete .*--owner mockowner' "$MOCK_LOG"
assert "T6 no project written to state" bash -c '[ "$(jq -r ".project.number // \"none\"" "$1/.migration-state.json")" = "none" ]' _ "$REPO"
teardown_fixture

# T7: link and delete both fail → exit 1 with the manual link / delete steps on stderr
setup_fixture 0
export MOCK_LINK_FAILS=1 MOCK_DELETE_FAILS=1
run_create
assert "T7 create-project exits 1" [ "$_rc" = "1" ]
assert "T7 manual link step" grep -qF 'gh project link 99 --owner mockowner --repo mockowner/mockrepo' "$TMPROOT/err"
assert "T7 manual delete step" grep -qF 'gh project delete 99 --owner mockowner' "$TMPROOT/err"
assert "T7 no project written to state" bash -c '[ "$(jq -r ".project.number // \"none\"" "$1/.migration-state.json")" = "none" ]' _ "$REPO"
teardown_fixture
case_end

# T6b: the created board's owner (createProjectV2 response) differs from the repo owner → delete names it
case_begin "link-failure-deletes-under-created-owner" "bin/github-issues/migration/create-project.sh"
setup_fixture 0
export MOCK_LINK_FAILS=1 MOCK_CREATED_OWNER=createdorg
run_create
assert "T6b create-project exits 1" [ "$_rc" = "1" ]
assert "T6b delete names the response owner" grep -qE '^gh project delete 99 --owner createdorg( |$)' "$MOCK_LOG"
assert "T6b delete never names the repo owner" bash -c '! grep -qE "^gh project delete .*--owner mockowner" "$1"' _ "$MOCK_LOG"
teardown_fixture
setup_fixture 0
export MOCK_LINK_FAILS=1 MOCK_DELETE_FAILS=1 MOCK_CREATED_OWNER=createdorg
run_create
assert "T6b manual steps name the response owner" grep -qF 'gh project delete 99 --owner createdorg' "$TMPROOT/err"
teardown_fixture
case_end

# T8 / T9: an ambiguous (two open linked boards) or failed board lookup stops before creating a board (#2164).
# stops_before_create <name> <knob=value> <stderr-reason-regex>
stops_before_create() {
    setup_fixture 0
    export "$2"
    run_create
    assert "$1 create-project exits 1" [ "$_rc" = "1" ]
    assert "$1 the reason is on stderr" grep -qiE "$3" "$TMPROOT/err"
    assert "$1 board lookup was attempted" grep -qF 'projectsV2' "$MOCK_LOG"
    assert "$1 no new board created" bash -c '! grep -qF "createProjectV2(input" "$1"' _ "$MOCK_LOG"
    assert "$1 no project written to state" bash -c '[ "$(jq -r ".project.number // \"none\"" "$1/.migration-state.json")" = "none" ]' _ "$REPO"
    teardown_fixture
}
case_begin "ambiguous-board-stops-before-create" "bin/github-issues/migration/create-project.sh"
stops_before_create "T8 ambiguous" MOCK_LINKED=2 'ambiguous'
# MOCK_LINKED=2 links open #99 and #98: the stop names both candidates.
setup_fixture 0
export MOCK_LINKED=2
run_create
assert "T8 ambiguous names candidate #99 on stderr" grep -qE '#99([^0-9]|$)' "$TMPROOT/err"
assert "T8 ambiguous names candidate #98 on stderr" grep -qE '#98([^0-9]|$)' "$TMPROOT/err"
teardown_fixture
case_end
case_begin "failed-board-lookup-stops-before-create" "bin/github-issues/migration/create-project.sh"
stops_before_create "T9 fetch-failed" MOCK_LINKED_QUERY_FAILS=1 'fetch.failed'
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
