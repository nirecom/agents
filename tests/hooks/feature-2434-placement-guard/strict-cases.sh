#!/usr/bin/env bash
# Tests: hooks/block-clearance-token-write/placement-guard.js
# Tags: scope:issue-specific, TL1, placement-guard, control-dir, path-normalization, win32
# Part of tests/hooks/feature-2434-placement-guard.sh (rules/coding/file-split.md);
# sourced by it — relies on its harness, $TMP and $GUARD_JS. Not run standalone.
# ── strict classifier cases (TL1) ──────────────────────────────────
# #2434 D7b / #1814 (user decision: strict): EVERY write under WORKFLOW_STATE_DIR is
# control-dir — own <sid>.json, other sessions' files, arbitrary names. WF == PLANS blocks.
# classifyPlacement / classifyBashPlacement are called directly with explicit dir env,
# so the dispatcher's fake-HOME juggling of WORKFLOW_STATE_DIR cannot leak in here.
ST_T="$TMP/strict"
mkdir -p "$ST_T/wf" "$ST_T/plans" "$ST_T/elsewhere" "$ST_T/wf-sibling" "$ST_T/same"

ST_GUARD="$(np "$GUARD_JS")"
ST_WF="$(np "$ST_T/wf")"
ST_PLANS="$(np "$ST_T/plans")"
ST_EW="$(np "$ST_T/elsewhere")"
ST_SID="sid-2434-strict"
ST_IS_WIN=0
command -v cygpath >/dev/null 2>&1 && ST_IS_WIN=1

# st_verdict <wf-env> <plans-env> <path> [workflowOff] -> classifyPlacement result or "null"
st_verdict() {
  WORKFLOW_STATE_DIR="$1" WORKFLOW_PLANS_DIR="$2" run_with_timeout 15 node -e '
const g = require(process.argv[1]);
const v = g.classifyPlacement(process.argv[2], { sid: process.argv[3], wsid: process.argv[3], workflowOff: process.argv[4] === "1" });
process.stdout.write(String(v));
' "$ST_GUARD" "$3" "$ST_SID" "${4:-0}" 2>&1
}

# st_bash_verdict <wf-env> <plans-env> <command> -> classifyBashPlacement result or "null"
st_bash_verdict() {
  WORKFLOW_STATE_DIR="$1" WORKFLOW_PLANS_DIR="$2" run_with_timeout 15 node -e '
const g = require(process.argv[1]);
process.stdout.write(String(g.classifyBashPlacement(process.argv[2], { sid: process.argv[3], wsid: process.argv[3] })));
' "$ST_GUARD" "$3" "$ST_SID" 2>&1
}

st_expect() {  # <case-label> <want> <got>
  if [ "$3" = "$2" ]; then pass "$1"; else fail "$1" "want=$2 got=$3"; fi
}

case_begin "arbitrary-file-under-wf-blocked" "hooks/block-clearance-token-write/placement-guard.js"
st_expect "arbitrary-file-under-wf-blocked/top-level" control-dir "$(st_verdict "$ST_WF" "$ST_PLANS" "$ST_WF/notes.txt")"
st_expect "arbitrary-file-under-wf-blocked/nested" control-dir "$(st_verdict "$ST_WF" "$ST_PLANS" "$ST_WF/sub/dir/scratch.md")"
case_end

case_begin "other-session-file-blocked" "hooks/block-clearance-token-write/placement-guard.js"
st_expect "other-session-file-blocked/state-json" control-dir "$(st_verdict "$ST_WF" "$ST_PLANS" "$ST_WF/other-sid-9.json")"
st_expect "other-session-file-blocked/control-file" control-dir "$(st_verdict "$ST_WF" "$ST_PLANS" "$ST_WF/other-sid-9.control/codex-rounds.txt")"
case_end

case_begin "own-sid-json-blocked" "hooks/block-clearance-token-write/placement-guard.js"
st_expect "own-sid-json-blocked/state-json" control-dir "$(st_verdict "$ST_WF" "$ST_PLANS" "$ST_WF/$ST_SID.json")"
st_expect "own-sid-json-blocked/own-control-file" control-dir "$(st_verdict "$ST_WF" "$ST_PLANS" "$ST_WF/$ST_SID.control/wi-checkpoint.json")"
case_end

