#!/usr/bin/env bash
# Tests: bin/github-issues/lib/resolve-project.sh, bin/github-issues/lib/resolve-project/linked.sh
# Tags: scope:issue-specific, feature-3142, resolve-project, projects-v2, cache, TL2
# TL3 gap: the repository projectsV2 connection is answered by a JSON mock (real jq applied to
# the code's own filters); a live GitHub API with closed / unlinked boards is not exercised.
#
# #3142 Step 1 / Step 3: the resolver keys on the repo's linked boards, counts open ones only and
# reports RESOLVED_STATUS (resolved / no-link / ambiguous / fetch-failed); a cache hit re-checks the
# link and re-resolves (or fails ambiguous) when the cached board is no longer the only open one.

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
  BOARD_CARD_REPO_OVERRIDE GH_MOCK_FAIL GH_MOCK_LINKED_FILE GH_MOCK_LINKED_NEXT_FILE GH_MOCK_LINKED_RAW

# shellcheck source=feature-3142-board-resolve/_lib.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-3142-board-resolve/_lib.sh"
RP="$SCRIPT_CHECKOUT_ROOT/bin/github-issues/lib/resolve-project.sh"
LINKED_SH="$SCRIPT_CHECKOUT_ROOT/bin/github-issues/lib/resolve-project/linked.sh"
f3142_install_mock "$TMP_ROOT"
export GH_MOCK_LOG="$TMP_ROOT/gh.log" GH_MOCK_REPO="mockowner/mockrepo"
export GH_MOCK_LINKED_FILE="$TMP_ROOT/linked.json"
REPO="$TMP_ROOT/repo"
f3142_repo "$REPO" "mockowner/mockrepo"
CACHE="$(f3142_cache_file)"

