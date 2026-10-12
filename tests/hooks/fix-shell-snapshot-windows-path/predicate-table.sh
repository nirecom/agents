#!/usr/bin/env bash
# tests/hooks/fix-shell-snapshot-windows-path/predicate-table.sh
# Tests: hooks/lib/shell-snapshot-path.js
# Tags: hook, shell-snapshot, windows-path, classify, scope:issue-specific, TL1
# Part of tests/hooks/fix-shell-snapshot-windows-path.sh (sourced by the dispatcher; uses its snap_js).
# One row per representative example of the plan's classification table, plus hasWindowsSign,
# the sign/verdict invariants, and classifySnapshotText on whole-file shapes.

snap_js "predicate" <<'JS'
const P = () => load('hooks/lib/shell-snapshot-path.js');
const LONG = Array.from({ length: 1500 }, (_, i) => 'C:\\Program Files\\Vendor' + i + '\\bin').join(';');
const ROWS = {
  'ok': [String.raw`/usr/bin:/bin`, String.raw`/usr/bin/:/bin`, String.raw`/bin:/x`,
    String.raw`/c/WINDOWS/System32/OpenSSH:/mingw64/bin:/usr/bin:/bin:C:\repo\dotfiles/bin:/x`,
    String.raw`C:\a;C:\b:/usr/bin`],
  'windows-form': [String.raw`C:\Windows\System32;C:\Windows`, String.raw`C:\Windows`, String.raw`c:/a;c:/b`,
    String.raw`C:\a;C:\b;`, String.raw`;C:\a`, String.raw`;C:\a;C:\b`, String.raw`\\srv\share;C:\a`,
    String.raw`C:\a;/usr/bin`, String.raw`/usr/bin;C:\a`, LONG],
  'windows-unrepairable': [String.raw`C:\a;relative\dir`, String.raw`%SystemRoot%\x;C:\a`, String.raw`C:\a;~/bin`,
    String.raw`1:\x;2:\y`, String.raw`C:\repo\dotfiles/bin:/c/x`, String.raw`C:\a:C:\b`, String.raw`/x:C:\a`,
    String.raw`/c/WINDOWS/System32:C:\repo\dotfiles/bin:/x`],
  'missing-core': ['', String.raw`/definitely/not:/bin2`, String.raw`/c/x:/d/y`, String.raw`/opt/C:/x`],
};
const show = (v) => (v.length > 60 ? v.slice(0, 40) + '...(' + v.length + ' chars)' : JSON.stringify(v));

T('LONG fixture is a 32KB-class Windows PATH', () => { assert.ok(LONG.length >= 32000, String(LONG.length)); });
for (const [verdict, values] of Object.entries(ROWS)) {
  for (const v of values) {
    T('classifyPathValue ' + show(v) + ' -> ' + verdict, () => { assert.equal(P().classifyPathValue(v), verdict); });
  }
}
for (const verdict of ['windows-form', 'windows-unrepairable']) {
  for (const v of ROWS[verdict]) {
    T('hasWindowsSign true for ' + verdict + ' ' + show(v), () => { assert.equal(P().hasWindowsSign(v), true); });
  }
}
for (const v of ROWS['missing-core']) {
  T('hasWindowsSign false for missing-core ' + show(v), () => { assert.equal(P().hasWindowsSign(v), false); });
}
T('invariant: a Windows sign never classifies as missing-core', () => {
  const L = P();
  for (const v of Object.values(ROWS).flat()) {
    if (L.hasWindowsSign(v)) assert.notEqual(L.classifyPathValue(v), 'missing-core', show(v));
  }
});
// Plan: a drive/UNC trace mixed in with ':' separators. A lone drive element (C:\Windows) has
// only its leading drive colon, so it is windows-form and stays out of this selection.
T('invariant: a drive trace mixed with ":" separators (no ";") that is not ok is windows-unrepairable', () => {
  const L = P();
  const trace = /(^|[;:])([A-Za-z]:[\\/]|\\\\)/;
  const colonSeparated = (v) => v.replace(/^[A-Za-z]:(?=[\\/])/, '').includes(':');
  let checked = 0;
  for (const v of Object.values(ROWS).flat()) {
    if (trace.test(v) && !v.includes(';') && colonSeparated(v) && L.classifyPathValue(v) !== 'ok') {
      checked++;
      assert.equal(L.classifyPathValue(v), 'windows-unrepairable', show(v));
    }
  }
  assert.ok(checked >= 4, 'expected at least 4 colon-trace rows, saw ' + checked);
});
T('VERDICTS lists every value verdict and the text-only verdicts', () => {
  const vs = Object.values(P().VERDICTS);
  for (const v of ['ok', 'windows-form', 'windows-unrepairable', 'missing-core', 'no-path-line', 'unparsed']) {
    assert.ok(vs.includes(v), 'missing ' + v);
  }
});
T('MSYS_HEAD_CANDIDATES is the ordered MSYS head list', () => {
  assert.deepEqual(Array.from(P().MSYS_HEAD_CANDIDATES), ['/mingw64/bin', '/usr/local/bin', '/usr/bin', '/bin']);
});

