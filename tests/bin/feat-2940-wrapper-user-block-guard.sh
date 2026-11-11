#!/usr/bin/env bash
# Tests: bin/lib/gh-user-block-guard.sh
# lang-check: ignore -- the wrapper message pinned here is user-facing Japanese text.
# Tags: TL2, user-block-guard, user-block, gh, guard, wrapper, scope:issue-specific, TL1
# #2940 Step 6: every gh-writing wrapper asks bin/user-block-guard before its write. A `<user>`
# diff stops the wrapper and the gh write is never called; no diff lets the write through.
# TL2: the real wrappers, lib and CLI run against tests/lib/gh-scripted-stub.js as gh.
# TL3 gap (what this test does NOT catch):
# - real GitHub payloads and the live `<user>` blocks of real issues
# - gh's own argv handling of the bodies the wrappers send

set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
GI="$SCRIPT_CHECKOUT_ROOT/bin/github-issues"
GUARD_LIB="$SCRIPT_CHECKOUT_ROOT/bin/lib/gh-user-block-guard.sh"

readonly BASE="$(make_tmp)"
trap 'rm -rf "$BASE"' EXIT
harness_isolate "$BASE/iso"
unset CLAUDE_CODE_SESSION_ID GH_REPO
export CLAUDE_TRANSCRIPT_BASE_DIR="$BASE/transcripts"
mkdir -p "$CLAUDE_TRANSCRIPT_BASE_DIR" "$BASE/cwd" "$BASE/main/bin"

# The outbound scanner's anchor, with empty allow/block lists (as tests/bin/fix-1591-*.sh do).
cp "$SCRIPT_CHECKOUT_ROOT/bin/scan-outbound.sh" "$BASE/main/bin/scan-outbound.sh"
: >"$BASE/main/.private-info-allowlist"
: >"$BASE/main/.private-info-blocklist"
export AGENTS_MAIN_ROOT="$BASE/main"

STUB_OUT="$(node "$(np "$SCRIPT_CHECKOUT_ROOT/tests/lib/gh-scripted-stub.js")" setup "$(np "$BASE/stub")")"
STUB_BIN="${STUB_OUT%%$'\n'*}"
PRELOAD="${STUB_OUT#*$'\n'}"
command -v cygpath >/dev/null 2>&1 && STUB_BIN="$(cygpath -u "$STUB_BIN")"
export PATH="$STUB_BIN:$PATH"
export NODE_OPTIONS="--require \"$PRELOAD\""
export F2940_GH_SPEC="$(np "$BASE/spec.json")"
export F2940_GH_LOG="$(np "$BASE/gh-calls.jsonl")"
if ! [ "$(command -v gh 2>/dev/null)" -ef "$STUB_BIN/gh" ]; then
  echo "FATAL: gh does not resolve to the stub ($(command -v gh 2>/dev/null)); aborting before any real gh call"
  exit 1
fi

R="example-owner/example-repo"
B='<user>keep me</user>'

# js <text> — <text> as a JSON string literal.
js() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '"%s"' "$s"
}
# rule <regex> <json-stdout> — one stub rule; txt <text> makes a plain-text stdout.
rule() { printf '{"match":%s,"stdout":%s}' "$(js "$1")" "$2"; }
txt() { js "$1"; }
# gql <title> <body> — the `gh api graphql` reply for an issue without comments.
gql() {
  printf '{"data":{"repository":{"issue":{"id":"I_kw1","title":%s,"body":%s,"comments":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}' "$(js "$1")" "$(js "$2")"
}
# spec <rule>... — installs the script and clears the call log.
spec() {
  local IFS=,
  printf '{"rules":[%s],"fallback":{"exit":0}}\n' "$*" >"$BASE/spec.json"
  rm -f "$BASE/gh-calls.jsonl"
}
called() { grep -qF "$1" "$BASE/gh-calls.jsonl" 2>/dev/null; }
# run_wrapper <cwd> <cmd...> — sets RC, OUT, ERR.
run_wrapper() {
  local dir="$1"
  shift
  RC=0
  (cd "$dir" && run_with_timeout 60 "$@") >"$BASE/out.txt" 2>"$BASE/err.txt" || RC=$?
  OUT="$(cat "$BASE/out.txt")"
  ERR="$(cat "$BASE/err.txt")"
}
expect_write() {
  if called "$1"; then pass "$2: the gh write ran"; else fail "$2" "no '$1' call (rc=$RC err=$ERR)"; fi
}
expect_no_write() {
  if called "$1"; then fail "$2" "the gh write '$1' ran although a <user> block differs"; else pass "$2: the gh write was not called"; fi
}
expect_guard_fetch() {
  if called '"api","graphql"'; then pass "$1: the guard read the old issue"; else fail "$1" "no GraphQL read of the old issue"; fi
}
lib_present() {
  [ -f "$GUARD_LIB" ] && return 0
  fail "$1" "bin/lib/gh-user-block-guard.sh is not present (expected before write-code)"
  return 1
}

