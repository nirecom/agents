#!/usr/bin/env bash
# tests/hooks/feat-2218-handoff-pressure.sh
# Tests: hooks/lib/handoff-pressure.js, hooks/handoff-pressure-nudge.js, settings.json
# Tags: handoff, context-pressure, user-prompt-submit, crisis-detection, fail-open, regression-2218, regression-2430, baseline-increment, nudge-trigger, risk-signal, flush-mark, time-injection, scope:issue-specific, pwsh-not-required, TL1

# Issue #2218 Step 10 detection layer, reshaped by #2430 — the self-report rule alone cannot fire when the model never notices the pressure. The hook measures transcript growth since a baseline that only a nudge or a main-session flush moves, so a hook-side write can never silence the check (#2430 baseline contract).

# TL3 gap: the real UserPromptSubmit dispatch — Claude Code actually feeding additionalContext back into the turn, and the 2MiB / 60 min constants' usefulness against a real compaction — is not exercised here. Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: hooks.

# TDD (#2430 write_code has not run): P1, P2, P3, P6 and every T3 row are expected to FAIL until the baseline sidecar, the flush-mark / risk derivation, the active-period gate and the new nudge text land. P4 and P5 stay green.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t 'wf2218'; }
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

AGENTS_DIR_NODE="$(node_path "$AGENTS_DIR")"
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_ENV_FILE

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
    out=$(env CLAUDE_WORKFLOW_DIR="$tn/wf" WORKFLOW_PLANS_DIR="$tn/wf" \
        HOME="$tn/home" USERPROFILE="$tn/home" \
        "$RWT" 60 node -e "$1" 2>&1)
    rm -rf "$tmp" 2>/dev/null || true
    printf '%s' "$out"
}

# run_js <tmp> <script-file> — run a generated script with the fixture pinned.
# The script reads every path from process.env, so no path is spliced into JS.
run_js() {
    local tn; tn="$(node_path "$1")"
    mkdir -p "$1/wf" "$1/home"
    env CLAUDE_WORKFLOW_DIR="$tn/wf" WORKFLOW_PLANS_DIR="$tn/wf" \
        HOME="$tn/home" USERPROFILE="$tn/home" TMPD="$tn" AGENTS="$AGENTS_DIR_NODE" \
        "$RWT" 60 node "$2" 2>&1
}

# P1 — the increment threshold, table driven. The baseline is planted at 0 and
# the clock is one minute past it, so only the bytes trigger can fire: strictly
# below 2MiB stays quiet, 2MiB itself fires with trigger "bytes".
run_P1() {
    require_module "$LIB" || return 0
    local tmp out
    tmp="$(make_tmp)"
    cat > "$tmp/p1.js" <<'JS'
const fs = require('fs');
const { computePressureSignal } = require(process.env.AGENTS + '/hooks/lib/handoff-pressure.js');
const D = process.env.TMPD, W = D + '/wf', MiB = 1024 * 1024, t0 = Date.parse('2026-01-01T00:00:00Z');
const problems = [];
const cases = [['under', 2 * MiB - 1, false], ['edge', 2 * MiB, true], ['over', 3 * MiB, true]];
for (const [sid, size, want] of cases) {
  fs.writeFileSync(W + '/' + sid + '-handoff-pressure.json', JSON.stringify({ baseline_bytes: 0, baseline_at: t0 }));
  fs.writeFileSync(D + '/' + sid + '.jsonl', Buffer.alloc(size, 120));
  const sig = computePressureSignal({ sid, transcriptPath: D + '/' + sid + '.jsonl', now: t0 + 60000 });
  if (!sig || sig.shouldNudge !== want) problems.push(sid + ':want=' + want + ':' + JSON.stringify(sig));
  else if (want && sig.trigger !== 'bytes') problems.push(sid + ':trigger=' + String(sig.trigger));
  else if (sig.bytesSince !== size) problems.push(sid + ':bytesSince=' + String(sig.bytesSince));
}
fs.writeFileSync(W + '/absent-handoff-pressure.json', JSON.stringify({ baseline_bytes: 0, baseline_at: t0 }));
const missing = computePressureSignal({ sid: 'absent', transcriptPath: D + '/absent.jsonl', now: t0 + 60000 });
if (!missing || missing.shouldNudge !== false) problems.push('absent-transcript:' + JSON.stringify(missing));
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
JS
    out="$(run_js "$tmp" "$(node_path "$tmp")/p1.js")"
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$out" = "OK" ]; then
        pass "P1: below a 2MiB increment stays quiet, 2MiB fires with trigger 'bytes', a missing transcript is quiet"
    else
        fail "P1: expected 'OK', got '${out:-<err>}'"
    fi
}

