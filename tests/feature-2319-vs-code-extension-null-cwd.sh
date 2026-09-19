#!/usr/bin/env bash
# tests/feature-2319-vs-code-extension-null-cwd.sh
# Tests: hooks/workflow-gate.js, hooks/workflow-gate/supervisor-check.js, hooks/workflow-gate/user-verified-audit.js
# Tags: supervisor, tr5, freshness, premerge, null-cwd, vscode-extension, regression-2319, scope:issue-specific, pwsh-not-required, TL2
# #2319: an extension Bash tool sends no toolInput.cwd (null/absent/""); workflow-gate.js:178
# propagates null to both freshness consumers -> symptom 1 (TR5 infinite arm) + symptom 2
# (pre-merge fail-closed). SSOT fix: one freshnessCwd outside the sentinel branch, process.cwd()
# fallback. Rationale/loci: detail plan テスト計画 T1 + Steps 1-4. TDD (write_code not run): assertions
# target POST-fix; pre-fix each case FAILS (that RED is the evidence, do not weaken). TL3 gap: a real
# extension host omitting cwd is not exercised — this SIMULATES the shape, pinning process.cwd() via spawn-from-repo.

set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
nrm() { cygpath -m "$1" 2>/dev/null || printf '%s' "$1"; }
AGENTS_NODE="$(nrm "$AGENTS_DIR")"
HOOKS_NODE="$AGENTS_NODE/hooks"
FP_NODE="$HOOKS_NODE/lib/diff-fingerprint.js"
WRITER_NODE="$HOOKS_NODE/lib/supervisor-state-writer.js"
SCHEMA_NODE="$HOOKS_NODE/lib/supervisor-state-schema.js"
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

# fixture isolation: rules/test/fixture-isolation.md (dual-pin plans dir, unset session IDs).
WORK="$(mktemp -d 2>/dev/null || mktemp -d -t f2319)"
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

SID="ext2319"
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
git -C "$REPO" checkout -q -b feature/ext2319
REPO_NODE="$(nrm "$REPO")"

SENTINEL_UV='echo "<<WORKFLOW_USER_VERIFIED: verified the fix end to end in the app>>"'
MERGE_CMD='gh pr merge 42 --squash --delete-branch'
DETAIL_BODY='# detail

## Files to modify

- seed.txt
- extra.txt
'
write_plans() {
    printf '# intent\n%s\n' "${1:-i1}" > "$WORK/plans/$SID-intent.md"
    printf '# outline\n%s\n' "${2:-o1}" > "$WORK/plans/$SID-outline.md"
    printf '%s' "${3:-$DETAIL_BODY}" > "$WORK/plans/$SID-detail.md"
}
write_plans

fresh_key() {
    FP="$FP_NODE" RCWD="$REPO_NODE" PLANS="$WORK_NODE/plans" SESS="$SID" node -e "
const fp = require(process.env.FP);
const r = fp.computeFreshnessKey(process.env.RCWD, process.env.PLANS, process.env.SESS);
process.stdout.write(String((r && r.freshness_key) || 'null'));
" 2>/dev/null
}
input_version() {
    FP="$FP_NODE" RCWD="$REPO_NODE" node -e "
const fp = require(process.env.FP);
process.stdout.write(String(fp.computeInputVersion(process.env.RCWD) || 'null'));
" 2>/dev/null
}
artifact_key() {
    FP="$FP_NODE" PLANS="$WORK_NODE/plans" SESS="$SID" NAMES="$1" node -e "
const fp = require(process.env.FP);
const v = fp.computeArtifactKey(process.env.PLANS, process.env.SESS, process.env.NAMES.split(','));
process.stdout.write(String(v === null || v === undefined ? 'null' : v));
" 2>/dev/null
}

