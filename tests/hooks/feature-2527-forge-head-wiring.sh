#!/usr/bin/env bash
# feature-2527-forge-head-wiring.sh — #2527: gh / glab head commits reach the local-HEAD check.
# Tests: hooks/lib/forge/github.js, hooks/lib/forge/gitlab.js, hooks/workflow-state/evidence-resolver/release-evidence.js
# Tags: scope:issue-specific, workflow, release-phase, forge, gh-stub, glab-stub, evidence, issue-2527
# TL2: calls the codehost descriptors and hasCompletionEvidence in-process against a fixture repo;
# gh / glab are the node-copy stubs answered by tests/bin/feature-2527-release-phase/fake-forge.js.
# TL3 gap (not caught here): the field names and values a real gh (headRefOid) / glab (sha)
# of the installed version reports for an open or merged PR / MR.
# Closest-to-action mitigation: the release preflight reads the live forge before any merge.
set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
# shellcheck source=tests/bin/feature-2527-release-phase/helpers.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2527-release-phase/helpers.sh"

RP_TMP="$(make_tmp)"
readonly RP_TMP
trap rp_teardown EXIT
harness_isolate "$RP_TMP"
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true
rp_setup
rp_fake_forge "$RP_TMP/forgebin" gh glab
# Every case names the head commit the stub reports; none -> the stub reports no head commit.
unset FAKE_FORGE_HEAD
GH_URL="https://github.com/example/repo.git"
GL_URL="https://gitlab.com/example/repo.git"
use_origin() { git -C "$RP_REPO" remote set-url origin "$1"; }

HEAD_OID="$(git -C "$RP_REPO" rev-parse HEAD)"
OTHER_OID="2222222222222222222222222222222222222222"
GH_PR_URL="https://github.com/example/repo/pull/42"
GL_MR_URL="https://gitlab.com/example/repo/-/merge_requests/42"

# forge_ans <github|gitlab> <fn> — the descriptor's answer for the fixture repo:
# prForBranch -> "state#number"; mergeStateForBranch -> "state#number#mergeState#url#error".
# The forge answer comes from the caller's FAKE_FORGE_* environment.
forge_ans() {
  local js
  IFS= read -r -d '' js <<'JS'
const [mod, fn, repo] = process.argv.slice(1);
const M = require(process.env.RP_SCRIPT_CHECKOUT_ROOT + "/hooks/lib/forge/" + mod + ".js");
const F = M[mod === "github" ? "codehostGithub" : "codehostGitlab"];
if (!F || typeof F[fn] !== "function") { console.log("NO_FN"); process.exit(0); }
const r = F[fn](repo);
console.log(fn === "prForBranch" ? r.state + "#" + r.number
  : [r.state, r.number, r.mergeState, r.url, r.error].join("#"));
JS
  run_with_timeout 60 node -e "$js" "$1" "$2" "$RP_REPO_M" 2>&1
}

# evid <step> <sid> — hasCompletionEvidence through the exported evidence resolver.
IFS= read -r -d '' EVID_JS <<'JS' || true
const E = require(process.env.RP_SCRIPT_CHECKOUT_ROOT + "/hooks/workflow-state/evidence-resolver.js");
try { console.log(String(E.hasCompletionEvidence(process.argv[1], process.argv[2], { repoDir: process.argv[3] }))); }
catch (e) { console.log("THROW:" + e.message); }
JS
evid() { run_with_timeout 60 node -e "$EVID_JS" "$1" "$2" "$RP_REPO_M" 2>&1; }
log_count() { grep -c -- "$1" "$RP_TMP/forge.log" || true; }

case_begin "sanity: the fixture HEAD is a commit id the stubs can report" "hooks/lib/forge/github.js"
if [[ "$HEAD_OID" =~ ^[0-9a-f]{40,64}$ && "$HEAD_OID" != "$OTHER_OID" ]]; then pass "local HEAD is a commit id"; else fail "local HEAD is a commit id" "got=[$HEAD_OID]"; fi
case_end

UNK_ERR="PR head commit or local HEAD unreadable"

