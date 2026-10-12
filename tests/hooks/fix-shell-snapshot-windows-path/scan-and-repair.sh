#!/usr/bin/env bash
# tests/hooks/fix-shell-snapshot-windows-path/scan-and-repair.sh
# Tests: hooks/lib/shell-snapshot-repair.js
# Tags: hook, shell-snapshot, windows-path, scan, cygpath, scope:issue-specific, TL2
# Part of tests/hooks/fix-shell-snapshot-windows-path.sh (sourced by the dispatcher; uses its snap_js).
# The directory scan shared by SessionStart and the recheck: idempotent, never deletes, stays in
# its directory, newest first, honours maxRepairs and createdAfterMs; plus resolveCygpath.
# TL3 gap: the real cygpath conversion runs only on a win32 host with Git for Windows; elsewhere
# it is SKIP and the stub converter carries the contract.

snap_js "scan" <<'JS'
const R = () => load('hooks/lib/shell-snapshot-repair.js');
const WIN = String.raw`C:\Windows\System32;C:\Windows`;
const UNREP = String.raw`C:\a;relative\dir`;
const BASE = 1800000000000;
function home() { const h = mkd('home'); return { h, d: snapDir(h) }; }
const scan = (h, extra = {}) => R().scanAndRepair(Object.assign({ homeDir: h, platform: 'win32', converterDeps: makeStubDeps(), deadline: fakeDeadline(60000), budgetMs: 60000 }, extra));
const read = (f) => fs.readFileSync(f, 'utf8');
const twoDaysAgo = () => (Date.now() - 2 * 86400000) / 1000;

