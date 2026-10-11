#!/usr/bin/env bash
# session-close-route.sh — #2527 3-11: /session-close routes by the recorded delivery path.
# Tests: bin/session-close-detect-route.js, bin/session-close-build-env.js
# Tags: scope:issue-specific, workflow, release-phase, session-close
# TL2: both CLIs run against v5 fixtures and a fake gh (NONE / fail / MERGED).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

# TL3 gap (not caught here): the SC-1 branch the model takes after reading ROUTE.
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh
# category: skill-orchestration.
rp_setup
trap rp_teardown EXIT
# build-env spawns gh shell-less (F3); on Windows that resolves only gh.exe, so bridge it to gh.cmd.
# shellcheck source=../../lib/cli-stub.sh
source "$_HELPERS_SCRIPT_CHECKOUT_ROOT/tests/lib/cli-stub.sh"
cli_stub_bridge_cmd "$RP_TMP/bin" gh || fail "setup" "cli_stub_bridge_cmd gh"
DETECT="$RP_SCRIPT_CHECKOUT_ROOT/bin/session-close-detect-route.js"
BUILD="$RP_SCRIPT_CHECKOUT_ROOT/bin/session-close-build-env.js"

route() {
  [ -f "$DETECT" ] || { printf 'MISSING:bin/session-close-detect-route.js'; return; }
  run_with_timeout 60 node "$DETECT" --session "$1" 2>&1
}
# build <args...> — "<exit>|<PR_NUMBER>|<PR_TITLE>|<PR_STATE>|<BRANCH>" from the written env file.
build() {
  local out code envf
  out="$(run_with_timeout 60 node "$BUILD" "$@" 2>&1)"; code=$?
  envf="$(field "$out" ENV_FILE)"
  if [ "$code" != "0" ] || [ ! -f "$envf" ]; then printf '%s|<no env>' "$code"; return; fi
  node -e 'const e = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    console.log([process.argv[2], e.PR_NUMBER, e.PR_TITLE, e.PR_STATE, e.BRANCH].join("|"));' "$envf" "$code"
}

case_begin "detect-route follows the recorded value" "bin/session-close-detect-route.js"
mk_state '{"sid":"sc-meta","dtype":"wf-meta","path":"pull_request","upto":"pre_final_report_gate"}'
mk_state '{"sid":"sc-pr","path":"pull_request","entered":true,"upto":"pre_final_report_gate"}'
mk_state '{"sid":"sc-d","path":"direct","upto":"pre_final_report_gate"}'
export ENFORCE_WORKTREE=on
check "wf-meta" "$(route sc-meta)" "ROUTE=wf-meta"
check "recorded pull_request (live on)" "$(route sc-pr)" "ROUTE=pull_request"
check "recorded direct beats live on" "$(route sc-d)" "ROUTE=direct"
export ENFORCE_WORKTREE=off
check "recorded pull_request beats live off" "$(route sc-pr)" "ROUTE=pull_request"
export ENFORCE_WORKTREE=on
case_end

case_begin "build-env --direct: no PR found -> exit 0, empty PR fields, BRANCH filled" "bin/session-close-build-env.js"
export RP_GH_MODE=NONE
check "gh returns []" "$(build --direct --session sc-d)" "0||||feature/2527-rp"
case_end

case_begin "build-env --direct: gh failure -> exit 0, empty PR fields, BRANCH filled" "bin/session-close-build-env.js"
export RP_GH_MODE=fail
check "gh fails" "$(build --direct --session sc-d)" "0||||feature/2527-rp"
case_end

case_begin "build-env --direct: PR found -> PR fields filled" "bin/session-close-build-env.js"
export RP_GH_MODE=MERGED RP_GH_HEAD="$(git -C "$RP_REPO" rev-parse HEAD)"
: > "$RP_GH_LOG"
check "old-off session that used a PR" "$(build --direct --session sc-d)" "0|42|Fixture PR 2527|MERGED|feature/2527-rp"
check_contains "queried by branch" "$(cat "$RP_GH_LOG")" "pr list --head feature/2527-rp"
export RP_GH_HEAD=0000000000000000000000000000000000000000
check "PR head is not this HEAD -> no PR, BRANCH filled" "$(build --direct --session sc-d)" "0||||feature/2527-rp"
unset RP_GH_HEAD
case_end

case_begin "build-env default (no flag) still requires a PR" "bin/session-close-build-env.js"
export RP_GH_MODE=NONE
check "no PR -> exit 1" "$(build --session sc-pr)" "1|<no env>"
export RP_GH_MODE=MERGED
check "PR found -> filled" "$(build --session sc-pr)" "0|42|Fixture PR 2527|MERGED|feature/2527-rp"
case_end

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit "$FAIL"
