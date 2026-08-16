#!/usr/bin/env bash
# tests/feature-1979-stall-regression.sh
# Tests: hooks/user-prompt-submit-mechanism-check.js, hooks/lib/mechanism-failure.js, hooks/workflow-state/lifecycle.js, hooks/lib/step-in-flight-policy.js, settings.json
# Tags: stall-detection, user-prompt-submit, hook, step-in-flight, no-state-session, stall-reported, regression-1979, scope:issue-specific, pwsh-not-required, TL1, TL2

# Issue #1979 — a session sat idle overnight waiting for a forked-skill
# notification that never arrived. `write_tests` stayed in_progress, every quiet
# layer kept honouring it, and nothing ever surfaced the stall to the user.

# The regression is a boundary, so it is tested as a PAIR (R1/R2): inside the TTL
# the in-flight record is legitimate and must keep C4 quiet; past the TTL it must
# both stop being honoured AND be reported. R3/R4 close the loop at the real
# hook, and R5 pins the settings.json registration without which none of it runs.

# TL3 gap (what this test does NOT catch):
# - Whether Claude Code actually invokes UserPromptSubmit hooks with the payload
#   shape assumed here, and whether it renders the returned block to the user
# - Whether an overnight wall-clock gap really produces the timestamps modelled
#   here by backdating
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: hook-registration

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

STATEIO_NODE="$_AGENTS_DIR_NODE/hooks/workflow-state/state-io.js"
LIFECYCLE_NODE="$_AGENTS_DIR_NODE/hooks/workflow-state/lifecycle.js"
MF_NODE="$_AGENTS_DIR_NODE/hooks/lib/mechanism-failure.js"
COMPLETION_APPROVAL_NODE="$_AGENTS_DIR_NODE/hooks/workflow-state/completion-approval.js"
UPS_HOOK="$AGENTS_DIR/hooks/user-prompt-submit-mechanism-check.js"
TTL_MS=$((4 * 60 * 60 * 1000))

make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t 'stall1979'; }
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

# seed_stall_fixture <tmp> <tn> <sid> <ms-ago> — the #1979 shape: the session got
# as far as write_tests, marked it in_progress, and then nothing happened for
# <ms-ago> milliseconds. `steps` is a projection recomputed from the event
# stream, so the age is moved on write_tests' own events.
seed_stall_fixture() {
    CLAUDE_WORKFLOW_DIR="$2" WORKFLOW_PLANS_DIR="$2" SID="$3" "$RWT" 15 node -e "
const wf = require('$STATEIO_NODE');
const CA = require('$COMPLETION_APPROVAL_NODE');
for (const s of ['workflow_init','clarify_intent','research','outline','detail','branching_complete']) {
  if (CA.isApprovalGatedStep(s)) {
    CA.recordPlanApproval(process.env.SID, s, { source: 'reset-sentinel', reason: '1979 fixture' });
  }
  wf.markStep(process.env.SID, s, 'complete');
}
wf.markStep(process.env.SID, 'write_tests', 'in_progress');" >/dev/null 2>&1
    P="$(node_path "$1/$3.json")" MS="$4" "$RWT" 15 node -e "
const fs = require('fs');
const s = JSON.parse(fs.readFileSync(process.env.P, 'utf8'));
const at = new Date(Date.now() - Number(process.env.MS)).toISOString();
for (const e of s.events || []) { if (e.step === 'write_tests') e.at = at; }
fs.writeFileSync(process.env.P, JSON.stringify(s));" >/dev/null 2>&1
}

# run_ups <tn> <sid> — drives the real UserPromptSubmit hook with a Claude
# Code-shaped payload. Sets UPS_OUT / UPS_RC.
run_ups() {
    UPS_OUT=$(SID="$2" "$RWT" 15 node -e "
process.stdout.write(JSON.stringify({ session_id: process.env.SID, transcript_path: '',
  prompt: 'where are we?', hook_event_name: 'UserPromptSubmit' }));" \
        | CLAUDE_WORKFLOW_DIR="$1" WORKFLOW_PLANS_DIR="$1" AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" \
          "$RWT" 25 node "$(node_path "$UPS_HOOK")" 2>/dev/null)
    UPS_RC=$?
}

