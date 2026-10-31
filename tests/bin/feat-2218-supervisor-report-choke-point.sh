#!/usr/bin/env bash
# tests/bin/feat-2218-supervisor-report-choke-point.sh
# Tests: bin/supervisor-report
# Tags: supervisor, handoff, choke-point, class-e, exit-code, regression-2218, regression-2652, state-handoff-record, scope:issue-specific, pwsh-not-required, TL1

# Issue #2218 Step 12 — five skills call bin/supervisor-report, so the record belongs in the CLI's own success path, not in five prompt files that drift. The record carries only "a report exists, here"; the report body stays canonical in the supervisor state file (CPR-SSOT).
# Issue #2652 — the record is a state handoff record (a `state_handoff_record` event in the session's state file: cls E, record_key supervisor-reported, origin procedure-point), no longer a handoff.md line. hooks/lib/handoff-artifact.js is deleted, so it left the Tests: header.

# TL3 gap: the skill-side trigger — a model actually deciding to report mid-step — is not exercised here; only the CLI choke point it funnels through. Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: workflow-state.

# TDD (write_code has not run): S1/S2 are expected to FAIL until the CLI writes through hooks/lib/state-handoff-record.js; S3–S5 guard invariants that must keep holding.

set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RWT="$SCRIPT_CHECKOUT_ROOT/bin/run-with-timeout.sh"
CLI="$SCRIPT_CHECKOUT_ROOT/bin/supervisor-report"

# isolation (#2512): pin state and plans dirs once for this file
_ISOLATION_TMP_ROOT="$(mktemp -d)"; readonly _ISOLATION_TMP_ROOT
mkdir -p "$_ISOLATION_TMP_ROOT/workflow-state" "$_ISOLATION_TMP_ROOT/plans"
export WORKFLOW_STATE_DIR="$_ISOLATION_TMP_ROOT/workflow-state" WORKFLOW_PLANS_DIR="$_ISOLATION_TMP_ROOT/plans"
trap 'rm -rf "$_ISOLATION_TMP_ROOT"' EXIT

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t 'wf2218'; }
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

SCRIPT_CHECKOUT_ROOT_NODE="$(node_path "$SCRIPT_CHECKOUT_ROOT")"

ARTIFACT="hooks/lib/state-handoff-record.js"

require_module() {
    if [ -f "$SCRIPT_CHECKOUT_ROOT/$1" ]; then return 0; fi
    fail "MODULE NOT FOUND: $1 — expected per issue #2652 S1, not yet implemented (write_code has not run)"
    return 1
}

# count_records <tmp> <sid> — the number of supervisor-reported state handoff
# records in the sid's state file (0 when the file is absent or unreadable).
count_records() {
    local tmp="$1" sid="$2"
    env -u CLAUDE_CODE_SESSION_ID SID="$sid" \
        WORKFLOW_STATE_DIR="$tmp/wf" WORKFLOW_PLANS_DIR="$tmp/wf" \
        HOME="$tmp/home" USERPROFILE="$tmp/home" \
        "$RWT" 30 node -e "
const S = require('$SCRIPT_CHECKOUT_ROOT_NODE/hooks/workflow-state/state-io');
let ev = [];
try { ev = ((S.readRawState(process.env.SID) || {}).events || []); } catch (e) { ev = []; }
process.stdout.write(String(ev.filter((e) => e && e.kind === 'state_handoff_record' && e.record_key === 'supervisor-reported').length));
" 2>/dev/null
}

# The CLI resolves its own sid when --session-id is omitted, so both forms are
# driven the same way apart from that one flag.
report() {
    local tmp="$1" envsid="$2"
    shift 2
    env CLAUDE_CODE_SESSION_ID="$envsid" \
        WORKFLOW_STATE_DIR="$tmp/wf" WORKFLOW_PLANS_DIR="$tmp/wf" \
        HOME="$tmp/home" USERPROFILE="$tmp/home" \
        "$RWT" 60 node "$CLI" --categories 'workflow' --severity 'warning' \
        --detail 'gate blocked a sanctioned command' --reporter 'write-tests' "$@" 2>&1
}

