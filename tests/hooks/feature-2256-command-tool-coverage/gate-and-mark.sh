#!/usr/bin/env bash
# tests/hooks/feature-2256-command-tool-coverage/gate-and-mark.sh
# Tests: hooks/workflow-gate.js, hooks/workflow-mark.js, hooks/lib/tool-command-text.js
# Tags: supervisor, command-tool, sentinel, TR5, premerge, workflow-mark, TL2, scope:issue-specific
# #2256 round-2 C1: the TR5 sentinel path, the chain guard, the merge backstop and the
# workflow-mark recording must all behave identically across the command tools.

# Parent: tests/hooks/feature-2256-command-tool-coverage.sh

set -uo pipefail
# shellcheck source=./_common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

repo="$(mk_repo gate)"
git -C "$WORK/gate" checkout -q -b feature/ct-cover
SID="ctcover"
printf '# intent\ni\n' > "$WORK/plans/$SID-intent.md"
printf '# outline\no\n' > "$WORK/plans/$SID-outline.md"
printf '# detail\nd\n\n## Files to modify\n\n- seed.txt\n' > "$WORK/plans/$SID-detail.md"

fresh_key() {
    FP="$FP_NODE" RCWD="$repo" PLANS="$WORK_NODE/plans" SESS="$SID" node -e "
const fp = require(process.env.FP);
const r = fp.computeFreshnessKey(process.env.RCWD, process.env.PLANS, process.env.SESS);
process.stdout.write(String((r && r.freshness_key) || 'null'));
" 2>&1
}

# seed_audit <verdict> <freshness-key> — one terminal TR5 run in the ledger.
seed_audit() {
    WR="$WRITER_NODE" SC="$SCHEMA_NODE" SESS="$SID" VERDICT="$1" FK="$2" node -e "
const writer = require(process.env.WR);
const schema = require(process.env.SC);
const fs = require('fs');
const st = schema.createEmptyState(process.env.SESS);
st.audit.ledger = [{
  id: 'run-0007', outcome: 'terminal', tr_ids: ['TR5'], cause: 'step-complete:user_verification',
  verdict: process.env.VERDICT, freshness_key: process.env.FK,
  sub_checks: ['recurrence-patterns'], input_key: { 'recurrence-patterns': process.env.FK },
}];
st.audit.last_terminal_run_id = 'run-0007';
st.audit.audit_verdict_summary = process.env.VERDICT;
fs.writeFileSync(writer.getStatePath(process.env.SESS), JSON.stringify(st));
" 2>&1
}

# gate_decision <shape> <command> — the workflow-gate decision for that shape.
gate_decision() {
    local p; p="$(payload "$1" "$2" "$repo" "$SID")"
    jfield "$(run_hook workflow-gate.js "$p")" decision
}

FK="$(fresh_key)"

# --- 1-4: an unresolved BLOCK hold denies the sentinel in every shape ---
seed_audit BLOCK "$FK" >/dev/null
for s in $SHAPES; do
    assert_eq "1-4 ($s): an unresolved TR5 BLOCK hold denies the USER_VERIFIED sentinel" \
        "$(gate_decision "$s" "$SENTINEL_UV")" "block"
done

# --- 5: the deny reason names the hold rather than falling through to a generic error ---
p="$(payload rc1 "$SENTINEL_UV" "$repo" "$SID")"
reason="$(jfield "$(run_hook workflow-gate.js "$p")" reason)"
assert_match "5: the rc1 deny reason names the BLOCK hold" "$reason" 'BLOCK|USER_VERIFIED|TR5'

# --- 6-9: a settled non-BLOCK run lets the sentinel through in every shape ---
seed_audit CONTINUE "$FK" >/dev/null
for s in $SHAPES; do
    assert_eq "6-9 ($s): a fresh non-BLOCK TR5 run approves the USER_VERIFIED sentinel" \
        "$(gate_decision "$s" "$SENTINEL_UV")" "approve"
done

# --- 10-13: the sentinel chain guard fires identically in every shape ---
CHAIN="$SENTINEL_UV"' && rm -rf ./scratch'
for s in $SHAPES; do
    assert_eq "10-13 ($s): a sentinel chained with a non-sentinel is blocked" \
        "$(gate_decision "$s" "$CHAIN")" "block"
done

