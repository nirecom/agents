#!/usr/bin/env bash
# tests/feature-2256-tr5-user-verified-hold/_common.sh
# Tests: hooks/workflow-gate.js, hooks/lib/audit-ledger.js, hooks/lib/diff-fingerprint.js
# Tags: test-infrastructure, fixture, shared-lib, scope:issue-specific
# Shared fixture, state seeding and assertion preamble for the TR5 hold sections.

# Sourced by each section, never run as one: the parent lists sections explicitly.

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
nrm() { cygpath -m "$1" 2>/dev/null || printf '%s' "$1"; }
AGENTS_NODE="$(nrm "$AGENTS_DIR")"
HOOKS_NODE="$AGENTS_NODE/hooks"
FP_NODE="$HOOKS_NODE/lib/diff-fingerprint.js"
WRITER_NODE="$HOOKS_NODE/lib/supervisor-state-writer.js"
SCHEMA_NODE="$HOOKS_NODE/lib/supervisor-state-schema.js"
OVERRIDE_BIN="$AGENTS_DIR/bin/supervisor-record-block-override"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1${2:+ — $2}"; FAIL=$((FAIL + 1)); }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected '$3', got '$2'"; fi; }
assert_ne() { if [ "$2" != "$3" ]; then pass "$1"; else fail "$1" "both sides are '$2'"; fi; }
assert_match() {
    if printf '%s' "$2" | grep -Eq "$3"; then pass "$1"; else fail "$1" "'$2' does not match /$3/"; fi
}
assert_nomatch() {
    if printf '%s' "$2" | grep -Eq "$3"; then fail "$1" "'$2' unexpectedly matches /$3/"; else pass "$1"; fi
}

WORK="$(mktemp -d 2>/dev/null || mktemp -d -t f2256tr5)"
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

SID="tr5hold"
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
git -C "$REPO" checkout -q -b feature/tr5
REPO_NODE="$(nrm "$REPO")"

SENTINEL_UV='echo "<<WORKFLOW_USER_VERIFIED: verified the fix end to end in the app>>"'
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

artifact_key() {
    FP="$FP_NODE" PLANS="$WORK_NODE/plans" SESS="$SID" NAMES="$1" node -e "
const fp = require(process.env.FP);
const v = fp.computeArtifactKey(process.env.PLANS, process.env.SESS, process.env.NAMES.split(','));
process.stdout.write(String(v === null || v === undefined ? 'null' : v));
" 2>/dev/null
}

input_version() {
    FP="$FP_NODE" RCWD="$REPO_NODE" node -e "
const fp = require(process.env.FP);
process.stdout.write(String(fp.computeInputVersion(process.env.RCWD) || 'null'));
" 2>/dev/null
}

# seed_state <json-fragment-applied-to-st.audit> — reset the session state, then patch audit.
seed_state() {
    WR="$WRITER_NODE" SC="$SCHEMA_NODE" SESS="$SID" PATCHJSON="$1" node -e "
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

# gate <command> — run the real PreToolUse gate with a Bash payload and print its stdout.
gate() {
    CMDTEXT="$1" RCWD="$REPO_NODE" SESS="$SID" node -e "
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

# terminal_run <verdict> <freshness-key> — the ledger fragment for one settled TR5 run.
terminal_run() {
    VERD="$1" FKEY="$2" node -e "
process.stdout.write(JSON.stringify({
  ledger: [{
    id: 'run-0011', outcome: 'terminal', cause: 'step-complete:user_verification',
    tr_ids: ['TR5'], verdict: process.env.VERD, freshness_key: process.env.FKEY,
    sub_checks: ['recurrence-patterns'], input_key: { 'recurrence-patterns': process.env.FKEY },
  }],
  last_terminal_run_id: 'run-0011',
  audit_verdict_summary: process.env.VERD,
}));
"
}

# two_terminal_runs <tr5-verdict> <fkey> <tr6-verdict> [<block-overrides-json>] — a
# two-entry ledger: a terminal TR5 run, then a LATER terminal TR6 run at the same
# freshness_key. Exercises the hasLaterTerminalBlock / laterBlockExists guard
# (a TR6 BLOCK that postdates a non-BLOCK TR5, or one an old TR5 override cannot
# speak to). The optional 4th arg seeds audit.block_overrides verbatim — pass the
# JSON that `state_field audit.block_overrides` prints after a real CLI record.
two_terminal_runs() {
    V5="$1" FK5="$2" V6="$3" OV="${4:-[]}" node -e "
const overrides = JSON.parse(process.env.OV || '[]');
process.stdout.write(JSON.stringify({
  ledger: [
    { id: 'run-0011', outcome: 'terminal', cause: 'step-complete:user_verification',
      tr_ids: ['TR5'], verdict: process.env.V5, freshness_key: process.env.FK5,
      sub_checks: ['recurrence-patterns'], input_key: { 'recurrence-patterns': process.env.FK5 } },
    { id: 'run-0012', outcome: 'terminal', cause: 'step-complete:user_verification',
      tr_ids: ['TR6'], verdict: process.env.V6, freshness_key: process.env.FK5,
      sub_checks: ['recurrence-patterns'], input_key: { 'recurrence-patterns': process.env.FK5 } },
  ],
  last_terminal_run_id: 'run-0012',
  audit_verdict_summary: process.env.V6,
  block_overrides: overrides,
}));
"
}
