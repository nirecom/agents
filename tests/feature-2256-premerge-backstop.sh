#!/usr/bin/env bash
# tests/feature-2256-premerge-backstop.sh
# Tests: hooks/workflow-gate/supervisor-check.js, hooks/workflow-gate.js
# Tags: supervisor, premerge, backstop, freshness-key, TL2, scope:issue-specific

# #2256 S5-e — the pre-merge gate loses every arming duty and degrades to a
# read-only freshness backstop: it allows a merge only when a terminal TR5 run
# exists whose freshness_key still matches and whose verdict is not BLOCK.

set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
nrm() { cygpath -m "$1" 2>/dev/null || printf '%s' "$1"; }
AGENTS_NODE="$(nrm "$AGENTS_DIR")"
HOOKS_NODE="$AGENTS_NODE/hooks"
FP_NODE="$HOOKS_NODE/lib/diff-fingerprint.js"
WRITER_NODE="$HOOKS_NODE/lib/supervisor-state-writer.js"
SCHEMA_NODE="$HOOKS_NODE/lib/supervisor-state-schema.js"
SUP_CHECK="$AGENTS_DIR/hooks/workflow-gate/supervisor-check.js"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1${2:+ — $2}"; FAIL=$((FAIL + 1)); }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected '$3', got '$2'"; fi; }
assert_match() {
    if printf '%s' "$2" | grep -Eq "$3"; then pass "$1"; else fail "$1" "'$2' does not match /$3/"; fi
}
assert_nomatch() {
    if printf '%s' "$2" | grep -Eq "$3"; then fail "$1" "'$2' unexpectedly matches /$3/"; else pass "$1"; fi
}

if ! command -v node >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
    fail "prerequisites" "node and git are both required — this suite drives the real gate"
    echo ""
    echo "=== Results: $PASS passed, $FAIL failed ==="
    exit 1
fi

WORK="$(mktemp -d 2>/dev/null || mktemp -d -t f2256bs)"
trap 'rm -rf "$WORK"' EXIT
WORK_NODE="$(nrm "$WORK")"
mkdir -p "$WORK/plans" "$WORK/wf" "$WORK/transcripts" "$WORK/cfg"
: > "$WORK/cfg/.env"
export CLAUDE_WORKFLOW_DIR="$WORK_NODE/wf"
export WORKFLOW_PLANS_DIR="$WORK_NODE/plans"
export CLAUDE_TRANSCRIPT_BASE_DIR="$WORK_NODE/transcripts"
export AGENTS_CONFIG_DIR="$WORK_NODE/cfg"
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_ENV_FILE
cd "$WORK" || exit 1

REPO="$WORK/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" config core.hooksPath /dev/null
git -C "$REPO" config core.autocrlf false
git -C "$REPO" config commit.gpgsign false
git -C "$REPO" config user.email t@example.invalid
git -C "$REPO" config user.name tester
printf 'seed\n' > "$REPO/seed.txt"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m seed
git -C "$REPO" checkout -q -b feature/backstop
REPO_NODE="$(nrm "$REPO")"

SID="bstop"
printf '# intent\ni1\n' > "$WORK/plans/$SID-intent.md"
printf '# outline\no1\n' > "$WORK/plans/$SID-outline.md"
printf '# detail\nd1\n\n## Files to modify\n\n- seed.txt\n' > "$WORK/plans/$SID-detail.md"

MERGE_CMD='gh pr merge 42 --squash --delete-branch'

fresh_key() {
    FP="$FP_NODE" RCWD="$REPO_NODE" PLANS="$WORK_NODE/plans" SESS="$SID" node -e "
const fp = require(process.env.FP);
const r = fp.computeFreshnessKey(process.env.RCWD, process.env.PLANS, process.env.SESS);
process.stdout.write(String((r && r.freshness_key) || 'null'));
" 2>&1
}
input_version() {
    FP="$FP_NODE" RCWD="$REPO_NODE" node -e "
const fp = require(process.env.FP);
process.stdout.write(String(fp.computeInputVersion(process.env.RCWD) || 'null'));
" 2>&1
}

