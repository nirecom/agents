#!/usr/bin/env bash
# Tests: bin/github-issues/migration/backfill-board-cards.sh
# Tags: scope:issue-specific, feature-3142, backfill, board-card, projects-v2, TL2
# TL3 gap: ensure-board-card is a fake and gh is the #3142 JSON mock; no live issue listing or item-add runs.
#
# #3142 Step 8: backfill counts each issue by the last BOARD_CARD= line of ensure-board-card (added/existing
# ok, skipped, failed or no line failed), prints `[backfill] FAIL #n (<reason>)`, and exits 1 on any failure.
# --list-missing walks the open issues 100 per page and prints only the issues with no card on the resolved
# board; an issue whose first 20 projectItems miss the board but have more is reported unknown on stderr.

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

set -uo pipefail

readonly TMP_ROOT="$(make_tmp)"
trap 'rm -rf "$TMP_ROOT"' EXIT
export HOME="$TMP_ROOT/home"
export WORKFLOW_STATE_DIR="$TMP_ROOT/state" WORKFLOW_PLANS_DIR="$TMP_ROOT/plans"
mkdir -p "$HOME" "$WORKFLOW_STATE_DIR" "$WORKFLOW_PLANS_DIR"
unset CLAUDE_CODE_SESSION_ID _ISSUE_CREATE_INTERNAL_OWNER _ISSUE_CREATE_INTERNAL_PROJECT_NUM \
  _ISSUE_CREATE_INTERNAL_PROJECT_ID GH_MOCK_FAIL GH_MOCK_SLEEP GH_MOCK_ITEM_ON GH_MOCK_ITEMADD_GONE_FILE \
  GH_MOCK_ITEMADD_GONE_TIMES

# shellcheck source=feature-3142-board-resolve/_lib.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-3142-board-resolve/_lib.sh"
f3142_install_mock "$TMP_ROOT"
export GH_MOCK_LOG="$TMP_ROOT/gh.log" GH_MOCK_REPO="mockowner/mockrepo"
export GH_MOCK_LINKED_FILE="$TMP_ROOT/linked.json" GH_MOCK_ISSUES_DIR="$TMP_ROOT/pages"
BACKFILL="$SCRIPT_CHECKOUT_ROOT/bin/github-issues/migration/backfill-board-cards.sh"
GH_REPO="$TMP_ROOT/gh-repo"
f3142_repo "$GH_REPO" mockowner/mockrepo

# A copy of the github-issues tree whose ensure-board-card.sh is a fake: the backfill finds the primitive
# next to itself, so the fake replaces it only in the copy. Fake answers by issue number:
#   1 added, 2 existing, 3 failed (item-add), 4 no result line, 5 skipped (gitlab); all exit 0.
FAKE_TREE="$TMP_ROOT/tree/bin/github-issues"
mkdir -p "$FAKE_TREE"
cp -R "$SCRIPT_CHECKOUT_ROOT/bin/github-issues/migration" "$SCRIPT_CHECKOUT_ROOT/bin/github-issues/lib" "$FAKE_TREE/"
cat >"$FAKE_TREE/ensure-board-card.sh" <<'EOF'
#!/usr/bin/env bash
n="${!#}"
echo "ensure-board-card: working on #$n"
case "$n" in
  1) echo "BOARD_CARD=added issue=1 reason=added" ;;
  2) echo "BOARD_CARD=existing issue=2 reason=existing" ;;
  3) echo "ensure-board-card: item-add failed" >&2; echo "BOARD_CARD=failed issue=3 reason=item-add" ;;
  4) : ;;
  5) echo "BOARD_CARD=skipped issue=5 reason=gitlab" ;;
esac
exit 0
EOF
chmod +x "$FAKE_TREE/ensure-board-card.sh"
FAKE_BACKFILL="$FAKE_TREE/migration/backfill-board-cards.sh"

# run <dir> <script> <args...> — RC, OUT, ERR.
run() {
  local dir="$1" script="$2"; shift 2
  (cd "$dir" && run_with_timeout 60 bash "$script" "$@") >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"
  RC=$?
  OUT="$(tr -d '\r' <"$TMP_ROOT/out")"
  ERR="$(tr -d '\r' <"$TMP_ROOT/err")"
}
has() { grep -qE -- "$2" <<<"$1"; }
check() { if has "$1" "$2"; then pass "$3"; else fail "$3" "$(head -c 400 <<<"$1")"; fi; }
check_not() { if has "$1" "$2"; then fail "$3" "$(head -c 400 <<<"$1")"; else pass "$3"; fi; }

