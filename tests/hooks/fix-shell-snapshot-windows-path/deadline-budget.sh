#!/usr/bin/env bash
# tests/hooks/fix-shell-snapshot-windows-path/deadline-budget.sh
# Tests: hooks/lib/hook-deadline.js
# Tags: hook, shell-snapshot, deadline, time-budget, scope:issue-specific, TL1, TL2
# Part of tests/hooks/fix-shell-snapshot-windows-path.sh (sourced by the dispatcher; uses its snap_js).
# Deadline arithmetic, settings timeout == HOOK_TIMEOUT_MS, no fixed child timeouts left in
# session-start.js, the repair budget and scan cut, and a real-time run of session-start.js.
# TL3 gap: an existing child process that really takes 3 s cannot be staged (its path is fixed
# to __dirname); the static structure check and the sliceMs unit rows stand in for it.

snap_js "deadline" <<'JS'
const D = () => load('hooks/lib/hook-deadline.js');
const R = () => load('hooks/lib/shell-snapshot-repair.js');
const src = (rel) => fs.readFileSync(path.join(ROOT, rel), 'utf8');
function hookTimeoutConst(rel) {
  const m = /const\s+HOOK_TIMEOUT_MS\s*=\s*(\d+)\s*;/.exec(src(rel));
  assert.ok(m, rel + ' has no `const HOOK_TIMEOUT_MS = <n>;`');
  return Number(m[1]);
}
function settingsTimeouts(event, needle) {
  const s = JSON.parse(src('settings.json'));
  const out = [];
  for (const g of (s.hooks && s.hooks[event]) || []) for (const h of g.hooks || []) if (String(h.command).includes(needle)) out.push(h.timeout);
  return out;
}
for (const [event, file] of [['SessionStart', 'hooks/session-start.js'], ['PostToolUse', 'hooks/postuse-shell-snapshot-repair.js'], ['PostToolUseFailure', 'hooks/postuse-shell-snapshot-repair.js']]) {
  T('settings ' + event + ' timeout x1000 == HOOK_TIMEOUT_MS of ' + file, () => {
    const ts = settingsTimeouts(event, path.basename(file));
    assert.equal(ts.length, 1, event + ' entries for ' + file + ': ' + JSON.stringify(ts));
    assert.equal(ts[0] * 1000, hookTimeoutConst(file));
  });
}
const clock = (start = 1000000) => { const c = { t: start }; c.now = () => c.t; return c; };
T('remainingMs = hookTimeoutMs - safetyMarginMs - elapsed', () => {
  const c = clock();
  const dl = D().createDeadline({ hookTimeoutMs: 5000, safetyMarginMs: 700, now: c.now, uptimeSec: () => 0 });
  assert.equal(dl.remainingMs(), 4300);
  c.t += 1000;
  assert.equal(dl.remainingMs(), 3300);
});
T('a larger process uptime leaves less time', () => {
  const c = clock();
  const dl = D().createDeadline({ hookTimeoutMs: 5000, safetyMarginMs: 700, now: c.now, uptimeSec: () => 1.5 });
  assert.equal(dl.remainingMs(), 2800);
});
T('default safety margin is DEFAULT_SAFETY_MARGIN_MS (700)', () => {
  const L = D();
  assert.equal(L.DEFAULT_SAFETY_MARGIN_MS, 700);
  const c = clock();
  assert.equal(L.createDeadline({ hookTimeoutMs: 5000, now: c.now, uptimeSec: () => 0 }).remainingMs(), 4300);
});
T('sliceMs: capped, reserve subtracted, under MIN_SLICE_MS -> 0, negative -> 0', () => {
  const L = D();
  assert.equal(L.MIN_SLICE_MS, 100);
  const c = clock();
  const dl = L.createDeadline({ hookTimeoutMs: 5000, safetyMarginMs: 700, now: c.now, uptimeSec: () => 0 });
  assert.equal(dl.sliceMs(3000, 400), 3000);
  c.t += 1000;
  assert.equal(dl.sliceMs(3000, 400), 2900);
  c.t += 2700;
  assert.equal(dl.sliceMs(3000, 400), 200);
  c.t += 150;
  assert.equal(dl.sliceMs(3000, 400), 0);
  c.t += 5000;
  assert.equal(dl.sliceMs(3000, 0), 0);
});
T('session-start.js: no literal child timeout left; deadline wired', () => {
  const s = src('hooks/session-start.js');
  assert.doesNotMatch(s, /timeout:\s*\d/);
  assert.match(s, /createDeadline\(/);
  assert.match(s, /sliceMs\(/);
});
T('repair budget runs out mid-way: rest deferred as time-budget', () => {
  const c = clock();
  const dl = D().createDeadline({ hookTimeoutMs: 600000, safetyMarginMs: 700, now: c.now, uptimeSec: () => 0 });
  const h = mkd('home'); const d = snapDir(h);
  for (let i = 0; i < 5; i++) writeSnap(d, snapName(1800000000000 + i * 1000), String.raw`C:\a;C:\b`);
  const stub = makeStubDeps({ onConvert: () => { c.t += 400; } });
  const r = R().scanAndRepair({ homeDir: h, platform: 'win32', converterDeps: stub, deadline: dl, budgetMs: 1000 });
  const rep = count(r.repaired);
  assert.ok(rep >= 1 && rep <= 4, 'repaired=' + rep);
  assert.equal(rep + count(r.deferred), 5);
  assert.match(JSON.stringify(r.deferred) + noticeText(R().formatRepairNotice(r, { trigger: 'session-start' })), /time-budget/);
});
T('detect-only below MIN_REPAIR_SLICE_MS: converter never called', () => {
  const h = mkd('home'); const d = snapDir(h);
  writeSnap(d, snapName(1800000000000), String.raw`C:\a;C:\b`);
  const stub = makeStubDeps();
  const r = R().scanAndRepair({ homeDir: h, platform: 'win32', converterDeps: stub, deadline: fakeDeadline(60000), budgetMs: R().MIN_REPAIR_SLICE_MS - 100 });
  assert.equal(stub.calls.toPosixList.length, 0);
  assert.equal(count(r.repaired), 0);
  assert.equal(count(r.deferred), 1);
});
T('scan cut below 50 ms: everything left is unscanned and warned', () => {
  const h = mkd('home'); const d = snapDir(h);
  for (let i = 0; i < 3; i++) writeSnap(d, snapName(1800000000000 + i), String.raw`C:\a;C:\b`);
  const r = R().scanAndRepair({ homeDir: h, platform: 'win32', converterDeps: makeStubDeps(), deadline: fakeDeadline(40), budgetMs: 0 });
  assert.equal(count(r.unscanned), 3);
  assert.match(noticeText(R().formatRepairNotice(r, { trigger: 'session-start' })), /unscanned|scan/i);
});
JS

# TL2 real time: 20 windows-form snapshots, the real session-start.js, valid JSON
# inside hookTimeoutMs - safetyMarginMs + 300 ms (5000 - 700 + 300).
SNAP_DB_HOME="$SNAP_TMP/deadline-home"
for _i in $(seq 10 29); do
  snap_write "$SNAP_DB_HOME/.claude/shell-snapshots" "snapshot-bash-18000000000${_i}-rt${_i}.sh" 'C:\Windows\System32;C:\Windows'
done
SNAP_DB_START="$(now_ms)"
SNAP_DB_OUT="$(printf '{"session_id":"deadline-rt","source":"startup"}' | HOME="$SNAP_DB_HOME" USERPROFILE="$SNAP_DB_HOME" run_with_timeout 30 node "$SESSION_START_HOOK" 2>/dev/null)"
SNAP_DB_RC=$?
SNAP_DB_ELAPSED=$(( $(now_ms) - SNAP_DB_START ))
printf '%s' "$SNAP_DB_OUT" > "$SNAP_TMP/deadline-rt.json"
if [ "$SNAP_DB_RC" -eq 0 ] && [ "$(json_get "$SNAP_TMP/deadline-rt.json" '')" != "__INVALID__" ] && [ "$(json_get "$SNAP_TMP/deadline-rt.json" '')" != "__EMPTY__" ]; then
  pass "deadline: session-start.js with 20 snapshots returns valid JSON (rc=0)"
else
  fail "deadline: session-start.js with 20 snapshots returns valid JSON" "rc=$SNAP_DB_RC out=${SNAP_DB_OUT:0:200}"
fi
if [ "$SNAP_DB_ELAPSED" -le 4600 ]; then
  pass "deadline: session-start.js finished in ${SNAP_DB_ELAPSED}ms (<= 4600)"
else
  fail "deadline: session-start.js finished within 4600ms" "elapsed=${SNAP_DB_ELAPSED}ms"
fi
