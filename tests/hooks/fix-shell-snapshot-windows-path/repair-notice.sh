#!/usr/bin/env bash
# tests/hooks/fix-shell-snapshot-windows-path/repair-notice.sh
# Tests: hooks/lib/shell-snapshot-repair.js
# Tags: hook, shell-snapshot, notice, wording, scope:issue-specific, TL1
# Part of tests/hooks/fix-shell-snapshot-windows-path.sh (sourced by the dispatcher; uses its snap_js).
# formatRepairNotice wording: the confirmed-exit-127 sentence only when exit 127 was confirmed,
# a neutral sentence otherwise, and failed/unrepairable lines that never promise deletion.
# Results come from real scanAndRepair runs on fixtures, so the result shape is never guessed.

snap_js "notice" <<'JS'
const R = () => load('hooks/lib/shell-snapshot-repair.js');
const CONFIRMED = process.env.SNAP_CONFIRMED_SENTENCE;
const BASE = 1800000000000;
function resultsFor(value, extra = {}) {
  const h = mkd('home'); const d = snapDir(h);
  const f = writeSnap(d, snapName(BASE), value);
  const r = R().scanAndRepair(Object.assign({ homeDir: h, platform: 'win32', converterDeps: makeStubDeps(), deadline: fakeDeadline(60000), budgetMs: 60000 }, extra));
  return { r, name: path.basename(f) };
}
const fmt = (r, o) => noticeText(R().formatRepairNotice(r, o));
const NEUTRAL_FORBIDDEN = ['exited with code 127', 'exiting 127', 'previous command', 're-run'];
const assertNeutral = (t) => {
  assert.match(t, /PATH has been repaired/);
  assert.match(t, /takes effect for subsequent Bash calls/);
  for (const w of NEUTRAL_FORBIDDEN) assert.ok(!t.toLowerCase().includes(w), 'neutral notice contains "' + w + '": ' + t);
};