# A terminal TR5 CONTINUE run settled against the current tree + plan artifacts —
# the shape the audit gate approves without re-arming (mirrors the #2256 settled run).
settled_run() {
    IV="$(input_version)" \
    KI="$(artifact_key intent)" \
    KIO="$(artifact_key intent,outline)" \
    KIOD="$(artifact_key intent,outline,detail)" \
    FK="$(fresh_key)" \
    DK="$(artifact_key detail)" node -e "
const e = process.env;
process.stdout.write(JSON.stringify({
  ledger: [{
    id: 'run-0021', outcome: 'terminal', cause: 'step-complete:user_verification',
    tr_ids: ['TR3', 'TR4', 'TR5'], verdict: 'CONTINUE', freshness_key: e.FK,
    input_version: e.IV,
    artifact_keys: { intent: e.KI, outline: e.KIO, detail: e.KIOD },
    sub_checks: ['intent-internal', 'intent-outline', 'outline-detail', 'detail-code',
      'scope-drift', 'systemic-risk', 'recurrence-patterns'],
    input_key: {
      'intent-internal': e.KI, 'intent-outline': e.KIO, 'outline-detail': e.KIOD,
      'detail-code': e.IV, 'scope-drift': e.IV, 'systemic-risk': e.IV,
      'recurrence-patterns': e.FK,
    },
  }],
  last_terminal_run_id: 'run-0021',
  audit_verdict_summary: 'CONTINUE',
  declared_files: { snapshot_at: '2026-01-01T00:00:00.000Z', run_id: 'run-0021',
    detail_key: e.DK, files: ['seed.txt', 'extra.txt'], truncated: false },
}));
"
}

# A single terminal TR5 CONTINUE run at the given freshness key (pre-merge backstop).
seed_continue() {
    WR="$WRITER_NODE" SC="$SCHEMA_NODE" SESS="$SID" FK="$1" node -e "
const writer = require(process.env.WR);
const schema = require(process.env.SC);
const fs = require('fs');
const st = schema.createEmptyState(process.env.SESS);
st.audit.ledger = [{
  id: 'run-0011', outcome: 'terminal', cause: 'step-complete:user_verification',
  tr_ids: ['TR5'], verdict: 'CONTINUE', freshness_key: process.env.FK,
  sub_checks: ['recurrence-patterns'], input_key: { 'recurrence-patterns': process.env.FK },
}];
st.audit.last_terminal_run_id = 'run-0011';
st.audit.audit_verdict_summary = 'CONTINUE';
fs.writeFileSync(writer.getStatePath(process.env.SESS), JSON.stringify(st));
" 2>&1
}

seed_settled() {
    WR="$WRITER_NODE" SC="$SCHEMA_NODE" SESS="$SID" PATCHJSON="$(settled_run)" node -e "
const writer = require(process.env.WR);
const schema = require(process.env.SC);
const fs = require('fs');
const st = schema.createEmptyState(process.env.SESS);
Object.assign(st.audit, JSON.parse(process.env.PATCHJSON));
fs.writeFileSync(writer.getStatePath(process.env.SESS), JSON.stringify(st));
" 2>&1
}

state_field() {
    WR="$WRITER_NODE" SESS="$SID" RSPATH="$1" node -e "
const writer = require(process.env.WR);
let v;
try { v = writer.readState(process.env.SESS); } catch (e) { process.stdout.write('read-error'); process.exit(0); }
for (const k of process.env.RSPATH.split('.')) v = v === null || v === undefined ? undefined : v[k];
process.stdout.write(v === undefined ? 'none' : (typeof v === 'object' ? JSON.stringify(v) : String(v)));
" 2>&1
}