# --- issue-body-append ------------------------------------------------------------
IBA_OLD="intro
$B"
case_begin "issue-body-append-note-with-block-stops" "bin/github-issues/issue-body-append.sh"
spec "$(rule '^issue view' "$(txt "$IBA_OLD")")" "$(rule '^api graphql' "$(gql 'T' "$IBA_OLD")")"
run_wrapper "$BASE/cwd" bash "$GI/issue-body-append.sh" --issue 4242 --note "adds <user>new</user>"
expect_no_write '"issue","edit","4242"' "iba stop"
[ "$RC" -ne 0 ] && pass "iba stop: non-zero exit" || fail "iba stop" "exit 0 although stopped"
case_end

case_begin "issue-body-append-plain-note-passes" "bin/github-issues/issue-body-append.sh"
spec "$(rule '^issue view' "$(txt "$IBA_OLD")")" "$(rule '^api graphql' "$(gql 'T' "$IBA_OLD")")"
run_wrapper "$BASE/cwd" bash "$GI/issue-body-append.sh" --issue 4242 --note "plain revision note"
expect_write '"issue","edit","4242"' "iba pass"
assert_eq "$RC" "0"
lib_present "iba pass guard" && expect_guard_fetch "iba pass"
case_end

# --- parent-body-update -----------------------------------------------------------
parent_spec() {
  spec "$(rule 'parent \{ number \}' "$(txt 77)")" "$(rule 'issues/77 --jq' "$(txt false)")" \
    "$(rule '^issue view 77' "$(txt "$1")")" "$(rule '^api graphql' "$(gql 'Parent' "$1")")"
}
case_begin "parent-body-update-checkbox-inside-block-stops" "bin/github-issues/parent-body-update.sh"
parent_spec "children:
<user>- [ ] #5</user>"
run_wrapper "$BASE/cwd" bash "$GI/parent-body-update.sh" "$R" 5
expect_no_write '"issue","edit","77"' "parent stop"
case_end

case_begin "parent-body-update-checkbox-outside-block-passes" "bin/github-issues/parent-body-update.sh"
parent_spec "- [ ] #5
$B"
run_wrapper "$BASE/cwd" bash "$GI/parent-body-update.sh" "$R" 5
expect_write '"issue","edit","77"' "parent pass"
lib_present "parent pass guard" && expect_guard_fetch "parent pass"
case_end

# --- reopen-with-update -----------------------------------------------------------
# The banner refresh rewrites the old banner region; a block inside it is a `<user>` diff.
reopen_spec() {
  spec "$(rule '^repo view' "$(txt "$R")")" "$(rule 'issues/9/comments --jq' "$(txt '[]')")" \
    "$(rule '^issue view 9' "$(txt "$1")")" "$(rule '^api graphql' "$(gql 'Reopened' "$1")")"
}
case_begin "reopen-with-update-banner-with-block-stops" "bin/github-issues/reopen-with-update.sh"
reopen_spec "<!-- BEGIN reopen-banner -->
**Reopened** (count: 1) $B
<!-- END reopen-banner -->

rest"
run_wrapper "$BASE/cwd" bash "$GI/reopen-with-update.sh" 9
expect_no_write '"--body-file"' "reopen stop"
expect_no_write '"issue","comment"' "reopen stop comment"
assert_eq "$RC" "1"
case_end

case_begin "reopen-with-update-block-kept-passes" "bin/github-issues/reopen-with-update.sh"
reopen_spec "intro
$B"
run_wrapper "$BASE/cwd" bash "$GI/reopen-with-update.sh" 9
expect_write '"--body-file"' "reopen pass"
expect_write '"issue","comment","9"' "reopen pass comment"
assert_eq "$RC" "0"
lib_present "reopen pass guard" && expect_guard_fetch "reopen pass"
case_end

