#!/usr/bin/env bash
# premature-guard.sh — #2527 3-5: premature USER_VERIFIED guard, bootstrap exception, new wording.
# Tests: hooks/workflow-gate.js, hooks/workflow-gate/gh-detect.js
# Tags: scope:issue-specific, workflow, release-phase, premature-guard
# TL2: workflow-gate.js fed a USER_VERIFIED sentinel from a linked worktree; fake gh; local bare
# remotes for the empty / populated cases; https disallowed so a github ls-remote fails fast.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

# TL3 gap (not caught here): the empty-remote allow path against real github.com (the last case
# serves an empty bare repo through a fake GIT_SSH_COMMAND behind a github ssh URL). Closest-to-action
# mitigation: WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: hook-registration.
rp_setup
trap rp_teardown EXIT
rp_worktree
printf 'wt change\n' > "$RP_WT/wt.txt"
git -C "$RP_WT" add wt.txt
git -C "$RP_WT" commit -q -m "wt change"
mk_state "{\"sid\":\"pg\",\"path\":\"pull_request\",\"entered\":true,\"cwd\":\"$RP_WT_M\",\"upto\":\"user_verification\",\"steps\":\"user_verification=pending\"}"
SENTINEL='echo "<<WORKFLOW_USER_VERIFIED: release approved by user>>"'
# The TR5 audit gate (user-verified-audit.js) runs only after the premature guard lets the sentinel
# through, and with no recorded audit it always arms a run; its message is the positive allow signal.
TR5_MARK="[EM Supervisor] user_verification (TR5) audit"
EXEMPT_LINE="[workflow-gate] origin has no default-branch head; premature-UV exemption applied"
absent() {
  local js
  IFS= read -r -d '' js <<'JS'
const G = require(process.env.RP_SCRIPT_CHECKOUT_ROOT + "/hooks/workflow-gate/gh-detect.js");
if (typeof G.isRemoteDefaultBranchAbsent !== "function") { console.log("NO_EXPORT"); process.exit(0); }
console.log(String(G.isRemoteDefaultBranchAbsent(process.argv[1])));
JS
  run_with_timeout 30 node -e "$js" "$1" 2>&1
}

case_begin "no PR, branch ahead -> blocked, wording points at /get-release-approval" "hooks/workflow-gate.js"
export RP_GH_MODE=NONE
out="$(gate_bash pg "$RP_WT_M" "$SENTINEL")"
check_contains "blocked as premature" "$out" "premature <<WORKFLOW_USER_VERIFIED>> emission blocked"
check_contains "names /commit-push for the PR" "$out" "/commit-push"
check_contains "names /get-release-approval" "$out" "/get-release-approval"
check_not_contains "no stale WE-7 pointer" "$out" "WE-7"
check_not_contains "no exemption line when origin/main exists" "$out" "$EXEMPT_LINE"
case_end

case_begin "PR open -> allowed (baseline)" "hooks/workflow-gate.js"
export RP_GH_MODE=OPEN
out="$(gate_bash pg "$RP_WT_M" "$SENTINEL")"
check_not_contains "not blocked with an open PR" "$out" "premature"
check_contains "passed the guard: reached the downstream TR5 audit gate" "$out" "$TR5_MARK"
case_end

case_begin "github origin, no origin/main ref, ls-remote fails -> still blocked (fail-closed)" "hooks/workflow-gate.js"
export RP_GH_MODE=NONE
git -C "$RP_REPO" update-ref -d refs/remotes/origin/main
check "detection failure reads as not-absent" "$(absent "$RP_WT_M")" "false"
out="$(gate_bash pg "$RP_WT_M" "$SENTINEL")"
check_contains "guard stays on" "$out" "premature <<WORKFLOW_USER_VERIFIED>> emission blocked"
check_not_contains "no exemption line when detection fails" "$out" "$EXEMPT_LINE"
case_end

case_begin "isRemoteDefaultBranchAbsent: empty bare remote -> true" "hooks/workflow-gate/gh-detect.js"
git init -q --bare "$RP_TMP/empty.git"
git -C "$RP_TMP/empty.git" config core.hooksPath /dev/null
git -C "$RP_REPO" remote set-url origin "$(np "$RP_TMP/empty.git")"
check "empty remote" "$(absent "$RP_WT_M")" "true"
case_end

case_begin "empty remote -> USER_VERIFIED allowed (bootstrap exception)" "hooks/workflow-gate.js"
out="$(gate_bash pg "$RP_WT_M" "$SENTINEL")"
check_not_contains "bootstrap emission not blocked" "$out" "premature"
check_contains "passed the guard: reached the downstream TR5 audit gate" "$out" "$TR5_MARK"
case_end

