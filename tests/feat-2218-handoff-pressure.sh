#!/usr/bin/env bash
# tests/feat-2218-handoff-pressure.sh
# Tests: hooks/lib/handoff-pressure.js, hooks/handoff-pressure-nudge.js, settings.json
# Tags: handoff, context-pressure, user-prompt-submit, crisis-detection, fail-open, regression-2218, scope:issue-specific, pwsh-not-required, TL1

# Issue #2218 Step 10 detection layer — the self-report rule alone cannot fire when the model never notices the pressure. This hook computes an objective proxy every turn (transcript growth since the last handoff write) so the nudge does not depend on the model's own judgement (round2-fix C5).

# TL3 gap: the real UserPromptSubmit dispatch — Claude Code actually feeding additionalContext back into the turn, and the 300KB threshold's usefulness against a real compaction — is not exercised here. Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: hooks.

# TDD (write_code has not run): every case is expected to FAIL with "MODULE NOT FOUND".

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t 'wf2218'; }
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

AGENTS_DIR_NODE="$(node_path "$AGENTS_DIR")"

LIB="hooks/lib/handoff-pressure.js"
HOOK="hooks/handoff-pressure-nudge.js"

require_module() {
    if [ -f "$AGENTS_DIR/$1" ]; then return 0; fi
    fail "MODULE NOT FOUND: $1 — expected per issue #2218 Step 10, not yet implemented (write_code has not run)"
    return 1
}

run_node() {
    local tmp tn out
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    out=$(env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID \
        CLAUDE_WORKFLOW_DIR="$tn/wf" WORKFLOW_PLANS_DIR="$tn/wf" \
        HOME="$tn/home" USERPROFILE="$tn/home" \
        "$RWT" 60 node -e "$1" 2>&1)
    rm -rf "$tmp" 2>/dev/null || true
    printf '%s' "$out"
}

