#!/usr/bin/env bash
# session-close-build-env-argv.sh — #2527 F3 (CWE-78): the branch name reaches git / gh as argv, never a shell.
# Tests: bin/session-close-build-env.js
# Tags: scope:issue-specific, workflow, release-phase, session-close, security, cwe-78
# TL2: the CLI runs in a fixture repo whose branch carries $(...) / backtick payloads, against a fake gh.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

# TL3 gap (not caught here): a real gh binary and a POSIX /bin/sh other than the one on this host.
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh
# category: skill-orchestration.
rp_setup
trap rp_teardown EXIT
# A node-copy gh (reachable with and without a shell, Windows included) logs argv as node parsed it;
# the bash fake would be re-globbed by the MSYS runtime ({IFS} -> IFS) and blur the byte check.
# shellcheck source=../../lib/cli-stub.sh
source "$_HELPERS_SCRIPT_CHECKOUT_ROOT/tests/lib/cli-stub.sh"
cli_stub_make "$RP_TMP/stub" gh || fail "setup" "cli_stub_make gh"
PATH="$CLI_STUB_DIR:$(rp_path_without gh)"
CLI_STUB_LOG="$(np "$RP_TMP/gh-argv.log")"
export PATH CLI_STUB_LOG CLI_STUB_RC=0 NODE_OPTIONS="--require \"$CLI_STUB_PRELOAD\""
# pr_list_json <state> <headRefOid> — one-PR `gh pr list` answer.
pr_list_json() {
  printf '[{"number":42,"title":"Fixture PR 2527","url":"https://github.com/example/repo/pull/42","state":"%s","headRefOid":"%s"}]' "$1" "$2"
}
BUILD="$RP_SCRIPT_CHECKOUT_ROOT/bin/session-close-build-env.js"
BUILD_SRC="$_HELPERS_SCRIPT_CHECKOUT_ROOT/bin/session-close-build-env.js"

mk_state '{"sid":"argv-d","path":"direct","upto":"pre_final_report_gate"}'
mk_state '{"sid":"argv-pr","path":"pull_request","entered":true,"upto":"pre_final_report_gate"}'

# build_row <args...> — "<exit>|<PR_NUMBER>|<PR_STATE>|<BRANCH>" from the written env file.
build_row() {
  local out code envf
  out="$(run_with_timeout 60 node "$BUILD" "$@" 2>&1)"; code=$?
  envf="$(field "$out" ENV_FILE)"
  if [[ "$code" != "0" || ! -f "$envf" ]]; then printf '%s|<no env: %s>' "$code" "$out"; return; fi
  node -e 'const e = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    console.log([process.argv[2], e.PR_NUMBER, e.PR_STATE, e.BRANCH].join("|"));' "$envf" "$code"
}

# no_marker <label> <marker> — the payload's file exists nowhere the shell could have run.
no_marker() {
  if [[ -e "$RP_REPO/$2" || -e "$RP_TMP/$2" || -e "$PWD/$2" ]]; then
    fail "$1" "shell executed the branch payload: $2 was created"
  else
    pass "$1"
  fi
}

# payload_case <label> <branch> <marker> <mode-flag...> — checkout <branch>, run build-env, assert.
payload_case() {
  local label="$1" br="$2" marker="$3" row
  shift 3
  check "$label: git accepts the refname" "$(git check-ref-format --branch "$br" 2>&1)" "$br"
  git -C "$RP_REPO" checkout -q -B "$br" || fail "$label" "checkout failed"
  rm -f "$RP_REPO/$marker" "$RP_TMP/$marker"
  # headRefOid = this HEAD: --direct accepts only the PR built from it.
  CLI_STUB_OUT="$(pr_list_json MERGED "$(git -C "$RP_REPO" rev-parse HEAD)")"
  export CLI_STUB_OUT
  : > "$CLI_STUB_LOG"
  row="$(build_row "$@")"
  no_marker "$label: payload not executed" "$marker"
  check_contains "$label: gh --head got the branch byte-for-byte" "$(cat "$CLI_STUB_LOG")" "gh pr list --head $br --state all"
  check "$label: env JSON BRANCH is the literal branch" "$row" "0|42|MERGED|$br"
}

# shellcheck disable=SC2016
BR_DOLLAR='feature/x$(touch${IFS}PWNED)'
# shellcheck disable=SC2016
BR_TICK='feature/x`touch${IFS}PWNED2`'

case_begin "B1: \$(...) branch payload, --direct" "bin/session-close-build-env.js"
payload_case "B1" "$BR_DOLLAR" PWNED --direct --session argv-d
case_end

case_begin "B2: backtick branch payload, --direct" "bin/session-close-build-env.js"
payload_case "B2" "$BR_TICK" PWNED2 --direct --session argv-d
case_end