# ---------------------------------------------------------------------------
# R1: the legitimate half of the boundary. Inside the TTL the in-flight record is
#     exactly what it claims to be, so the quiet layer honours it. Without this
#     row, "always report a stall" would satisfy R2 and R3 while destroying the
#     feature the quiet layer exists for.
# ---------------------------------------------------------------------------
run_R1() {
    local tmp tn out problems=""
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    seed_stall_fixture "$tmp" "$tn" r1 $((TTL_MS - 60000))
    out=$(CLAUDE_WORKFLOW_DIR="$tn" WORKFLOW_PLANS_DIR="$tn" "$RWT" 20 node -e "
const L = require('$LIFECYCLE_NODE');
process.stdout.write(String(L.isStepInFlight('r1', 'write_tests')));" 2>/dev/null)
    [ "$out" = "true" ] || problems="$problems [isStepInFlight=${out:-<err>}, expected true inside the TTL]"
    out=$(CLAUDE_WORKFLOW_DIR="$tn" WORKFLOW_PLANS_DIR="$tn" "$RWT" 20 node -e "
const { detectStalledSteps } = require('$MF_NODE');
process.stdout.write(String((detectStalledSteps('r1') || []).length));" 2>/dev/null)
    [ "$out" = "0" ] || problems="$problems [detectStalledSteps reported ${out:-<err>} finding(s) on a healthy session]"
    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "R1: write_tests in_progress at TTL-1min is honoured as in flight and is not a stall"
    else
        fail "R1: healthy in-flight session misjudged;$problems"
    fi
}

# ---------------------------------------------------------------------------
# R2: the regression itself. Past the TTL the SAME record must flip both ways at
#     once — no longer honoured (so the guard speaks again) and detected as a
#     stall (so the mechanism failure is reported). Asserting only one half would
#     leave the overnight-silence bug reachable through the other.
# ---------------------------------------------------------------------------
run_R2() {
    local tmp tn out problems=""
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    seed_stall_fixture "$tmp" "$tn" r2 $((TTL_MS + 60000))
    out=$(CLAUDE_WORKFLOW_DIR="$tn" WORKFLOW_PLANS_DIR="$tn" "$RWT" 20 node -e "
const L = require('$LIFECYCLE_NODE');
process.stdout.write(String(L.isStepInFlight('r2', 'write_tests')));" 2>/dev/null)
    [ "$out" = "false" ] || problems="$problems [isStepInFlight=${out:-<err>}, expected false past the TTL]"
    out=$(CLAUDE_WORKFLOW_DIR="$tn" WORKFLOW_PLANS_DIR="$tn" "$RWT" 20 node -e "
const { detectStalledSteps } = require('$MF_NODE');
const f = detectStalledSteps('r2') || [];
process.stdout.write(f.map((x) => x.step + ':' + x.kind).join(','));" 2>/dev/null)
    [ "$out" = "write_tests:in-flight-expired" ] ||
        problems="$problems [detectStalledSteps returned '${out:-<err>}', expected write_tests:in-flight-expired]"
    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "R2: past the TTL the same record stops being honoured AND is detected as an expired in-flight stall"
    else
        fail "R2: stall not detected at the boundary;$problems"
    fi
}

# ---------------------------------------------------------------------------
# R3: end of the chain — the user finally hears about it. The next prompt after
#     the stall must come back with a blocking notice rather than the silence
#     that defined #1979.
# ---------------------------------------------------------------------------
run_R3() {
    local tmp tn compact problems=""
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    seed_stall_fixture "$tmp" "$tn" r3 $((TTL_MS + 60000))
    run_ups "$tn" r3
    [ "$UPS_RC" -eq 0 ] || problems="$problems [hook exited $UPS_RC, a UserPromptSubmit hook must exit 0]"
    compact="$(printf '%s' "$UPS_OUT" | tr -d ' \n\r')"
    case "$compact" in
        *'"blocks":true'*) : ;;
        *) problems="$problems [output did not carry \"blocks\":true — got '${UPS_OUT:-<empty>}']" ;;
    esac
    case "$compact" in
        *write_tests*) : ;;
        *) problems="$problems [the stalled step is not named in the output]" ;;
    esac
    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "R3: the UserPromptSubmit mechanism check surfaces the stalled write_tests step with blocks:true"
    else
        fail "R3: stall was not surfaced to the user;$problems"
    fi
}

