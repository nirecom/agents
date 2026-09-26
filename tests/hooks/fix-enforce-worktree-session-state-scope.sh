#!/usr/bin/env bash
# tests/hooks/fix-enforce-worktree-session-state-scope.sh
# Tests: hooks/enforce-worktree/handle-bash-write.js, hooks/enforce-worktree/bash-write-scope/marker-gate.js, hooks/enforce-worktree/handle-edit-write.js
# Tags: TL1, hook, enforce, worktree, workflow-state, session-scope, security, scope:permanent
# #1324 (via #2393): the workflow dir sits outside every session repo, so Guard 5
# and the Bug2 allow path wave through writes to ANOTHER session's state file.
# G2/G3/G6/G-U* are RED until targetsHitOtherSessionWorkflowState is OR-ed into
# _markerHit (Bash) and checked first in handle-edit-write (Edit/Write).
# Runs from the main checkout: a linked-worktree CWD bypasses the gate by design.

set -euo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$AGENTS_DIR/tests/lib/harness.sh"
# shellcheck source=tests/lib/ew-runner.sh
. "$AGENTS_DIR/tests/lib/ew-runner.sh"

T="$(make_tmp)"
trap 'rm -rf "$T"' EXIT
harness_isolate "$T/iso"
WF="$(np "$CLAUDE_WORKFLOW_DIR")"
export CLAUDE_WORKFLOW_DIR="$WF"

SID="11111111-2222-3333-4444-555555555555"
OTHER_SID="99999999-8888-7777-6666-555555555555"
MAIN="$(np "$T/main")"
ew_make_repo "$MAIN"
mkdir -p "$WF/$SID.instructions-loaded"
EW_CONFIG_DIR="$MAIN"

bash_run() { ew_run "$MAIN" "$(ew_bash_payload "$SID" "$1")"; }
tool_run() { ew_run "$MAIN" "$(ew_write_payload "$SID" "$1" "$2")"; }

case_begin "workflow-state-bash" "hooks/enforce-worktree/handle-bash-write.js"
ew_expect allow "G1. Bash redirect to own <sid>.json → ALLOW" \
    "$(bash_run "echo x > \"$WF/$SID.json\"")"
ew_expect block "G2. Bash redirect to other session's <other-sid>.json → BLOCK" \
    "$(bash_run "echo x > \"$WF/$OTHER_SID.json\"")"
# G4: `.workflow-off` would be the natural own-sid sibling, but marker-gate blocks
# protected state-kind basenames even for the own sid — an unprotected suffix
# isolates the stem check from that unrelated gate.
ew_expect allow "G4. Bash redirect to own <sid>.notes.txt → ALLOW (stem match)" \
    "$(bash_run "echo x > \"$WF/$SID.notes.txt\"")"
ew_expect allow "G5. Bash redirect into own <sid>.instructions-loaded/ subdir → ALLOW" \
    "$(bash_run "echo x > \"$WF/$SID.instructions-loaded/some-file\"")"
case_end

case_begin "workflow-state-edit-write" "hooks/enforce-worktree/handle-edit-write.js"
ew_expect block "G3. Write tool on other session's <other-sid>.json → BLOCK" \
    "$(tool_run Write "$WF/$OTHER_SID.json")"
ew_expect allow "G3b. Write tool on own <sid>.json → ALLOW" \
    "$(tool_run Write "$WF/$SID.json")"
ew_expect block "G6. Edit tool on other session's <other-sid>.json → BLOCK (CPR-ORTH)" \
    "$(tool_run Edit "$WF/$OTHER_SID.json")"
case_end

case_begin "targets-hit-other-session-unit" "hooks/enforce-worktree/bash-write-scope/marker-gate.js"
unit() {
    run_with_timeout 30 node -e "
      const mg = require(process.argv[1]);
      const f = mg.targetsHitOtherSessionWorkflowState;
      if (typeof f !== 'function') { console.log('NOT_EXPORTED'); }
      else {
        const wf = process.argv[2], sid = process.argv[3], other = process.argv[4];
        const t = (p) => [{ resolveVia: 'ancestor', path: wf + '/' + p }];
        const ctx = { sessionId: sid };
        console.log([
          f(t(other + '.json'), ctx),
          f(t(sid + '.json'), ctx),
          f(t(sid + '.instructions-loaded/x'), ctx),
          f(t(other + '.json'), null),
          f([{ resolveVia: 'ancestor', path: process.argv[5] }], ctx),
        ].join(','));
      }
    " "$(np "$AGENTS_DIR/hooks/enforce-worktree/bash-write-scope/marker-gate.js")" "$WF" "$SID" "$OTHER_SID" "$MAIN/README.md" 2>&1 || true
}
# order: other→true, own→false, own subdir→false, null ctx→true (fail-closed), outside wf→false
expect="true,false,false,true,false"
got="$(unit)"
if [[ "$got" == "$expect" ]]; then pass "G-U1. targetsHitOtherSessionWorkflowState truth table"
else fail "G-U1. targetsHitOtherSessionWorkflowState truth table" "want=$expect got=$got"; fi
case_end

echo ""
echo "Results: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[[ "$FAIL" -eq 0 ]]