# P2 — the baseline lifecycle. The old design re-fired every turn once the
# transcript passed 300KB; the regression under test is "a nudge advances the
# baseline, so the very next turn is quiet", and "hook-side writes never move it".
run_P2() {
    require_module "$LIB" || return 0
    local tmp out
    tmp="$(make_tmp)"
    cat > "$tmp/p2.js" <<'JS'
const fs = require('fs');
const { computePressureSignal } = require(process.env.AGENTS + '/hooks/lib/handoff-pressure.js');
const { appendHandoffEntry } = require(process.env.AGENTS + '/hooks/lib/handoff-artifact.js');
const D = process.env.TMPD, W = D + '/wf', MiB = 1024 * 1024, t0 = Date.parse('2026-01-01T00:00:00Z');
const ms = (v) => new Date(v).getTime();
const readSide = (sid) => { try { return JSON.parse(fs.readFileSync(W + '/' + sid + '-handoff-pressure.json', 'utf8')); } catch (e) { return null; } };
const problems = [];
// (a) first sight: initialise, never nudge.
let t = D + '/a.jsonl';
fs.writeFileSync(t, Buffer.alloc(3 * MiB, 120));
let s = computePressureSignal({ sid: 'a', transcriptPath: t, now: t0 });
if (!s || s.shouldNudge !== false) problems.push('init-nudged:' + JSON.stringify(s));
let side = readSide('a');
if (!side || side.baseline_bytes !== 3 * MiB || ms(side.baseline_at) !== t0) problems.push('init-sidecar:' + JSON.stringify(side));
// (b) +2MiB fires and advances the baseline to {size, now}.
fs.appendFileSync(t, Buffer.alloc(2 * MiB, 121));
s = computePressureSignal({ sid: 'a', transcriptPath: t, now: t0 + 60000 });
if (!s || s.shouldNudge !== true || s.trigger !== 'bytes') problems.push('increment-did-not-fire:' + JSON.stringify(s));
side = readSide('a');
if (!side || side.baseline_bytes !== 5 * MiB || ms(side.baseline_at) !== t0 + 60000) problems.push('baseline-not-advanced:' + JSON.stringify(side));
// (c) the next turn adds a little: no re-fire.
fs.appendFileSync(t, Buffer.alloc(10 * 1024, 122));
s = computePressureSignal({ sid: 'a', transcriptPath: t, now: t0 + 120000 });
if (!s || s.shouldNudge !== false) problems.push('re-fired-next-turn:' + JSON.stringify(s));
// (d) auto-record / gate-block / procedure-point entries after the baseline do not move it.
t = D + '/d.jsonl';
fs.writeFileSync(W + '/d-handoff-pressure.json', JSON.stringify({ baseline_bytes: 0, baseline_at: t0 }));
for (const origin of ['auto-record', 'gate-block', 'procedure-point']) {
  appendHandoffEntry('d', { cls: 'C', step: '-', key: 'k-' + origin, summary: 's', pointer: '-', origin });
}
fs.writeFileSync(t, Buffer.alloc(2 * MiB, 120));
s = computePressureSignal({ sid: 'd', transcriptPath: t, now: t0 + 60000 });
if (!s || s.shouldNudge !== true) problems.push('hook-writes-silenced-the-check:' + JSON.stringify(s));
// (e) a shrunken transcript re-anchors baseline_bytes only.
t = D + '/e.jsonl';
fs.writeFileSync(W + '/e-handoff-pressure.json', JSON.stringify({ baseline_bytes: 5 * MiB, baseline_at: t0 }));
fs.writeFileSync(t, Buffer.alloc(1 * MiB, 120));
s = computePressureSignal({ sid: 'e', transcriptPath: t, now: t0 + 60000 });
if (!s || s.shouldNudge !== false) problems.push('shrink-nudged:' + JSON.stringify(s));
side = readSide('e');
if (!side || side.baseline_bytes !== 1 * MiB || ms(side.baseline_at) !== t0) problems.push('shrink-sidecar:' + JSON.stringify(side));
// (f) an unwritable sidecar never nudges — firing without advancing is the every-turn loop.
t = D + '/f.jsonl';
fs.mkdirSync(W + '/f-handoff-pressure.json');
fs.writeFileSync(t, Buffer.alloc(3 * MiB, 120));
for (const dt of [60000, 120000]) {
  s = computePressureSignal({ sid: 'f', transcriptPath: t, now: t0 + dt });
  if (!s || s.shouldNudge !== false) problems.push('unwritable-sidecar-nudged@' + dt + ':' + JSON.stringify(s));
}
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
JS
    out="$(run_js "$tmp" "$(node_path "$tmp")/p2.js")"
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$out" = "OK" ]; then
        pass "P2: init is quiet, a nudge advances the baseline, hook writes and shrinkage never fire, an unwritable sidecar never nudges"
    else
        fail "P2: expected 'OK', got '${out:-<err>}'"
    fi
}