# seed_state <verdict> <freshness-key> <tr-ids-json> — one terminal run, or none at all.
seed_state() {
    WR="$WRITER_NODE" SC="$SCHEMA_NODE" SESS="$SID" VERDICT="$1" FK="$2" TRS="${3:-[\"TR5\"]}" node -e "
const writer = require(process.env.WR);
const schema = require(process.env.SC);
const fs = require('fs');
const st = schema.createEmptyState(process.env.SESS);
if (process.env.VERDICT !== 'NONE') {
  st.audit.ledger = [{
    id: 'run-0011', outcome: 'terminal', cause: 'step-complete:user_verification',
    tr_ids: JSON.parse(process.env.TRS), verdict: process.env.VERDICT,
    freshness_key: process.env.FK, sub_checks: ['recurrence-patterns'],
    input_key: { 'recurrence-patterns': process.env.FK },
  }];
  st.audit.last_terminal_run_id = 'run-0011';
  st.audit.audit_verdict_summary = process.env.VERDICT;
}
fs.writeFileSync(writer.getStatePath(process.env.SESS), JSON.stringify(st));
" 2>&1
}

# seed_two_run <tr5-verdict> <fkey> <tr6-verdict> — a terminal TR5 run then a
# LATER terminal TR6 run at the same freshness_key. Exercises hasLaterTerminalBlock
# in supervisor-check.js (a later BLOCK that postdates a fresh non-BLOCK TR5).
seed_two_run() {
    WR="$WRITER_NODE" SC="$SCHEMA_NODE" SESS="$SID" V5="$1" FK="$2" V6="$3" node -e "
const writer = require(process.env.WR);
const schema = require(process.env.SC);
const fs = require('fs');
const st = schema.createEmptyState(process.env.SESS);
st.audit.ledger = [
  { id: 'run-0011', outcome: 'terminal', cause: 'step-complete:user_verification',
    tr_ids: ['TR5'], verdict: process.env.V5, freshness_key: process.env.FK,
    sub_checks: ['recurrence-patterns'], input_key: { 'recurrence-patterns': process.env.FK } },
  { id: 'run-0012', outcome: 'terminal', cause: 'step-complete:user_verification',
    tr_ids: ['TR6'], verdict: process.env.V6, freshness_key: process.env.FK,
    sub_checks: ['recurrence-patterns'], input_key: { 'recurrence-patterns': process.env.FK } },
];
st.audit.last_terminal_run_id = 'run-0012';
st.audit.audit_verdict_summary = process.env.V6;
fs.writeFileSync(writer.getStatePath(process.env.SESS), JSON.stringify(st));
" 2>&1
}

read_state_field() {
    WR="$WRITER_NODE" SESS="$SID" RSPATH="$1" node -e "
const writer = require(process.env.WR);
let v;
try { v = writer.readState(process.env.SESS); } catch (e) { process.stdout.write('read-error'); process.exit(0); }
for (const k of process.env.RSPATH.split('.')) v = v === null || v === undefined ? undefined : v[k];
process.stdout.write(v === undefined ? 'none' : (typeof v === 'object' ? JSON.stringify(v) : String(v)));
" 2>&1
}

gate() {
    local cmd="$1"
    CMDTEXT="$cmd" RCWD="$REPO_NODE" SESS="$SID" node -e "
process.stdout.write(JSON.stringify({
  tool_name: 'Bash',
  tool_input: { command: process.env.CMDTEXT, cwd: process.env.RCWD },
  session_id: process.env.SESS,
}));
" 2>/dev/null | bash "$RWT" 60 node "$AGENTS_DIR/hooks/workflow-gate.js" 2>/dev/null
}
decision_of() {
    JBODY="$1" node -e "
let o; try { o = JSON.parse(process.env.JBODY); } catch (e) { o = null; }
process.stdout.write(o ? String(o.decision || 'none') : 'parse-error');
"
}
reason_of() {
    JBODY="$1" node -e "
let o; try { o = JSON.parse(process.env.JBODY); } catch (e) { o = null; }
process.stdout.write(o ? String(o.reason || '') : 'parse-error');
"
}