# ---------------------------------------------------------------------------
# R3a/R3b: cross-module reporting path — R3 only checks the block payload;
# these also verify supervisor-report was actually invoked (via a stub
# binary reached through AGENTS_CONFIG_DIR) and that a second prompt against
# the SAME unchanged stall is idempotent: the .stall-reported ledger stays at
# one entry and supervisor-report is not called a second time.
# ---------------------------------------------------------------------------
run_R3a_R3b() {
    local tmp tn cfgdir cfgdir_n log_file problems=""
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    seed_stall_fixture "$tmp" "$tn" r3ab $((TTL_MS + 60000))

    cfgdir="$(make_tmp)"; cfgdir_n="$(node_path "$cfgdir")"
    mkdir -p "$cfgdir/bin"
    log_file="$cfgdir/supervisor-report.invocations"
    cat > "$cfgdir/bin/supervisor-report" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$log_file"
EOF
    chmod +x "$cfgdir/bin/supervisor-report"

    UPS_OUT=$(SID=r3ab "$RWT" 15 node -e "
process.stdout.write(JSON.stringify({ session_id: process.env.SID, transcript_path: '',
  prompt: 'where are we?', hook_event_name: 'UserPromptSubmit' }));" \
        | CLAUDE_WORKFLOW_DIR="$tn" WORKFLOW_PLANS_DIR="$tn" AGENTS_CONFIG_DIR="$cfgdir_n" \
          "$RWT" 25 node "$(node_path "$UPS_HOOK")" 2>/dev/null)
    UPS_RC=$?
    [ "$UPS_RC" -eq 0 ] || problems="$problems [1st call: hook exited $UPS_RC]"

    local ledger_1 ledger_count_1
    ledger_1="$(ls "$tmp" 2>/dev/null | grep 'stall-reported' | tr '\n' ' ')"
    [ -n "$ledger_1" ] || problems="$problems [1st call: no .stall-reported ledger file was created]"
    ledger_count_1=$(printf '%s\n' "$ledger_1" | tr ' ' '\n' | grep -c 'stall-reported')

    # Second prompt, same stall state: ledger must stay the same, and
    # supervisor-report must not be invoked a second time.
    UPS_OUT2=$(SID=r3ab "$RWT" 15 node -e "
process.stdout.write(JSON.stringify({ session_id: process.env.SID, transcript_path: '',
  prompt: 'still there?', hook_event_name: 'UserPromptSubmit' }));" \
        | CLAUDE_WORKFLOW_DIR="$tn" WORKFLOW_PLANS_DIR="$tn" AGENTS_CONFIG_DIR="$cfgdir_n" \
          "$RWT" 25 node "$(node_path "$UPS_HOOK")" 2>/dev/null)
    UPS_RC2=$?
    [ "$UPS_RC2" -eq 0 ] || problems="$problems [2nd call: hook exited $UPS_RC2]"

    local ledger_2 ledger_count_2
    ledger_2="$(ls "$tmp" 2>/dev/null | grep 'stall-reported' | tr '\n' ' ')"
    [ -n "$ledger_2" ] || problems="$problems [2nd call: .stall-reported ledger disappeared]"
    ledger_count_2=$(printf '%s\n' "$ledger_2" | tr ' ' '\n' | grep -c 'stall-reported')
    [ "$ledger_count_1" = "$ledger_count_2" ] ||
        problems="$problems [ledger file count changed: ${ledger_count_1} then ${ledger_count_2}, expected stable]"

    local invocations=0
    [ -f "$log_file" ] && invocations=$(wc -l < "$log_file" | tr -d ' ')
    [ "${invocations:-0}" -ge 1 ] ||
        problems="$problems [supervisor-report stub was never invoked — reporting path not exercised]"
    [ "${invocations:-0}" -le 1 ] ||
        problems="$problems [supervisor-report stub invoked ${invocations} times across two identical stalls, expected exactly 1]"

    rm -rf "$tmp" "$cfgdir" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "R3a/R3b: stall reporting creates a .stall-reported ledger once and does not double-report an unchanged stall"
    else
        fail "R3a/R3b: reporting path or idempotency broken;$problems"
    fi
}

# ---------------------------------------------------------------------------
# R4: the counterpart of R3 — a healthy session must pass through untouched.
#     This hook runs on EVERY prompt, so a false positive here interrupts every
#     turn of every session.
# ---------------------------------------------------------------------------
run_R4() {
    local tmp tn compact problems=""
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    seed_stall_fixture "$tmp" "$tn" r4 $((TTL_MS - 60000))
    run_ups "$tn" r4
    [ "$UPS_RC" -eq 0 ] || problems="$problems [hook exited $UPS_RC]"
    compact="$(printf '%s' "$UPS_OUT" | tr -d ' \n\r')"
    case "$compact" in
        *'"blocks":true'*) problems="$problems [healthy session was blocked: '$UPS_OUT']" ;;
        ""|"{}") : ;;
        *) : ;;   # any non-blocking payload is fine; only blocks:true is wrong here
    esac
    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "R4: a healthy in-flight session passes the UserPromptSubmit check without blocking"
    else
        fail "R4: false-positive stall report;$problems"
    fi
}