case_begin "isRemoteDefaultBranchAbsent: populated remote / broken remote -> false" "hooks/workflow-gate/gh-detect.js"
git init -q --bare "$RP_TMP/full.git"
git -C "$RP_TMP/full.git" config core.hooksPath /dev/null
git -C "$RP_REPO" push -q "$(np "$RP_TMP/full.git")" main
git -C "$RP_REPO" remote set-url origin "$(np "$RP_TMP/full.git")"
check "populated remote" "$(absent "$RP_WT_M")" "false"
git -C "$RP_REPO" remote set-url origin "$(np "$RP_TMP/does-not-exist.git")"
check "unreachable remote (git error)" "$(absent "$RP_WT_M")" "false"
case_end

# ls_remote_ssh — GIT_SSH_COMMAND the ls-remote child received (spawnSync patched before gh-detect loads).
ls_remote_ssh() {
  local js
  IFS= read -r -d '' js <<'JS'
const cp = require("child_process");
let seen = "<no ls-remote call>";
cp.spawnSync = (cmd, argv, opts) => {
  if (argv.includes("ls-remote")) {
    seen = opts && opts.env ? String(opts.env.GIT_SSH_COMMAND) + "|" + String(opts.env.GIT_TERMINAL_PROMPT) : "<no env>";
    return { status: 0, stdout: "", stderr: "" };
  }
  return { status: 1, stdout: "", stderr: "" };
};
const G = require(process.env.RP_SCRIPT_CHECKOUT_ROOT + "/hooks/workflow-gate/gh-detect.js");
const r = G.isRemoteDefaultBranchAbsent("/nonexistent");
console.log(seen + "|" + r);
JS
  run_with_timeout 30 node -e "$js" 2>&1
}

case_begin "isRemoteDefaultBranchAbsent: ls-remote child env always carries SSH BatchMode" "hooks/workflow-gate/gh-detect.js"
check "GIT_SSH_COMMAND unset -> ssh -o BatchMode=yes" "$(unset GIT_SSH_COMMAND; ls_remote_ssh)" "ssh -o BatchMode=yes|0|true"
check "GIT_SSH_COMMAND set without BatchMode -> BatchMode appended" "$(GIT_SSH_COMMAND="ssh -i /tmp/fixture-key" ls_remote_ssh)" "ssh -i /tmp/fixture-key -o BatchMode=yes|0|true"
check "GIT_SSH_COMMAND with BatchMode -> kept as is" "$(GIT_SSH_COMMAND="ssh -o BatchMode=no -i /tmp/fixture-key" ls_remote_ssh)" "ssh -o BatchMode=no -i /tmp/fixture-key|0|true"
check "GIT_SSH_COMMAND with lowercase batchmode -> kept as is (case-insensitive)" "$(GIT_SSH_COMMAND="ssh -o batchmode=yes" ls_remote_ssh)" "ssh -o batchmode=yes|0|true"
check "GIT_SSH_COMMAND empty -> BatchMode default" "$(GIT_SSH_COMMAND="" ls_remote_ssh)" "ssh -o BatchMode=yes|0|true"
case_end

# A github ssh origin keeps the github forge (gh stub: no PR); the inherited GIT_SSH_COMMAND is a fake
# ssh serving the empty bare repo, so ls-remote succeeds empty and the exemption branch is reached.
case_begin "github origin, empty remote via ssh -> exemption announced on stderr exactly once" "hooks/workflow-gate.js"
printf '#!/usr/bin/env bash\nexec git upload-pack "%s"\n' "$(np "$RP_TMP/empty.git")" > "$RP_TMP/fake-ssh"
chmod +x "$RP_TMP/fake-ssh"
git -C "$RP_REPO" remote set-url origin git@github.com:example/repo.git
git -C "$RP_REPO" update-ref -d refs/remotes/origin/main 2>/dev/null || true
export RP_GH_MODE=NONE GIT_SSH_VARIANT=simple GIT_SSH_COMMAND="bash $(np "$RP_TMP/fake-ssh")"
check "sanity: detection reads the ssh remote as absent" "$(absent "$RP_WT_M")" "true"
out="$(gate_bash pg "$RP_WT_M" "$SENTINEL")"
check_not_contains "bootstrap emission not blocked" "$out" "premature <<WORKFLOW_USER_VERIFIED>> emission blocked"
check_contains "passed the guard: reached the downstream TR5 audit gate" "$out" "$TR5_MARK"
check "exemption line printed exactly once" "$(printf '%s\n' "$out" | tr -d '\r' | grep -cxF "$EXEMPT_LINE")" "1"
unset GIT_SSH_VARIANT GIT_SSH_COMMAND
case_end

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit "$FAIL"
