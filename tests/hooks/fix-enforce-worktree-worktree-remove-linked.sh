#!/usr/bin/env bash
# tests/hooks/fix-enforce-worktree-worktree-remove-linked.sh
# Tests: hooks/enforce-worktree.js, hooks/enforce-worktree/handle-bash-write.js
# Tags: TL1, hook, enforce, worktree, worktree-remove, linked, scope:common
# #838 (via #2393): `git -C <main> worktree remove <wt2>` is gated on
# isMainCheckout(CWD), so a session standing in a linked worktree cannot clean up
# a sibling worktree even with an explicit -C at the main checkout. D1/D1b are
# RED until the gate keys on the -C target; D2-D6 pin the boundaries.

set -euo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
# shellcheck source=tests/lib/ew-runner.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/ew-runner.sh"

T="$(make_tmp)"
trap 'rm -rf "$T"' EXIT
harness_isolate "$T/iso"

MAIN="$(np "$T/main")"
LINKED="$(np "$T/wt-linked")"
VICTIM="$(np "$T/wt-victim")"
OTHER="$(np "$T/other")"
ew_make_repo "$MAIN"
ew_make_repo "$OTHER"
git -C "$MAIN" worktree add -q -b feature/foo "$LINKED"
git -C "$MAIN" worktree add -q -b feature/victim "$VICTIM"
EW_CFG_ROOT="$MAIN"

run() { ew_run "$1" "$(ew_bash_payload test "$2")"; }

case_begin "worktree-remove-from-linked" "hooks/enforce-worktree/handle-bash-write.js"
ew_expect allow "D1. linked CWD: git -C <main> worktree remove <sibling> → ALLOW" \
    "$(run "$LINKED" "git -C \"$MAIN\" worktree remove \"$VICTIM\"")"
ew_expect allow "D1b. linked CWD: git -C <main> worktree prune → ALLOW" \
    "$(run "$LINKED" "git -C \"$MAIN\" worktree prune")"
case_end

case_begin "worktree-remove-from-main-regression" "hooks/enforce-worktree.js"
ew_expect allow "D2. main CWD: git -C <main> worktree remove <sibling> → ALLOW (regression)" \
    "$(run "$MAIN" "git -C \"$MAIN\" worktree remove \"$VICTIM\"")"
case_end

case_begin "worktree-remove-boundaries" "hooks/enforce-worktree/handle-bash-write.js"
ew_expect block "D3. linked CWD: git worktree remove <sibling> without -C → BLOCK" \
    "$(run "$LINKED" "git worktree remove \"$VICTIM\"")"
ew_expect block "D4. linked CWD: git -C <unrelated-repo> worktree remove → BLOCK" \
    "$(run "$LINKED" "git -C \"$OTHER\" worktree remove \"$VICTIM\"")"
ew_expect block "D5. linked CWD: git -C <linked> worktree remove <sibling> → BLOCK (-C is not main)" \
    "$(run "$LINKED" "git -C \"$LINKED\" worktree remove \"$VICTIM\"")"
ew_expect block "D6. linked CWD: git -C <main> worktree remove --force <sibling> → BLOCK" \
    "$(run "$LINKED" "git -C \"$MAIN\" worktree remove --force \"$VICTIM\"")"
ew_expect block "D7. linked CWD: git -C <main> worktree remove <sibling> && git -C <main> commit → BLOCK (chain)" \
    "$(run "$LINKED" "git -C \"$MAIN\" worktree remove \"$VICTIM\" && git -C \"$MAIN\" commit -m x")"
ew_expect block "D7b. linked CWD: git -C <main> worktree prune && git -C <main> commit → BLOCK (chain)" \
    "$(run "$LINKED" "git -C \"$MAIN\" worktree prune && git -C \"$MAIN\" commit -m x")"
case_end

# --- #1680 (via #2447): stale tool_input.cwd after ExitWorktree ---------------
# After ExitWorktree the Bash payload's tool_input.cwd stays pinned to the linked
# (or an already-removed) worktree. With worktree_exited_at in the session state
# the hook must ignore that cwd and judge from the real process cwd (main), so
# worktree-end WE-15/WE-20 (skills/worktree-end/scripts/cleanup-cascade.md) pass.
# Without worktree_exited_at the stale cwd must still be honoured (regression).
# TL3 gap: a real ExitWorktree tool call via `claude -p` is not exercised here.
export CLAUDE_TRANSCRIPT_BASE_DIR="$T/transcripts"
mkdir -p "$CLAUDE_TRANSCRIPT_BASE_DIR"
GONE="$(np "$T/wt-gone")"
git -C "$MAIN" worktree add -q -b feature/gone "$GONE"
git -C "$MAIN" worktree remove "$GONE"
# The eval case names the pre-flight script of the checkout the hook runs from:
# the hook sanctions a script only under its own checkout, by literal path (#2561).
GUARD_CHECKOUT="$(np "$SCRIPT_CHECKOUT_ROOT")"