case_begin "B1 github prForBranch: OPEN / MERGED stand only for the local HEAD" "hooks/lib/forge/github.js"
use_origin "$GH_URL"
: > "$RP_TMP/forge.log"
check "matching headRefOid -> MERGED with number" "$(FAKE_FORGE_STATE=MERGED FAKE_FORGE_HEAD="$HEAD_OID" forge_ans github prForBranch)" "MERGED#42"
check "gh was asked for headRefOid" "$(log_count 'gh pr view --json state,number,headRefOid')" "1"
check "upper-case headRefOid -> MERGED" "$(FAKE_FORGE_STATE=MERGED FAKE_FORGE_HEAD="${HEAD_OID^^}" forge_ans github prForBranch)" "MERGED#42"
check "mismatched headRefOid -> NONE, number cleared" "$(FAKE_FORGE_STATE=MERGED FAKE_FORGE_HEAD="$OTHER_OID" forge_ans github prForBranch)" "NONE#"
check "no headRefOid reported -> UNKNOWN, number cleared" "$(FAKE_FORGE_STATE=MERGED forge_ans github prForBranch)" "UNKNOWN#"
check "empty headRefOid -> UNKNOWN" "$(FAKE_FORGE_STATE=MERGED FAKE_FORGE_HEAD="" forge_ans github prForBranch)" "UNKNOWN#"
check "abbreviated headRefOid -> UNKNOWN" "$(FAKE_FORGE_STATE=MERGED FAKE_FORGE_HEAD="${HEAD_OID:0:12}" forge_ans github prForBranch)" "UNKNOWN#"
check "OPEN + matching headRefOid -> OPEN with number" "$(FAKE_FORGE_STATE=OPEN FAKE_FORGE_HEAD="$HEAD_OID" forge_ans github prForBranch)" "OPEN#42"
check "OPEN + mismatched headRefOid -> NONE, number cleared" "$(FAKE_FORGE_STATE=OPEN FAKE_FORGE_HEAD="$OTHER_OID" forge_ans github prForBranch)" "NONE#"
check "OPEN + no headRefOid reported -> UNKNOWN" "$(FAKE_FORGE_STATE=OPEN forge_ans github prForBranch)" "UNKNOWN#"
check "CLOSED + mismatched headRefOid -> CLOSED kept" "$(FAKE_FORGE_STATE=CLOSED FAKE_FORGE_HEAD="$OTHER_OID" forge_ans github prForBranch)" "CLOSED#42"
check "CLOSED + no headRefOid reported -> CLOSED kept" "$(FAKE_FORGE_STATE=CLOSED forge_ans github prForBranch)" "CLOSED#42"
case_end

case_begin "B1 github mergeStateForBranch: OPEN / MERGED stand only for the local HEAD" "hooks/lib/forge/github.js"
: > "$RP_TMP/forge.log"
check "matching headRefOid -> MERGED, answer intact" "$(FAKE_FORGE_STATE=MERGED FAKE_FORGE_HEAD="$HEAD_OID" forge_ans github mergeStateForBranch)" "MERGED#42#CLEAN#$GH_PR_URL#"
check "gh was asked for headRefOid" "$(log_count 'gh pr view --json state,number,mergeStateStatus,url,headRefOid')" "1"
check "mismatched headRefOid -> NONE, number / mergeState / url cleared" "$(FAKE_FORGE_STATE=MERGED FAKE_FORGE_HEAD="$OTHER_OID" forge_ans github mergeStateForBranch)" "NONE####"
check "no headRefOid reported -> UNKNOWN with the reason" "$(FAKE_FORGE_STATE=MERGED forge_ans github mergeStateForBranch)" "UNKNOWN####$UNK_ERR"
check "OPEN + matching headRefOid -> OPEN, answer intact" "$(FAKE_FORGE_STATE=OPEN FAKE_FORGE_MERGE=BEHIND FAKE_FORGE_HEAD="$HEAD_OID" forge_ans github mergeStateForBranch)" "OPEN#42#BEHIND#$GH_PR_URL#"
check "OPEN + mismatched headRefOid -> NONE, cleared" "$(FAKE_FORGE_STATE=OPEN FAKE_FORGE_MERGE=BEHIND FAKE_FORGE_HEAD="$OTHER_OID" forge_ans github mergeStateForBranch)" "NONE####"
check "OPEN + no headRefOid reported -> UNKNOWN with the reason" "$(FAKE_FORGE_STATE=OPEN forge_ans github mergeStateForBranch)" "UNKNOWN####$UNK_ERR"
check "CLOSED + no headRefOid reported -> CLOSED kept" "$(FAKE_FORGE_STATE=CLOSED forge_ans github mergeStateForBranch)" "CLOSED#42#CLEAN#$GH_PR_URL#"
case_end