# The comment paths are WARN+continue: a stopped comment write leaves the body edit and exit 0.
REOPEN_NOTE_BLOCK="why <user>new</user>"
case_begin "reopen-with-update-comment-create-with-block-stops" "bin/github-issues/reopen-with-update.sh"
reopen_spec "intro only"
run_wrapper "$BASE/cwd" bash "$GI/reopen-with-update.sh" 9 "$REOPEN_NOTE_BLOCK"
expect_no_write '"issue","comment"' "reopen comment-create stop"
expect_write '"--body-file"' "reopen comment-create stop body"
expect_write '"--add-label"' "reopen comment-create stop label"
assert_eq "$RC" "0"
case_end

REOPEN_LOG="<!-- reopen-log --> log $B"
reopen_patch_spec() {
  spec "$(rule '^repo view' "$(txt "$R")")" \
    "$(rule 'issues/9/comments --jq' "$(txt "[{\"id\":501,\"body\":\"$REOPEN_LOG\"}]")")" \
    "$(rule '^issue view 9' "$(txt 'intro only')")" "$(rule '^api graphql' "$(gql 'Reopened' 'intro only')")" \
    "$(rule 'issues/comments/501 --jq \.body$' "$(txt "$REOPEN_LOG")")" \
    "$(rule '^api -X PATCH' "$(txt '{}')")" \
    "$(rule 'issues/comments/501' "{\"id\":501,\"body\":$(js "$REOPEN_LOG")}")"
}
case_begin "reopen-with-update-comment-patch-with-block-stops" "bin/github-issues/reopen-with-update.sh"
reopen_patch_spec
run_wrapper "$BASE/cwd" bash "$GI/reopen-with-update.sh" 9 "$REOPEN_NOTE_BLOCK"
expect_no_write '"PATCH"' "reopen comment-patch stop"
expect_write '"--body-file"' "reopen comment-patch stop body"
assert_eq "$RC" "0"
case_end

case_begin "reopen-with-update-comment-patch-block-kept-passes" "bin/github-issues/reopen-with-update.sh"
reopen_patch_spec
run_wrapper "$BASE/cwd" bash "$GI/reopen-with-update.sh" 9
expect_write '"PATCH"' "reopen comment-patch pass"
assert_eq "$RC" "0"
if lib_present "reopen comment-patch guard"; then
  n="$(grep -cF 'issues/comments/501' "$BASE/gh-calls.jsonl" 2>/dev/null || true)"
  [ "${n:-0}" -ge 3 ] && pass "reopen comment-patch pass: the guard read comment 501" || fail "reopen comment-patch guard" "only ${n:-0} calls on comment 501 (wrapper read + PATCH, no guard read)"
fi
case_end

# --- migrate-model-labels ---------------------------------------------------------
MREPO="$BASE/mrepo"
harness_git_init "$MREPO"
git -C "$MREPO" remote add origin "https://github.com/$R.git"
mkdir -p "$MREPO/.github"
: >"$MREPO/.github/labels.yml"
migrate_spec() {
  spec "$(rule '^issue view 1488' "$(txt '[ds4] Fix the thing')")" \
    "$(rule '^api graphql' "$(gql '[ds4] Fix the thing' "$1")")"
}
case_begin "migrate-model-labels-title-on-block-issue-skips" "bin/github-issues/migrate-model-labels.sh"
migrate_spec "body $B"
run_wrapper "$MREPO" bash "$GI/migrate-model-labels.sh" --repo "$R"
expect_no_write '"issue","edit","1488"' "migrate stop"
case "$OUT" in *SKIP*"1488"*|*"1488"*SKIP*) pass "migrate stop: SKIP is shown" ;; *) fail "migrate stop" "no SKIP for #1488 in: $OUT" ;; esac
case "$OUT" in *"Migration complete."*) pass "migrate stop: the run continues" ;; *) fail "migrate stop" "the run did not complete (rc=$RC)" ;; esac
case_end

case_begin "migrate-model-labels-title-without-block-passes" "bin/github-issues/migrate-model-labels.sh"
migrate_spec "plain body"
run_wrapper "$MREPO" bash "$GI/migrate-model-labels.sh" --repo "$R"
expect_write '"issue","edit","1488"' "migrate pass"
lib_present "migrate pass guard" && expect_guard_fetch "migrate pass"
case_end

