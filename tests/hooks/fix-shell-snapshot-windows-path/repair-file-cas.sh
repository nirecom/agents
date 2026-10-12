#!/usr/bin/env bash
# tests/hooks/fix-shell-snapshot-windows-path/repair-file-cas.sh
# Tests: hooks/lib/shell-snapshot-repair.js
# Tags: hook, shell-snapshot, windows-path, compare-and-swap, scope:issue-specific, TL1, TL2
# Part of tests/hooks/fix-shell-snapshot-windows-path.sh (sourced by the dispatcher; uses its snap_js).
# One-file repair: only the PATH line changes, the swap is compare-and-swap, failures leave the
# original and no tmp behind, and nothing but our own tmp is ever unlinked.

snap_js "repair-file" <<'JS'
const R = () => load('hooks/lib/shell-snapshot-repair.js');
const WIN = String.raw`C:\Windows\System32;C:\Windows`;
const FIXED = '/mingw64/bin:/usr/local/bin:/usr/bin:/bin:/c/Windows/System32:/c/Windows';
const isTmp = (p) => /\.repair\.tmp$/.test(String(p));
const outcomeOf = (r) => (typeof r === 'string' ? r : (r && (r.outcome || r.reason)) || JSON.stringify(r));
const reasonOf = (r) => (typeof r === 'string' ? r : (r && (r.reason || r.outcome)) || JSON.stringify(r));
function oneFile(value, opts) {
  const d = mkd('cas');
  return { dir: d, file: writeSnap(d, snapName(1800000000000), value, opts) };
}
// fsImpl wrapper: real fs plus spies; onTmp(tmpPath) fires once per distinct tmp path.
function spyFs(hooks = {}) {
  const seen = new Set();
  const removed = [];
  const fire = (p) => { if (isTmp(p) && !seen.has(String(p))) { seen.add(String(p)); if (hooks.onTmp) hooks.onTmp(String(p)); } };
  const w = Object.assign({}, fs);
  w.openSync = (p, ...a) => { fire(p); return fs.openSync(p, ...a); };
  w.writeFileSync = (p, ...a) => { if (typeof p === 'string') fire(p); return fs.writeFileSync(p, ...a); };
  w.unlinkSync = (p) => { if (!isTmp(p)) removed.push(String(p)); return fs.unlinkSync(p); };
  w.rmSync = (p, o) => { if (!isTmp(p)) removed.push(String(p)); return fs.rmSync(p, o); };
  if (hooks.renameSync) w.renameSync = hooks.renameSync;
  return { fsImpl: w, removed, seen };
}
const run = (file, extra = {}) => R().repairSnapshotFile(file, Object.assign({ converterDeps: makeStubDeps(), deadline: fakeDeadline(60000), platform: 'win32' }, extra));