# gate_ext <cwd-mode> <command> — spawn the REAL gate FROM $REPO (so process.cwd()
# is the worktree) with an extension-shaped payload. cwd-mode: absent | null | empty.
gate_ext() {
    local mode="$1" cmd="$2" payload
    payload="$(CMDTEXT="$cmd" MODE="$mode" SESS="$SID" node -e "
const ti = { command: process.env.CMDTEXT };
if (process.env.MODE === 'null') ti.cwd = null;
else if (process.env.MODE === 'empty') ti.cwd = '';
process.stdout.write(JSON.stringify({ tool_name: 'Bash', tool_input: ti, session_id: process.env.SESS }));
")"
    ( cd "$REPO" && printf '%s' "$payload" | bash "$RWT" 60 node "$AGENTS_DIR/hooks/workflow-gate.js" 2>/dev/null )
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

# Symptom 1 — the USER_VERIFIED audit gate must not infinite-arm on a null cwd.
for mode in absent null empty; do
    seed_settled >/dev/null
    out="$(gate_ext "$mode" "$SENTINEL_UV")"
    assert_eq "S1-$mode: settled TR5 approves the sentinel despite a $mode cwd" \
        "$(decision_of "$out")" "approve"
    assert_eq "S1-$mode: approving the sentinel arms no re-audit (no infinite loop)" \
        "$(state_field audit.audit_phase)" "null"
done

# Infinite-loop regression: re-issuing after it settles keeps approving.
seed_settled >/dev/null
d1="$(decision_of "$(gate_ext null "$SENTINEL_UV")")"
d2="$(decision_of "$(gate_ext null "$SENTINEL_UV")")"
d3="$(decision_of "$(gate_ext null "$SENTINEL_UV")")"
assert_eq "S1-loop: 1st re-issue approves under null cwd" "$d1" "approve"
assert_eq "S1-loop: 2nd re-issue approves under null cwd" "$d2" "approve"
assert_eq "S1-loop: 3rd re-issue approves — no arm/deny ping-pong" "$d3" "approve"

# Symptom 2 — the pre-merge backstop must reach freshness, not fail-closed.
FK="$(fresh_key)"
for mode in absent null empty; do
    seed_continue "$FK" >/dev/null
    out="$(gate_ext "$mode" "$MERGE_CMD")"
    assert_eq "S2-$mode: a fresh CONTINUE TR5 allows the merge despite a $mode cwd" \
        "$(decision_of "$out")" "approve"
    assert_nomatch "S2-$mode: the merge never falls into the fail-closed TypeError path" \
        "$(reason_of "$out")" 'failed to evaluate \(fail-closed\)'
done

# Defense-in-depth (#2319 Steps 3-4): each consumer's OWN null-CWD guard holds
# independently of the workflow-gate.js Step-1 primary fix. The S1/S2 cases above
# drive the full gate, where Step 1 has already replaced a null cwd before these
# functions run, so their inner guards are never exercised there. Here each is
# called DIRECTLY with a null cwd. Spawned from $REPO, so process.cwd() is the tree.
SC_NODE="$HOOKS_NODE/workflow-gate/supervisor-check.js"
UVA_NODE="$HOOKS_NODE/workflow-gate/user-verified-audit.js"

# S3 — supervisor-check.js pre-merge backstop: a null hookCwd with a resolveRepoDirFn
# that THROWS on (null, null) must not crash. The inner try-catch falls back to
# process.cwd() and the backstop still evaluates a fresh CONTINUE TR5 to approve.
FK="$(fresh_key)"
seed_continue "$FK" >/dev/null
s3_out="$( cd "$REPO" && SC="$SC_NODE" SESS="$SID" node -e "
const { checkSupervisorPreMerge } = require(process.env.SC);
const problems = [];
let called = false;
const opts = {
  blockFn: (r) => { problems.push('blocked:' + String(r || '').slice(0, 60)); },
  resolveRepoDirFn: () => { called = true; throw new Error('null cwd rejected'); },
};
let r = null;
try { r = checkSupervisorPreMerge(process.env.SESS, 'squash', null, opts); }
catch (e) { problems.push('threw:' + e.message); }
if (!called) problems.push('resolver-not-reached');
if (!r || r.authoritative !== true) problems.push('not-authoritative:' + JSON.stringify(r));
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
" 2>/dev/null )"
assert_eq "S3-supervisor-check: a null hookCwd falls back to process.cwd(), reaches the resolver, and still evaluates authoritatively without throwing" \
    "$s3_out" "OK"

# S4 — user-verified-audit.js TR5 gate: a null hookCwd is null-guarded at entry
# (cwd = hookCwd || process.cwd()). A settled TR5 CONTINUE run approves through the
# resolved cwd without throwing.
seed_settled >/dev/null
s4_out="$( cd "$REPO" && UVA="$UVA_NODE" SESS="$SID" node -e "
const { checkUserVerifiedAudit } = require(process.env.UVA);
const problems = [];
let approved = false;
const opts = {
  approveFn: () => { approved = true; },
  blockFn: (r) => { problems.push('blocked:' + String(r || '').slice(0, 60)); },
};
let r = null;
try { r = checkUserVerifiedAudit(process.env.SESS, null, opts); }
catch (e) { problems.push('threw:' + e.message); }
if (!r || r.authoritative !== true) problems.push('not-authoritative:' + JSON.stringify(r));
if (!approved) problems.push('not-approved');
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
" 2>/dev/null )"
assert_eq "S4-user-verified-audit: a null hookCwd resolves a usable cwd (process.cwd()) and the settled TR5 run approves without throwing" \
    "$s4_out" "OK"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0
exit 1