// classifySnapshotText on whole-file shapes.
const PRE = '# Snapshot file\nunalias -a 2>/dev/null || true\nshopt -s expand_aliases\n';
T('classifySnapshotText: no PATH line -> no-path-line', () => {
  assert.equal(P().classifySnapshotText(PRE + "alias ll='ls -l'\n"), 'no-path-line');
});
T('classifySnapshotText: double-quoted PATH line -> no-path-line', () => {
  assert.equal(P().classifySnapshotText(PRE + 'export PATH="C:\\a;C:\\b"\n'), 'no-path-line');
});
T('classifySnapshotText: two PATH lines, the first decides', () => {
  assert.equal(P().classifySnapshotText(PRE + "export PATH='C:\\a;C:\\b'\nexport PATH='/usr/bin:/bin'\n"), 'windows-form');
  assert.equal(P().classifySnapshotText(PRE + "export PATH='/usr/bin:/bin'\nexport PATH='C:\\a;C:\\b'\n"), 'ok');
});
T('classifySnapshotText: PATH line after the preamble', () => {
  assert.equal(P().classifySnapshotText(snapText(String.raw`C:\Windows\System32;C:\Windows`)), 'windows-form');
});
T('classifySnapshotText: multi-line value -> unparsed', () => {
  assert.equal(P().classifySnapshotText(PRE + "export PATH='C:\\a;\nC:\\b'\n"), 'unparsed');
});
T('classifySnapshotText: CRLF line ends still classify by value', () => {
  assert.equal(P().classifySnapshotText(snapText(String.raw`C:\a;C:\b`, { eol: '\r\n' })), 'windows-form');
  assert.equal(P().classifySnapshotText(snapText('/usr/bin:/bin', { eol: '\r\n' })), 'ok');
});
T('parsePathLine: CRLF keeps \\r in eol, not in value', () => {
  const r = P().parsePathLine(snapText(String.raw`C:\a;C:\b`, { eol: '\r\n' }));
  assert.equal(r.found, true);
  assert.equal(r.closed, true);
  assert.equal(r.value, String.raw`C:\a;C:\b`);
  assert.ok(String(r.eol).includes('\r'), JSON.stringify(r.eol));
});
T('parsePathLine: absent line -> found false', () => {
  assert.equal(P().parsePathLine(PRE).found, false);
});
// A shell-escaped quote ('\'') ends the first '...' early: not a simple value, so fail safe.
const QUOTED_LINE = String.raw`export PATH='C:\Users\O'\''Brien\bin;C:\Windows'`;
T('classifySnapshotText: escaped single quote in the value -> unparsed', () => {
  assert.equal(P().classifySnapshotText(PRE + QUOTED_LINE + '\n'), 'unparsed');
});
T('parsePathLine: escaped single quote in the value -> found true, closed false', () => {
  const r = P().parsePathLine(PRE + QUOTED_LINE + '\n');
  assert.equal(r.found, true);
  assert.equal(r.closed, false);
});
JS
