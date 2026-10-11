#!/usr/bin/env bash
# release-evidence.sh — #2527 3-3: push_branch / deliver completion evidence and when it is queried.
# Tests: hooks/workflow-state/evidence-resolver/release-evidence.js, hooks/workflow-gate/gh-detect.js, hooks/lib/forge/github.js
# Tags: scope:issue-specific, workflow, release-phase, evidence
# TL2: unit calls with a fake gh (OPEN/MERGED/CLOSED/NONE/fail) + git dirty/clean/ahead fixtures;
# query placement is observed through the fake gh argv log.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

# TL3 gap (not caught here): real gh auth / rate-limit behaviour against GitHub.
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh
# category: hook-registration.
RP_TMP="$(make_tmp)"
readonly RP_TMP
trap rp_teardown EXIT
harness_isolate "$RP_TMP"
rp_setup

# rp_js <body> — node with G (gh-detect), E (evidence-resolver), R (repo path) in scope.
rp_js() {
  RP_REPO_M="$RP_REPO_M" run_with_timeout 30 node -e '
    const A = process.env.RP_SCRIPT_CHECKOUT_ROOT, R = process.env.RP_REPO_M;
    const G = require(A + "/hooks/workflow-gate/gh-detect.js");
    const E = require(A + "/hooks/workflow-state/evidence-resolver.js");
    try { console.log(String(eval(process.argv[1]))); } catch (e) { console.log("THROW:" + e.message); }
  ' "$1" 2>&1
}
pr_state() { RP_GH_MODE="$1" rp_js 'typeof G.prStateForBranch === "function" ? G.prStateForBranch(R) : "NO_EXPORT"'; }
evid() { RP_GH_MODE="$2" rp_js "E.hasCompletionEvidence(\"$1\", \"$3\", { repoDir: R })"; }

case_begin "prStateForBranch maps the forge answer" "hooks/lib/forge/github.js"
check "OPEN" "$(pr_state OPEN)" "OPEN"
check "MERGED" "$(pr_state MERGED)" "MERGED"
check "CLOSED" "$(pr_state CLOSED)" "CLOSED"
check "no PR -> NONE" "$(pr_state NONE)" "NONE"
check "gh failure -> UNKNOWN" "$(pr_state fail)" "UNKNOWN"
case_end

case_begin "hasOpenPrForBranch keeps its fail-open contract" "hooks/workflow-gate/gh-detect.js"
check "OPEN -> true" "$(RP_GH_MODE=OPEN rp_js 'G.hasOpenPrForBranch(R)')" "true"
check "MERGED -> true" "$(RP_GH_MODE=MERGED rp_js 'G.hasOpenPrForBranch(R)')" "true"
check "NONE -> false" "$(RP_GH_MODE=NONE rp_js 'G.hasOpenPrForBranch(R)')" "false"
check "gh failure (UNKNOWN) -> true" "$(RP_GH_MODE=fail rp_js 'G.hasOpenPrForBranch(R)')" "true"
case_end

case_begin "push_branch evidence (pull_request): OPEN or MERGED" "hooks/workflow-state/evidence-resolver/release-evidence.js"
mk_state '{"sid":"ev-pr","path":"pull_request","entered":true,"upto":"push_branch","steps":"push_branch=pending"}'
check "OPEN -> evidence" "$(evid push_branch OPEN ev-pr)" "true"
check "MERGED -> evidence" "$(evid push_branch MERGED ev-pr)" "true"
check "NONE -> no evidence" "$(evid push_branch NONE ev-pr)" "false"
check "CLOSED -> no evidence" "$(evid push_branch CLOSED ev-pr)" "false"
check "gh failure -> no evidence" "$(evid push_branch fail ev-pr)" "false"
case_end