case_begin "outside-wf-unaffected" "hooks/block-clearance-token-write/placement-guard.js"
st_expect "outside-wf-unaffected/elsewhere" null "$(st_verdict "$ST_WF" "$ST_PLANS" "$ST_EW/notes.txt")"
# Prefix boundary: <wf>-sibling shares the string prefix but is not under <wf>/.
st_expect "outside-wf-unaffected/prefix-sibling" null "$(st_verdict "$ST_WF" "$ST_PLANS" "$(np "$ST_T/wf-sibling")/notes.txt")"
st_expect "outside-wf-unaffected/wf-dir-itself" null "$(st_verdict "$ST_WF" "$ST_PLANS" "$ST_WF")"
st_expect "outside-wf-unaffected/registered-plans-artifact" null "$(st_verdict "$ST_WF" "$ST_PLANS" "$ST_PLANS/$ST_SID-intent.md")"
case_end

# Classifier counterpart: the same targets lift under WORKFLOW=off, so a guard that
# returned control-dir unconditionally could not pass both halves.
case_begin "workflow-off-lifts" "hooks/block-clearance-token-write/placement-guard.js"
st_expect "workflow-off-lifts/arbitrary" null "$(st_verdict "$ST_WF" "$ST_PLANS" "$ST_WF/notes.txt" 1)"
st_expect "workflow-off-lifts/own-sid-json" null "$(st_verdict "$ST_WF" "$ST_PLANS" "$ST_WF/$ST_SID.json" 1)"
case_end

case_begin "wf-equals-plans-blocks" "hooks/block-clearance-token-write/placement-guard.js"
ST_SAME="$(np "$ST_T/same")"
# Unsupported configuration: the workflow-dir check wins, so even a registered prose
# artifact is refused rather than silently accepted as plans content.
st_expect "wf-equals-plans-blocks/registered-artifact" control-dir "$(st_verdict "$ST_SAME" "$ST_SAME" "$ST_SAME/$ST_SID-intent.md")"
st_expect "wf-equals-plans-blocks/control-name" control-dir "$(st_verdict "$ST_SAME" "$ST_SAME" "$ST_SAME/$ST_SID-codex-rounds.txt")"
case_end

case_begin "spelling-normalization" "hooks/block-clearance-token-write/placement-guard.js"
# Shared rows: `..` must be resolved before the containment test, in both directions.
# ST_EW and ST_WF are siblings under ST_T, so elsewhere/../wf lands inside wf and
# wf/../elsewhere lands outside it — a raw string-prefix match gets both wrong.
st_expect "spelling-normalization/dot-escape-into-wf" control-dir "$(st_verdict "$ST_WF" "$ST_PLANS" "$ST_EW/../wf/notes.txt")"
st_expect "spelling-normalization/dot-escape-out-of-wf" null "$(st_verdict "$ST_WF" "$ST_PLANS" "$ST_WF/../elsewhere/notes.txt")"
if [ "$ST_IS_WIN" = "1" ]; then
  st_expect "spelling-normalization/backslash-path" control-dir "$(st_verdict "$ST_WF" "$ST_PLANS" "$(cygpath -w "$ST_T/wf")\\notes.txt")"
  st_expect "spelling-normalization/msys-path" control-dir "$(st_verdict "$ST_WF" "$ST_PLANS" "$(cygpath -u "$ST_T/wf")/notes.txt")"
  st_expect "spelling-normalization/upper-case-path" control-dir "$(st_verdict "$ST_WF" "$ST_PLANS" "${ST_WF^^}/NOTES.TXT")"
  st_expect "spelling-normalization/msys-env" control-dir "$(st_verdict "$(cygpath -u "$ST_T/wf")" "$ST_PLANS" "$ST_WF/notes.txt")"
  st_expect "spelling-normalization/backslash-env" control-dir "$(st_verdict "$(cygpath -w "$ST_T/wf")" "$ST_PLANS" "$ST_WF/notes.txt")"
  st_expect "spelling-normalization/msys-outside" null "$(st_verdict "$ST_WF" "$ST_PLANS" "$(cygpath -u "$ST_T/elsewhere")/notes.txt")"
  st_expect "spelling-normalization/backslash-outside" null "$(st_verdict "$ST_WF" "$ST_PLANS" "$(cygpath -w "$ST_T/elsewhere")\\notes.txt")"