# rp <args...> — resolve_project_for_repo from the fixture repo; sets RC STATUS CANDS PID NUM OWNER KEY ERR.
rp() {
  : >"$GH_MOCK_LOG"
  (cd "$REPO" && run_with_timeout 60 bash -c '. "$1" >/dev/null 2>&1 || exit 99; shift
    resolve_project_for_repo "$@"; rc=$?
    printf "RC=%s\nSTATUS=%s\nCANDS=%s\nPID=%s\nNUM=%s\nOWNER=%s\nKEY=%s\n" "$rc" "${RESOLVED_STATUS:-}" \
      "${RESOLVED_CANDIDATES:-}" "$RESOLVED_PROJECT_ID" "$RESOLVED_PROJECT_NUM" "$RESOLVED_OWNER" "$RESOLVED_CACHE_KEY"' \
    _ "$RP" "$@") >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"
  local o
  o="$(tr -d '\r' <"$TMP_ROOT/out")"
  RC="$(sed -n 's/^RC=//p' <<<"$o")"; STATUS="$(sed -n 's/^STATUS=//p' <<<"$o")"
  CANDS="$(sed -n 's/^CANDS=//p' <<<"$o")"; PID="$(sed -n 's/^PID=//p' <<<"$o")"
  NUM="$(sed -n 's/^NUM=//p' <<<"$o")"; OWNER="$(sed -n 's/^OWNER=//p' <<<"$o")"
  KEY="$(sed -n 's/^KEY=//p' <<<"$o")"; ERR="$(cat "$TMP_ROOT/err")"
}
reset_cache() { rm -f "$CACHE"; }
seed_cache() { mkdir -p "$(dirname "$CACHE")"; f3142_cache_row mockowner/mockrepo cacheowner 9 "$1" >"$CACHE"; }
cache_pid() { awk -F'\t' '$1 == "mockowner/mockrepo" {print $4}' "$CACHE" 2>/dev/null; }
expect_in() { if [[ "$3" == *"$2"* ]]; then pass "$1"; else fail "$1" "missing [$2] in: $3"; fi; }
expect_not_in() { if [[ "$3" != *"$2"* ]]; then pass "$1"; else fail "$1" "unexpected [$2] in: $3"; fi; }
words() { set -f; set -- $1; set +f; echo "$#"; }

case_begin "linked-helper-present" "bin/github-issues/lib/resolve-project/linked.sh"
if [ -f "$LINKED_SH" ]; then pass "linked.sh exists"; else fail "linked.sh exists" "bin/github-issues/lib/resolve-project/linked.sh not found (implementation missing)"; fi
case_end

case_begin "one-open-board-resolves-with-project-owner" "bin/github-issues/lib/resolve-project.sh"
reset_cache
f3142_linked "$GH_MOCK_LINKED_FILE" false "PVT_a:3:boardowner:false"
rp
assert_eq "$RC/$STATUS" "0/resolved"
assert_eq "$PID/$NUM/$OWNER" "PVT_a/3/boardowner"
assert_eq "$(cache_pid)" "PVT_a"
case_end

case_begin "closed-board-is-not-counted" "bin/github-issues/lib/resolve-project/linked.sh"
reset_cache
f3142_linked "$GH_MOCK_LINKED_FILE" false "PVT_closed:1:o:true" "PVT_open:2:o:false"
rp
assert_eq "$RC/$STATUS/$PID/$NUM" "0/resolved/PVT_open/2"
case_end

case_begin "no-linked-board-is-no-link" "bin/github-issues/lib/resolve-project/linked.sh"
reset_cache
f3142_linked "$GH_MOCK_LINKED_FILE" false
rp
assert_eq "$RC/$STATUS/$PID" "1/no-link/"
f3142_linked "$GH_MOCK_LINKED_FILE" false "PVT_closed:1:o:true"
rp
assert_eq "only-closed: $RC/$STATUS" "only-closed: 1/no-link"
case_end

case_begin "two-open-boards-are-ambiguous" "bin/github-issues/lib/resolve-project/linked.sh"
reset_cache
f3142_linked "$GH_MOCK_LINKED_FILE" false "PVT_a:3:o:false" "PVT_b:4:o:false"
rp
assert_eq "$RC/$STATUS/$PID" "1/ambiguous/"
assert_eq "$(words "$CANDS")" "2"
expect_in "candidates name o#3" "o#3" "$CANDS"
expect_in "candidates name o#4" "o#4" "$CANDS"
expect_in "stderr refuses to pick" "refusing to pick one" "$ERR"
expect_in "stderr gives close recovery" "gh project close" "$ERR"
expect_in "stderr gives unlink recovery" "gh project unlink" "$ERR"
expect_not_in "no first-wins warn" "using first" "$ERR"
if [ ! -f "$CACHE" ]; then pass "ambiguous writes no cache"; else fail "ambiguous writes no cache" "$(cat "$CACHE")"; fi
case_end

case_begin "truncated-link-list-is-ambiguous" "bin/github-issues/lib/resolve-project/linked.sh"
reset_cache
f3142_linked "$GH_MOCK_LINKED_FILE" true "PVT_a:3:o:false"
rp
assert_eq "$RC/$STATUS/$PID" "1/ambiguous/"
case_end

case_begin "graphql-failure-is-fetch-failed" "bin/github-issues/lib/resolve-project/linked.sh"
reset_cache
f3142_linked "$GH_MOCK_LINKED_FILE" false "PVT_a:3:o:false"
GH_MOCK_FAIL=linked rp
assert_eq "$RC/$STATUS/$PID" "1/fetch-failed/"
case_end

case_begin "missing-gh-is-fetch-failed" "bin/github-issues/lib/resolve-project.sh"
reset_cache
NOGH_PATH="$(f3142_path_without_gh "$TMP_ROOT/nogh-tools")"
SAVED_PATH="$PATH"
PATH="$NOGH_PATH" rp
PATH="$SAVED_PATH"
assert_eq "$RC/$STATUS" "1/fetch-failed"
if [ -e "$TMP_ROOT/nogh-tools/gh" ]; then fail "tools dir holds no gh" "$(ls "$TMP_ROOT/nogh-tools")"; else pass "tools dir holds no gh"; fi
case_end

case_begin "internal-short-circuit-is-resolved-without-gh" "bin/github-issues/lib/resolve-project.sh"
reset_cache
f3142_linked "$GH_MOCK_LINKED_FILE" false "PVT_a:3:o:false" "PVT_b:4:o:false"
_ISSUE_CREATE_INTERNAL_OWNER=io _ISSUE_CREATE_INTERNAL_PROJECT_NUM=5 _ISSUE_CREATE_INTERNAL_PROJECT_ID=PVT_int rp
assert_eq "$RC/$STATUS/$PID/$NUM/$OWNER" "0/resolved/PVT_int/5/io"
if [ -s "$GH_MOCK_LOG" ]; then fail "short-circuit calls no gh" "$(head -c 400 "$GH_MOCK_LOG")"; else pass "short-circuit calls no gh"; fi
case_end

case_begin "cache-pid-outside-the-id-charset-is-a-confirm-failure" "bin/github-issues/lib/resolve-project.sh"
# PVT.c fails ^[A-Za-z0-9_-]+$: detail Step 3 treats it as a failed link confirmation — the cached board
# is used with a warn, the pid is never embedded in a query, and the row is kept.
seed_cache 'PVT.c'
f3142_linked "$GH_MOCK_LINKED_FILE" false "PVT_new:7:o:false"
rp
assert_eq "$RC/$STATUS/$PID/$NUM/$OWNER" "0/resolved/PVT.c/9/cacheowner"
expect_in "stderr warns the confirmation failed" "link check of cached board PVT.c failed" "$ERR"
expect_not_in "not treated as a stale hit" "is no longer the only open linked board" "$ERR"
expect_not_in "no link-check query issued" "projectsV2" "$(cat "$GH_MOCK_LOG")"
expect_not_in "pid never embedded in a gh call" "PVT.c" "$(cat "$GH_MOCK_LOG")"
assert_eq "$(cache_pid)" "PVT.c"
case_end

case_begin "origin-unresolvable-is-fetch-failed" "bin/github-issues/lib/resolve-project.sh"
reset_cache
f3142_linked "$GH_MOCK_LINKED_FILE" false "PVT_a:3:o:false"
git -C "$REPO" remote remove origin
rp
git -C "$REPO" remote add origin "https://github.com/mockowner/mockrepo.git"
assert_eq "$RC/$STATUS/$PID" "1/fetch-failed/"
expect_in "stderr names the origin remote" "could not resolve owner/repo from the origin remote" "$ERR"
expect_not_in "no linked query without an owner/repo" "projectsV2" "$(cat "$GH_MOCK_LOG")"
case_end

case_begin "count-one-but-no-open-node-is-fetch-failed" "bin/github-issues/lib/resolve-project/linked.sh"
# Race: the count query sees one open board, the board is gone before the head-node query.
reset_cache
f3142_linked "$GH_MOCK_LINKED_FILE" false "PVT_a:3:o:false"
f3142_linked "$TMP_ROOT/linked-next.json" false
GH_MOCK_LINKED_NEXT_FILE="$TMP_ROOT/linked-next.json" rp
assert_eq "$RC/$STATUS/$PID" "1/fetch-failed/"
expect_in "stderr says the board could not be read" "could not read the linked board" "$ERR"
if [ ! -f "$CACHE" ]; then pass "race writes no cache"; else fail "race writes no cache" "$(cat "$CACHE")"; fi
case_end

case_begin "non-numeric-count-is-fetch-failed" "bin/github-issues/lib/resolve-project/linked.sh"
reset_cache
f3142_linked "$GH_MOCK_LINKED_FILE" false "PVT_a:3:o:false"
GH_MOCK_LINKED_RAW="abc" rp
assert_eq "$RC/$STATUS/$PID" "1/fetch-failed/"
expect_in "stderr names the unexpected count" "unexpected linked board count 'abc'" "$ERR"
case_end

case_begin "invalid-repo-flag-is-fetch-failed-without-gh" "bin/github-issues/lib/resolve-project.sh"
reset_cache
f3142_linked "$GH_MOCK_LINKED_FILE" false "PVT_a:3:o:false"
for bad in "a/b/c" "o/r;x" "o r/x"; do
  rp --repo "$bad"
  assert_eq "[$bad]: $RC/$STATUS/$PID" "[$bad]: 1/fetch-failed/"
  if [ -s "$GH_MOCK_LOG" ]; then fail "[$bad] calls no gh" "$(head -c 400 "$GH_MOCK_LOG")"; else pass "[$bad] calls no gh"; fi
done
case_end

case_begin "repo-flag-overrides-origin" "bin/github-issues/lib/resolve-project.sh"
reset_cache
git -C "$REPO" remote set-url origin "https://github.com/wrongowner/elsewhere.git"
f3142_linked "$GH_MOCK_LINKED_FILE" false "PVT_a:3:o:false"
rp --repo rightowner/rightrepo
assert_eq "$RC/$STATUS/$KEY" "0/resolved/rightowner/rightrepo"
expect_in "query asks for the --repo owner" "owner=rightowner" "$(cat "$GH_MOCK_LOG")"
expect_not_in "origin owner never queried" "owner=wrongowner" "$(cat "$GH_MOCK_LOG")"
expect_not_in "no unknown-option warn" "unknown option" "$ERR"
rp --repo rightrepo
assert_eq "short form: $RC/$STATUS" "short form: 1/fetch-failed"
git -C "$REPO" remote set-url origin "https://github.com/mockowner/mockrepo.git"
case_end

case_begin "no-cache-write-leaves-cache-untouched" "bin/github-issues/lib/resolve-project.sh"
mkdir -p "$(dirname "$CACHE")"
f3142_cache_row other/repo o 1 PVT_other >"$CACHE"
BEFORE="$(cksum <"$CACHE")"
f3142_linked "$GH_MOCK_LINKED_FILE" false "PVT_a:3:o:false"
rp --no-cache-write
assert_eq "$RC/$STATUS/$PID" "0/resolved/PVT_a"
assert_eq "$(cksum <"$CACHE")" "$BEFORE"
case_end

case_begin "cache-hit-valid-skips-query-a" "bin/github-issues/lib/resolve-project.sh"
seed_cache PVT_c
f3142_linked "$GH_MOCK_LINKED_FILE" false "PVT_c:9:cacheowner:false"
rp
assert_eq "$RC/$STATUS/$PID/$OWNER" "0/resolved/PVT_c/cacheowner"
expect_in "link check ran" "projectsV2" "$(cat "$GH_MOCK_LOG")"
expect_not_in "Query A head node not fetched" "ownerLogin" "$(cat "$GH_MOCK_LOG")"
case_end

case_begin "cache-hit-stale-board-re-resolves" "bin/github-issues/lib/resolve-project.sh"
seed_cache PVT_old
f3142_linked "$GH_MOCK_LINKED_FILE" false "PVT_new:7:o:false"
rp
assert_eq "$RC/$STATUS/$PID/$NUM" "0/resolved/PVT_new/7"
assert_eq "$(cache_pid)" "PVT_new"
expect_in "stderr says re-resolving" "is no longer the only open linked board of mockowner/mockrepo; re-resolving" "$ERR"
case_end

case_begin "cache-hit-check-failure-keeps-cached-board" "bin/github-issues/lib/resolve-project.sh"
seed_cache PVT_c
f3142_linked "$GH_MOCK_LINKED_FILE" false "PVT_c:9:cacheowner:false"
GH_MOCK_FAIL=linked rp
assert_eq "$RC/$STATUS/$PID" "0/resolved/PVT_c"
expect_in "link check was attempted" "projectsV2" "$(cat "$GH_MOCK_LOG")"
assert_eq "$(cache_pid)" "PVT_c"
case_end

case_begin "cache-hit-second-open-board-is-ambiguous" "bin/github-issues/lib/resolve-project.sh"
seed_cache PVT_c
f3142_linked "$GH_MOCK_LINKED_FILE" false "PVT_c:9:cacheowner:false" "PVT_d:10:cacheowner:false"
rp
assert_eq "$RC/$STATUS/$PID" "1/ambiguous/"
assert_eq "$(words "$CANDS")" "2"
expect_in "stderr gives close recovery" "gh project close" "$ERR"
expect_in "stderr gives unlink recovery" "gh project unlink" "$ERR"
assert_eq "row dropped and not rewritten: [$(cache_pid)]" "row dropped and not rewritten: []"
case_end

case_begin "cache-hit-truncated-link-list-is-ambiguous" "bin/github-issues/lib/resolve-project.sh"
seed_cache PVT_c
f3142_linked "$GH_MOCK_LINKED_FILE" true "PVT_c:9:cacheowner:false"
rp
assert_eq "$RC/$STATUS/$PID" "1/ambiguous/"
assert_eq "row dropped: [$(cache_pid)]" "row dropped: []"
case_end

case_begin "cache-hit-board-closed-re-resolves-to-open-board" "bin/github-issues/lib/resolve-project.sh"
seed_cache PVT_old
f3142_linked "$GH_MOCK_LINKED_FILE" false "PVT_old:9:cacheowner:true" "PVT_new:7:o:false"
rp
assert_eq "$RC/$STATUS/$PID/$NUM/$OWNER" "0/resolved/PVT_new/7/o"
assert_eq "$(cache_pid)" "PVT_new"
expect_not_in "closed board id gone from cache" "PVT_old" "$(cat "$CACHE" 2>/dev/null)"
assert_eq "re-resolve count: $(grep -c 're-resolving' <<<"$ERR")" "re-resolve count: 1"
expect_in "stderr names the closed cached board" "cached board PVT_old is no longer the only open linked board" "$ERR"
case_end

case_begin "malformed-linked-node-is-fetch-failed" "bin/github-issues/lib/resolve-project/linked.sh"
# Table: one open linked node per row, fed through the real jq head-node filter into _resolve_project_parse_node.
while IFS='|' read -r name node want; do
  [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
  name="${name//[[:space:]]/}"; want="${want//[[:space:]]/}"
  reset_cache
  printf '{"nodes":[%s],"pageInfo":{"hasNextPage":false,"endCursor":null}}\n' "$node" >"$GH_MOCK_LINKED_FILE"
  rp
  assert_eq "$name: $RC/$STATUS/$PID/$NUM" "$name: $want"
  if [[ "$want" == 1/* ]]; then
    if [[ -f "$CACHE" ]]; then fail "$name: no cache write" "$(cat "$CACHE")"; else pass "$name: no cache write"; fi
    expect_in "$name: stderr says the board could not be read" "could not read the linked board" "$ERR"
  fi
done <<'TABLE'
valid-control        | {"id":"PVT_v","number":3,"closed":false,"owner":{"login":"o"}}  | 0/resolved/PVT_v/3
missing-id           | {"number":3,"closed":false,"owner":{"login":"o"}}               | 1/fetch-failed//
missing-number       | {"id":"PVT_v","closed":false,"owner":{"login":"o"}}             | 1/fetch-failed//
missing-owner-login  | {"id":"PVT_v","number":3,"closed":false,"owner":{}}             | 1/fetch-failed//
missing-owner        | {"id":"PVT_v","number":3,"closed":false}                        | 1/fetch-failed//
id-not-string        | {"id":123,"number":3,"closed":false,"owner":{"login":"o"}}      | 1/fetch-failed//
number-quoted        | {"id":"PVT_v","number":"3","closed":false,"owner":{"login":"o"}} | 1/fetch-failed//
number-non-numeric   | {"id":"PVT_v","number":"abc","closed":false,"owner":{"login":"o"}} | 1/fetch-failed//
owner-login-number   | {"id":"PVT_v","number":3,"closed":false,"owner":{"login":5}}    | 1/fetch-failed//
id-null              | {"id":null,"number":3,"closed":false,"owner":{"login":"o"}}     | 1/fetch-failed//
number-null          | {"id":"PVT_v","number":null,"closed":false,"owner":{"login":"o"}} | 1/fetch-failed//
owner-login-null     | {"id":"PVT_v","number":3,"closed":false,"owner":{"login":null}} | 1/fetch-failed//
id-empty             | {"id":"","number":3,"closed":false,"owner":{"login":"o"}}       | 1/fetch-failed//
owner-login-empty    | {"id":"PVT_v","number":3,"closed":false,"owner":{"login":""}}   | 1/fetch-failed//
TABLE
case_end

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
if [[ "$FAIL" -gt 0 ]]; then exit 1; fi
exit 0
