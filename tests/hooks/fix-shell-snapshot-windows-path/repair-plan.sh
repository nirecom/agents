#!/usr/bin/env bash
# tests/hooks/fix-shell-snapshot-windows-path/repair-plan.sh
# Tests: hooks/lib/shell-snapshot-path.js
# Tags: hook, shell-snapshot, windows-path, repair-plan, scope:issue-specific, TL1
# Part of tests/hooks/fix-shell-snapshot-windows-path.sh (sourced by the dispatcher; uses its snap_js).
# planRepair with an injected stub converter: MSYS heads first, order kept, no duplicates,
# conversion is refused on any mismatch, and only windows-form input reaches the converter.

snap_js "repair-plan" <<'JS'
const P = () => load('hooks/lib/shell-snapshot-path.js');
const plan = (v, deps) => P().planRepair(v, deps);
const okValue = (r) => { assert.equal(r.ok, true, 'planRepair refused: ' + JSON.stringify(r)); return r.value; };

T('standard: System32 lands after /usr/bin', () => {
  const d = makeStubDeps();
  const v = okValue(plan(String.raw`C:\Windows\System32;C:\Program Files\Git\cmd`, d));
  assert.equal(v, '/mingw64/bin:/usr/local/bin:/usr/bin:/bin:/c/Windows/System32:/c/Program Files/Git/cmd');
  assert.ok(v.indexOf('/c/Windows/System32') > v.indexOf('/usr/bin'));
});
T('single element C:\\Windows', () => {
  assert.equal(okValue(plan(String.raw`C:\Windows`, makeStubDeps())), '/mingw64/bin:/usr/local/bin:/usr/bin:/bin:/c/Windows');
});
T('mixed: only drive elements go to the converter, once, joined by ";"', () => {
  const d = makeStubDeps();
  const v = okValue(plan(String.raw`C:\a;/usr/bin;C:\b`, d));
  assert.deepEqual(d.calls.toPosixList, [String.raw`C:\a;C:\b`]);
  const els = v.split(':');
  assert.equal(els.filter((e) => e === '/usr/bin').length, 1, v);
  assert.ok(els.indexOf('/c/a') >= 0 && els.indexOf('/c/a') < els.indexOf('/c/b'), v);
});
T('UNC element is passed to the converter', () => {
  const d = makeStubDeps({ convert: (l) => l.split(';').map((s) => (s.startsWith('\\\\') ? '//srv/share' : stubToPosixOne(s))).join(':') });
  okValue(plan(String.raw`\\srv\share;C:\a`, d));
  assert.deepEqual(d.calls.toPosixList, [String.raw`\\srv\share;C:\a`]);
});
T('Git usr\\bin element does not duplicate /usr/bin', () => {
  const v = okValue(plan(String.raw`C:\Program Files\Git\usr\bin;C:\Windows`, makeStubDeps()));
  assert.equal(v.split(':').filter((e) => e === '/usr/bin').length, 1, v);
});
T('heads that exist are kept, missing heads dropped', () => {
  const v = okValue(plan(String.raw`C:\a`, makeStubDeps({ heads: ['/usr/bin', '/bin'] })));
  assert.equal(v, '/usr/bin:/bin:/c/a');
});
T('empty ";" elements are dropped', () => {
  assert.equal(okValue(plan(String.raw`;C:\a;;C:\b;`, makeStubDeps())), '/mingw64/bin:/usr/local/bin:/usr/bin:/bin:/c/a:/c/b');
});
const reason = (r) => { assert.equal(r.ok, false, 'expected refusal, got ' + JSON.stringify(r)); return r.reason; };
T('conversion-mismatch: fewer elements than given', () => {
  assert.equal(reason(plan(String.raw`C:\a;C:\b`, makeStubDeps({ convert: () => '/c/a' }))), 'conversion-mismatch');
});
T('conversion-mismatch: ";" left in output', () => {
  assert.equal(reason(plan(String.raw`C:\a;C:\b`, makeStubDeps({ convert: () => '/c/a;/c/b' }))), 'conversion-mismatch');
});
T('conversion-mismatch: newline in output', () => {
  assert.equal(reason(plan(String.raw`C:\a;C:\b`, makeStubDeps({ convert: () => '/c/a:/c/b\n/x' }))), 'conversion-mismatch');
});
T('conversion-mismatch: single quote in output', () => {
  assert.equal(reason(plan(String.raw`C:\a;C:\b`, makeStubDeps({ convert: () => "/c/a:/c/b'x" }))), 'conversion-mismatch');
});
T('no-msys-usr-bin when /usr/bin is not among existing heads', () => {
  assert.equal(reason(plan(String.raw`C:\a;C:\b`, makeStubDeps({ heads: ['/mingw64/bin'] }))), 'no-msys-usr-bin');
});
for (const v of ['/usr/bin:/bin', String.raw`C:\repo\dotfiles/bin:/c/x`, String.raw`C:\a;relative\dir`, '/c/x:/d/y', '']) {
  T('not-windows-form for ' + JSON.stringify(v) + ', converter never called', () => {
    const d = makeStubDeps();
    assert.equal(reason(plan(v, d)), 'not-windows-form');
    assert.equal(d.calls.toPosixList.length, 0);
    assert.equal(d.calls.msysHeadExisting, 0);
  });
}
T('idempotent: every planned value classifies as ok, and is not windows-form again', () => {
  const L = P();
  for (const v of [String.raw`C:\Windows\System32;C:\Windows`, String.raw`C:\Windows`, String.raw`c:/a;c:/b`,
    String.raw`C:\a;/usr/bin`, String.raw`/usr/bin;C:\a`, String.raw`\\srv\share;C:\a`]) {
    const out = okValue(L.planRepair(v, makeStubDeps({ convert: (l) => l.split(';').map((s) => (s.startsWith('\\\\') ? '//srv/share' : stubToPosixOne(s))).join(':') })));
    assert.equal(L.classifyPathValue(out), 'ok', out);
    assert.equal(L.planRepair(out, makeStubDeps()).reason, 'not-windows-form');
  }
});
JS