# --- issue-create -----------------------------------------------------------------
create_body() {
  printf '## Background\n%s\n\n## Changes\nchange the thing\n' "$1" >"$BASE/create-body.md"
}
CREATE_SPEC_URL="$(rule '^issue create' "$(txt "https://github.com/$R/issues/555")")"
case_begin "issue-create-body-with-block-stops" "bin/github-issues/issue-create.sh"
spec "$CREATE_SPEC_URL"
create_body "why $B"
run_wrapper "$BASE/cwd" bash "$GI/issue-create.sh" --title "A task" --body-file "$(np "$BASE/create-body.md")" --origin-session sid2940
expect_no_write '"issue","create"' "create stop"
[ "$RC" -ne 0 ] && pass "create stop: non-zero exit" || fail "create stop" "exit 0 although stopped"
case_end

case_begin "issue-create-plain-body-passes" "bin/github-issues/issue-create.sh"
spec "$CREATE_SPEC_URL"
create_body "why it matters"
run_wrapper "$BASE/cwd" bash "$GI/issue-create.sh" --title "A task" --body-file "$(np "$BASE/create-body.md")" --origin-session sid2940
expect_write '"issue","create"' "create pass"
case_end

# --- clarify-commit-scope (Path C) ------------------------------------------------
SID="sid-test-2940"
write_intent() {
  printf '# Tracking issue — %s\n\n**Title:** Guard the user block\n\n## Issues\n- closes #2940\n\n## Background / Motivation\n%s\n\n## Scope\nwrap the writes.\n' \
    "$SID" "$1" >"$WORKFLOW_PLANS_DIR/${SID}-intent.md"
}
SIDECAR="$WORKFLOW_STATE_DIR/${SID}.control/intent-scan-block.txt"
case_begin "clarify-commit-scope-block-in-intent-stops" "bin/github-issues/clarify-commit-scope.sh"
spec "$CREATE_SPEC_URL"
rm -f "$SIDECAR"
write_intent "motivation $B"
run_wrapper "$BASE/cwd" bash "$GI/clarify-commit-scope.sh" --session-id "$SID" --plans-dir "$WORKFLOW_PLANS_DIR" --issues ""
expect_no_write '"issue","create"' "clarify stop"
assert_eq "$RC" "2"
[ -s "$SIDECAR" ] && pass "clarify stop: the reason is in the sidecar" || fail "clarify stop" "sidecar missing or empty: $SIDECAR"
case_end

case_begin "clarify-commit-scope-plain-intent-passes" "bin/github-issues/clarify-commit-scope.sh"
spec "$CREATE_SPEC_URL"
rm -f "$SIDECAR"
write_intent "plain motivation"
run_wrapper "$BASE/cwd" bash "$GI/clarify-commit-scope.sh" --session-id "$SID" --plans-dir "$WORKFLOW_PLANS_DIR" --issues ""
expect_write '"issue","create"' "clarify pass"
assert_eq "$RC" "0"
case_end

# --- scan-offensive/scan-repo.sh --apply -------------------------------------------
SCAN="$SCRIPT_CHECKOUT_ROOT/skills/scan-offensive/scripts/scan-repo.sh"
sha_of() { printf '%s' "$1" | sha256sum | cut -c1-64; }
# scan_case <kind issue-body|issue-comment> <live body>
scan_case() {
  local src
  if [ "$1" = issue-body ]; then
    src="{\"kind\":\"issue-body\",\"repo\":\"$R\",\"issue\":7}"
    spec "$(rule "issues/7 --jq" "$(txt "$2")")" "$(rule '^api graphql' "$(gql 'Scanned' "$2")")"
  else
    src="{\"kind\":\"issue-comment\",\"repo\":\"$R\",\"issue\":7,\"comment_id\":77}"
    spec "$(rule 'issues/comments/77 --jq \.body // ""' "$(txt "$2")")" \
      "$(rule 'issues/comments/77' "{\"id\":77,\"body\":$(js "$2")}")"
  fi
  printf '{"type":"preamble"}\n{"id":"x1","content_sha256":"%s","source":%s}\n' "$(sha_of "$2")" "$src" >"$BASE/manifest.jsonl"
  run_wrapper "$BASE/cwd" bash "$SCAN" "$R" --apply --include-private --manifest-path "$(np "$BASE/manifest.jsonl")" --confirm-ids x1
}
have_jq() {
  command -v jq >/dev/null 2>&1 && return 0
  skip "scan-repo.sh needs jq, which is not installed"
  return 1
}