FK="$(fresh_key)"
IV_BASE="$(input_version)"

# --- 1-4: the gate never arms anything, whatever it finds ---
seed_state NONE "$FK" >/dev/null
printf 'undeclared\n' > "$REPO/stray.txt"
out="$(gate "$MERGE_CMD")"
assert_eq "1: a denied merge leaves audit_phase untouched" "$(read_state_field audit.audit_phase)" "null"
assert_eq "2: a denied merge appends no ledger entry" "$(read_state_field audit.ledger)" "[]"
assert_eq "3: a denied merge sets no audit_run_id" "$(read_state_field audit.audit_run_id)" "none"
assert_eq "4: an undeclared file present at merge time still arms nothing" \
    "$(read_state_field audit.audit_dispatched_at)" "none"
rm -f "$REPO/stray.txt"

# --- 5-7: the three deny branches ---
seed_state NONE "$FK" >/dev/null
assert_eq "5: no terminal TR5 run at all denies the merge" "$(decision_of "$(gate "$MERGE_CMD")")" "block"

seed_state CONTINUE "stale0000000000000000000000000000000000000000000000000000000000" >/dev/null
assert_eq "6: a terminal TR5 run with a stale freshness_key denies the merge" \
    "$(decision_of "$(gate "$MERGE_CMD")")" "block"

seed_state BLOCK "$FK" >/dev/null
assert_eq "7: a fresh but BLOCK verdict denies the merge" "$(decision_of "$(gate "$MERGE_CMD")")" "block"

# --- 8-9: Path (i-b) records the bypass attempt as an error finding ---
findings="$(read_state_field layer1.findings)"
assert_match "8: the BLOCK deny appends a finding" "$findings" '"severity"'
assert_match "9: that finding is severity=error and names the bypassed TR5 hold" \
    "$findings" '"severity":"error"'

# --- 10: a fresh non-BLOCK terminal TR5 run allows the merge ---
seed_state CONTINUE "$FK" >/dev/null
assert_eq "10: a fresh non-BLOCK TR5 run allows the merge" \
    "$(decision_of "$(gate "$MERGE_CMD")")" "approve"

# --- 11-13: a plan-artifact edit alone re-closes the gate (input_version unchanged) ---
printf '# detail\nd2\n\n## Files to modify\n\n- seed.txt\n' > "$WORK/plans/$SID-detail.md"
assert_eq "11: editing detail.md leaves input_version unchanged" "$(input_version)" "$IV_BASE"
out="$(gate "$MERGE_CMD")"
assert_eq "12: editing detail.md alone re-denies the merge" "$(decision_of "$out")" "block"
assert_match "13: the deny message names detail as the component that moved" \
    "$(reason_of "$out")" 'detail'

# --- 14-15: the same holds for outline.md and intent.md ---
printf '# detail\nd1\n\n## Files to modify\n\n- seed.txt\n' > "$WORK/plans/$SID-detail.md"
printf '# outline\no2\n' > "$WORK/plans/$SID-outline.md"
out="$(gate "$MERGE_CMD")"
assert_match "14: the deny message names outline as the component that moved" \
    "$(reason_of "$out")" 'outline'
printf '# outline\no1\n' > "$WORK/plans/$SID-outline.md"
printf '# intent\ni2\n' > "$WORK/plans/$SID-intent.md"
assert_match "15: the deny message names intent as the component that moved" \
    "$(reason_of "$(gate "$MERGE_CMD")")" 'intent'
printf '# intent\ni1\n' > "$WORK/plans/$SID-intent.md"

