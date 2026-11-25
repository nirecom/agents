#!/usr/bin/env bash
# tests/bin/feature-2308-ensure-board-card-gitlab.sh
# Tests: bin/github-issues/ensure-board-card.sh
# Tags: scope:issue-specific, gitlab, forge, ensure-board-card, board-card, TL2, dup-group-keep:size-hard-limit, feature-3142, projects-v2
# Serial: H1 — probes and removes the fixed shared path /tmp/EBC_INJECT
# Issue #2308 — the GitLab skip path of ensure-board-card.sh. GitLab Free has no
# Projects v2 board (status labels are the board, owned by wip-state.sh), so on a
# gitlab remote the script skips board-card creation cleanly (exit 0) BEFORE it
# touches gh, and attempts no `gh project` mutation. Own file because the natural
# target is over the 500-line HARD limit. Forge is forced via a fake
# bin/detect-forge-type CLI; gh is a logging mock so any gh call is observable.
set -u

# # TL3 gap (what this test does NOT catch):
# - Real `node bin/detect-forge-type` resolving a live gitlab origin.
# - Real `gh project` refusal — the mock only records that gh was never called.
# Closest mitigation: WORKFLOW_USER_VERIFIED preflight (skill-orchestration).
# - #3142 cases: gh is the #3142 JSON mock on PATH; a real item-add against a closed board is not run.

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EBC_SCRIPT="$SCRIPT_CHECKOUT_ROOT/bin/github-issues/ensure-board-card.sh"
# shellcheck source=../lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
# shellcheck source=tests/lib/script-checkout-fixture.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/script-checkout-fixture.sh"
# #3142: ensure-board-card.sh reaches the board resolver; keep its state, cache and HOME out of the real store.
F3142_PIN_ROOT="$(mktemp -d)"; readonly F3142_PIN_ROOT
trap 'rm -rf "$F3142_PIN_ROOT"' EXIT
export WORKFLOW_STATE_DIR="$F3142_PIN_ROOT/wf-state" WORKFLOW_PLANS_DIR="$F3142_PIN_ROOT/wf-plans"
export HOME="$F3142_PIN_ROOT/home"
mkdir -p "$HOME" "$WORKFLOW_STATE_DIR" "$WORKFLOW_PLANS_DIR"
unset CLAUDE_CODE_SESSION_ID _ISSUE_CREATE_INTERNAL_OWNER _ISSUE_CREATE_INTERNAL_PROJECT_NUM \
  _ISSUE_CREATE_INTERNAL_PROJECT_ID GH_MOCK_FAIL GH_MOCK_SLEEP GH_MOCK_ITEM_ON GH_MOCK_ITEMADD_GONE_FILE \
  GH_MOCK_ITEMADD_GONE_TIMES

# Existence gate.
if [ ! -f "$EBC_SCRIPT" ]; then
    echo "FAIL: precondition missing — bin/github-issues/ensure-board-card.sh"
    echo ""
    echo "Results: 0 passed, 1 failed"
    exit 1
fi

_OLDPATH="$PATH"

# Fake detect-forge-type CLI (invoked via `node <path>`, so no exec bit is
# needed), keyed by SHIM_FORGE so each case fixes the resolved forge. gh is a
# logging mock: every invocation is appended to GH_LOG.
setup_ebc() {
    EBCTMP="$(mktemp -d)"
    mkdir -p "$EBCTMP/bin" "$EBCTMP/mockbin"
    # The script finds detect-forge-type from its own path, so the fake is reached only when a
    # copy of the script (with its lib/) runs from the same fake checkout.
    script_checkout_fixture_copy "$EBCTMP" bin/github-issues/ensure-board-card.sh bin/github-issues/lib
    FAKE_EBC_SCRIPT="$EBCTMP/bin/github-issues/ensure-board-card.sh"
    cat > "$EBCTMP/bin/detect-forge-type" <<'NODE'
"use strict";
const argv = process.argv;
function arg(n){const i=argv.indexOf(n);return i>=0&&i+1<argv.length?argv[i+1]:null;}
const field = arg("--field");
if (field === "type") process.stdout.write((process.env.SHIM_FORGE || "") + "\n");
else if (field === "project") process.stdout.write((process.env.SHIM_PROJECT || "acme/widgets") + "\n");
else process.stdout.write("\n");
NODE
    export GH_LOG="$EBCTMP/gh.log"
    : > "$GH_LOG"
    cat > "$EBCTMP/mockbin/gh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$*" in
    "auth status"*) echo "Token scopes: 'project'"; exit 0 ;;