SID_EXITED="test-1680-exited"
SID_ACTIVE="test-1680-active"
SID_NOSTATE="test-1680-nostate"
# mk_state <sid> <json-extra> — v1-shaped state (readState migrates it in memory).
mk_state() {
    node -e '
const fs=require("fs"),path=require("path");
const [dir,sid,extra]=process.argv.slice(1);
const st=()=>({status:"complete",updated_at:null});
const state={version:1,session_id:sid,created_at:"2026-09-29T00:00:00.000Z",
  steps:{workflow_init:st(),clarify_intent:st(),branching_complete:st()}};
Object.assign(state,JSON.parse(extra));
fs.writeFileSync(path.join(dir,sid+".json"),JSON.stringify(state,null,2));
' "$WORKFLOW_STATE_DIR" "$1" "$2"
}
mk_state "$SID_EXITED" '{"worktree_entered_at":"2026-09-29T00:00:00.000Z","worktree_exited_at":"2026-09-29T01:00:00.000Z"}'
mk_state "$SID_ACTIVE" '{"worktree_entered_at":"2026-09-29T00:00:00.000Z"}'
PRE="$(node -e 'const s=require(process.argv[1]).readState(process.argv[2]);process.stdout.write(String(s&&s.worktree_exited_at))' \
    "$(np "$SCRIPT_CHECKOUT_ROOT/hooks/workflow-state/state-io.js")" "$SID_EXITED")"
[[ "$PRE" == "2026-09-29T01:00:00.000Z" ]] || { fail "fixture: readState did not surface worktree_exited_at" "got=$PRE"; exit 1; }

# stale <sid> <tool-cwd> <command> — hook process runs from MAIN (the real cwd
# after ExitWorktree); only the payload's tool_input.cwd is stale.
stale() {
    local payload
    payload="$(node -e 'process.stdout.write(JSON.stringify({session_id:process.argv[1],tool_name:"Bash",tool_input:{command:process.argv[3],cwd:process.argv[2]}}))' "$1" "$2" "$3")"
    ew_run "$MAIN" "$payload" "ENFORCE_WORKTREE_ADDITIONAL_REPOS=$MAIN"
}
# stale_write <sid> <tool-cwd> <file-path> — same as stale() but uses the Write
# tool path (handleEditWrite) so that the stale-cwd guard is exercised for that
# code branch too (CPR-ORTH with the Bash / handleBashWrite path).
stale_write() {
    local payload
    payload="$(node -e 'process.stdout.write(JSON.stringify({session_id:process.argv[1],tool_name:"Write",tool_input:{file_path:process.argv[3],content:"x",cwd:process.argv[2]}}))' "$1" "$2" "$3")"
    ew_run "$MAIN" "$payload" "ENFORCE_WORKTREE_ADDITIONAL_REPOS=$MAIN"
}
EVAL_PREFLIGHT="eval \"\$(bash \"$GUARD_CHECKOUT/skills/issue-close-finalize/scripts/pre-flight.sh\")\""

case_begin "exited-stale-cwd-allow" "hooks/enforce-worktree.js"
ew_expect allow "WE-15-ALLOW: exited_at set, cwd=linked: git worktree remove <linked> → ALLOW" \
    "$(stale "$SID_EXITED" "$LINKED" "git worktree remove \"$LINKED\"")"
ew_expect allow "WE-15-C-ALLOW: exited_at set, cwd=removed wt: git -C <main> worktree remove <linked> → ALLOW" \
    "$(stale "$SID_EXITED" "$GONE" "git -C \"$MAIN\" worktree remove \"$LINKED\"")"
ew_expect allow "WE-20-ALLOW: exited_at set, cwd=removed wt: git -C <main> pull --ff-only → ALLOW" \
    "$(stale "$SID_EXITED" "$GONE" "git -C \"$MAIN\" pull --ff-only")"
ew_expect allow "WE-20-BARE-ALLOW: exited_at set, cwd=removed wt: git pull --ff-only → ALLOW" \
    "$(stale "$SID_EXITED" "$GONE" "git pull --ff-only")"
ew_expect allow "PHASE2-EVAL-ALLOW: exited_at set, cwd=removed wt: eval pre-flight.sh → ALLOW" \
    "$(stale "$SID_EXITED" "$GONE" "$EVAL_PREFLIGHT")"
case_end

# Dropping the stale cwd must re-anchor on the main checkout, never widen it.
case_begin "exited-stale-cwd-still-guards-main" "hooks/enforce-worktree/handle-bash-write.js"
ew_expect block "STALE-MAIN-WRITE-BLOCK: exited_at set, cwd=linked: write to main tracked file → BLOCK" \
    "$(stale "$SID_EXITED" "$LINKED" "echo x > \"$MAIN/README.md\"")"
ew_expect block "STALE-MAIN-COMMIT-BLOCK: exited_at set, cwd=removed wt: git commit → BLOCK" \
    "$(stale "$SID_EXITED" "$GONE" "git commit -m x")"
ew_expect block "STALE-MAIN-PULL-BLOCK: exited_at set, cwd=removed wt: git pull (non-ff-only) → BLOCK" \
    "$(stale "$SID_EXITED" "$GONE" "git pull")"
# CPR-ORTH: the stale-cwd guard must also fire for the Write tool (handleEditWrite
# path), not only for Bash redirects (handleBashWrite path).
ew_expect block "STALE-WRITE-TOOL-BLOCK: exited_at set, cwd=linked: Write to main tracked file → BLOCK" \
    "$(stale_write "$SID_EXITED" "$LINKED" "$MAIN/README.md")"
case_end

case_begin "no-exit-stale-cwd-regression" "hooks/enforce-worktree/handle-bash-write.js"
ew_expect block "WE-15-NO-EXIT-BLOCK: entered only, cwd=linked: git worktree remove <linked> → BLOCK" \
    "$(stale "$SID_ACTIVE" "$LINKED" "git worktree remove \"$LINKED\"")"
ew_expect block "WE-15-NO-STATE-BLOCK: no state file, cwd=linked: git worktree remove <linked> → BLOCK" \
    "$(stale "$SID_NOSTATE" "$LINKED" "git worktree remove \"$LINKED\"")"
case_end

echo ""
echo "Results: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[[ "$FAIL" -eq 0 ]]