# --- 14: a runCommands call mixing a sentinel element with an unrelated one is all-or-nothing ---
p="$(payload rcmix "$SENTINEL_UV" "$repo" "$SID" "" "rm -rf ./scratch")"
assert_eq "14: a mixed sentinel/non-sentinel runCommands tool call is judged as one unit" \
    "$(jfield "$(run_hook workflow-gate.js "$p")" decision)" "block"

# --- 15-18: the pre-merge backstop is reached from every shape ---
seed_audit BLOCK "$FK" >/dev/null
MERGE='gh pr merge 123 --squash --delete-branch'
for s in $SHAPES; do
    assert_eq "15-18 ($s): a merge command reaches the pre-merge backstop and is denied" \
        "$(gate_decision "$s" "$MERGE")" "block"
done

# --- 19: the backstop deny names its own cause, not the sentinel hold ---
p="$(payload rc1 "$MERGE" "$repo" "$SID")"
assert_match "19: the merge deny reason carries the freshness-backstop cause" \
    "$(jfield "$(run_hook workflow-gate.js "$p")" reason)" 'freshness-backstop'

# --- 20-21: non-command tools are untouched by the sentinel path ---
p="$(payload edit "$WORK_NODE/gate/seed.txt" "$repo" "$SID" "" "$SENTINEL_UV")"
assert_nomatch "20: an Edit carrying sentinel text in new_string never enters the sentinel path" \
    "$(run_hook workflow-gate.js "$p")" 'USER_VERIFIED'
p="$(payload write "$WORK_NODE/gate/note.txt" "$repo" "$SID" "" "$SENTINEL_UV")"
assert_nomatch "21: a Write carrying sentinel text in content never enters the sentinel path" \
    "$(run_hook workflow-gate.js "$p")" 'USER_VERIFIED'

# --- 22-25: workflow-mark records user_verification from every shape ---
mark_status() {
    local sid="$1"
    PROBE_SID="$sid" PROBE_STEP="user_verification" PROBE_FIELD="status" \
        node "$PROBE" field 2>&1
}
i=0
for s in $SHAPES; do
    i=$((i + 1))
    msid="ctmark$i"
    p="$(payload "$s" "$SENTINEL_UV" "$repo" "$msid" 0)"
    run_hook workflow-mark.js "$p" >/dev/null
    assert_match "22-25 ($s): workflow-mark records user_verification as complete" \
        "$(mark_status "$msid")" '"complete"'
done

# --- 26: a non-zero exit code records nothing, in the rc1 shape too ---
p="$(payload rc1 "$SENTINEL_UV" "$repo" "ctmarkfail" 1)"
run_hook workflow-mark.js "$p" >/dev/null
assert_nomatch "26: a failed rc1 sentinel call records no verification" \
    "$(mark_status ctmarkfail)" '"complete"'

# --- 27: the all-or-nothing judgement widens to the whole runCommands tool call ---
p="$(payload rcmix "$SENTINEL_UV" "$repo" "ctmarkmix" 0 "rm -rf ./scratch")"
run_hook workflow-mark.js "$p" >/dev/null
assert_nomatch "27: a mixed runCommands call records no verification (all-or-nothing)" \
    "$(mark_status ctmarkmix)" '"complete"'

# --- 28-29: a merge command placed BEFORE the sentinel in one runCommands is blocked
# by the hasMergeInCall guard (workflow-gate.js:199-206), even under a fresh CONTINUE
# TR5 that would otherwise approve the sentinel. Cases 10-14 only ever reach a block
# via the &&-chain guard or an audit hold; none reach hasMergeInCall. Seeding
# CONTINUE+fresh means the audit gate would approve, so the block here can only come
# from the leading-merge guard (#2256 C33 leading-merge bypass). rc1 puts LEAD first,
# so the merge precedes the sentinel in the array. ---
seed_audit CONTINUE "$FK" >/dev/null
p="$(payload rc1 "$SENTINEL_UV" "$repo" "$SID" "" "gh pr merge 123 --squash")"
out="$(run_hook workflow-gate.js "$p")"
assert_eq "28: a merge command in the same runCommands as the sentinel is blocked" \
    "$(jfield "$out" decision)" "block"
assert_match "29: the block names the merge-command-in-same-runCommands condition" \
    "$(jfield "$out" reason)" 'merge command in the same runCommands'

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