esac
exit 0
EOF
    chmod +x "$EBCTMP/mockbin/gh"
    export PATH="$EBCTMP/mockbin:$PATH"
}

teardown_ebc() {
    export PATH="$_OLDPATH"
    if [ -n "${EBCTMP:-}" ] && [ -d "$EBCTMP" ]; then rm -rf "$EBCTMP"; fi
    unset GH_LOG SHIM_FORGE SHIM_PROJECT EBCTMP FAKE_EBC_SCRIPT
}

# run_ebc <args...> : run the fake-checkout copy of the real script from a neutral CWD;
# captures stderr into EBC_ERR and returns the exit code.
run_ebc() {
    local rc
    ( cd "$EBCTMP" && run_with_timeout 20 bash "$FAKE_EBC_SCRIPT" "$@" ) >/tmp/ebc_out.$$ 2>/tmp/ebc_err.$$
    rc=$?
    EBC_OUT=$(cat /tmp/ebc_out.$$ 2>/dev/null)
    EBC_ERR=$(cat /tmp/ebc_err.$$ 2>/dev/null)
    rm -f /tmp/ebc_out.$$ /tmp/ebc_err.$$
    return $rc
}

SKIP_MSG="GitLab has no Projects v2 board"

case_begin "gitlab-skip-path" "bin/github-issues/ensure-board-card.sh"
# E1: gitlab remote -> clean skip (exit 0), skip message on stderr, gh untouched.
setup_ebc
SHIM_FORGE=gitlab run_ebc 42; RC=$?
if [ "$RC" -eq 0 ] && echo "$EBC_ERR" | grep -qF "$SKIP_MSG" && [ ! -s "$GH_LOG" ]; then
    pass "E1: gitlab remote -> skip (exit 0), skip message, gh never called"
else
    fail "E1: gitlab skip path" "rc=$RC gh_log=[$(cat "$GH_LOG" 2>/dev/null)] err=$EBC_ERR"
fi
teardown_ebc

# E2: gitlab skip must not attempt a `gh project` mutation specifically — the
# CPR-ORTH board-mutation counterpart of E1's "gh never called".
setup_ebc
SHIM_FORGE=gitlab run_ebc 42 >/dev/null 2>&1
if ! grep -q 'project' "$GH_LOG" 2>/dev/null; then
    pass "E2: gitlab skip attempts no 'gh project' mutation"
else
    fail "E2: gh project mutation attempted on skip path" "gh_log=[$(cat "$GH_LOG" 2>/dev/null)]"
fi
teardown_ebc

# E3 (CPR-ORTH negative): github remote must NOT take the gitlab skip path —
# proves the skip message is gitlab-specific, not emitted unconditionally.
setup_ebc
SHIM_FORGE=github run_ebc 42; RC=$?
if ! echo "$EBC_ERR" | grep -qF "$SKIP_MSG"; then
    pass "E3: github remote does not emit the gitlab skip message"
else
    fail "E3: github remote wrongly took the gitlab skip path" "rc=$RC err=$EBC_ERR"
fi
teardown_ebc

# E4 (edge): unknown/empty forge -> not the gitlab skip path either.
setup_ebc
SHIM_FORGE='' run_ebc 42; RC=$?
if ! echo "$EBC_ERR" | grep -qF "$SKIP_MSG"; then
    pass "E4: unknown/empty forge does not emit the gitlab skip message"
else
    fail "E4: unknown forge wrongly took the gitlab skip path" "rc=$RC err=$EBC_ERR"
fi
teardown_ebc

# E5 (edge, usage error): non-numeric N -> exit 2 (usage), BEFORE forge detection.
setup_ebc
SHIM_FORGE=gitlab run_ebc "42; touch /tmp/EBC_INJECT" >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 2 ] && [ ! -f /tmp/EBC_INJECT ]; then
    pass "E5: non-numeric N -> exit 2 (usage), no shell injection"
else
    fail "E5: usage guard" "rc=$RC inject=$([ -f /tmp/EBC_INJECT ] && echo yes || echo no)"
    rm -f /tmp/EBC_INJECT 2>/dev/null
fi
teardown_ebc

# E6 (edge, usage error): missing N -> exit 2 (usage).
setup_ebc
SHIM_FORGE=gitlab run_ebc >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 2 ]; then
    pass "E6: missing N -> exit 2 (usage)"
else
    fail "E6: missing N should exit 2" "rc=$RC"
fi
teardown_ebc