case_begin "scan-repo-redact-body-with-block-stops" "skills/scan-offensive/scripts/scan-repo.sh"
if have_jq; then
  scan_case issue-body "leak $B"
  expect_no_write '"issue","edit","7"' "scan body stop"
  assert_eq "$RC" "0"
fi
case_end

case_begin "scan-repo-redact-body-without-block-passes" "skills/scan-offensive/scripts/scan-repo.sh"
if have_jq; then
  scan_case issue-body "leak only"
  expect_write '"issue","edit","7"' "scan body pass"
  lib_present "scan body pass guard" && expect_guard_fetch "scan body pass"
fi
case_end

case_begin "scan-repo-redact-comment-with-block-stops" "skills/scan-offensive/scripts/scan-repo.sh"
if have_jq; then
  scan_case issue-comment "leak $B"
  expect_no_write '"PATCH"' "scan comment stop"
fi
case_end

# Detail Step 6 / Files: a stop prints the "redact inside <user> by hand" guidance for the id; no "redacted:" line.
case_begin "scan-repo-stop-prints-manual-guidance" "skills/scan-offensive/scripts/scan-repo.sh"
if have_jq; then
  for kind in issue-body issue-comment; do
    scan_case "$kind" "leak $B"
    case "$OUT$ERR" in *"redacted: x1"*) fail "scan guidance $kind" "x1 reported as redacted although stopped" ;; *) pass "scan guidance $kind: x1 not reported as redacted" ;; esac
    case "$OUT$ERR" in *x1*redaction*|*redaction*x1*) pass "scan guidance $kind: manual redaction guidance names x1" ;; *) fail "scan guidance $kind" "no manual redaction guidance for x1 in: $OUT $ERR" ;; esac
  done
fi
case_end

case_begin "scan-repo-redact-comment-without-block-passes" "skills/scan-offensive/scripts/scan-repo.sh"
if have_jq; then
  scan_case issue-comment "leak only"
  expect_write '"PATCH"' "scan comment pass"
fi
case_end

# --- gh_user_block_guard itself (Step 5, TL1) --------------------------------------
# rc 0 -> return 0; rc 1/2/3 -> return 1 with "[<label>] <CLI reason> ..." set and on stderr, never
# exit. The lib runs from a fake checkout whose bin/user-block-guard is a scripted fake (last: it is sourced here).
FAKE_ROOT="$BASE/fake"
mkdir -p "$FAKE_ROOT/bin/lib"
FAKE_LIB="$FAKE_ROOT/bin/lib/gh-user-block-guard.sh"
[ -f "$GUARD_LIB" ] && cp "$GUARD_LIB" "$FAKE_LIB"
# The fake CLI records its argv one per line and answers with the scripted rc.
cat >"$FAKE_ROOT/bin/user-block-guard" <<'FAKE'
const fs = require("fs");
if (process.env.F2940_FAKE_LOG) fs.writeFileSync(process.env.F2940_FAKE_LOG, process.argv.slice(2).join("\n") + "\n");
process.stdout.write("user-block-guard: scripted reason\n");
process.exit(Number(process.env.F2940_FAKE_RC || 0));
FAKE
export F2940_FAKE_LOG="$BASE/fake-argv.txt"

# call_guard <rc> <label> <args...> — sources the lib here so the message variable is observable.
call_guard() {
  local rc="$1"
  shift
  export F2940_FAKE_RC="$rc"
  GH_USER_BLOCK_GUARD_MESSAGE=""
  rm -f "$F2940_FAKE_LOG" "$BASE/guard-err.txt"
  # shellcheck disable=SC1090
  source "$FAKE_LIB"
  if gh_user_block_guard "$@" 2>"$BASE/guard-err.txt"; then GUARD_RC=0; else GUARD_RC=$?; fi
  GUARD_ERR="$(cat "$BASE/guard-err.txt" 2>/dev/null || true)"
}
fake_lib_present() {
  [ -f "$FAKE_LIB" ] && return 0
  fail "$1" "bin/lib/gh-user-block-guard.sh is not present (expected before write-code)"
  return 1
}

