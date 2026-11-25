#!/usr/bin/env bash
# Tests: bin/github-issues/resolve-board.sh
# Tags: scope:issue-specific, feature-3142, resolve-project, projects-v2, TL2
# TL3 gap: gh is a JSON mock on PATH; the live GraphQL API is not exercised.
#
# #3142 Step 2: resolve-board.sh [--no-cache-read] <owner/repo> sources the resolver, passes --repo, and
# prints key=value lines (status, owner, number, project_id, *_field_id, *_option_id, candidates);
# exit 0 whenever a result is printed, 2 on a usage error; --no-cache-read implies --no-cache-write.

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

set -uo pipefail

readonly TMP_ROOT="$(make_tmp)"
trap 'rm -rf "$TMP_ROOT"' EXIT
export HOME="$TMP_ROOT/home"
export WORKFLOW_STATE_DIR="$TMP_ROOT/state" WORKFLOW_PLANS_DIR="$TMP_ROOT/plans"
mkdir -p "$HOME" "$WORKFLOW_STATE_DIR" "$WORKFLOW_PLANS_DIR"
unset _ISSUE_CREATE_INTERNAL_OWNER _ISSUE_CREATE_INTERNAL_PROJECT_NUM _ISSUE_CREATE_INTERNAL_PROJECT_ID \
  GH_MOCK_FAIL GH_MOCK_SLEEP

# shellcheck source=feature-3142-board-resolve/_lib.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-3142-board-resolve/_lib.sh"
f3142_install_mock "$TMP_ROOT"
export GH_MOCK_LOG="$TMP_ROOT/gh.log" GH_MOCK_REPO="mockowner/mockrepo"
export GH_MOCK_LINKED_FILE="$TMP_ROOT/linked.json"
CLI="$SCRIPT_CHECKOUT_ROOT/bin/github-issues/resolve-board.sh"
CACHE="$(f3142_cache_file)"
# A cwd outside any repo: the board comes from the argument, never from origin.
cd "$TMP_ROOT" || exit 1

# rb <args...> — runs the CLI; RC, OUT (CR-stripped stdout), ERR.
rb() {
  run_with_timeout 60 bash "$CLI" "$@" >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"
  RC=$?
  OUT="$(tr -d '\r' <"$TMP_ROOT/out")"
  ERR="$(cat "$TMP_ROOT/err")"
}
kv() { sed -n "s/^$1=//p" <<<"$OUT"; }

case_begin "entry-present-and-usage" "bin/github-issues/resolve-board.sh"
if [ -f "$CLI" ]; then pass "resolve-board.sh exists"; else fail "resolve-board.sh exists" "bin/github-issues/resolve-board.sh not found (implementation missing)"; fi
rb
assert_eq "no repo argument: rc=$RC" "no repo argument: rc=2"
case_end

case_begin "resolved-prints-every-key" "bin/github-issues/resolve-board.sh"
f3142_linked "$GH_MOCK_LINKED_FILE" false "PVT_a:3:boardowner:false"
rb --no-cache-read mockowner/mockrepo
assert_eq "$RC/$(kv status)/$(kv project_id)/$(kv number)/$(kv owner)" "0/resolved/PVT_a/3/boardowner"
assert_eq "$(kv content_date_field_id)/$(kv status_field_id)/$(kv todo_option_id)/$(kv in_progress_option_id)/$(kv done_option_id)/$(kv session_id_field_id)" \
  "PVTF_cd/PVTSSF_st/OPT_todo/OPT_ip/OPT_done/PVTF_sid"
if [ -f "$CACHE" ]; then fail "--no-cache-read also skips the cache write" "$(cat "$CACHE")"; else pass "--no-cache-read also skips the cache write"; fi
case_end

case_begin "repo-argument-is-queried" "bin/github-issues/resolve-board.sh"
: >"$GH_MOCK_LOG"
f3142_linked "$GH_MOCK_LINKED_FILE" false "PVT_a:3:o:false"
rb --no-cache-read otherowner/otherrepo
if grep -q 'owner=otherowner' "$GH_MOCK_LOG" && grep -q 'repo=otherrepo' "$GH_MOCK_LOG"; then pass "query names the argument repo"
else fail "query names the argument repo" "$(head -c 400 "$GH_MOCK_LOG")"; fi
case_end

case_begin "non-resolved-statuses-exit-zero" "bin/github-issues/resolve-board.sh"
f3142_linked "$GH_MOCK_LINKED_FILE" false
rb --no-cache-read mockowner/mockrepo
assert_eq "$RC/$(kv status)/$(kv project_id)" "0/no-link/"
f3142_linked "$GH_MOCK_LINKED_FILE" false "PVT_a:3:o:false" "PVT_b:4:o:false"
rb --no-cache-read mockowner/mockrepo
assert_eq "$RC/$(kv status)" "0/ambiguous"
cands=" $(kv candidates) "
if [[ "$cands" == *" o#3 "* && "$cands" == *" o#4 "* ]]; then pass "ambiguous lists both candidates"; else fail "ambiguous lists both candidates" "$OUT"; fi
GH_MOCK_FAIL=linked rb --no-cache-read mockowner/mockrepo
assert_eq "$RC/$(kv status)" "0/fetch-failed"
case_end

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ] || exit 1