# #2430: the handoff write goes through the workflow-active-period gate, so a
# case that expects an entry seeds a session inside its active period first
# (workflow_init complete, final_report pending).
seed_active() {
    local tmp="$1" sid="$2"
    env -u CLAUDE_CODE_SESSION_ID \
        WORKFLOW_STATE_DIR="$tmp/wf" WORKFLOW_PLANS_DIR="$tmp/wf" \
        HOME="$tmp/home" USERPROFILE="$tmp/home" \
        "$RWT" 30 node -e "
const { writeState, createInitialState, markStep } = require('$SCRIPT_CHECKOUT_ROOT_NODE/hooks/workflow-state/state-io');
writeState('$sid', createInitialState('$sid', { cwd: '/report/fixture', git_branch: 'feature/report' }));
markStep('$sid', 'workflow_init', 'complete');
" >/dev/null 2>&1
}

inspect() {
    local tmp="$1" sid="$2"
    env -u CLAUDE_CODE_SESSION_ID SID="$sid" \
        WORKFLOW_STATE_DIR="$tmp/wf" WORKFLOW_PLANS_DIR="$tmp/wf" \
        HOME="$tmp/home" USERPROFILE="$tmp/home" \
        "$RWT" 30 node -e "
const S = require('$SCRIPT_CHECKOUT_ROOT_NODE/hooks/workflow-state/state-io');
const sid = process.env.SID;
const problems = [];
let ev = [];
try { ev = ((S.readRawState(sid) || {}).events || []); } catch (err) { problems.push('state-unreadable:' + err.message); }
const all = ev.filter((x) => x && x.kind === 'state_handoff_record' && x.record_key === 'supervisor-reported');
const e = all.filter((x) => x.cls === 'E');
if (e.length !== 1) problems.push('class-E-supervisor-reported-records:' + e.length);
else {
  const entry = e[0];
  if (String(entry.pointer).replace(/\\\\/g, '/').indexOf(sid + '.control/supervisor-state.json') === -1) problems.push('pointer:' + String(entry.pointer));
  if (entry.origin !== 'procedure-point') problems.push('origin:' + String(entry.origin));
  const s = String(entry.summary);
  if (!/(^|[^a-zA-Z0-9-])workflow($|[^a-zA-Z0-9-])/.test(s)) problems.push('summary-omits-category:' + s);
  if (s.indexOf('workflow-state') !== -1) problems.push('summary-contains-invalid-category:workflow-state');
  if (s.indexOf('warning') === -1) problems.push('summary-omits-severity:' + s);
}
if (all.length !== e.length) problems.push('recorded-outside-class-E:' + (all.length - e.length));
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
" 2>&1
}

# S1 — the explicit form. The sid the entry lands under is the one the CLI acted
# on, and the pointer names the file that owns the report body.
run_S1() {
    require_module "$ARTIFACT" || return 0
    local tmp out rc problems
    tmp="$(make_tmp)"; problems=""
    mkdir -p "$tmp/wf"
    seed_active "$tmp" "explicit-sid-s1"
    seed_active "$tmp" "env-sid-s1"
    out="$(report "$tmp" "env-sid-s1" --session-id "explicit-sid-s1")"; rc=$?
    [ "$rc" -eq 0 ] || problems="$problems exit:$rc out:'${out:0:160}'"
    [ -f "$tmp/wf/explicit-sid-s1.control/supervisor-state.json" ] || problems="$problems supervisor-state-not-written"
    out="$(inspect "$tmp" "explicit-sid-s1")"
    [ "$out" = "OK" ] || problems="$problems entry:'$out'"
    [ "$(count_records "$tmp" "env-sid-s1")" = "0" ] || problems="$problems recorded-under-the-ambient-sid-instead"
    [ -e "$tmp/wf/explicit-sid-s1.control/handoff.md" ] && problems="$problems still-writes-handoff-md"
    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "S1: --session-id records one class E supervisor-reported entry pointing at that sid's supervisor state file"
    else
        fail "S1: —$problems"
    fi
}

