#!/usr/bin/env bash
# Tests: bin/github-issues/migration/create-project.sh, bin/github-issues/migration/state.sh
# Tags: github, issues, bin, shell, env, scope:issue-specific, feature-3142, projects-v2
set -euo pipefail
# The resolver behind create-project.sh must never reach the real cache or state store.
readonly PIN_ROOT="$(mktemp -d)"
trap 'rm -rf "$PIN_ROOT"' EXIT
export HOME="$PIN_ROOT/home" WORKFLOW_STATE_DIR="$PIN_ROOT/state" WORKFLOW_PLANS_DIR="$PIN_ROOT/plans"
mkdir -p "$HOME" "$WORKFLOW_STATE_DIR" "$WORKFLOW_PLANS_DIR"
unset CLAUDE_CODE_SESSION_ID _ISSUE_CREATE_INTERNAL_OWNER _ISSUE_CREATE_INTERNAL_PROJECT_NUM _ISSUE_CREATE_INTERNAL_PROJECT_ID
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
. "$REPO_ROOT/tests/lib/harness.sh"
STATE_SCRIPT="$REPO_ROOT/bin/github-issues/migration/state.sh"
CREATE_SCRIPT="$REPO_ROOT/bin/github-issues/migration/create-project.sh"
GH_MOCK="$REPO_ROOT/tests/fixtures/migration/gh-mock.sh"

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
    if [ "$has_existing" = "1" ]; then export MOCK_HAS_EXISTING_PROJECT="1"
    else unset MOCK_HAS_EXISTING_PROJECT 2>/dev/null || true; fi
}
teardown_fixture() {
    rm -rf "$TMPROOT"
    unset MOCK_LOG MOCK_COUNTER MOCK_HAS_EXISTING_PROJECT MOCK_LINK_FAILS 2>/dev/null || true
    TMPROOT=""; REPO=""
}

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "PASS: $1"; }
ng() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
assert() { local n="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$n"; else ng "$n"; fi; }

case_begin "new-board-created-and-linked" "bin/github-issues/migration/create-project.sh"
# L1: new-create path
setup_fixture 0
_rc=0
run_with_timeout bash "$CREATE_SCRIPT" "$REPO" >/dev/null 2>&1 || _rc=$?
assert "L1 create-project exits 0" [ "$_rc" = "0" ]
assert "L1 linkProjectV2ToRepository called on new-create" grep -qE 'linkProjectV2ToRepository' "$MOCK_LOG"
assert "L1 repo_linked=true in state" bash -c '[ "$(jq -r .project.repo_linked "$1/.migration-state.json")" = "true" ]' _ "$REPO"
teardown_fixture
case_end

case_begin "linked-board-reused-without-link-mutation" "bin/github-issues/migration/create-project.sh"
# L2: existing-reuse path (#3142) — the repo's single open linked board (#99 per the mock) is reused:
# no board created, no link mutation, repo_linked=true.
setup_fixture 1
_rc=0
run_with_timeout bash "$CREATE_SCRIPT" "$REPO" >/dev/null 2>&1 || _rc=$?
assert "L2 create-project exits 0" [ "$_rc" = "0" ]
assert "L2 linkProjectV2ToRepository NOT called on existing-reuse" bash -c '! grep -qE linkProjectV2ToRepository "$1"' _ "$MOCK_LOG"
assert "L2 createProjectV2 NOT called on existing-reuse" bash -c '! grep -qE "createProjectV2\(" "$1"' _ "$MOCK_LOG"
assert "L2 linked board #99 recorded in state" bash -c '[ "$(jq -r .project.number "$1/.migration-state.json")" = "99" ]' _ "$REPO"
assert "L2 repo_linked=true in state" bash -c '[ "$(jq -r .project.repo_linked "$1/.migration-state.json")" = "true" ]' _ "$REPO"
teardown_fixture
case_end

case_begin "link-failure-deletes-new-board" "bin/github-issues/migration/create-project.sh"
# L3: link failure on a new board (#3142) — the unlinked board is deleted and the script exits non-zero
# before state_set_project, so no project number reaches the state.
setup_fixture 0
export MOCK_LINK_FAILS=1
_rc=0
run_with_timeout bash "$CREATE_SCRIPT" "$REPO" >/dev/null 2>&1 || _rc=$?
assert "L3 create-project exits non-zero on link failure" [ "$_rc" != "0" ]
assert "L3 createProjectV2 called before the failed link" grep -qE 'createProjectV2\(' "$MOCK_LOG"
assert "L3 new board #99 deleted after link failure" grep -qE '^gh project delete 99 --owner mockowner' "$MOCK_LOG"
assert "L3 no project number in state after link failure" bash -c '[ -z "$(jq -r ".project.number // empty" "$1/.migration-state.json")" ]' _ "$REPO"
unset MOCK_LINK_FAILS
teardown_fixture
case_end