case_begin "B2 gitlab prForBranch: OPEN / MERGED stand only for the local HEAD" "hooks/lib/forge/gitlab.js"
use_origin "$GL_URL"
: > "$RP_TMP/forge.log"
check "matching sha -> MERGED with iid" "$(FAKE_FORGE_STATE=MERGED FAKE_FORGE_HEAD="$HEAD_OID" forge_ans gitlab prForBranch)" "MERGED#42"
check "glab was asked for the MR sha" "$(log_count 'glab mr view --json sha --jq .sha')" "1"
check "upper-case sha -> MERGED" "$(FAKE_FORGE_STATE=MERGED FAKE_FORGE_HEAD="${HEAD_OID^^}" forge_ans gitlab prForBranch)" "MERGED#42"
: > "$RP_TMP/forge.log"
check "mismatched sha -> NONE, iid cleared" "$(FAKE_FORGE_STATE=MERGED FAKE_FORGE_HEAD="$OTHER_OID" forge_ans gitlab prForBranch)" "NONE#"
check "mismatched sha: the iid is never queried" "$(log_count '--json iid')" "0"
check "no sha reported (jq null) -> UNKNOWN, iid cleared" "$(FAKE_FORGE_STATE=MERGED forge_ans gitlab prForBranch)" "UNKNOWN#"
: > "$RP_TMP/forge.log"
check "OPEN + matching sha -> OPEN with iid" "$(FAKE_FORGE_STATE=OPEN FAKE_FORGE_HEAD="$HEAD_OID" forge_ans gitlab prForBranch)" "OPEN#42"
check "OPEN: the MR sha is queried" "$(log_count 'glab mr view --json sha --jq .sha')" "1"
check "OPEN: the iid is queried" "$(log_count '--json iid')" "1"
: > "$RP_TMP/forge.log"
check "OPEN + mismatched sha -> NONE, iid cleared" "$(FAKE_FORGE_STATE=OPEN FAKE_FORGE_HEAD="$OTHER_OID" forge_ans gitlab prForBranch)" "NONE#"
check "OPEN + mismatched sha: the iid is never queried" "$(log_count '--json iid')" "0"
check "OPEN + no sha reported (jq null) -> UNKNOWN" "$(FAKE_FORGE_STATE=OPEN forge_ans gitlab prForBranch)" "UNKNOWN#"
: > "$RP_TMP/forge.log"
check "CLOSED + mismatched sha -> CLOSED kept" "$(FAKE_FORGE_STATE=CLOSED FAKE_FORGE_HEAD="$OTHER_OID" forge_ans gitlab prForBranch)" "CLOSED#42"
check "CLOSED: the MR sha is never queried" "$(log_count '--json sha')" "0"
case_end