T('second run repairs nothing and leaves bytes alone', () => {
  const { h, d } = home();
  const f = writeSnap(d, snapName(BASE), WIN);
  assert.equal(count(scan(h).repaired), 1);
  const once = read(f);
  assert.ok(reachesCore(pathValue(once)));
  assert.equal(count(scan(h).repaired), 0);
  assert.equal(read(f), once);
});
T('unrepairable is counted, kept, unchanged; also when 2 days old', () => {
  const { h, d } = home();
  const a = writeSnap(d, snapName(BASE + 1), UNREP);
  const b = writeSnap(d, snapName(BASE + 2), String.raw`C:\repo\dotfiles/bin:/c/x`);
  fs.utimesSync(b, twoDaysAgo(), twoDaysAgo());
  const [ta, tb] = [read(a), read(b)];
  const r = scan(h);
  assert.equal(count(r.unrepairable), 2);
  assert.equal(read(a), ta);
  assert.equal(read(b), tb);
});
T('cygpath-unavailable on a 2-day-old windows-form: failed, file kept unchanged', () => {
  const { h, d } = home();
  const f = writeSnap(d, snapName(BASE), WIN);
  fs.utimesSync(f, twoDaysAgo(), twoDaysAgo());
  const t = read(f);
  const r = scan(h, { converterDeps: null });
  assert.equal(r.failed.length, 1);
  assert.equal(r.failed[0].reason, 'cygpath-unavailable');
  assert.equal(r.failed[0].name, path.basename(f));
  assert.equal(read(f), t);
});
T('missingCore counted on win32 only', () => {
  const { h, d } = home();
  writeSnap(d, snapName(BASE), '/c/x:/d/y');
  assert.equal(count(scan(h, { platform: 'win32' }).missingCore), 1);
  assert.equal(count(scan(h, { platform: 'linux' }).missingCore), 0);
});
T('unparsed is untouched and in no count', () => {
  const { h, d } = home();
  const f = path.join(d, snapName(BASE));
  fs.writeFileSync(f, "# Snapshot file\nexport PATH='C:\\a;\nC:\\b'\n");
  const t = read(f);
  const r = scan(h);
  for (const k of ['repaired', 'deferred', 'unrepairable', 'missingCore']) assert.equal(count(r[k]), 0, k);
  assert.equal(r.failed.length, 0);
  assert.equal(read(f), t);
});
T('escaped single quote in the value (unparsed) is untouched and in no count', () => {
  const { h, d } = home();
  const f = writeSnap(d, snapName(BASE), String.raw`C:\Users\O'\''Brien\bin;C:\Windows`);
  const t = read(f);
  const r = scan(h);
  for (const k of ['repaired', 'deferred', 'unrepairable', 'missingCore']) assert.equal(count(r[k]), 0, k);
  assert.equal(r.failed.length, 0);
  assert.equal(read(f), t);
});
T('symlinked snapshot file is skipped: target unchanged, link kept', () => {
  const { h, d } = home();
  const real = mkd('elsewhere');
  const target = writeSnap(real, snapName(BASE), WIN);
  const link = path.join(d, snapName(BASE + 1));
  try { fs.symlinkSync(target, link, 'file'); } catch (e) { return SKIP; }
  const t = read(target);
  const r = scan(h);
  assert.equal(count(r.repaired), 0);
  assert.equal(read(target), t);
  assert.ok(fs.lstatSync(link).isSymbolicLink(), 'link was replaced by a regular file');
  assert.deepEqual(tmpLeft(d), []);
});
T('symlinked snapshot dir is skipped', () => {
  const h = mkd('home');
  const real = mkd('elsewhere');
  const f = writeSnap(real, snapName(BASE), WIN);
  fs.mkdirSync(path.join(h, '.claude'), { recursive: true });
  try { fs.symlinkSync(real, path.join(h, '.claude', 'shell-snapshots'), process.platform === 'win32' ? 'junction' : 'dir'); } catch (e) { return SKIP; }
  const t = read(f);
  const r = scan(h);
  assert.equal(count(r.repaired), 0);
  assert.equal(read(f), t);
});
T('non-.sh, subdir .sh and decoys outside the dir are untouched', () => {
  const { h, d } = home();
  const txt = path.join(d, 'snapshot-bash-' + BASE + '-a.txt'); fs.writeFileSync(txt, snapText(WIN));
  fs.mkdirSync(path.join(d, 'sub'));
  const sub = writeSnap(path.join(d, 'sub'), snapName(BASE), WIN);
  const decoy = writeSnap(path.join(h, '.claude'), snapName(BASE), WIN);
  const before = [txt, sub, decoy].map(read);
  const r = scan(h);
  assert.equal(count(r.repaired), 0);
  assert.deepEqual([txt, sub, decoy].map(read), before);
  assert.deepEqual(tmpLeft(d), []);
});
T('maxRepairs+1 windows-form: newest five repaired, oldest deferred as max-repairs', () => {
  const { h, d } = home();
  const files = [0, 1, 2, 3, 4, 5].map((i) => writeSnap(d, snapName(BASE + i * 1000), WIN));
  const r = scan(h, { maxRepairs: 5 });
  assert.equal(count(r.repaired), 5);
  assert.equal(count(r.deferred), 1);
  assert.match(JSON.stringify(r.deferred), /max-repairs/);
  assert.equal(pathValue(read(files[0])), WIN, 'oldest must be the one left');
  for (const f of files.slice(1)) assert.ok(reachesCore(pathValue(read(f))), f);
  assert.deepEqual(tmpLeft(d), []);
});
T('createdAfterMs: name epoch before the bound is neither judged nor counted', () => {
  const { h, d } = home();
  const old = writeSnap(d, snapName(BASE), WIN);
  const fresh = writeSnap(d, snapName(BASE + 100000), WIN);
  const t = read(old);
  const r = scan(h, { createdAfterMs: BASE + 50000 });
  assert.equal(count(r.repaired), 1);
  assert.equal(read(old), t);
  assert.ok(reachesCore(pathValue(read(fresh))));
  assert.equal(r.scanned, 1);
});
T('createdAfterMs: a non-conforming name is judged by mtime', () => {
  const { h, d } = home();
  const before = writeSnap(d, 'foo-before.sh', WIN);
  const after = writeSnap(d, 'foo-after.sh', WIN);
  const bound = Date.now() - 60000;
  fs.utimesSync(before, (bound - 600000) / 1000, (bound - 600000) / 1000);
  const t = read(before);
  const r = scan(h, { createdAfterMs: bound });
  assert.equal(count(r.repaired), 1);
  assert.equal(read(before), t);
  assert.ok(reachesCore(pathValue(read(after))));
});
T('newest reports the newest scanned snapshot and its verdict before', () => {
  const { h, d } = home();
  writeSnap(d, snapName(BASE), '/usr/bin:/bin');
  const n = writeSnap(d, snapName(BASE + 5000), WIN);
  const r = scan(h);
  assert.equal(r.newest.name, path.basename(n));
  assert.equal(r.newest.verdictBefore, 'windows-form');
});
T('snapshotCreatedAtMs: conforming name -> epoch, others -> mtime', () => {
  const L = R();
  const st = { mtimeMs: 42 };
  assert.equal(L.snapshotCreatedAtMs('snapshot-bash-1800000000000-abc.sh', st), 1800000000000);
  assert.equal(L.snapshotCreatedAtMs('snapshot-zsh-1800000000001-x1.sh', st), 1800000000001);
  assert.equal(L.snapshotCreatedAtMs('snapshot-bash-123-x.sh', st), 42);
  assert.equal(L.snapshotCreatedAtMs('foo.sh', st), 42);
});

