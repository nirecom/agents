#!/usr/bin/env bash
# tests/hooks/feature-2256-command-tool-coverage/sibling-hooks.sh
# Tests: hooks/confirm-checkpoint.js, hooks/gate-plan-skip-sentinel.js
# Tests: hooks/show-user-verified-context.js, hooks/supervisor-trigger.js
# Tags: supervisor, command-tool, sentinel, orthogonality, TL2, scope:issue-specific
# #2256 S5-a2: the remaining four hooks move off the literal Bash tool-name test,
# so each must answer identically when its own sentinel arrives as commands[1].

# Parent: tests/hooks/feature-2256-command-tool-coverage.sh

set -uo pipefail
# shellcheck source=./_common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

repo="$(mk_repo sib)"
SID="ctsib"

# --- 1-4: confirm-checkpoint surfaces the CONFIRM_DETAIL checkpoint from every shape ---
CONFIRM_DETAIL_SENTINEL='echo "<<WORKFLOW_CONFIRM_DETAIL: detail plan ready for review>>"'
export CONFIRM_DETAIL=off
for s in $SHAPES; do
    p="$(payload "$s" "$CONFIRM_DETAIL_SENTINEL" "$repo" "$SID")"
    assert_match "1-4 ($s): confirm-checkpoint sees the CONFIRM_DETAIL sentinel" \
        "$(run_hook confirm-checkpoint.js "$p")" 'confirm-skipped: CONFIRM_DETAIL=off'
done

# --- 5: a non-command tool still produces no checkpoint output ---
p="$(payload edit "$WORK_NODE/sib/seed.txt" "$repo" "$SID" "" "$CONFIRM_DETAIL_SENTINEL")"
assert_eq "5: an Edit carrying the CONFIRM sentinel as text produces no checkpoint" \
    "$(run_hook confirm-checkpoint.js "$p")" ""
unset CONFIRM_DETAIL

# --- 6-9: gate-plan-skip-sentinel auto-approves the outline skip from every shape ---
OUTLINE_SKIP='echo "<<WORKFLOW_OUTLINE_NOT_NEEDED: single-file change with no design choice>>"'
export CONFIRM_OUTLINE=off
for s in $SHAPES; do
    p="$(payload "$s" "$OUTLINE_SKIP" "$repo" "$SID")"
    out="$(run_hook gate-plan-skip-sentinel.js "$p")"
    assert_match "6-9 ($s): the outline-skip sentinel is auto-approved" \
        "$(jfield "$out" hookSpecificOutput.permissionDecision)" '^allow$'
done

# --- 10: an unrelated command in the same shapes still passes through ---
p="$(payload rc1 "git status --short" "$repo" "$SID")"
assert_nomatch "10: a non-sentinel rc1 call is not auto-approved" \
    "$(jfield "$(run_hook gate-plan-skip-sentinel.js "$p")" hookSpecificOutput.permissionDecision)" '^allow$'
unset CONFIRM_OUTLINE

# --- 11-14: show-user-verified-context surfaces the context from every shape ---
for s in $SHAPES; do
    p="$(payload "$s" "$SENTINEL_UV" "$repo" "$SID")"
    assert_match "11-14 ($s): the user-verification context message is emitted" \
        "$(run_hook show-user-verified-context.js "$p")" 'User verification context:'
done

# --- 15: the same hook stays silent for a non-command tool ---
p="$(payload write "$WORK_NODE/sib/note.txt" "$repo" "$SID" "" "$SENTINEL_UV")"
assert_eq "15: a Write carrying the sentinel as content emits no context message" \
    "$(run_hook show-user-verified-context.js "$p")" ""

# --- 16-19: supervisor-trigger emits its blocking-concern advisory from every shape ---
TSID="cttrig"
WR="$WRITER_NODE" SC="$SCHEMA_NODE" SESS="$TSID" node -e "
const writer = require(process.env.WR);
const schema = require(process.env.SC);
const fs = require('fs');
const st = schema.createEmptyState(process.env.SESS);
st.alert = Object.assign({}, st.alert, { cumulative_severity: 'error' });
st.layer1 = st.layer1 || { findings: [] };
st.layer1.findings = [{
  severity: 'error', categories: ['workflow'], detail: 'blocking concern fixture',
}];
fs.writeFileSync(writer.getStatePath(process.env.SESS), JSON.stringify(st));
" 2>&1
for s in $SHAPES; do
    p="$(payload "$s" "$SENTINEL_UV" "$repo" "$TSID")"
    assert_match "16-19 ($s): the EM Supervisor advisory reaches the transcript" \
        "$(run_hook supervisor-trigger.js "$p")" 'EM Supervisor'
done

# --- 20: a non-command tool still gets no advisory ---
p="$(payload edit "$WORK_NODE/sib/seed.txt" "$repo" "$TSID" "" "$SENTINEL_UV")"
assert_eq "20: an Edit tool call receives no supervisor advisory" \
    "$(run_hook supervisor-trigger.js "$p")" ""

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