# ---------------------------------------------------------------------------
# R6: the no-workflow session — by volume the COMMONEST case this hook sees. Most
#     prompts are typed in sessions that never ran /workflow-init, so there is no
#     state file to read at all. That absence is normal, not a mechanism failure:
#     the hook must return a bare {} and leave the prompt alone.

#     The second assertion is the one that matters. A hook that treated "no state
#     file" as a stall would write a .stall-reported ledger on the way past, and
#     because the ledger suppresses repeats, the FIRST genuine stall in that
#     session would then be silently swallowed — #1979 reintroduced by the very
#     code meant to close it. So: no block, and no ledger anywhere in the dir.
# ---------------------------------------------------------------------------
run_R6() {
    local tmp tn compact strays problems=""
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    # Deliberately no seeding: an empty workflow dir, no <sid>.json.
    run_ups "$tn" r6
    [ "$UPS_RC" -eq 0 ] || problems="$problems [hook exited $UPS_RC, a UserPromptSubmit hook must exit 0]"
    compact="$(printf '%s' "$UPS_OUT" | tr -d ' \n\r')"
    case "$compact" in
        ""|"{}") : ;;
        *) problems="$problems [expected an empty {} payload, got '$UPS_OUT']" ;;
    esac
    [ ! -f "$tmp/r6.json" ] ||
        problems="$problems [the hook created a workflow state file for a session that has none]"
    strays="$(ls "$tmp" 2>/dev/null | grep 'stall-reported' | tr '\n' ' ')"
    [ -z "$strays" ] ||
        problems="$problems [a stall-reported ledger was written for a session with no state: $strays]"
    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "R6: a session with no workflow state at all gets a bare {} and no stall-reported ledger"
    else
        fail "R6: the no-state case is misread as a mechanism failure;$problems"
    fi
}

# ---------------------------------------------------------------------------
# R5: registration. Detection that is never invoked is the #1979 bug itself, so
#     the hook must be wired into settings.json's UserPromptSubmit chain — and
#     the pre-existing entries in that chain must survive the edit.
# ---------------------------------------------------------------------------
run_R5() {
    local out
    out=$("$RWT" 20 node -e "
const s = require('$_AGENTS_DIR_NODE/settings.json');
const groups = (s.hooks && s.hooks.UserPromptSubmit) || [];
const cmds = groups.reduce((a, g) => a.concat((g.hooks || []).map((h) => String(h.command))), []);
const problems = [];
const entry = cmds.find((c) => c.includes('user-prompt-submit-mechanism-check.js'));
if (!entry) problems.push('not-registered');
else if (!entry.includes('\$AGENTS_CONFIG_DIR')) problems.push('command-not-AGENTS_CONFIG_DIR-relative');
for (const sibling of ['post-push-workflow-reset.js', 'lang-inject.js', 'record-off-skill-invocation.js']) {
  if (!cmds.some((c) => c.includes(sibling))) problems.push('sibling-lost:' + sibling);
}
process.stdout.write(problems.length ? 'BAD:' + problems.join(' ') : 'OK');" 2>/dev/null)
    if [ "$out" = "OK" ]; then
        pass "R5: settings.json registers user-prompt-submit-mechanism-check.js and keeps every pre-existing UserPromptSubmit hook"
    else
        fail "R5: UserPromptSubmit registration wrong; got '${out:-<err>}'"
    fi
}

run_R1
run_R2
run_R3
run_R3a_R3b
run_R4
run_R6
run_R5

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
