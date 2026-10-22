# #2218 / #2430 detection-layer cases, folded into ../feat-progress-pressure.sh (was
# tests/hooks/feat-2218-progress-pressure.sh). This part holds the shared helpers and P1 / P2;
# legacy-2218-hook.sh holds P3-P6 and legacy-2218-triggers.sh holds T3. Each run_* is called by
# the dispatcher inside its own case block, after the dispatcher's top-level pins.
# The hook measures transcript growth since a baseline that only a request or a session-progress.md
# update moves, so a hook-side write can never silence the check. The #2430 flush mark is
# retired (#2594). Assumed contract: progress-pressure.json keeps baseline_bytes / baseline_at
# and computePressureSignal keeps its {sid, transcriptPath, now} signature.

L2218_RWT="$SCRIPT_CHECKOUT_ROOT/bin/run-with-timeout.sh"
L2218_ROOT_NODE="$(np "$SCRIPT_CHECKOUT_ROOT")"
L2218_LIB="hooks/lib/progress-pressure.js"
L2218_HOOK="hooks/progress-nudge.js"

l2218_require_module() {
    if [ -f "$SCRIPT_CHECKOUT_ROOT/$1" ]; then return 0; fi
    fail "MODULE NOT FOUND: $1 — expected per issue #2594 (renamed from the #2218 handoff-pressure module), not yet implemented (write_code has not run)"
    return 1
}

l2218_run_node() {
    local tmp tn out
    tmp="$(make_tmp)"; tn="$(np "$tmp")"
    out=$(env WORKFLOW_STATE_DIR="$tn/wf" WORKFLOW_PLANS_DIR="$tn/wf" \
        HOME="$tn/home" USERPROFILE="$tn/home" \
        "$L2218_RWT" 60 node -e "$1" 2>&1)
    rm -rf "$tmp" 2>/dev/null || true
    printf '%s' "$out"
}

# l2218_run_js <tmp> <script-file> — run a generated script with the fixture pinned.
# The script reads every path from process.env, so no path is spliced into JS.
l2218_run_js() {
    local tn; tn="$(np "$1")"
    mkdir -p "$1/wf" "$1/home"
    env WORKFLOW_STATE_DIR="$tn/wf" WORKFLOW_PLANS_DIR="$tn/wf" \
        HOME="$tn/home" USERPROFILE="$tn/home" TMPD="$tn" AGENTS="$L2218_ROOT_NODE" \
        "$L2218_RWT" 60 node "$2" 2>&1
}

# P1 — the increment threshold, table driven. The baseline is planted at 0 and
# the clock is one minute past it, so only the bytes trigger can fire: strictly
# below 2MiB stays quiet, 2MiB itself fires with trigger "bytes".
run_P1() {
    l2218_require_module "$L2218_LIB" || return 0
    local tmp out
    tmp="$(make_tmp)"
    cat > "$tmp/p1.js" <<'JS'
const fs = require('fs');
const { computePressureSignal } = require(process.env.AGENTS + '/hooks/lib/progress-pressure.js');
const D = process.env.TMPD, W = D + '/wf', MiB = 1024 * 1024, t0 = Date.parse('2026-01-01T00:00:00Z');
const ctl = (sid, name) => { fs.mkdirSync(W + '/' + sid + '.control', { recursive: true }); return W + '/' + sid + '.control/' + name; };
const problems = [];
const cases = [['under', 2 * MiB - 1, false], ['edge', 2 * MiB, true], ['over', 3 * MiB, true]];
for (const [sid, size, want] of cases) {
  fs.writeFileSync(ctl(sid, 'progress-pressure.json'), JSON.stringify({ baseline_bytes: 0, baseline_at: t0 }));
  fs.writeFileSync(D + '/' + sid + '.jsonl', Buffer.alloc(size, 120));
  const sig = computePressureSignal({ sid, transcriptPath: D + '/' + sid + '.jsonl', now: t0 + 60000 });
  if (!sig || sig.shouldNudge !== want) problems.push(sid + ':want=' + want + ':' + JSON.stringify(sig));
  else if (want && sig.trigger !== 'bytes') problems.push(sid + ':trigger=' + String(sig.trigger));
  else if (sig.bytesSince !== size) problems.push(sid + ':bytesSince=' + String(sig.bytesSince));
}
fs.writeFileSync(ctl('absent', 'progress-pressure.json'), JSON.stringify({ baseline_bytes: 0, baseline_at: t0 }));
const missing = computePressureSignal({ sid: 'absent', transcriptPath: D + '/absent.jsonl', now: t0 + 60000 });
if (!missing || missing.shouldNudge !== false) problems.push('absent-transcript:' + JSON.stringify(missing));
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
JS
    out="$(l2218_run_js "$tmp" "$(np "$tmp")/p1.js")"
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$out" = "OK" ]; then
        pass "P1: below a 2MiB increment stays quiet, 2MiB fires with trigger 'bytes', a missing transcript is quiet"
    else
        fail "P1: expected 'OK', got '${out:-<err>}'"
    fi
}