T('confirmed exit 127: the exact sentence, every required phrase', () => {
  const { r } = resultsFor(String.raw`C:\a;C:\b`);
  assert.equal(count(r.repaired), 1);
  const t = fmt(r, { trigger: 'first', failedCommandExit127: true });
  assert.ok(t.includes(CONFIRMED), t);
  for (const w of ['exited with code 127', 'PATH has been repaired', 'check whether it changed any state before exiting 127', 're-run it only if needed', 'did not re-run']) assert.ok(t.includes(w), w);
});
T('confirmed exit 127: no unconditional re-run advice', () => {
  const { r } = resultsFor(String.raw`C:\a;C:\b`);
  const t = fmt(r, { trigger: 'recheck', failedCommandExit127: true });
  assert.doesNotMatch(t, /Re-run the same command|run it again to get/i);
});
// PostToolUse and a non-127 PostToolUseFailure reach the notice with the same opts; the decide
// layer tells them apart (postuse-decide.sh), so one row covers both here.
const NEUTRAL_CALLS = [
  ['(a) first, exit 127 not confirmed', { trigger: 'first', failedCommandExit127: false }],
  ['(b) SessionStart startup', { trigger: 'session-start', failedCommandExit127: false, affectsCurrentSession: false }],
  ['(c) SessionStart compact, current session', { trigger: 'session-start', failedCommandExit127: false, affectsCurrentSession: true }],
];
for (const [label, opts] of NEUTRAL_CALLS) {
  T('neutral wording ' + label, () => { assertNeutral(fmt(resultsFor(String.raw`C:\a;C:\b`).r, opts)); });
}
T('(c) affectsCurrentSession adds the likely-this-session line, (b) does not', () => {
  const { r } = resultsFor(String.raw`C:\a;C:\b`);
  const c = fmt(r, NEUTRAL_CALLS[2][1]);
  const b = fmt(r, NEUTRAL_CALLS[1][1]);
  assert.match(c, /likely this session/i);
  assert.doesNotMatch(b, /likely this session/i);
});
T('affectsCurrentSession and failedCommandExit127 are independent', () => {
  const { r } = resultsFor(String.raw`C:\a;C:\b`);
  assert.doesNotMatch(fmt(r, { trigger: 'session-start', affectsCurrentSession: true, failedCommandExit127: false }), /re-run/i);
  assert.ok(fmt(r, { trigger: 'recheck', affectsCurrentSession: false, failedCommandExit127: true }).includes(CONFIRMED));
});
T('the shared repaired line never mentions exit 127 by itself', () => {
  const { r } = resultsFor(String.raw`C:\a;C:\b`);
  const lines = fmt(r, { trigger: 'first', failedCommandExit127: true }).split('\n').filter((l) => !l.includes(CONFIRMED));
  for (const l of lines) assert.doesNotMatch(l, /127/, l);
});
function assertWarnLine(t, reason, name) {
  assert.match(t, /not rewritten/i);
  assert.match(t, /restart/i);
  assert.ok(t.includes('/sweep-shell-snapshots --dry-run'), t);
  assert.ok(t.includes(reason), 'reason ' + reason + ' missing: ' + t);
  assert.ok(t.includes(name), 'file name missing: ' + t);
  assert.doesNotMatch(t, /will be deleted|will delete/i);
  assert.doesNotMatch(t, /sweep[^.\n]*(fix|repair)[^.\n]*this session/i);
}
T('unrepairable warning: not rewritten, restart, dry-run, reason, name, no deletion promise', () => {
  const { r, name } = resultsFor(String.raw`C:\a;relative\dir`);
  assertWarnLine(fmt(r, { trigger: 'first', failedCommandExit127: false }), 'windows-unrepairable', name);
});
T('unrepairable colon-trace form warns the same way', () => {
  const { r, name } = resultsFor(String.raw`C:\repo\dotfiles/bin:/c/x`);
  assertWarnLine(fmt(r, { trigger: 'session-start' }), 'windows-unrepairable', name);
});
T('failed (cygpath-unavailable) warning: windows-form reason, failure reason, name', () => {
  const { r, name } = resultsFor(String.raw`C:\a;C:\b`, { converterDeps: null });
  const t = fmt(r, { trigger: 'first', failedCommandExit127: true });
  assertWarnLine(t, 'windows-form', name);
  assert.ok(t.includes('cygpath-unavailable'), t);
  assert.ok(!t.includes(CONFIRMED), 'nothing was repaired, so no confirmed sentence');
});
T('deferred max-repairs is named in the notice', () => {
  const h = mkd('home'); const d = snapDir(h);
  for (let i = 0; i < 6; i++) writeSnap(d, snapName(BASE + i * 1000), String.raw`C:\a;C:\b`);
  const r = R().scanAndRepair({ homeDir: h, platform: 'win32', converterDeps: makeStubDeps(), deadline: fakeDeadline(60000), budgetMs: 60000, maxRepairs: 5 });
  assert.match(fmt(r, { trigger: 'recheck', failedCommandExit127: true }), /max-repairs/);
});
T('missingCore (win32): one line with the count and the dry-run pointer', () => {
  const { r } = resultsFor('/c/x:/d/y');
  assert.equal(count(r.missingCore), 1);
  const lines = fmt(r, { trigger: 'session-start' }).split('\n').filter((l) => l.includes('/sweep-shell-snapshots --dry-run'));
  assert.equal(lines.length, 1, 'expected one dry-run line: ' + JSON.stringify(lines));
  assert.match(lines[0], /\b1\b/, 'count missing: ' + lines[0]);
});
T('missingCore 0 (not win32): no dry-run pointer', () => {
  const { r } = resultsFor('/c/x:/d/y', { platform: 'linux' });
  assert.equal(count(r.missingCore), 0);
  assert.ok(!fmt(r, { trigger: 'session-start' }).includes('/sweep-shell-snapshots --dry-run'));
});
T('ok directory -> no notice lines', () => {
  const { r } = resultsFor('/usr/bin:/bin');
  assert.equal(fmt(r, { trigger: 'first' }).trim(), '');
});
T('SWEEP_HOLDBACK_NOTE_MINUTES equals the sweep MIN_AGE_MINUTES default', () => {
  const m = /^MIN_AGE_MINUTES=(\d+)\s*$/m.exec(fs.readFileSync(path.join(ROOT, 'bin/sweep-shell-snapshots.sh'), 'utf8'));
  assert.ok(m, 'MIN_AGE_MINUTES default not found');
  assert.equal(R().SWEEP_HOLDBACK_NOTE_MINUTES, Number(m[1]));
});
JS