case_begin "dry-run-skips-link" "bin/github-issues/migration/create-project.sh"
# L4: dry-run — no linkProjectV2ToRepository in log
setup_fixture 0
_rc=0
run_with_timeout bash "$CREATE_SCRIPT" "$REPO" --dry-run >/dev/null 2>&1 || _rc=$?
assert "L4 dry-run exits 0 (rc=$_rc)" [ "$_rc" = "0" ]
assert "L4 dry-run skips link mutation" bash -c '! grep -qE linkProjectV2ToRepository "$1"' _ "$MOCK_LOG"
teardown_fixture
case_end

case_begin "rerun-skips-link" "bin/github-issues/migration/create-project.sh"
# L5: skip-on-already-linked — second run skips link mutation
setup_fixture 1
_rc=0
run_with_timeout bash "$CREATE_SCRIPT" "$REPO" >/dev/null 2>&1 || _rc=$?
assert "L5 first run exits 0 (rc=$_rc)" [ "$_rc" = "0" ]
_num_before="$(jq -r '.project.number // empty' "$REPO/.migration-state.json")"
assert "L5 first run records board #99 (got [$_num_before])" [ "$_num_before" = "99" ]
: > "$MOCK_LOG"
_rc=0
run_with_timeout bash "$CREATE_SCRIPT" "$REPO" >/dev/null 2>&1 || _rc=$?
assert "L5 second run exits 0 (rc=$_rc)" [ "$_rc" = "0" ]
assert "L5 second run skips link mutation when repo_linked=true" bash -c '! grep -qE linkProjectV2ToRepository "$1"' _ "$MOCK_LOG"
_num_after="$(jq -r '.project.number // empty' "$REPO/.migration-state.json")"
assert "L5 second run keeps board number ($_num_before -> $_num_after)" [ "$_num_after" = "$_num_before" ]
assert "L5 repo_linked still true after rerun" bash -c '[ "$(jq -r .project.repo_linked "$1/.migration-state.json")" = "true" ]' _ "$REPO"
teardown_fixture
case_end

# L6-L8 (#3142 duplicate guard): run_guarded <list-json|FAILS> — a no-link run with the given owner board list.
run_guarded() {
    setup_fixture 0
    if [ "$1" = "FAILS" ]; then export MOCK_PROJECT_LIST_FAILS=1; else export MOCK_PROJECT_LIST_JSON="$1"; fi
    _rc=0
    run_with_timeout bash "$CREATE_SCRIPT" "$REPO" >/dev/null 2>"$TMPROOT/err" || _rc=$?
}
end_guarded() { unset MOCK_PROJECT_LIST_JSON MOCK_PROJECT_LIST_FAILS; teardown_fixture; }
no_create() { ! grep -qF 'createProjectV2(input' "$1"; }
no_state() { [ "$(jq -r '.project.number // "none"' "$1/.migration-state.json")" = "none" ]; }

case_begin "same-titled-unlinked-board-refuses-create" "bin/github-issues/migration/create-project.sh"
for title in "mockowner/mockrepo — Issue Timeline" "mockrepo — Issue Timeline"; do
    run_guarded "{\"projects\":[{\"number\":77,\"title\":\"$title\",\"id\":\"PVT_kwDOdup\"}]}"
    assert "L6 [$title] exits 1 (rc=$_rc)" [ "$_rc" = "1" ]
    assert "L6 [$title] owner boards listed" grep -qE '^gh project list --owner mockowner --format json --limit 200' "$MOCK_LOG"
    assert "L6 [$title] no createProjectV2 call" no_create "$MOCK_LOG"
    assert "L6 [$title] no link mutation" bash -c '! grep -qE linkProjectV2ToRepository "$1"' _ "$MOCK_LOG"
    assert "L6 [$title] link guidance on stderr" grep -qF 'gh project link 77 --owner mockowner --repo mockowner/mockrepo' "$TMPROOT/err"
    assert "L6 [$title] no project in state" no_state "$REPO"
    end_guarded
done
case_end

case_begin "unrelated-titles-still-create" "bin/github-issues/migration/create-project.sh"
for listing in '{"projects":[]}' '{"projects":[{"number":66,"title":"mockowner/mockrepo2 — Issue Timeline","id":"PVT_a"},{"number":65,"title":"otherrepo — Issue Timeline","id":"PVT_b"}]}'; do
    run_guarded "$listing"
    assert "L7 [$listing] exits 0 (rc=$_rc)" [ "$_rc" = "0" ]
    assert "L7 [$listing] board created" grep -qF 'createProjectV2(input' "$MOCK_LOG"
    assert "L7 [$listing] board linked" grep -qE 'linkProjectV2ToRepository' "$MOCK_LOG"
    assert "L7 [$listing] new board #99 in state" bash -c '[ "$(jq -r .project.number "$1/.migration-state.json")" = "99" ]' _ "$REPO"
    end_guarded
done
case_end

case_begin "owner-board-list-failure-creates-nothing" "bin/github-issues/migration/create-project.sh"
run_guarded FAILS
assert "L8 exits 1 (rc=$_rc)" [ "$_rc" = "1" ]
assert "L8 no createProjectV2 call" no_create "$MOCK_LOG"
assert "L8 'nothing created' on stderr" grep -qF 'nothing created' "$TMPROOT/err"
assert "L8 no project in state" no_state "$REPO"
end_guarded
case_end

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