# P2 — the baseline lifecycle. The old design re-fired every turn once the
# transcript passed 300KB; the regression under test is "a request advances the
# baseline, so the very next turn is quiet", and "hook-side writes never move it".
run_P2() {
    l2218_require_module "$L2218_LIB" || return 0
    local tmp out
    tmp="$(make_tmp)"
    cat > "$tmp/p2.js" <<'JS'
const fs = require('fs');
const { computePressureSignal } = require(process.env.AGENTS + '/hooks/lib/progress-pressure.js');
const { appendHandoffEntry } = require(process.env.AGENTS + '/hooks/lib/handoff-artifact.js');
const D = process.env.TMPD, W = D + '/wf', MiB = 1024 * 1024, t0 = Date.parse('2026-01-01T00:00:00Z');
const ms = (v) => new Date(v).getTime();
const ctl = (sid, name) => { fs.mkdirSync(W + '/' + sid + '.control', { recursive: true }); return W + '/' + sid + '.control/' + name; };
const readSide = (sid) => { try { return JSON.parse(fs.readFileSync(ctl(sid, 'progress-pressure.json'), 'utf8')); } catch (e) { return null; } };
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
fs.writeFileSync(ctl('d', 'progress-pressure.json'), JSON.stringify({ baseline_bytes: 0, baseline_at: t0 }));
for (const origin of ['auto-record', 'gate-block', 'procedure-point']) {
  appendHandoffEntry('d', { cls: 'C', step: '-', key: 'k-' + origin, summary: 's', pointer: '-', origin });
}
fs.writeFileSync(t, Buffer.alloc(2 * MiB, 120));
s = computePressureSignal({ sid: 'd', transcriptPath: t, now: t0 + 60000 });
if (!s || s.shouldNudge !== true) problems.push('hook-writes-silenced-the-check:' + JSON.stringify(s));
// (e) a shrunken transcript re-anchors baseline_bytes only.
t = D + '/e.jsonl';
fs.writeFileSync(ctl('e', 'progress-pressure.json'), JSON.stringify({ baseline_bytes: 5 * MiB, baseline_at: t0 }));
fs.writeFileSync(t, Buffer.alloc(1 * MiB, 120));
s = computePressureSignal({ sid: 'e', transcriptPath: t, now: t0 + 60000 });
if (!s || s.shouldNudge !== false) problems.push('shrink-nudged:' + JSON.stringify(s));
side = readSide('e');
if (!side || side.baseline_bytes !== 1 * MiB || ms(side.baseline_at) !== t0) problems.push('shrink-sidecar:' + JSON.stringify(side));
// (f) an unwritable sidecar never nudges — firing without advancing is the every-turn loop.
t = D + '/f.jsonl';
fs.mkdirSync(ctl('f', 'progress-pressure.json'));
fs.writeFileSync(t, Buffer.alloc(3 * MiB, 120));
for (const dt of [60000, 120000]) {
  s = computePressureSignal({ sid: 'f', transcriptPath: t, now: t0 + dt });
  if (!s || s.shouldNudge !== false) problems.push('unwritable-sidecar-nudged@' + dt + ':' + JSON.stringify(s));
}
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
JS
    out="$(l2218_run_js "$tmp" "$(np "$tmp")/p2.js")"
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$out" = "OK" ]; then
        pass "P2: init is quiet, a request advances the baseline, hook writes and shrinkage never fire, an unwritable sidecar never nudges"
    else
        fail "P2: expected 'OK', got '${out:-<err>}'"
    fi
}