case_begin "B3: \$(...) branch payload, default mode (PR required)" "bin/session-close-build-env.js"
payload_case "B3" "$BR_DOLLAR" PWNED --session argv-pr
case_end

case_begin "B3b: --direct, no PR found -> BRANCH still literal" "bin/session-close-build-env.js"
git -C "$RP_REPO" checkout -q -B "$BR_DOLLAR" || fail "B3b" "checkout failed"
export CLI_STUB_OUT='[]'
check "B3b: no-PR env keeps the literal branch" "$(build_row --direct --session argv-d)" "0|||$BR_DOLLAR"
no_marker "B3b: payload not executed" PWNED
case_end

case_begin "B4: static guard — no shell-spawning child_process call" "bin/session-close-build-env.js"
if grep -q 'execSync(' "$BUILD_SRC"; then
  fail "B4: no execSync(" "$(grep -n 'execSync(' "$BUILD_SRC")"
else
  pass "B4: no execSync("
fi
if grep -Eq 'shell:[[:space:]]*true' "$BUILD_SRC"; then
  fail "B4: no shell: true" "$(grep -nE 'shell:[[:space:]]*true' "$BUILD_SRC")"
else
  pass "B4: no shell: true"
fi
case_end

# C5: a reused branch name lists unrelated PRs; only a PR whose headRefOid is this HEAD belongs here.
C5_BR=feature/2527-c5
git -C "$RP_REPO" checkout -q -B "$C5_BR" || fail "C5 setup" "checkout failed"
C5_HEAD="$(git -C "$RP_REPO" rev-parse HEAD)"
C5_OTHER=1111111111111111111111111111111111111111
# pr <number> <state> <headRefOid> — one `gh pr list` row.
pr() { printf '{"number":%s,"title":"PR %s","url":"https://github.com/example/repo/pull/%s","state":"%s","headRefOid":"%s"}' "$1" "$1" "$1" "$2" "$3"; }

case_begin "C5a: gh pr list argv carries --limit 20 and headRefOid" "bin/session-close-build-env.js"
export CLI_STUB_OUT="[$(pr 7 MERGED "$C5_HEAD")]"
: > "$CLI_STUB_LOG"
build_row --direct --session argv-d >/dev/null
check_contains "argv: --state all --limit 20" "$(cat "$CLI_STUB_LOG")" "gh pr list --head $C5_BR --state all --limit 20 --json"
check_contains "argv: json fields include headRefOid" "$(cat "$CLI_STUB_LOG")" "--json number,title,url,state,headRefOid"
case_end

case_begin "C5b: --direct, no PR head matches HEAD -> no PR fields" "bin/session-close-build-env.js"
export CLI_STUB_OUT="[$(pr 9 MERGED "$C5_OTHER"),$(pr 8 OPEN "$C5_OTHER")]"
check "C5b: unrelated MERGED/OPEN PRs ignored" "$(build_row --direct --session argv-d)" "0|||$C5_BR"
case_end

case_begin "C5c: --direct, head match -> that PR, not the first listed" "bin/session-close-build-env.js"
export CLI_STUB_OUT="[$(pr 9 OPEN "$C5_OTHER"),$(pr 7 MERGED "$C5_HEAD")]"
check "C5c: matching PR fields set" "$(build_row --direct --session argv-d)" "0|7|MERGED|$C5_BR"
case_end

case_begin "C5d: default mode, no head match -> newest OPEN/MERGED, CLOSED skipped" "bin/session-close-build-env.js"
export CLI_STUB_OUT="[$(pr 9 CLOSED "$C5_OTHER"),$(pr 8 MERGED "$C5_OTHER"),$(pr 7 OPEN "$C5_OTHER")]"
check "C5d: first OPEN/MERGED in list order" "$(build_row --session argv-pr)" "0|8|MERGED|$C5_BR"
case_end

case_begin "C5e: default mode, head match preferred over an earlier OPEN" "bin/session-close-build-env.js"
export CLI_STUB_OUT="[$(pr 9 OPEN "$C5_OTHER"),$(pr 5 MERGED "$C5_HEAD")]"
check "C5e: head-matching PR wins" "$(build_row --session argv-pr)" "0|5|MERGED|$C5_BR"
case_end

case_begin "C5f: default mode, only CLOSED unrelated PRs -> fails (PR required)" "bin/session-close-build-env.js"
export CLI_STUB_OUT="[$(pr 9 CLOSED "$C5_OTHER")]"
row="$(build_row --session argv-pr)"
check_contains "C5f: exit 1, no env written" "$row" "1|<no env"
check_contains "C5f: names the unresolved PR" "$row" "cannot resolve PR"
case_end

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit "$FAIL"