# hook_fixture <tmp> — a 3MiB transcript and a baseline at 0 one minute ago:
# enough to fire whenever the session is inside its active period.
hook_fixture() {
    local tmp="$1"
    cat > "$tmp/fx.js" <<'JS'
const fs = require('fs');
const D = process.env.TMPD;
fs.writeFileSync(D + '/transcript.jsonl', Buffer.alloc(3 * 1024 * 1024, 120));
for (const sid of ['sid-p3', 'sid-p6']) {
  fs.writeFileSync(D + '/wf/' + sid + '-handoff-pressure.json', JSON.stringify({ baseline_bytes: 0, baseline_at: Date.now() - 60000 }));
}
if (process.env.ACTIVE_SID) {
  const S = require(process.env.AGENTS + '/hooks/workflow-state/state-io');
  S.writeState(process.env.ACTIVE_SID, S.createInitialState(process.env.ACTIVE_SID, { cwd: '/x', git_branch: 'feature/x' }));
  S.markStep(process.env.ACTIVE_SID, 'workflow_init', 'complete');
}
JS
    run_js "$tmp" "$(node_path "$tmp")/fx.js" >/dev/null
}

run_hook() {
    local tmp="$1" sid="$2" tn; tn="$(node_path "$tmp")"
    printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","hook_event_name":"UserPromptSubmit","prompt":"go"}' \
        "$sid" "$tn/transcript.jsonl" "$tn" \
        | env CLAUDE_WORKFLOW_DIR="$tn/wf" WORKFLOW_PLANS_DIR="$tn/wf" \
            HOME="$tn/home" USERPROFILE="$tn/home" \
            "$RWT" 60 node "$AGENTS_DIR/$HOOK" 2>&1
}