case_begin "deliver evidence (pull_request): MERGED only" "hooks/workflow-state/evidence-resolver/release-evidence.js"
check "MERGED -> evidence" "$(evid deliver MERGED ev-pr)" "true"
check "OPEN -> no evidence" "$(evid deliver OPEN ev-pr)" "false"
check "gh failure -> no evidence" "$(evid deliver fail ev-pr)" "false"
case_end

case_begin "deliver evidence (direct, on main): clean tree and not ahead of origin/default" "hooks/workflow-state/evidence-resolver/release-evidence.js"
export ENFORCE_WORKTREE=off
git -C "$RP_REPO" checkout -q main
mk_state '{"sid":"ev-d","path":"direct","branch":"main","upto":"deliver","steps":"deliver=pending"}'
check "clean + not ahead -> evidence" "$(evid deliver NONE ev-d)" "true"
printf 'dirty\n' > "$RP_REPO/dirty.txt"
check "dirty (untracked) -> no evidence" "$(evid deliver NONE ev-d)" "false"
rm -f "$RP_REPO/dirty.txt"
rp_ahead
check "unpushed commit on main (ahead of origin/main) -> no evidence" "$(evid deliver NONE ev-d)" "false"
git -C "$RP_REPO" update-ref refs/remotes/origin/main HEAD
check "pushed (origin/main caught up) -> evidence" "$(evid deliver NONE ev-d)" "true"
case_end

case_begin "deliver evidence (direct) is bound to main: a feature branch at origin/main is rejected" "hooks/workflow-state/evidence-resolver/release-evidence.js"
git -C "$RP_REPO" checkout -q -b feature/2527-direct-ev main
check "sanity: feature HEAD equals origin/main" "$(git -C "$RP_REPO" rev-parse HEAD)" "$(git -C "$RP_REPO" rev-parse origin/main)"
check "sanity: tree is clean" "$(git -C "$RP_REPO" status --porcelain)" ""
check "clean, not ahead, but not on main -> no evidence" "$(evid deliver NONE ev-d)" "false"
git -C "$RP_REPO" checkout -q main
case_end

case_begin "deliver evidence (direct) rejects main diverged from its pushed HEAD" "hooks/workflow-state/evidence-resolver/release-evidence.js"
remote_tip="$(git -C "$RP_REPO" commit-tree -p HEAD -m "remote-only change" "HEAD^{tree}")"
git -C "$RP_REPO" update-ref refs/remotes/origin/main "$remote_tip"
rp_ahead
check "sanity: HEAD differs from origin/main" "$(git -C "$RP_REPO" rev-list --count origin/main...HEAD)" "2"
check "diverged main (local and remote each one commit) -> no evidence" "$(evid deliver NONE ev-d)" "false"
git -C "$RP_REPO" update-ref refs/remotes/origin/main HEAD
git -C "$RP_REPO" checkout -q feature/2527-rp
export ENFORCE_WORKTREE=on
case_end

case_begin "query placement: verdict of the evaluated step queries, --list never does" "hooks/workflow-state/evidence-resolver/release-evidence.js"
mk_state '{"sid":"ev-q","path":"pull_request","entered":true,"upto":"deliver","steps":"deliver=pending"}'
export RP_GH_MODE=OPEN
: > "$RP_GH_LOG"
run_next_step ev-q --list >/dev/null
check "--list made no gh call" "$(wc -l < "$RP_GH_LOG" | tr -d ' ')" "0"
out="$(run_next_step ev-q)"
check_contains "verdict on deliver queried the PR state" "$(cat "$RP_GH_LOG")" "pr "
check "OPEN is not deliver evidence -> NEXT_SKILL=deliver" "$(field "$out" NEXT_SKILL)" "deliver"
mk_state '{"sid":"ev-early","path":"pull_request","entered":true,"upto":"docs","steps":"docs=pending"}'
: > "$RP_GH_LOG"
run_next_step ev-early >/dev/null
check "verdict on an earlier step makes no release query" "$(wc -l < "$RP_GH_LOG" | tr -d ' ')" "0"
case_end

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit "$FAIL"