# S2 — the omitted form (the one the skills actually use). The record must use
# the same resolveSessionId() value the CLI already resolved for the finding —
# not a second, independently guessed id.
run_S2() {
    require_module "$ARTIFACT" || return 0
    local tmp out rc problems
    tmp="$(make_tmp)"; problems=""
    mkdir -p "$tmp/wf"
    seed_active "$tmp" "ambient-sid-s2"
    out="$(report "$tmp" "ambient-sid-s2")"; rc=$?
    [ "$rc" -eq 0 ] || problems="$problems exit:$rc out:'${out:0:160}'"
    out="$(inspect "$tmp" "ambient-sid-s2")"
    [ "$out" = "OK" ] || problems="$problems entry:'$out'"
    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "S2: with --session-id omitted the entry lands under the auto-resolved sid"
    else
        fail "S2: —$problems"
    fi
}

# S3 — the invariant. The report itself succeeded; a failed record write is a
# lost breadcrumb, not a failed report, and must not turn exit 0 into exit 1.
# #2652: the record lives in the state file, so a corrupt state file (not a
# directory squatting on handoff.md) is what makes the write fail; the
# supervisor state file sits in the control dir and stays writable.
run_S3() {
    local tmp out rc problems
    tmp="$(make_tmp)"; problems=""
    mkdir -p "$tmp/wf"
    printf '{ not json' > "$tmp/wf/unwritable-sid-s3.json"
    out="$(report "$tmp" "env-sid-s3" --session-id "unwritable-sid-s3")"; rc=$?
    [ "$rc" -eq 0 ] || problems="$problems exit-changed-by-a-failed-artifact-write:$rc out:'${out:0:160}'"
    [ -f "$tmp/wf/unwritable-sid-s3.control/supervisor-state.json" ] || problems="$problems report-lost-with-the-breadcrumb"
    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "S3: a failing state handoff record write (corrupt state file) leaves the report written and the exit code at 0"
    else
        fail "S3: —$problems"
    fi
}

# S4 — the other side of the same invariant: the entry claims "a report exists",
# so it must not be written when the report itself failed. A directory at the
# supervisor state path makes appendFinding fail.
run_S4() {
    local tmp out rc problems
    tmp="$(make_tmp)"; problems=""
    mkdir -p "$tmp/wf/failing-sid-s4.control/supervisor-state.json"
    seed_active "$tmp" "failing-sid-s4"
    out="$(report "$tmp" "env-sid-s4" --session-id "failing-sid-s4")"; rc=$?
    [ "$rc" -eq 1 ] || problems="$problems want-exit-1-got:$rc out:'${out:0:160}'"
    [ "$(count_records "$tmp" "failing-sid-s4")" = "0" ] || problems="$problems recorded-a-report-that-never-landed"
    [ -f "$tmp/wf/failing-sid-s4.json" ] || problems="$problems fixture-state-missing"
    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "S4: a failed appendFinding exits 1 and records no supervisor-reported entry"
    else
        fail "S4: —$problems"
    fi
}

# S5 — usage errors exit before anything is recorded; a rejected invocation is
# not a report.
run_S5() {
    local tmp rc problems files
    tmp="$(make_tmp)"; problems=""
    mkdir -p "$tmp/wf"
    seed_active "$tmp" "usage-sid-s5"
    env CLAUDE_CODE_SESSION_ID="usage-sid-s5" \
        WORKFLOW_STATE_DIR="$tmp/wf" WORKFLOW_PLANS_DIR="$tmp/wf" \
        HOME="$tmp/home" USERPROFILE="$tmp/home" \
        "$RWT" 30 node "$CLI" --severity 'warning' >/dev/null 2>&1
    rc=$?
    [ "$rc" -eq 1 ] || problems="$problems usage-exit:$rc"
    files="$(find "$tmp/wf" -name 'handoff.md' 2>/dev/null | grep -c . || true)"
    [ "$files" -eq 0 ] || problems="$problems usage-error-wrote-a-handoff-md"
    [ "$(count_records "$tmp" "usage-sid-s5")" = "0" ] || problems="$problems usage-error-wrote-a-record"
    [ -f "$tmp/wf/usage-sid-s5.json" ] || problems="$problems fixture-state-missing"
    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "S5: a usage error exits 1 and writes no state handoff record"
    else
        fail "S5: —$problems"
    fi
}

run_S1
run_S2
run_S3
run_S4
run_S5

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