# Only 40-64 hex digits are a reported commit id; anything else is "no usable head commit" -> UNKNOWN.
case_begin "B2 gitlab prForBranch: a sha that is no commit id is not accepted as one" "hooks/lib/forge/gitlab.js"
for st in OPEN MERGED; do
  check "$st + non-hex sha -> UNKNOWN" "$(FAKE_FORGE_STATE=$st FAKE_FORGE_HEAD="not-a-commit-id" forge_ans gitlab prForBranch)" "UNKNOWN#"
  check "$st + abbreviated sha -> UNKNOWN" "$(FAKE_FORGE_STATE=$st FAKE_FORGE_HEAD="${HEAD_OID:0:12}" forge_ans gitlab prForBranch)" "UNKNOWN#"
  check "$st + 39 hex digits -> UNKNOWN" "$(FAKE_FORGE_STATE=$st FAKE_FORGE_HEAD="${OTHER_OID:0:39}" forge_ans gitlab prForBranch)" "UNKNOWN#"
  check "$st + 40 characters with a non-hex one -> UNKNOWN" "$(FAKE_FORGE_STATE=$st FAKE_FORGE_HEAD="${OTHER_OID:0:39}z" forge_ans gitlab prForBranch)" "UNKNOWN#"
  check "$st + sanity: the full 40-digit mismatching sha is accepted -> NONE" "$(FAKE_FORGE_STATE=$st FAKE_FORGE_HEAD="$OTHER_OID" forge_ans gitlab prForBranch)" "NONE#"
done
case_end

case_begin "B2 gitlab mergeStateForBranch: OPEN / MERGED stand only for the local HEAD" "hooks/lib/forge/gitlab.js"
check "matching sha -> MERGED, answer intact" "$(FAKE_FORGE_STATE=MERGED FAKE_FORGE_HEAD="$HEAD_OID" forge_ans gitlab mergeStateForBranch)" "MERGED#42#CLEAN#$GL_MR_URL#"
check "mismatched sha -> NONE, iid / mergeState / url cleared" "$(FAKE_FORGE_STATE=MERGED FAKE_FORGE_HEAD="$OTHER_OID" forge_ans gitlab mergeStateForBranch)" "NONE####"
check "no sha reported -> UNKNOWN with the reason" "$(FAKE_FORGE_STATE=MERGED forge_ans gitlab mergeStateForBranch)" "UNKNOWN####$UNK_ERR"
check "OPEN + matching sha -> OPEN, answer intact" "$(FAKE_FORGE_STATE=OPEN FAKE_FORGE_HEAD="$HEAD_OID" forge_ans gitlab mergeStateForBranch)" "OPEN#42#CLEAN#$GL_MR_URL#"
check "OPEN + mismatched sha -> NONE, cleared" "$(FAKE_FORGE_STATE=OPEN FAKE_FORGE_HEAD="$OTHER_OID" forge_ans gitlab mergeStateForBranch)" "NONE####"
check "OPEN + no sha reported -> UNKNOWN with the reason" "$(FAKE_FORGE_STATE=OPEN forge_ans gitlab mergeStateForBranch)" "UNKNOWN####$UNK_ERR"
check "CLOSED + no sha reported -> CLOSED kept" "$(FAKE_FORGE_STATE=CLOSED forge_ans gitlab mergeStateForBranch)" "CLOSED#42#CLEAN#$GL_MR_URL#"
check "non-hex sha -> UNKNOWN" "$(FAKE_FORGE_STATE=MERGED FAKE_FORGE_HEAD="not-a-commit-id" forge_ans gitlab mergeStateForBranch)" "UNKNOWN####$UNK_ERR"
check "abbreviated sha -> UNKNOWN" "$(FAKE_FORGE_STATE=MERGED FAKE_FORGE_HEAD="${HEAD_OID:0:12}" forge_ans gitlab mergeStateForBranch)" "UNKNOWN####$UNK_ERR"
case_end