# E7 (idempotency): re-running the gitlab skip is a no-op — both runs exit 0,
# both emit the skip message, and gh is never called across either run.
setup_ebc
SHIM_FORGE=gitlab run_ebc 42; RC1=$?
SHIM_FORGE=gitlab run_ebc 42; RC2=$?
if [ "$RC1" -eq 0 ] && [ "$RC2" -eq 0 ] && echo "$EBC_ERR" | grep -qF "$SKIP_MSG" && [ ! -s "$GH_LOG" ]; then
    pass "E7: repeated gitlab skip is idempotent (exit 0, no gh side effect)"
else
    fail "E7: idempotency" "rc1=$RC1 rc2=$RC2 gh_log=[$(cat "$GH_LOG" 2>/dev/null)]"
fi
teardown_ebc
case_end

# ---- #3142 Steps 3 and 7 ----
# ensure-board-card prints one last stdout line `BOARD_CARD=<added|existing|failed|skipped> issue=<N>
# reason=<token>` (none on a usage error), keeps exit 0, passes --repo to the resolver, and on an item-add
# that says the board is gone drops the cached row, re-resolves once and retries the item-add once.
TMP_ROOT="$F3142_PIN_ROOT/f3142"; readonly TMP_ROOT
mkdir -p "$TMP_ROOT"
# shellcheck source=feature-3142-board-resolve/_lib.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-3142-board-resolve/_lib.sh"
f3142_install_mock "$TMP_ROOT"
export GH_MOCK_LOG="$TMP_ROOT/gh.log" GH_MOCK_REPO="mockowner/mockrepo"
export GH_MOCK_LINKED_FILE="$TMP_ROOT/linked.json"
CACHE="$(f3142_cache_file)"
GH_REPO="$TMP_ROOT/gh-repo"
GL_REPO="$TMP_ROOT/gl-repo"
f3142_repo "$GH_REPO" mockowner/mockrepo
mkdir -p "$GL_REPO"
harness_git_init "$GL_REPO"
git -C "$GL_REPO" remote add origin "https://gitlab.com/mockowner/mockrepo.git"

# fresh — one open linked board PVT_a, no cache, empty log, every knob cleared.
fresh() {
  unset GH_MOCK_FAIL GH_MOCK_ITEM_ON GH_MOCK_ITEMADD_GONE_FILE GH_MOCK_ITEMADD_GONE_TIMES GH_MOCK_CARD_STATUS
  unset WIP_STATE_STATUS_FIELD_ID WIP_STATE_IN_PROGRESS_OPTION_ID EBC_STATUS_FIELD_ID EBC_STATUS_INPROG_OPTION_ID
  unset _ISSUE_CREATE_INTERNAL_OWNER _ISSUE_CREATE_INTERNAL_PROJECT_NUM _ISSUE_CREATE_INTERNAL_PROJECT_ID
  rm -rf "$(dirname "$CACHE")" "$TMP_ROOT/gone"
  f3142_linked "$GH_MOCK_LINKED_FILE" false "PVT_a:3:mockowner:false"
  : >"$GH_MOCK_LOG"
}
# ebc <dir> <args...> — runs ensure-board-card.sh from <dir>; RC, OUT, LAST (last stdout line), ERR.
ebc() {
  local dir="$1"; shift
  (cd "$dir" && run_with_timeout 60 bash "$EBC_SCRIPT" "$@") >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"
  RC=$?
  OUT="$(tr -d '\r' <"$TMP_ROOT/out")"
  LAST="$(tail -n 1 <<<"$OUT")"
  ERR="$(cat "$TMP_ROOT/err")"
}
count() { grep -cE "$1" "$GH_MOCK_LOG"; }
# expect_ok <added|existing> — rc 0 and that result for #7; the plan fixes no reason token for a clean card.
expect_ok() {
  if [ "$RC" = 0 ] && [[ "$LAST" =~ ^BOARD_CARD=$1\ issue=7\ reason=[^\ ]*$ ]] && [[ "$LAST" != *failed* ]]; then
    pass "result $1 for #7"
  else fail "result $1 for #7" "rc=$RC last=[$LAST] err=$(head -c 300 <<<"$ERR")"; fi
}

case_begin "result-added-and-existing" "bin/github-issues/ensure-board-card.sh"
fresh
ebc "$GH_REPO" 7
expect_ok added
fresh
export GH_MOCK_ITEM_ON=PVT_a
ebc "$GH_REPO" 7
expect_ok existing
case_end

