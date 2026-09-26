#!/usr/bin/env bash
# tests/hooks/fix-workflow-gate-rtk-wrapper-model.sh
# Tests: hooks/lib/commit-detect.js, hooks/lib/merge-detect.js, hooks/workflow-gate.js
# Tags: TL1, hook, workflow-gate, commit, merge, rtk, wrapper, scope:permanent
# #2393 CPR-E2C: workflow-gate judged commit/merge by head-anchored raw regex, so
# `rtk git commit` / `env git commit` / `rtk gh pr merge` skipped the gate. The fix
# extracts isCommitCommand(ir) + extractCommitSegmentText(ir) into commit-detect.js
# and routes merge-detect's checkSegment through the shared wrapper model.
# commit-detect.js does not exist pre-fix, so B1-B4/B6 report NOT_EXPORTED (RED).

set -euo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$AGENTS_DIR/tests/lib/harness.sh"

T="$(make_tmp)"
trap 'rm -rf "$T"' EXIT
harness_isolate "$T/iso"

HOOKS_N="$(np "$AGENTS_DIR/hooks")"
GATE_HOOK="$HOOKS_N/workflow-gate.js"

# commit_eval <js-body> <command> — `cd` = commit-detect module (or null), `ir` =
# parse(command). Prints NOT_EXPORTED when the module/export is missing.
commit_eval() {
    run_with_timeout 30 node -e "
      const H = process.argv[1];
      const { parse } = require(H + '/lib/command-ir');
      let cd = null;
      try { cd = require(H + '/lib/commit-detect'); } catch (_) { cd = null; }
      const ir = parse(process.argv[2]);
      if (!cd || typeof cd.isCommitCommand !== 'function') console.log('NOT_EXPORTED');
      else { $1 }
    " "$HOOKS_N" "$2" 2>&1 || true
}

is_commit() { commit_eval 'console.log(String(cd.isCommitCommand(ir)));' "$1"; }

merge_kind() {
    run_with_timeout 30 node -e "
      const { isMergeToProtectedCommand } = require(process.argv[1] + '/lib/merge-detect');
      const r = isMergeToProtectedCommand(process.argv[2]);
      console.log(r.hit ? r.kind : 'MISS');
    " "$HOOKS_N" "$1" 2>&1 || true
}

expect_eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then pass "$label"; else fail "$label" "want=$want got=$got"; fi
}

case_begin "commit-detect-wrappers" "hooks/lib/commit-detect.js"
expect_eq "B1. isCommitCommand(rtk git commit -m msg) → true" "$(is_commit 'rtk git commit -m msg')" "true"
expect_eq "B2. isCommitCommand(env git commit -m msg) → true" "$(is_commit 'env git commit -m msg')" "true"
expect_eq "B3. isCommitCommand(nohup git commit -m msg) → true" "$(is_commit 'nohup git commit -m msg')" "true"
expect_eq "B1b. isCommitCommand(git -C /repo commit -m msg) → true (global option skipped)" "$(is_commit 'git -C /repo commit -m msg')" "true"
expect_eq "B1c. isCommitCommand(git commit -m msg) → true (plain form unchanged)" "$(is_commit 'git commit -m msg')" "true"
expect_eq "B4. isCommitCommand(git log --grep commit) → false (no false positive)" "$(is_commit 'git log --grep commit')" "false"
expect_eq "B4b. isCommitCommand(echo git commit) → false (not a git segment)" "$(is_commit 'echo git commit')" "false"
expect_eq "B4c. isCommitCommand(rtk read commit) → false (native rtk verb)" "$(is_commit 'rtk read commit')" "false"
# rtk-rewrite.js substituteRtkHead emits the quoted absolute binary on win32.
expect_eq "B1d. isCommitCommand(\"C:/x/rtk.exe\" git commit -m x) → true" "$(is_commit '"C:/x/rtk.exe" git commit -m x')" "true"
# Fail-closed: an unparseable rtk option must fall back to scanWrappedVerb, not fail-open.
expect_eq "B1e. isCommitCommand(rtk --unknown-opt git commit -m x) → true (fail-closed)" "$(is_commit 'rtk --unknown-opt git commit -m x')" "true"
case_end

case_begin "commit-detect-wip" "hooks/lib/commit-detect.js"
# B6: parseGitConfigValues anchors on ^git, so the WIP flag behind a wrapper is only
# visible through the text reconstructed from the effective git argv.
wip_of() {
    commit_eval "
      if (typeof cd.extractCommitSegmentText !== 'function') console.log('NOT_EXPORTED');
      else {
        const { parseGitConfigValues } = require(H + '/lib/parse-git-args');
        const txt = cd.extractCommitSegmentText(ir);
        const vals = typeof txt === 'string' ? parseGitConfigValues(txt, 'workflow.wip') : [];
        console.log(vals.some((v) => v === '1' || v.toLowerCase() === 'true') ? 'WIP' : 'NOWIP');
      }" "$1"
}
expect_eq "B6. rtk git -c workflow.wip=1 commit → WIP detected via reconstructed argv" "$(wip_of 'rtk git -c workflow.wip=1 commit -m x')" "WIP"
expect_eq "B6b. env git -c workflow.wip=1 commit → WIP detected" "$(wip_of 'env git -c workflow.wip=1 commit -m x')" "WIP"
expect_eq "B6c. rtk git commit -m x (no -c) → NOWIP" "$(wip_of 'rtk git commit -m x')" "NOWIP"
case_end

