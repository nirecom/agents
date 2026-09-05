#!/usr/bin/env bash
# tests/feat-2218-supervisor-report-choke-point.sh
# Tests: bin/supervisor-report, hooks/lib/handoff-artifact.js
# Tags: supervisor, handoff, choke-point, class-e, exit-code, regression-2218, scope:issue-specific, pwsh-not-required, TL1

# Issue #2218 Step 12 — five skills call bin/supervisor-report, so the record belongs in the CLI's own success path, not in five prompt files that drift. The handoff entry carries only "a report exists, here"; the report body stays canonical in the supervisor state file (CPR-SSOT).

# TL3 gap: the skill-side trigger — a model actually deciding to report mid-step — is not exercised here; only the CLI choke point it funnels through. Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: workflow-state.

# TDD (write_code has not run): every case is expected to FAIL until the recording is added to the CLI's success path.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"
CLI="$AGENTS_DIR/bin/supervisor-report"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t 'wf2218'; }
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

AGENTS_DIR_NODE="$(node_path "$AGENTS_DIR")"

ARTIFACT="hooks/lib/handoff-artifact.js"

require_module() {
    if [ -f "$AGENTS_DIR/$1" ]; then return 0; fi
    fail "MODULE NOT FOUND: $1 — expected per issue #2218 Step 2, not yet implemented (write_code has not run)"
    return 1
}

# The CLI resolves its own sid when --session-id is omitted, so both forms are
# driven the same way apart from that one flag.
report() {
    local tmp="$1" envsid="$2"
    shift 2
    env -u CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID="$envsid" \
        CLAUDE_WORKFLOW_DIR="$tmp/wf" WORKFLOW_PLANS_DIR="$tmp/wf" \
        HOME="$tmp/home" USERPROFILE="$tmp/home" \
        "$RWT" 60 node "$CLI" --categories 'workflow-state' --severity 'warning' \
        --detail 'gate blocked a sanctioned command' --reporter 'write-tests' "$@" 2>&1
}

inspect() {
    local tmp="$1" sid="$2"
    env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID SID="$sid" \
        CLAUDE_WORKFLOW_DIR="$tmp/wf" WORKFLOW_PLANS_DIR="$tmp/wf" \
        HOME="$tmp/home" USERPROFILE="$tmp/home" \
        "$RWT" 30 node -e "
const { readHandoff } = require('$AGENTS_DIR_NODE/$ARTIFACT');
const sid = process.env.SID;
const problems = [];
const doc = readHandoff(sid);
const e = ((doc.entriesByClass || {}).E || []).filter((x) => x.key === 'supervisor-reported');
if (e.length !== 1) problems.push('class-E-supervisor-reported-entries:' + e.length);
else {
  const entry = e[0];
  if (String(entry.pointer).indexOf(sid + '-supervisor-state.json') === -1) problems.push('pointer:' + String(entry.pointer));
  const s = String(entry.summary);
  if (s.indexOf('workflow-state') === -1) problems.push('summary-omits-category:' + s);
  if (s.indexOf('warning') === -1) problems.push('summary-omits-severity:' + s);
}
const others = [].concat.apply([], Object.values(doc.entriesByClass || {})).filter((x) => x.key === 'supervisor-reported' && x.class !== 'E');
if (others.length) problems.push('recorded-outside-class-E:' + others.length);
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
    out="$(report "$tmp" "env-sid-s1" --session-id "explicit-sid-s1")"; rc=$?
    [ "$rc" -eq 0 ] || problems="$problems exit:$rc out:'${out:0:160}'"
    [ -f "$tmp/wf/explicit-sid-s1-supervisor-state.json" ] || problems="$problems supervisor-state-not-written"
    out="$(inspect "$tmp" "explicit-sid-s1")"
    [ "$out" = "OK" ] || problems="$problems entry:'$out'"
    [ -f "$tmp/wf/env-sid-s1-handoff.md" ] && problems="$problems recorded-under-the-ambient-sid-instead"
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

# S3 — the invariant. The report itself succeeded; a failed handoff write is a
# lost breadcrumb, not a failed report, and must not turn exit 0 into exit 1.
run_S3() {
    require_module "$ARTIFACT" || return 0
    local tmp out rc problems
    tmp="$(make_tmp)"; problems=""
    mkdir -p "$tmp/wf/unwritable-sid-s3-handoff.md"
    out="$(report "$tmp" "env-sid-s3" --session-id "unwritable-sid-s3")"; rc=$?
    [ "$rc" -eq 0 ] || problems="$problems exit-changed-by-a-failed-artifact-write:$rc out:'${out:0:160}'"
    [ -f "$tmp/wf/unwritable-sid-s3-supervisor-state.json" ] || problems="$problems report-lost-with-the-breadcrumb"
    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "S3: a failing handoff write leaves the report written and the exit code at 0"
    else
        fail "S3: —$problems"
    fi
}

# S4 — the other side of the same invariant: the entry claims "a report exists",
# so it must not be written when the report itself failed. A directory at the
# supervisor state path makes appendFinding fail.
run_S4() {
    require_module "$ARTIFACT" || return 0
    local tmp out rc problems
    tmp="$(make_tmp)"; problems=""
    mkdir -p "$tmp/wf/failing-sid-s4-supervisor-state.json"
    out="$(report "$tmp" "env-sid-s4" --session-id "failing-sid-s4")"; rc=$?
    [ "$rc" -eq 1 ] || problems="$problems want-exit-1-got:$rc out:'${out:0:160}'"
    if [ -f "$tmp/wf/failing-sid-s4-handoff.md" ]; then
        grep -q 'supervisor-reported' "$tmp/wf/failing-sid-s4-handoff.md" && problems="$problems recorded-a-report-that-never-landed"
    fi
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
    require_module "$ARTIFACT" || return 0
    local tmp rc problems files
    tmp="$(make_tmp)"; problems=""
    mkdir -p "$tmp/wf"
    env -u CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID="usage-sid-s5" \
        CLAUDE_WORKFLOW_DIR="$tmp/wf" WORKFLOW_PLANS_DIR="$tmp/wf" \
        HOME="$tmp/home" USERPROFILE="$tmp/home" \
        "$RWT" 30 node "$CLI" --severity 'warning' >/dev/null 2>&1
    rc=$?
    [ "$rc" -eq 1 ] || problems="$problems usage-exit:$rc"
    files="$(ls "$tmp/wf" 2>/dev/null | grep -c 'handoff.md' || true)"
    [ "$files" -eq 0 ] || problems="$problems usage-error-wrote-an-artifact"
    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "S5: a usage error exits 1 and writes no handoff entry"
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