# P3 — output shape and wording. The envelope must match hooks/lang-inject.js
# (a different one is silently dropped). The text asks for an omission check,
# not a flush, and says to write nothing when nothing is missing.
run_P3() {
    require_module "$HOOK" || return 0
    local tmp out verdict
    tmp="$(make_tmp)"; mkdir -p "$tmp/wf"
    ACTIVE_SID="sid-p3" hook_fixture "$tmp"
    out="$(run_hook "$tmp" "sid-p3")"
    verdict=$(env HOOK_OUT="$out" "$RWT" 30 node -e "
const problems = [];
let parsed;
try { parsed = JSON.parse(process.env.HOOK_OUT); } catch (e) { problems.push('not-json:' + JSON.stringify(process.env.HOOK_OUT).slice(0, 200)); }
if (parsed) {
  const o = parsed.hookSpecificOutput;
  if (!o) problems.push('no-hookSpecificOutput:' + JSON.stringify(parsed));
  else {
    if (o.hookEventName !== 'UserPromptSubmit') problems.push('hookEventName:' + String(o.hookEventName));
    const c = typeof o.additionalContext === 'string' ? o.additionalContext : '';
    for (const need of ['[handoff check]', 'handoff-emergency-flush', 'What to record', 'C/D/F', 'write nothing', 'trigger: bytes']) {
      if (c.indexOf(need) === -1) problems.push('missing:' + need);
    }
    if (c.indexOf('since the last handoff write') !== -1) problems.push('old-wording-survives');
  }
}
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
" 2>&1)
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$verdict" = "OK" ]; then
        pass "P3: the nudge keeps the lang-inject envelope and asks for a C/D/F omission check that may write nothing"
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
    bad1=$(printf 'not json at all' | env \
        CLAUDE_WORKFLOW_DIR="$tmp/wf" WORKFLOW_PLANS_DIR="$tmp/wf" HOME="$tmp/home" USERPROFILE="$tmp/home" \
        "$RWT" 30 node "$AGENTS_DIR/$HOOK" 2>/dev/null)
    bad2=$(printf '{"session_id":"sid-p4"}' | env \
        CLAUDE_WORKFLOW_DIR="$tmp/wf" WORKFLOW_PLANS_DIR="$tmp/wf" HOME="$tmp/home" USERPROFILE="$tmp/home" \
        "$RWT" 30 node "$AGENTS_DIR/$HOOK" 2>/dev/null)
    bad3=$(printf '{"session_id":"sid-p4","transcript_path":"%s/nope.jsonl"}' "$(node_path "$tmp")" \
        | env \
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

# P6 — outside the workflow active period (no state for this sid) the same
# firing fixture must print `{}`: there is no workflow to resume, so nothing to
# check for.
run_P6() {
    require_module "$HOOK" || return 0
    local tmp out
    tmp="$(make_tmp)"; mkdir -p "$tmp/wf"
    hook_fixture "$tmp"
    out="$(run_hook "$tmp" "sid-p6")"
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$(printf '%s' "$out" | tr -d ' \n\r')" = "{}" ]; then
        pass "P6: outside the workflow active period the nudge prints '{}' even past the threshold"
    else
        fail "P6: expected '{}' for an inactive session, got '${out:0:200}'"
    fi
}

# T3 — #2430 ORed triggers: 2MiB of growth, or 60 min with any growth, halved
# to 1MiB / 30 min while a risk newer than the baseline is live; only a nudge or
# a flush restores the defaults. The T-2b rows pin the C3 regression: growth
# written after a flush must still count toward the next nudge. Time is
# injected as `now` and the sidecar / flush mark / risk file are planted with
# epoch-ms timestamps, so no row sleeps.
run_T3() {
    require_module "$LIB" || return 0
    local tmp results name desc got
    tmp="$(make_tmp)"
    cat > "$tmp/t3.js" <<'JS'
const fs = require('fs');
const P = require(process.env.AGENTS + '/hooks/lib/handoff-pressure.js');
const D = process.env.TMPD, W = D + '/wf';
const KiB = 1024, MiB = 1024 * KiB, MIN = 60000, t0 = Date.parse('2026-01-01T00:00:00Z'), B0 = 1 * MiB;
const ms = (v) => new Date(v).getTime();
const put = (name, obj) => fs.writeFileSync(W + '/' + name, typeof obj === 'string' ? obj : JSON.stringify(obj));
const side = (sid) => { try { return JSON.parse(fs.readFileSync(W + '/' + sid + '-handoff-pressure.json', 'utf8')); } catch (e) { return null; } };
// ev(sid, {size, now, base, risk, mark}) — plant the fixture and evaluate once.
const ev = (sid, o) => {
  if (o.base) put(sid + '-handoff-pressure.json', { baseline_bytes: o.base[0], baseline_at: o.base[1] });
  if (o.risk !== undefined) put(sid + '-handoff-risk.json', typeof o.risk === 'string' ? o.risk : { last_risk_at: o.risk, source: 'gate-block' });
  if (o.mark) put(sid + '-handoff-flush-mark.json', { bytes: o.mark[0], at: o.mark[1] });
  const t = D + '/' + sid + '.jsonl';
  if (o.size !== undefined) fs.writeFileSync(t, Buffer.alloc(o.size, 120));
  return P.computePressureSignal({ sid, transcriptPath: t, now: o.now });
};
const results = [];
const check = (name, fn) => {
  const bad = [];
  try { fn(bad); } catch (e) { bad.push('THREW:' + e.message); }
  results.push(name + ' ' + (bad.length ? 'BAD:' + bad.join(' | ') : 'OK'));
};
const want = (bad, label, sig, fire, trigger) => {
  if (!sig || sig.shouldNudge !== fire) bad.push(label + ':want-fire=' + fire + ':' + JSON.stringify(sig));
  else if (fire && sig.trigger !== trigger) bad.push(label + ':trigger=' + String(sig.trigger) + ',want=' + trigger);
};
const small = 100 * KiB;
check('elapsed-60min-boundary', (bad) => {
  want(bad, '59:59', ev('e1', { base: [B0, t0], size: B0 + small, now: t0 + 60 * MIN - 1000 }), false);
  const s = ev('e2', { base: [B0, t0], size: B0 + small, now: t0 + 60 * MIN });
  want(bad, '60:00', s, true, 'elapsed');
  if (s && s.riskActive !== false) bad.push('riskActive:' + String(s && s.riskActive));
});
check('no-growth-never-fires', (bad) => {
  want(bad, '120:00-zero-increment', ev('z1', { base: [B0, t0], size: B0, now: t0 + 120 * MIN }), false);
});
check('risk-resets-the-timer', (bad) => {
  const s = ev('r1', { base: [B0, t0], risk: t0 + 50 * MIN, size: B0 + small, now: t0 + 70 * MIN });
  want(bad, '70:00-after-risk-at-50', s, false);
  if (s && s.riskActive !== true) bad.push('riskActive:' + String(s.riskActive));
  if (s && s.msSinceTimer !== 20 * MIN) bad.push('msSinceTimer:' + String(s.msSinceTimer));
});
check('risk-halves-elapsed-to-30min', (bad) => {
  want(bad, '79:59', ev('r2', { base: [B0, t0], risk: t0 + 50 * MIN, size: B0 + small, now: t0 + 80 * MIN - 1000 }), false);
  want(bad, '80:00', ev('r3', { base: [B0, t0], risk: t0 + 50 * MIN, size: B0 + small, now: t0 + 80 * MIN }), true, 'elapsed');
});
check('risk-halves-increment-to-1MiB', (bad) => {
  want(bad, 'risk-1MiB', ev('h1', { base: [B0, t0], risk: t0 + MIN, size: B0 + MiB, now: t0 + 2 * MIN }), true, 'bytes');
  want(bad, 'risk-1MiB-1', ev('h2', { base: [B0, t0], risk: t0 + MIN, size: B0 + MiB - 1, now: t0 + 2 * MIN }), false);
  want(bad, 'no-risk-1MiB', ev('h3', { base: [B0, t0], size: B0 + MiB, now: t0 + 2 * MIN }), false);
});
check('risk-older-than-baseline-is-ignored', (bad) => {
  const s = ev('o1', { base: [B0, t0], risk: t0 - 10 * MIN, size: B0 + MiB, now: t0 + 2 * MIN });
  want(bad, 'no-halving', s, false);
  if (s && s.riskActive !== false) bad.push('riskActive:' + String(s.riskActive));
  want(bad, 'timer-from-baseline', ev('o2', { base: [B0, t0], risk: t0 - 10 * MIN, size: B0 + small, now: t0 + 60 * MIN - 1000 }), false);
});
check('nudge-restores-defaults', (bad) => {
  want(bad, 'fire-under-risk', ev('n1', { base: [B0, t0], risk: t0 + MIN, size: B0 + MiB, now: t0 + 2 * MIN }), true, 'bytes');
  want(bad, 'next-1MiB', ev('n1', { size: B0 + 2 * MiB, now: t0 + 3 * MIN }), false);
  want(bad, 'next-31min', ev('n1', { now: t0 + 33 * MIN }), false);
});
check('flush-restores-defaults', (bad) => {
  const o = { base: [B0, t0], risk: t0 + 10 * MIN, mark: [B0, t0 + 20 * MIN] };
  want(bad, 'after-flush-1MiB', ev('f1', Object.assign({}, o, { size: B0 + MiB, now: t0 + 21 * MIN })), false);
  want(bad, 'after-flush-31min', ev('f2', Object.assign({}, o, { size: B0 + small, now: t0 + 51 * MIN })), false);
});
check('risk-does-not-move-baseline-bytes', (bad) => {
  const s = ev('b1', { base: [B0, t0], risk: t0 + 5 * MIN, size: B0 + small, now: t0 + 6 * MIN });
  want(bad, 'quiet', s, false);
  if (s && s.bytesSince !== small) bad.push('bytesSince:' + String(s.bytesSince));
  const sc = side('b1');
  if (!sc || sc.baseline_bytes !== B0 || ms(sc.baseline_at) !== t0) bad.push('sidecar-moved:' + JSON.stringify(sc));
});
check('corrupt-risk-reads-as-none', (bad) => {
  const s = ev('c1', { base: [B0, t0], risk: '{ not json', size: B0 + MiB, now: t0 + 2 * MIN });
  want(bad, 'garbage', s, false);
  if (s && s.riskActive !== false) bad.push('riskActive:' + String(s.riskActive));
  fs.mkdirSync(W + '/c2-handoff-risk.json');
  want(bad, 'directory', ev('c2', { base: [B0, t0], size: B0 + MiB, now: t0 + 2 * MIN }), false);
});
check('trigger-table-is-ored', (bad) => {
  if (!Array.isArray(P.TRIGGERS)) { bad.push('TRIGGERS-not-exported'); return; }
  const probe = { name: 'probe', fires: () => true };
  P.TRIGGERS.push(probe);
  try {
    want(bad, 'probe', ev('x1', { base: [B0, t0], size: B0 + small, now: t0 + MIN }), true, 'probe');
  } finally { P.TRIGGERS.splice(P.TRIGGERS.indexOf(probe), 1); }
  want(bad, 'probe-removed', ev('x2', { base: [B0, t0], size: B0 + small, now: t0 + MIN }), false);
});
const S1 = 3 * MiB, t1 = t0 + 10 * MIN;
check('flush-mark-keeps-post-flush-growth', (bad) => {
  const s = ev('m1', { base: [B0, t0], mark: [S1, t1], size: S1 + 2 * MiB, now: t1 + MIN });
  want(bad, 'S1+2MiB', s, true, 'bytes');
  if (s && s.bytesSince !== 2 * MiB) bad.push('bytesSince:' + String(s.bytesSince));
});
check('flush-mark-below-threshold-is-quiet', (bad) => {
  want(bad, 'S1+1MiB', ev('m2', { base: [B0, t0], mark: [S1, t1], size: S1 + MiB, now: t1 + MIN }), false);
  const sc = side('m2');
  if (!sc || sc.baseline_bytes !== S1 || ms(sc.baseline_at) !== t1) bad.push('baseline-not-reset-to-mark:' + JSON.stringify(sc));
});
check('flush-mark-null-bytes-falls-back', (bad) => {
  want(bad, 'null', ev('m3', { base: [B0, t0], mark: [null, t1], size: S1 + 3 * MiB, now: t1 + MIN }), false);
  const sc = side('m3');
  if (!sc || sc.baseline_bytes !== S1 + 3 * MiB || ms(sc.baseline_at) !== t1) bad.push('fallback-sidecar:' + JSON.stringify(sc));
  want(bad, 'bytes-above-size', ev('m4', { base: [B0, t0], mark: [S1 + 9 * MiB, t1], size: S1 + 3 * MiB, now: t1 + MIN }), false);
});
check('flush-mark-older-than-baseline-is-ignored', (bad) => {
  want(bad, 'old-mark-1MiB', ev('m5', { base: [B0, t0], mark: [0, t0 - MIN], size: B0 + MiB, now: t0 + MIN }), false);
  const s = ev('m6', { base: [B0, t0], mark: [0, t0 - MIN], size: B0 + 2 * MiB, now: t0 + MIN });
  want(bad, 'old-mark-2MiB', s, true, 'bytes');
  if (s && s.bytesSince !== 2 * MiB) bad.push('bytesSince:' + String(s.bytesSince));
});
process.stdout.write(results.join('\n') + '\n');
JS
    results="$(run_js "$tmp" "$(node_path "$tmp")/t3.js")"
    rm -rf "$tmp" 2>/dev/null || true
    while IFS='|' read -r name desc; do
        got="$(printf '%s\n' "$results" | grep -E "^$name " | head -n 1)"
        got="${got#"$name "}"
        if [ "$got" = "OK" ]; then pass "T3 $name: $desc"; else fail "T3 $name: $desc — ${got:-<no row; output: ${results:0:300}>}"; fi
    done <<'ROWS'
elapsed-60min-boundary|59:59 is quiet, 60:00 fires with trigger 'elapsed'
no-growth-never-fires|120 min with a zero increment stays quiet
risk-resets-the-timer|a risk at +50 restarts the timer, so +70 is quiet
risk-halves-elapsed-to-30min|after a risk, 29:59 is quiet and 30:00 fires
risk-halves-increment-to-1MiB|a live risk fires at 1MiB but not 1MiB-1; without risk 1MiB is quiet
risk-older-than-baseline-is-ignored|a risk before the baseline neither halves nor restarts the timer
nudge-restores-defaults|a nudge under risk restores 2MiB / 60 min
flush-restores-defaults|a flush mark after a risk restores 2MiB / 60 min
risk-does-not-move-baseline-bytes|a risk leaves baseline_bytes where it was
corrupt-risk-reads-as-none|an unreadable risk file counts as no risk and does not throw
trigger-table-is-ored|an added trigger is ORed with the built-in ones
flush-mark-keeps-post-flush-growth|T-2b: 2MiB written after a flush still fires (C3)
flush-mark-below-threshold-is-quiet|T-2b: 1MiB after a flush is quiet and the baseline moves to the mark
flush-mark-null-bytes-falls-back|T-2b: a mark without bytes resets to the current size without firing
flush-mark-older-than-baseline-is-ignored|T-2b: a mark older than the baseline changes nothing
ROWS
}

run_P1
run_P2
run_P3
run_P4
run_P5
run_P6
run_T3

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