T('repaired: only the PATH line changes (LF)', () => {
  const { dir, file } = oneFile(WIN);
  const before = fs.readFileSync(file, 'utf8');
  assert.equal(outcomeOf(run(file)), 'repaired');
  const after = fs.readFileSync(file, 'utf8');
  assert.equal(pathValue(after), FIXED);
  assert.equal(after, before.replace("export PATH='" + WIN + "'", "export PATH='" + FIXED + "'"));
  assert.deepEqual(tmpLeft(dir), []);
});
T('repaired: CRLF file keeps every other byte and its CRLF on the PATH line', () => {
  const { dir, file } = oneFile(WIN, { eol: '\r\n' });
  const before = fs.readFileSync(file, 'utf8');
  assert.equal(outcomeOf(run(file)), 'repaired');
  const after = fs.readFileSync(file, 'utf8');
  assert.equal(after, before.replace("export PATH='" + WIN + "'\r\n", "export PATH='" + FIXED + "'\r\n"));
  assert.deepEqual(tmpLeft(dir), []);
});
T('repaired: file mode is kept (POSIX)', () => {
  if (process.platform === 'win32') return SKIP;
  const { file } = oneFile(WIN);
  fs.chmodSync(file, 0o640);
  assert.equal(outcomeOf(run(file)), 'repaired');
  assert.equal(fs.statSync(file).mode & 0o777, 0o640);
});
T('result names the file and the verdict before', () => {
  const { file } = oneFile(WIN);
  const r = run(file);
  assert.equal(r.name, path.basename(file));
  assert.equal(r.verdictBefore, 'windows-form');
});
T('ok file -> none, bytes unchanged', () => {
  const { file } = oneFile('/usr/bin:/bin');
  const before = fs.readFileSync(file, 'utf8');
  assert.equal(outcomeOf(run(file)), 'none');
  assert.equal(fs.readFileSync(file, 'utf8'), before);
});
T('replacePathLineAtomically: beforeSwap rewrite -> changed-during-repair, rewrite kept, no tmp', () => {
  const L = R();
  const { dir, file } = oneFile(WIN);
  const text = fs.readFileSync(file, 'utf8');
  const parsed = load('hooks/lib/shell-snapshot-path.js').parsePathLine(text);
  const other = "# someone else\nexport PATH='/x'\n";
  const r = L.replacePathLineAtomically(file, text, parsed, FIXED, { fsImpl: fs, beforeSwap: () => fs.writeFileSync(file, other) });
  assert.match(reasonOf(r), /changed-during-repair/);
  assert.equal(fs.readFileSync(file, 'utf8'), other);
  assert.deepEqual(tmpLeft(dir), []);
});
T('race: other side writes the repaired content first -> re-read sees ok, not failed', () => {
  const { dir, file } = oneFile(WIN);
  const fixedText = fs.readFileSync(file, 'utf8').replace(WIN, FIXED);
  const s = spyFs({ onTmp: () => fs.writeFileSync(file, fixedText) });
  const r = run(file, { fsImpl: s.fsImpl });
  assert.notEqual(outcomeOf(r), 'failed', JSON.stringify(r));
  assert.equal(fs.readFileSync(file, 'utf8'), fixedText);
  assert.deepEqual(tmpLeft(dir), []);
});
T('race twice: both attempts conflict -> failed: changed-during-repair', () => {
  const { dir, file } = oneFile(WIN);
  let n = 0;
  const s = spyFs({ onTmp: () => { n++; fs.writeFileSync(file, snapText(String.raw`C:\conflict` + n + ';C:\\y')); } });
  const r = run(file, { fsImpl: s.fsImpl });
  assert.equal(outcomeOf(r), 'failed');
  assert.equal(r.reason, 'changed-during-repair');
  assert.ok(n >= 2, 'expected two attempts, saw ' + n);
  assert.deepEqual(tmpLeft(dir), []);
});
T('rename EPERM -> failed: write-failed, original unchanged, no tmp, no throw', () => {
  const { dir, file } = oneFile(WIN);
  const before = fs.readFileSync(file, 'utf8');
  const s = spyFs({ renameSync: () => { const e = new Error('EPERM: operation not permitted'); e.code = 'EPERM'; throw e; } });
  const r = run(file, { fsImpl: s.fsImpl });
  assert.equal(outcomeOf(r), 'failed');
  assert.equal(r.reason, 'write-failed');
  assert.equal(fs.readFileSync(file, 'utf8'), before);
  assert.deepEqual(tmpLeft(dir), []);
});
T('pre-existing tmp name is never overwritten (wx)', () => {
  const { file } = oneFile(WIN);
  const planted = [];
  const s = spyFs({ onTmp: (p) => { if (!fs.existsSync(p)) { fs.writeFileSync(p, 'SENTINEL'); planted.push(p); } } });
  run(file, { fsImpl: s.fsImpl });
  assert.ok(planted.length >= 1, 'no tmp path was attempted');
  for (const p of planted) {
    assert.ok(fs.existsSync(p), 'planted tmp was removed: ' + p);
    assert.equal(fs.readFileSync(p, 'utf8'), 'SENTINEL', p);
  }
});
T('escaped single quote in the value (unparsed) -> not repaired, bytes unchanged, no tmp', () => {
  const { dir, file } = oneFile(String.raw`C:\Users\O'\''Brien\bin;C:\Windows`);
  const before = fs.readFileSync(file, 'utf8');
  const d = makeStubDeps();
  const r = run(file, { converterDeps: d });
  assert.notEqual(outcomeOf(r), 'repaired', JSON.stringify(r));
  assert.equal(fs.readFileSync(file, 'utf8'), before);
  assert.equal(d.calls.toPosixList.length, 0);
  assert.deepEqual(tmpLeft(dir), []);
});
T('converterDeps null -> failed: cygpath-unavailable, file unchanged', () => {
  const { file } = oneFile(WIN);
  const before = fs.readFileSync(file, 'utf8');
  const r = run(file, { converterDeps: null });
  assert.equal(outcomeOf(r), 'failed');
  assert.equal(r.reason, 'cygpath-unavailable');
  assert.equal(fs.readFileSync(file, 'utf8'), before);
});
T('budget under MIN_REPAIR_SLICE_MS -> deferred: time-budget, converter not called', () => {
  const { file } = oneFile(WIN);
  const d = makeStubDeps();
  const r = run(file, { converterDeps: d, deadline: fakeDeadline(R().MIN_REPAIR_SLICE_MS - 1) });
  assert.equal(outcomeOf(r), 'deferred');
  assert.equal(r.reason, 'time-budget');
  assert.equal(d.calls.toPosixList.length, 0);
});
T('windows-unrepairable -> unrepairable, bytes unchanged, file kept, nothing but tmp unlinked', () => {
  const { dir, file } = oneFile(String.raw`C:\a;relative\dir`);
  const before = fs.readFileSync(file, 'utf8');
  const s = spyFs();
  const r = run(file, { fsImpl: s.fsImpl });
  assert.equal(outcomeOf(r), 'unrepairable');
  assert.ok(fs.existsSync(file));
  assert.equal(fs.readFileSync(file, 'utf8'), before);
  assert.deepEqual(s.removed, []);
  assert.deepEqual(tmpLeft(dir), []);
});
T('no non-tmp unlink on any failure path', () => {
  const { file } = oneFile(WIN);
  const s = spyFs({ renameSync: () => { const e = new Error('EPERM'); e.code = 'EPERM'; throw e; } });
  run(file, { fsImpl: s.fsImpl });
  run(file, { fsImpl: s.fsImpl, converterDeps: null });
  assert.deepEqual(s.removed, []);
  assert.ok(fs.existsSync(file));
});
JS