case_begin "B3 release evidence (github): a PR of another commit is no evidence" "hooks/workflow-state/evidence-resolver/release-evidence.js"
use_origin "$GH_URL"
mk_state '{"sid":"hw-pr","path":"pull_request","entered":true,"upto":"push_branch","steps":"push_branch=pending"}'
check "merge_to_main: matching head -> evidence" "$(FAKE_FORGE_STATE=MERGED FAKE_FORGE_HEAD="$HEAD_OID" evid merge_to_main hw-pr)" "true"
check "merge_to_main: mismatched head -> no evidence" "$(FAKE_FORGE_STATE=MERGED FAKE_FORGE_HEAD="$OTHER_OID" evid merge_to_main hw-pr)" "false"
check "merge_to_main: no head reported -> no evidence" "$(FAKE_FORGE_STATE=MERGED evid merge_to_main hw-pr)" "false"
check "push_branch: MERGED + matching head -> evidence" "$(FAKE_FORGE_STATE=MERGED FAKE_FORGE_HEAD="$HEAD_OID" evid push_branch hw-pr)" "true"
check "push_branch: MERGED + mismatched head -> no evidence" "$(FAKE_FORGE_STATE=MERGED FAKE_FORGE_HEAD="$OTHER_OID" evid push_branch hw-pr)" "false"
check "push_branch: OPEN + matching head -> evidence" "$(FAKE_FORGE_STATE=OPEN FAKE_FORGE_HEAD="$HEAD_OID" evid push_branch hw-pr)" "true"
check "push_branch: OPEN + mismatched head -> no evidence" "$(FAKE_FORGE_STATE=OPEN FAKE_FORGE_HEAD="$OTHER_OID" evid push_branch hw-pr)" "false"
check "push_branch: OPEN + no head reported -> no evidence" "$(FAKE_FORGE_STATE=OPEN evid push_branch hw-pr)" "false"
check "push_branch: MERGED + no head reported -> no evidence" "$(FAKE_FORGE_STATE=MERGED evid push_branch hw-pr)" "false"
case_end

case_begin "B3 release evidence (github): a new local commit withdraws the evidence" "hooks/workflow-state/evidence-resolver/release-evidence.js"
rp_ahead
check "sanity: HEAD moved" "$([[ "$(git -C "$RP_REPO" rev-parse HEAD)" != "$HEAD_OID" ]] && echo moved)" "moved"
check "merge_to_main: PR head is the previous commit -> no evidence" "$(FAKE_FORGE_STATE=MERGED FAKE_FORGE_HEAD="$HEAD_OID" evid merge_to_main hw-pr)" "false"
check "push_branch: OPEN PR lacks the unpushed local commit -> no evidence" "$(FAKE_FORGE_STATE=OPEN FAKE_FORGE_HEAD="$HEAD_OID" evid push_branch hw-pr)" "false"
NEW_OID="$(git -C "$RP_REPO" rev-parse HEAD)"
check "merge_to_main: PR head is the new HEAD -> evidence" "$(FAKE_FORGE_STATE=MERGED FAKE_FORGE_HEAD="$NEW_OID" evid merge_to_main hw-pr)" "true"
check "push_branch: OPEN PR head is the new HEAD (pushed) -> evidence" "$(FAKE_FORGE_STATE=OPEN FAKE_FORGE_HEAD="$NEW_OID" evid push_branch hw-pr)" "true"
case_end

case_begin "B3 release evidence (gitlab): an MR of another commit is no evidence" "hooks/workflow-state/evidence-resolver/release-evidence.js"
use_origin "$GL_URL"
check "merge_to_main: matching sha -> evidence" "$(FAKE_FORGE_STATE=MERGED FAKE_FORGE_HEAD="$NEW_OID" evid merge_to_main hw-pr)" "true"
check "merge_to_main: mismatched sha -> no evidence" "$(FAKE_FORGE_STATE=MERGED FAKE_FORGE_HEAD="$OTHER_OID" evid merge_to_main hw-pr)" "false"
check "push_branch: MERGED + mismatched sha -> no evidence" "$(FAKE_FORGE_STATE=MERGED FAKE_FORGE_HEAD="$OTHER_OID" evid push_branch hw-pr)" "false"
check "push_branch: OPEN + matching sha -> evidence" "$(FAKE_FORGE_STATE=OPEN FAKE_FORGE_HEAD="$NEW_OID" evid push_branch hw-pr)" "true"
check "push_branch: OPEN MR lacks the unpushed local commit -> no evidence" "$(FAKE_FORGE_STATE=OPEN FAKE_FORGE_HEAD="$HEAD_OID" evid push_branch hw-pr)" "false"
check "push_branch: OPEN + no sha reported -> no evidence" "$(FAKE_FORGE_STATE=OPEN evid push_branch hw-pr)" "false"
use_origin "$GH_URL"
case_end

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit "$FAIL"