case_begin "result-failed-carries-the-reason" "bin/github-issues/ensure-board-card.sh"
fresh
f3142_linked "$GH_MOCK_LINKED_FILE" false
ebc "$GH_REPO" 7
assert_eq "rc=$RC last=$LAST" "rc=0 last=BOARD_CARD=failed issue=7 reason=resolve-no-link"
fresh
f3142_linked "$GH_MOCK_LINKED_FILE" false "PVT_a:3:mockowner:false" "PVT_b:4:mockowner:false"
ebc "$GH_REPO" 7
assert_eq "rc=$RC last=$LAST" "rc=0 last=BOARD_CARD=failed issue=7 reason=resolve-ambiguous"
fresh
export GH_MOCK_FAIL=linked
ebc "$GH_REPO" 7
assert_eq "rc=$RC last=$LAST" "rc=0 last=BOARD_CARD=failed issue=7 reason=resolve-fetch-failed"
fresh
export GH_MOCK_FAIL=issue-view
ebc "$GH_REPO" 7
assert_eq "rc=$RC last=$LAST" "rc=0 last=BOARD_CARD=failed issue=7 reason=issue-view"
fresh
export GH_MOCK_FAIL=item-add
ebc "$GH_REPO" 7
assert_eq "rc=$RC last=$LAST" "rc=0 last=BOARD_CARD=failed issue=7 reason=item-add"
case_end

case_begin "result-skipped-and-usage" "bin/github-issues/ensure-board-card.sh"
fresh
ebc "$GL_REPO" 7
assert_eq "rc=$RC last=$LAST" "rc=0 last=BOARD_CARD=skipped issue=7 reason=gitlab"
fresh
ebc "$GH_REPO" not-a-number
assert_eq "usage rc=$RC" "usage rc=2"
if grep -q '^BOARD_CARD=' <<<"$OUT"; then fail "no result line on a usage error" "$OUT"; else pass "no result line on a usage error"; fi
case_end

case_begin "repo-option-reaches-the-resolver" "bin/github-issues/ensure-board-card.sh"
fresh
ebc "$GH_REPO" --repo otherowner/otherrepo 7
q="$(grep -E 'projectsV2' "$GH_MOCK_LOG" | head -1)"
if [[ "$q" == *"owner=otherowner"* && "$q" == *"repo=otherrepo"* ]]; then pass "board resolved for the --repo repository"
else fail "board resolved for the --repo repository" "first projectsV2 call: ${q:-<none>}"; fi
case_end

# The issue already has a card on PVT_a, so the script goes on to read that card's Status and the read fails.
case_begin "result-status-read-reason" "bin/github-issues/ensure-board-card.sh"
fresh
export GH_MOCK_ITEM_ON=PVT_a GH_MOCK_FAIL=status-read
ebc "$GH_REPO" 7
if [ "$(count 'fieldValueByName')" -ge 1 ]; then pass "the existing card's Status was read"
else fail "the existing card's Status was read" "$(head -c 600 "$GH_MOCK_LOG")"; fi
assert_eq "rc=$RC last=$LAST" "rc=0 last=BOARD_CARD=failed issue=7 reason=status-read"
case_end

# The existing card sits at Done, so the script resets it to In Progress first and that write fails.
case_begin "result-status-reset-reason" "bin/github-issues/ensure-board-card.sh"
fresh
export GH_MOCK_ITEM_ON=PVT_a GH_MOCK_CARD_STATUS=Done GH_MOCK_FAIL=status-reset
export WIP_STATE_STATUS_FIELD_ID=PVTSSF_st WIP_STATE_IN_PROGRESS_OPTION_ID=OPT_ip
ebc "$GH_REPO" 7
assert_eq "rc=$RC last=$LAST" "rc=0 last=BOARD_CARD=failed issue=7 reason=status-reset"
assert_eq "no Content Date write after the failed reset: $(count ' --date ')" "no Content Date write after the failed reset: 0"
case_end

# A card exists (added or already there), so a failed Content Date write keeps that verdict.
case_begin "result-content-date-failure-keeps-the-card-verdict" "bin/github-issues/ensure-board-card.sh"
fresh
export GH_MOCK_FAIL=content-date
ebc "$GH_REPO" 7
assert_eq "rc=$RC last=$LAST" "rc=0 last=BOARD_CARD=added issue=7 reason=content-date-failed"
fresh
export GH_MOCK_FAIL=content-date GH_MOCK_ITEM_ON=PVT_a
ebc "$GH_REPO" 7
assert_eq "rc=$RC last=$LAST" "rc=0 last=BOARD_CARD=existing issue=7 reason=content-date-failed"
assert_eq "the Content Date write was attempted: $(count ' --date ')" "the Content Date write was attempted: 1"
case_end