// resolveCygpath: each candidate resolves on its own; separators and case are normalised.
const norm = (p) => (p == null ? null : String((p && (p.path || p.exe)) || p).replace(/\\/g, '/').toLowerCase());
const existsOnly = (...ok) => { const s = new Set(ok.map(norm)); return (p) => s.has(norm(p)); };
const rc = (env, ex, platform = 'win32') => R().resolveCygpath({ env, platform, existsSync: ex });
T('resolveCygpath: CLAUDE_CODE_GIT_BASH_PATH ...\\bin\\bash.exe', () => {
  const want = String.raw`D:\Tools\Git\usr\bin\cygpath.exe`;
  assert.equal(norm(rc({ CLAUDE_CODE_GIT_BASH_PATH: String.raw`D:\Tools\Git\bin\bash.exe` }, existsOnly(want))), norm(want));
});
T('resolveCygpath: CLAUDE_CODE_GIT_BASH_PATH ...\\usr\\bin\\bash.exe', () => {
  const want = String.raw`D:\Tools\Git\usr\bin\cygpath.exe`;
  assert.equal(norm(rc({ CLAUDE_CODE_GIT_BASH_PATH: String.raw`D:\Tools\Git\usr\bin\bash.exe` }, existsOnly(want))), norm(want));
});
T('resolveCygpath: cygpath.exe on env.PATH', () => {
  const want = String.raw`E:\Git2\usr\bin\cygpath.exe`;
  assert.equal(norm(rc({ PATH: String.raw`E:\x;E:\Git2\usr\bin` }, existsOnly(want))), norm(want));
});
T('resolveCygpath: ...\\cmd\\git.exe on env.PATH', () => {
  const want = String.raw`F:\G\usr\bin\cygpath.exe`;
  assert.equal(norm(rc({ PATH: String.raw`F:\G\cmd` }, existsOnly(String.raw`F:\G\cmd\git.exe`, want))), norm(want));
});
T('resolveCygpath: %ProgramFiles%\\Git fallback', () => {
  const want = String.raw`H:\PF\Git\usr\bin\cygpath.exe`;
  assert.equal(norm(rc({ ProgramFiles: String.raw`H:\PF` }, existsOnly(want))), norm(want));
});
T('resolveCygpath: nothing exists -> null', () => {
  assert.equal(rc({ PATH: String.raw`Z:\none`, ProgramFiles: String.raw`Z:\PF` }, () => false), null);
});
T('resolveCygpath: not win32 -> null even when a candidate exists', () => {
  assert.equal(rc({ ProgramFiles: String.raw`H:\PF` }, () => true, 'linux'), null);
});
T('real cygpath: single and multi element (win32 only)', () => {
  if (process.platform !== 'win32') return SKIP;
  const L = R();
  const exe = L.resolveCygpath({ env: process.env, platform: 'win32', existsSync: fs.existsSync });
  if (!exe) return SKIP;
  const deps = L.makeCygpathDeps(exe, { timeoutFor: () => 5000 });
  assert.equal(deps.toPosixList(String.raw`C:\Windows`).replace(/\/$/, '').toLowerCase(), '/c/windows');
  const multi = deps.toPosixList(String.raw`C:\Windows;C:\Windows\System32`).toLowerCase().split(':');
  assert.deepEqual(multi.map((s) => s.replace(/\/$/, '')), ['/c/windows', '/c/windows/system32']);
});
JS