# --- 16-17: a code change moves it too, and the message says so ---
printf 'seed-changed\n' > "$REPO/seed.txt"
out="$(gate "$MERGE_CMD")"
assert_eq "16: a code change after the verdict re-denies the merge" "$(decision_of "$out")" "block"
assert_match "17: the deny message names the code diff as the component that moved" \
    "$(reason_of "$out")" 'code|diff|input_version'
printf 'seed\n' > "$REPO/seed.txt"

# --- 18: the deny carries the backstop's own cause label ---
seed_state NONE "$FK" >/dev/null
assert_match "18: the deny reason carries the freshness-backstop:pre-merge cause" \
    "$(reason_of "$(gate "$MERGE_CMD")")" 'freshness-backstop:pre-merge'

# --- 22-24: a later terminal BLOCK postdating a fresh non-BLOCK TR5 denies the merge ---
# Guards supervisor-check.js:151-153 (hasLaterTerminalBlock at the pre-merge gate).
# Case 10 allows the merge on a fresh CONTINUE TR5; a later terminal BLOCK must flip
# it to a deny with the post-TR5 reason. Deleting lines 151-153 re-allows it (the
# case-10 path), so this case fails then. Self-contained — seeds its own ledger.
seed_two_run CONTINUE "$FK" BLOCK >/dev/null
out="$(gate "$MERGE_CMD")"
assert_eq "22: a later terminal BLOCK denies the merge despite a fresh CONTINUE TR5" \
    "$(decision_of "$out")" "block"
assert_match "23: the deny names the unresolved post-TR5 BLOCK" \
    "$(reason_of "$out")" 'later audit BLOCK verdict \(post-TR5\) is unresolved'
assert_eq "24: the denied merge still arms nothing" "$(read_state_field audit.audit_phase)" "null"

# --- 19-21: the retired arming paths are gone from the gate module ---
assert_absent() {
    if grep -Eq "$2" "$SUP_CHECK"; then
        fail "$1" "/$2/ is still present in $SUP_CHECK"
    else
        pass "$1"
    fi
}
if [ -f "$SUP_CHECK" ]; then
    assert_absent "19: pre-merge-warning-flush is retired from supervisor-check.js" \
        'pre-merge-warning-flush'
    assert_absent "20: scope-drift:pre-merge is retired from supervisor-check.js" \
        'scope-drift:pre-merge'
    assert_absent "21: the gate module no longer writes audit state" \
        'writeAuditState|armAuditRun'
else
    fail "19: pre-merge-warning-flush is retired from supervisor-check.js" "module missing"
    fail "20: scope-drift:pre-merge is retired from supervisor-check.js" "module missing"
    fail "21: the gate module no longer writes audit state" "module missing"
fi

# --- 25-27: a valid recorded BLOCK override lets the merge through the backstop ---
# The positive counterpart to case 7 (a fresh BLOCK denies the merge). Once the
# reviewer records an override for the exact run + freshness key, the read-only
# backstop must APPROVE the merge — arming nothing and appending no error finding.
# Deleting the override-release branch (supervisor-check.js:167-175) flips case 25 to
# a deny, so the positive path is what this case pins.
FK_OV="$(fresh_key)"
seed_state BLOCK "$FK_OV" >/dev/null
bash "$RWT" 60 node "$AGENTS_DIR/bin/supervisor-record-block-override" \
    run-0011 "verified manually with the reviewer; the BLOCK is a false positive here" \
    --session-id "$SID" >/dev/null 2>&1
out="$(gate "$MERGE_CMD")"
assert_eq "25: a valid recorded override approves the merge at the backstop" \
    "$(decision_of "$out")" "approve"
assert_eq "26: approving via the override arms no audit run" \
    "$(read_state_field audit.audit_phase)" "null"
assert_nomatch "27: the override-approved merge appends no error finding" \
    "$(read_state_field layer1.findings)" '"severity":"error"'

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -eq 0 ]; then
    echo "All tests passed."
    exit 0
fi
exit 1