case_begin "failed-result-line-fails-the-backfill" "bin/github-issues/migration/backfill-board-cards.sh"
run "$GH_REPO" "$FAKE_BACKFILL" 1 2 3 4 5
assert_eq "exit with a failed card: $RC" "exit with a failed card: 1"
check "$ERR" '^\[backfill\] FAIL #3 \(item-add\)' "the failed issue names its reason"
check "$ERR" '^\[backfill\] FAIL #4( |$)' "an issue with no result line counts as failed"
check_not "$ERR$OUT" '\[backfill\] (OK|FAIL) #5( |$)' "the skipped issue is neither ok nor failed"
check "$OUT" '^\[backfill\] OK #1$' "added counts as ok"
check "$OUT" '^\[backfill\] OK #2$' "existing counts as ok"
check "$OUT$ERR" 'failed: 2' "the summary counts two failures"
case_end

case_begin "all-ok-result-lines-exit-0" "bin/github-issues/migration/backfill-board-cards.sh"
run "$GH_REPO" "$FAKE_BACKFILL" 1 2 5
assert_eq "exit without failures: $RC" "exit without failures: 0"
check_not "$ERR" '\[backfill\] FAIL' "no FAIL line without a failed card"
case_end

# issue_node <num> <hasNextPage> <pid...> — one issues node with those projectItems.
issue_node() {
  local n="$1" more="$2" items="" sep="" p
  shift 2
  for p in "$@"; do items="$items$sep{\"project\":{\"id\":\"$p\"}}"; sep=","; done
  printf '{"number":%s,"projectItems":{"nodes":[%s],"pageInfo":{"hasNextPage":%s}}}' "$n" "$items" "$more"
}
# page <file> <hasNextPage> <endCursor> <node...>
page() {
  local f="$1" more="$2" cur="$3" nodes
  shift 3
  nodes="$(IFS=','; printf '%s' "$*")"
  printf '{"data":{"repository":{"issues":{"nodes":[%s],"pageInfo":{"hasNextPage":%s,"endCursor":%s}}}}}\n' \
    "$nodes" "$more" "$cur" >"$GH_MOCK_ISSUES_DIR/$f.json"
}
others() { local i; for i in $(seq 1 "$1"); do printf 'PVT_o%s ' "$i"; done; }

case_begin "list-missing-prints-only-issues-without-a-card" "bin/github-issues/migration/backfill-board-cards.sh"
mkdir -p "$GH_MOCK_ISSUES_DIR"
f3142_linked "$GH_MOCK_LINKED_FILE" false "PVT_a:3:mockowner:false"
# Page 1: #10 on the board; #11 no card; #12 20 other boards and more (the board is the 21st) -> unknown.
# Page 2: #13 the board within the first 20 and more -> on the board; #14 another board only -> no card.
# shellcheck disable=SC2046
page first true '"c2"' "$(issue_node 10 false PVT_a)" "$(issue_node 11 false)" \
  "$(issue_node 12 true $(others 20))"
# shellcheck disable=SC2046
page c2 false null "$(issue_node 13 true $(others 4) PVT_a $(others 15))" "$(issue_node 14 false PVT_z)"
: >"$GH_MOCK_LOG"
run "$GH_REPO" "$BACKFILL" --list-missing
assert_eq "list-missing exit: $RC" "list-missing exit: 0"
assert_eq "missing issues: $(sed 's/^#//' <<<"$OUT" | grep -E '^[0-9]+$' | tr '\n' ' ')" "missing issues: 11 14 "
check_not "$OUT" '(^|[^0-9])1[023]([^0-9]|$)' "issues on the board or unknown are not listed"
check "$ERR" '(^|[^0-9])12([^0-9]|$)' "the issue with more than 20 project items is reported unknown"
check_not "$ERR" '(^|[^0-9])13([^0-9]|$)' "an issue with the board in its first 20 items is not unknown"
check "$ERR" '--from-file' "the unknown summary points at --from-file"
if [ "$(grep -c 'issues(' "$GH_MOCK_LOG")" -ge 2 ] || grep -q -- '--paginate' "$GH_MOCK_LOG"; then
  pass "both issue pages were read"
else fail "both issue pages were read" "$(head -c 600 "$GH_MOCK_LOG")"; fi
case_end

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ] || exit 1