case_begin "rc0-returns-0-without-message" "bin/lib/gh-user-block-guard.sh"
if fake_lib_present "rc0"; then
  call_guard 0 "issue-body-append:#5" --op edit --issue 5
  assert_eq "$GUARD_RC" "0"
  assert_eq "${GH_USER_BLOCK_GUARD_MESSAGE:-}" ""
fi
case_end

case_begin "rc1-returns-1-with-labelled-message" "bin/lib/gh-user-block-guard.sh"
if fake_lib_present "rc1"; then
  call_guard 1 "issue-body-append:#5" --op edit --issue 5
  assert_eq "$GUARD_RC" "1"
  case "${GH_USER_BLOCK_GUARD_MESSAGE:-}" in
    "[issue-body-append:#5] "*"scripted reason"*) pass "message names the label and the CLI reason" ;;
    *) fail "rc1 message" "got '${GH_USER_BLOCK_GUARD_MESSAGE:-}'" ;;
  esac
  case "$GUARD_ERR" in
    *"[issue-body-append:#5]"*"scripted reason"*) pass "the message is printed on stderr" ;;
    *) fail "rc1 stderr" "got '$GUARD_ERR'" ;;
  esac
fi
case_end

case_begin "rc2-ask-returns-1" "bin/lib/gh-user-block-guard.sh"
if fake_lib_present "rc2"; then
  call_guard 2 "reopen:#9" --op edit --issue 9
  assert_eq "$GUARD_RC" "1"
  [ -n "${GH_USER_BLOCK_GUARD_MESSAGE:-}" ] && pass "ask sets the message" || fail "rc2 message" "empty"
fi
case_end

case_begin "rc3-usage-returns-1" "bin/lib/gh-user-block-guard.sh"
if fake_lib_present "rc3"; then
  call_guard 3 "create" --op create
  assert_eq "$GUARD_RC" "1"
  [ -n "${GH_USER_BLOCK_GUARD_MESSAGE:-}" ] && pass "usage error sets the message" || fail "rc3 message" "empty"
fi
case_end

# Detail Step 5: every stop message ends with the "the wrapper path cannot be approved; the user edits directly" suffix.
case_begin "stop-message-carries-no-approval-suffix" "bin/lib/gh-user-block-guard.sh"
if fake_lib_present "suffix"; then
  for rc in 1 2 3; do
    call_guard "$rc" "lbl" --op edit --issue 5
    case "${GH_USER_BLOCK_GUARD_MESSAGE:-}" in
      *"wrapper 経路は承認できない"*"ユーザーが直接編集する"*) pass "rc$rc: the message carries the no-approval suffix" ;;
      *) fail "rc$rc suffix" "got '${GH_USER_BLOCK_GUARD_MESSAGE:-}'" ;;
    esac
    case "$GUARD_ERR" in *"wrapper 経路は承認できない"*) pass "rc$rc: the suffix is on stderr" ;; *) fail "rc$rc suffix stderr" "got '$GUARD_ERR'" ;; esac
  done
fi
case_end

case_begin "cli-args-forwarded-verbatim" "bin/lib/gh-user-block-guard.sh"
if fake_lib_present "argv"; then
  call_guard 0 "lbl" --op edit --issue 12 --repo example-owner/example-repo --new-title "a title with spaces"
  assert_eq "$(cat "$F2940_FAKE_LOG" 2>/dev/null)" "$(printf '%s\n' --op edit --issue 12 --repo example-owner/example-repo --new-title "a title with spaces")"
fi
case_end

case_begin "never-exits-the-caller" "bin/lib/gh-user-block-guard.sh"
if fake_lib_present "no-exit"; then
  out="$(F2940_FAKE_RC=1 bash -c '. "$1"; gh_user_block_guard lbl --op edit --issue 1 2>/dev/null; echo "after:$?"' _ "$FAKE_LIB")"
  assert_eq "$out" "after:1"
fi
case_end

case_begin "missing-cli-fails-closed" "bin/lib/gh-user-block-guard.sh"
if fake_lib_present "missing-cli"; then
  mkdir -p "$BASE/bare/bin/lib"
  cp "$FAKE_LIB" "$BASE/bare/bin/lib/gh-user-block-guard.sh"
  out="$(bash -c '. "$1"; if gh_user_block_guard lbl --op edit --issue 1 2>/dev/null; then echo rc0; else echo rc1; fi' _ "$BASE/bare/bin/lib/gh-user-block-guard.sh")"
  assert_eq "$out" "rc1"
fi
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