case_begin "result-skipped-no-gh" "bin/github-issues/ensure-board-card.sh"
fresh
NOGH_PATH="$(f3142_path_without_gh "$TMP_ROOT/nogh-tools")"
SAVED_PATH="$PATH"
PATH="$NOGH_PATH" ebc "$GH_REPO" 7
PATH="$SAVED_PATH"
assert_eq "rc=$RC last=$LAST" "rc=0 last=BOARD_CARD=skipped issue=7 reason=no-gh"
if [ -s "$GH_MOCK_LOG" ]; then fail "no gh call without gh" "$(head -c 400 "$GH_MOCK_LOG")"; else pass "no gh call without gh"; fi
case_end

# The seeded row carries PVTF_stale in its Content Date column; a re-resolve writes PVTF_cd, so a remaining
# PVTF_stale row means the row was not dropped. gone <times> — the first <times> item-adds say the board is gone.
stale_row() {
  mkdir -p "$(dirname "$CACHE")"
  printf 'mockowner/mockrepo\tmockowner\t3\tPVT_a\tPVTF_stale\tPVTSSF_st\tOPT_todo\tOPT_ip\tOPT_done\tPVTF_sid\tsid1\n' >"$CACHE"
}
gone() { export GH_MOCK_ITEMADD_GONE_FILE="$TMP_ROOT/gone" GH_MOCK_ITEMADD_GONE_TIMES="$1"; }
row_kept() { [ -f "$CACHE" ] && grep -q 'PVTF_stale' "$CACHE"; }

case_begin "item-add-on-a-gone-board-re-resolves-once" "bin/github-issues/ensure-board-card.sh"
fresh; stale_row; gone 1
ebc "$GH_REPO" 7
expect_ok added
assert_eq "item-add attempts: $(count '^project item-add')" "item-add attempts: 2"
# Two projectsV2 calls at least: the cache-hit link check, then the --no-cache-read re-resolve.
if [ "$(count 'projectsV2')" -ge 2 ]; then pass "the board was re-resolved after the gone answer"
else fail "the board was re-resolved after the gone answer" "$(head -c 600 "$GH_MOCK_LOG")"; fi
if row_kept; then fail "the gone board's cached row was dropped" "$(cat "$CACHE")"; else pass "the gone board's cached row was dropped"; fi
case_end

case_begin "item-add-gone-twice-fails-after-one-retry" "bin/github-issues/ensure-board-card.sh"
fresh; stale_row; gone 5
ebc "$GH_REPO" 7
assert_eq "rc=$RC last=$LAST" "rc=0 last=BOARD_CARD=failed issue=7 reason=item-add"
assert_eq "item-add attempts: $(count '^project item-add')" "item-add attempts: 2"
if row_kept; then fail "the gone board's cached row was dropped (retry also gone)" "$(cat "$CACHE")"
else pass "the gone board's cached row was dropped (retry also gone)"; fi
case_end

case_begin "item-add-not-gone-or-internal-board-no-re-resolve" "bin/github-issues/ensure-board-card.sh"
fresh; stale_row
export GH_MOCK_FAIL=item-add
ebc "$GH_REPO" 7
assert_eq "plain failure: rc=$RC last=$LAST adds=$(count '^project item-add')" \
  "plain failure: rc=0 last=BOARD_CARD=failed issue=7 reason=item-add adds=1"
# At most the cache-hit link check: a second projectsV2 call would be a re-resolve.
if [ "$(count 'projectsV2')" -le 1 ]; then pass "a non-gone item-add failure does not re-resolve the board"
else fail "a non-gone item-add failure does not re-resolve the board" "$(head -c 600 "$GH_MOCK_LOG")"; fi
if row_kept; then pass "a non-gone item-add failure keeps the cached row"; else fail "a non-gone item-add failure keeps the cached row" "$(cat "$CACHE" 2>&1)"; fi
fresh; stale_row; gone 1
export _ISSUE_CREATE_INTERNAL_OWNER=mockowner _ISSUE_CREATE_INTERNAL_PROJECT_NUM=3 _ISSUE_CREATE_INTERNAL_PROJECT_ID=PVT_a
ebc "$GH_REPO" 7
assert_eq "internal board: rc=$RC last=$LAST adds=$(count '^project item-add') resolves=$(count 'projectsV2')" \
  "internal board: rc=0 last=BOARD_CARD=failed issue=7 reason=item-add adds=1 resolves=0"
if row_kept; then pass "the internal board's gone answer keeps the cached row"; else fail "the internal board's gone answer keeps the cached row" "$(cat "$CACHE" 2>&1)"; fi
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