else
  st_expect "spelling-normalization/trailing-slash-env" control-dir "$(st_verdict "$ST_WF/" "$ST_PLANS" "$ST_WF/notes.txt")"
  st_expect "spelling-normalization/dot-segments" control-dir "$(st_verdict "$ST_WF" "$ST_PLANS" "$ST_WF/sub/../notes.txt")"
fi
case_end

case_begin "bash-redirect-into-wf" "hooks/block-clearance-token-write/placement-guard.js"
st_expect "bash-redirect-into-wf/arbitrary" control-dir "$(st_bash_verdict "$ST_WF" "$ST_PLANS" "echo x > $ST_WF/notes.txt")"
st_expect "bash-redirect-into-wf/other-session" control-dir "$(st_bash_verdict "$ST_WF" "$ST_PLANS" "cp /dev/null $ST_WF/other-sid-9.json")"
st_expect "bash-redirect-into-wf/outside" null "$(st_bash_verdict "$ST_WF" "$ST_PLANS" "echo x > $ST_EW/notes.txt")"
case_end

# Each spelling bash can turn one raw target into (placement-guard/bash-candidates.js,
# reached through placement-guard.js) is a BLOCK row with an allow twin whose only
# difference is a target outside the workflow dir.
case_begin "bash-brace-expansion-into-wf" "hooks/block-clearance-token-write/placement-guard.js"
st_expect "bash-brace-expansion-into-wf/both-members" control-dir "$(st_bash_verdict "$ST_WF" "$ST_PLANS" "touch {$ST_WF/a,$ST_WF/b}")"
st_expect "bash-brace-expansion-into-wf/prefix-alternation" control-dir "$(st_bash_verdict "$ST_WF" "$ST_PLANS" "touch {$ST_WF,/tmp}/x")"
st_expect "bash-brace-expansion-into-wf/outside-twin" null "$(st_bash_verdict "$ST_WF" "$ST_PLANS" "touch {$ST_EW/a,$ST_EW/b}")"
case_end

case_begin "bash-ansi-c-redirect-into-wf" "hooks/block-clearance-token-write/placement-guard.js"
st_expect "bash-ansi-c-redirect-into-wf/block" control-dir "$(st_bash_verdict "$ST_WF" "$ST_PLANS" "echo x > \$'$ST_WF/x'")"
st_expect "bash-ansi-c-redirect-into-wf/outside-twin" null "$(st_bash_verdict "$ST_WF" "$ST_PLANS" "echo x > \$'$ST_EW/x'")"
case_end

case_begin "bash-assigned-var-target-into-wf" "hooks/block-clearance-token-write/placement-guard.js"
st_expect "bash-assigned-var-target-into-wf/block" control-dir "$(st_bash_verdict "$ST_WF" "$ST_PLANS" "X=$ST_WF/x; echo hi > \"\$X\"")"
st_expect "bash-assigned-var-target-into-wf/outside-twin" null "$(st_bash_verdict "$ST_WF" "$ST_PLANS" "X=$ST_EW/x; echo hi > \"\$X\"")"
case_end

case_begin "interpreter-body-into-wf" "hooks/block-clearance-token-write/placement-guard.js"
st_expect "interpreter-body-into-wf/node-e" control-dir \
  "$(st_bash_verdict "$ST_WF" "$ST_PLANS" "node -e \"require('fs').writeFileSync('$ST_WF/x','y')\"")"
st_expect "interpreter-body-into-wf/python-c" control-dir \
  "$(st_bash_verdict "$ST_WF" "$ST_PLANS" "python -c \"open('$ST_WF/x','w').write('y')\"")"
st_expect "interpreter-body-into-wf/bash-c" control-dir "$(st_bash_verdict "$ST_WF" "$ST_PLANS" "bash -c 'echo y > $ST_WF/x'")"
st_expect "interpreter-body-into-wf/node-e-outside-twin" null \
  "$(st_bash_verdict "$ST_WF" "$ST_PLANS" "node -e \"require('fs').writeFileSync('$ST_EW/x','y')\"")"
st_expect "interpreter-body-into-wf/python-c-outside-twin" null \
  "$(st_bash_verdict "$ST_WF" "$ST_PLANS" "python -c \"open('$ST_EW/x','w').write('y')\"")"
st_expect "interpreter-body-into-wf/bash-c-outside-twin" null "$(st_bash_verdict "$ST_WF" "$ST_PLANS" "bash -c 'echo y > $ST_EW/x'")"
case_end