# P1 — the threshold itself, table driven. 300KB is an Accepted Tradeoff, not a
# measured compaction trigger, so the contract under test is only "strictly
# below stays quiet, above nudges".
run_P1() {
    require_module "$LIB" || return 0
    local tmp out
    tmp="$(make_tmp)"
    "$RWT" 30 node -e "
const fs = require('fs');
fs.writeFileSync('$(node_path "$tmp")/small.txt', Buffer.alloc(100 * 1024, 120));
fs.writeFileSync('$(node_path "$tmp")/big.txt', Buffer.alloc(400 * 1024, 120));
fs.writeFileSync('$(node_path "$tmp")/edge.txt', Buffer.alloc(300 * 1024, 120));
" >/dev/null 2>&1
    out=$(env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID \
        CLAUDE_WORKFLOW_DIR="$tmp/wf" WORKFLOW_PLANS_DIR="$tmp/wf" \
        HOME="$tmp/home" USERPROFILE="$tmp/home" \
        "$RWT" 60 node -e "
const { computePressureSignal } = require('$AGENTS_DIR_NODE/$LIB');
const dir = '$(node_path "$tmp")';
const problems = [];
const cases = [['small.txt', false], ['edge.txt', false], ['big.txt', true]];
for (const c of cases) {
  const sig = computePressureSignal({ transcriptPath: dir + '/' + c[0], handoffMtime: null });
  if (!sig || typeof sig.shouldNudge !== 'boolean') problems.push(c[0] + ':no-shouldNudge:' + JSON.stringify(sig));
  else if (sig.shouldNudge !== c[1]) problems.push(c[0] + ':want=' + c[1] + ',got=' + sig.shouldNudge);
}
const missing = computePressureSignal({ transcriptPath: dir + '/absent.txt', handoffMtime: null });
if (!missing || missing.shouldNudge !== false) problems.push('absent-transcript:' + JSON.stringify(missing));
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
" 2>&1)
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$out" = "OK" ]; then
        pass "P1: computePressureSignal is quiet below 300KB, nudges above it, and treats a missing transcript as quiet"
    else
        fail "P1: expected 'OK', got '${out:-<err>}'"
    fi
}

# P2 — dedup. Once the handoff artifact has been written AFTER the transcript
# last grew, the accumulated bytes have already been flushed; re-nudging every
# turn would train the model to ignore the nudge.
run_P2() {
    require_module "$LIB" || return 0
    local tmp out
    tmp="$(make_tmp)"
    out=$(env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID \
        CLAUDE_WORKFLOW_DIR="$tmp/wf" WORKFLOW_PLANS_DIR="$tmp/wf" \
        HOME="$tmp/home" USERPROFILE="$tmp/home" \
        "$RWT" 60 node -e "
const fs = require('fs');
const { computePressureSignal } = require('$AGENTS_DIR_NODE/$LIB');
const dir = '$(node_path "$tmp")';
const t = dir + '/transcript.jsonl';
fs.writeFileSync(t, Buffer.alloc(400 * 1024, 120));
const problems = [];
const stale = new Date(fs.statSync(t).mtimeMs - 60000);
const first = computePressureSignal({ transcriptPath: t, handoffMtime: stale });
if (!first || first.shouldNudge !== true) problems.push('stale-handoff-should-nudge:' + JSON.stringify(first));
const fresh = new Date(fs.statSync(t).mtimeMs + 60000);
const second = computePressureSignal({ transcriptPath: t, handoffMtime: fresh });
if (!second || second.shouldNudge !== false) problems.push('fresh-handoff-should-be-quiet:' + JSON.stringify(second));
fs.appendFileSync(t, Buffer.alloc(400 * 1024, 121));
fs.utimesSync(t, new Date(), new Date(fresh.getTime() + 60000));
const third = computePressureSignal({ transcriptPath: t, handoffMtime: fresh });
if (!third || third.shouldNudge !== true) problems.push('growth-after-flush-should-nudge:' + JSON.stringify(third));
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
" 2>&1)
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$out" = "OK" ]; then
        pass "P2: a handoff write silences the nudge until the transcript grows again"
    else
        fail "P2: expected 'OK', got '${out:-<err>}'"
    fi
}

# P3 — output shape. The hook must be indistinguishable in form from
# hooks/lang-inject.js: same envelope, same event name. A different envelope is
# silently dropped by Claude Code, which reads as "the feature does nothing".
run_P3() {
    require_module "$HOOK" || return 0
    local tmp out
    tmp="$(make_tmp)"
    "$RWT" 30 node -e "
const fs = require('fs');
fs.writeFileSync('$(node_path "$tmp")/transcript.jsonl', Buffer.alloc(400 * 1024, 120));
" >/dev/null 2>&1
    out=$(printf '{"session_id":"sid-p3","transcript_path":"%s","cwd":"%s","hook_event_name":"UserPromptSubmit","prompt":"go"}' \
        "$(node_path "$tmp")/transcript.jsonl" "$(node_path "$tmp")" \
        | env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID \
            CLAUDE_WORKFLOW_DIR="$tmp/wf" WORKFLOW_PLANS_DIR="$tmp/wf" \
            HOME="$tmp/home" USERPROFILE="$tmp/home" \
            "$RWT" 60 node "$AGENTS_DIR/$HOOK" 2>&1)
    local verdict
    verdict=$(env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID HOOK_OUT="$out" \
        CLAUDE_WORKFLOW_DIR="$tmp/wf" WORKFLOW_PLANS_DIR="$tmp/wf" \
        HOME="$tmp/home" USERPROFILE="$tmp/home" \
        "$RWT" 30 node -e "
const problems = [];
let parsed;
try { parsed = JSON.parse(process.env.HOOK_OUT); } catch (e) { problems.push('not-json:' + JSON.stringify(process.env.HOOK_OUT).slice(0, 200)); }
if (parsed) {
  const o = parsed.hookSpecificOutput;
  if (!o) problems.push('no-hookSpecificOutput:' + JSON.stringify(parsed));
  else {
    if (o.hookEventName !== 'UserPromptSubmit') problems.push('hookEventName:' + String(o.hookEventName));
    if (typeof o.additionalContext !== 'string' || o.additionalContext.length === 0) problems.push('additionalContext:' + JSON.stringify(o.additionalContext));
    else if (o.additionalContext.indexOf('handoff-emergency-flush') === -1) problems.push('does-not-point-at-the-rule:' + o.additionalContext.slice(0, 200));
  }
}
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
" 2>&1)
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$verdict" = "OK" ]; then
        pass "P3: the nudge emits the lang-inject envelope and points at rules/handoff-emergency-flush.md"
    else
        fail "P3: expected 'OK', got '${verdict:-<err>}' (hook stdout: ${out:0:200})"
    fi
}

# P4 — fail-open. A UserPromptSubmit hook that dies takes the user's turn with
# it, so every unreadable input must still print exactly `{}`.
run_P4() {
    require_module "$HOOK" || return 0
    local tmp bad1 bad2 bad3 problems
    tmp="$(make_tmp)"
    problems=""
    bad1=$(printf 'not json at all' | env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID \
        CLAUDE_WORKFLOW_DIR="$tmp/wf" WORKFLOW_PLANS_DIR="$tmp/wf" HOME="$tmp/home" USERPROFILE="$tmp/home" \
        "$RWT" 30 node "$AGENTS_DIR/$HOOK" 2>/dev/null)
    bad2=$(printf '{"session_id":"sid-p4"}' | env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID \
        CLAUDE_WORKFLOW_DIR="$tmp/wf" WORKFLOW_PLANS_DIR="$tmp/wf" HOME="$tmp/home" USERPROFILE="$tmp/home" \
        "$RWT" 30 node "$AGENTS_DIR/$HOOK" 2>/dev/null)
    bad3=$(printf '{"session_id":"sid-p4","transcript_path":"%s/nope.jsonl"}' "$(node_path "$tmp")" \
        | env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID \
        CLAUDE_WORKFLOW_DIR="$tmp/wf" WORKFLOW_PLANS_DIR="$tmp/wf" HOME="$tmp/home" USERPROFILE="$tmp/home" \
        "$RWT" 30 node "$AGENTS_DIR/$HOOK" 2>/dev/null)
    rm -rf "$tmp" 2>/dev/null || true
    [ "$(printf '%s' "$bad1" | tr -d ' \n\r')" = "{}" ] || problems="$problems malformed-stdin:'${bad1}'"
    [ "$(printf '%s' "$bad2" | tr -d ' \n\r')" = "{}" ] || problems="$problems no-transcript_path:'${bad2}'"
    [ "$(printf '%s' "$bad3" | tr -d ' \n\r')" = "{}" ] || problems="$problems unreadable-transcript:'${bad3}'"
    if [ -z "$problems" ]; then
        pass "P4: the nudge fails open with '{}' on malformed, incomplete and unreadable input"
    else
        fail "P4: expected '{}' in every degraded case —$problems"
    fi
}

# P5 — registration. Adding a hook to the ALREADY registered UserPromptSubmit
# array is what keeps this inside the PR's scope; registering a new event kind
# (PreCompact / SessionEnd) is explicitly out of scope.
run_P5() {
    require_module "$HOOK" || return 0
    local out
    out="$(run_node "
const fs = require('fs');
const s = JSON.parse(fs.readFileSync('$AGENTS_DIR_NODE/settings.json', 'utf8'));
const problems = [];
const hooks = (s && s.hooks) || {};
const registeredIn = [];
for (const evt of Object.keys(hooks)) {
  for (const m of hooks[evt] || []) {
    for (const h of (m && m.hooks) || []) {
      if (String(h.command || '').indexOf('handoff-pressure-nudge') !== -1) registeredIn.push(evt);
    }
  }
}
if (registeredIn.length === 0) problems.push('not-registered');
else if (registeredIn.join(',') !== 'UserPromptSubmit') problems.push('registered-in:' + registeredIn.join(','));
for (const forbidden of ['PreCompact', 'SessionEnd']) {
  if (hooks[forbidden] !== undefined) problems.push('new-event-key-added:' + forbidden);
}
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
")"
    if [ "$out" = "OK" ]; then
        pass "P5: the nudge is registered only under the existing UserPromptSubmit event"
    else
        fail "P5: expected 'OK', got '${out:-<err>}'"
    fi
}

run_P1
run_P2
run_P3
run_P4
run_P5

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