case_begin "merge-detect-wrappers" "hooks/lib/merge-detect.js"
expect_eq "B5. rtk gh pr merge 12 → gh-pr-merge" "$(merge_kind 'rtk gh pr merge 12')" "gh-pr-merge"
expect_eq "B5b. rtk git push origin main → git-push-protected" "$(merge_kind 'rtk git push origin main')" "git-push-protected"
expect_eq "B5c. env gh pr merge 12 --squash → gh-pr-merge" "$(merge_kind 'env gh pr merge 12 --squash')" "gh-pr-merge"
expect_eq "B5d. gh pr merge 12 → gh-pr-merge (plain form unchanged)" "$(merge_kind 'gh pr merge 12')" "gh-pr-merge"
expect_eq "B5e. rtk git push origin feature/x → MISS (non-protected branch)" "$(merge_kind 'rtk git push origin feature/x')" "MISS"
expect_eq "B5f. rtk gh pr view 12 → MISS (read verb)" "$(merge_kind 'rtk gh pr view 12')" "MISS"
expect_eq "B5g. rtk --unknown-opt gh pr merge 12 → gh-pr-merge (fail-closed)" "$(merge_kind 'rtk --unknown-opt gh pr merge 12')" "gh-pr-merge"
case_end

case_begin "commit-detect-chain" "hooks/lib/commit-detect.js"
expect_eq "B7. isCommitCommand(git add -A && rtk git commit -m x) → true (commit in 2nd segment)" \
    "$(is_commit 'git add -A && rtk git commit -m x')" "true"
case_end

# --- Hook-level: hooks/workflow-gate.js end to end --------------------------
# The fixture repo doubles as AGENTS_CONFIG_DIR so isAgentsSessionRepo() keeps the
# gate armed; run_tests is pending, so any commit that reaches the gate is BLOCKed.
WG_REPO="$(np "$T/wg-repo")"
mkdir -p "$WG_REPO"
git -C "$WG_REPO" init -q -b main
git -C "$WG_REPO" config user.email "test@example.com"
git -C "$WG_REPO" config user.name "Test"
git -C "$WG_REPO" config core.hooksPath /dev/null
git -C "$WG_REPO" config core.autocrlf false
echo "init" > "$WG_REPO/README.md"
git -C "$WG_REPO" add README.md
git -C "$WG_REPO" commit -q -m "initial"
echo "src" > "$WG_REPO/app.js"
git -C "$WG_REPO" add app.js
WG_SID="wg2393pending"

run_with_timeout 30 node -e "
  const fs = require('fs'), path = require('path');
  const { VALID_STEPS } = require(process.argv[1] + '/workflow-state.js');
  const now = new Date().toISOString();
  const steps = {};
  for (const s of VALID_STEPS) steps[s] = { status: 'complete', updated_at: now };
  steps.run_tests = { status: 'pending', updated_at: null };
  const st = { version: 1, session_id: process.argv[2], created_at: now, steps };
  fs.writeFileSync(path.join(process.argv[3], process.argv[2] + '.json'), JSON.stringify(st, null, 2));
" "$HOOKS_N" "$WG_SID" "$(np "$CLAUDE_WORKFLOW_DIR")"

# wg_run <command> → approve | block | timeout | crash:<rc> | other:<out>
wg_run() {
    local payload out rc=0
    payload="$(node -e "process.stdout.write(JSON.stringify({session_id:process.argv[1],tool_name:'Bash',tool_input:{command:process.argv[2],cwd:process.argv[3]}}))" "$WG_SID" "$1" "$WG_REPO")"
    out="$(cd "$WG_REPO" && printf '%s' "$payload" | run_with_timeout 30 env \
        -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u CLAUDE_ENV_FILE -u WORKFLOW_OFF \
        "AGENTS_CONFIG_DIR=$WG_REPO" "CLAUDE_PROJECT_DIR=$WG_REPO" \
        node "$GATE_HOOK" 2>/dev/null)" || rc=$?
    out="$(printf '%s' "$out" | tr -d '\r\n')"
    case "$rc" in
        0|2) ;;
        124) printf 'timeout'; return ;;
        *) printf 'crash:%s' "$rc"; return ;;
    esac
    case "$out" in
        *'"decision":"block"'*) printf 'block' ;;
        *'"decision":"approve"'*) printf 'approve' ;;
        *) printf 'other:%s' "$out" ;;
    esac
}

case_begin "workflow-gate-hook-wrappers" "hooks/workflow-gate.js"
expect_eq "G1a. hook: git commit -m x with run_tests pending → block (fixture sanity)" "$(wg_run 'git commit -m x')" "block"
expect_eq "G1b. hook: rtk git commit -m x with run_tests pending → block (reaches commit gate)" "$(wg_run 'rtk git commit -m x')" "block"
expect_eq "G1c. hook: rtk git status → approve (read-only, not a commit)" "$(wg_run 'rtk git status')" "approve"
expect_eq "G1d. hook: git add -A && rtk git commit -m x → block (commit in 2nd segment)" "$(wg_run 'git add -A && rtk git commit -m x')" "block"
expect_eq "G1e. hook: echo hi && rtk git commit -m x → block (non-git lead segment)" "$(wg_run 'echo hi && rtk git commit -m x')" "block"
expect_eq "G1f. hook: \"C:/x/rtk.exe\" git commit -m x → block (rewritten absolute head)" "$(wg_run '"C:/x/rtk.exe" git commit -m x')" "block"
case_end

echo ""
echo "Results: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[[ "$FAIL" -eq 0 ]]
