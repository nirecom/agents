"use strict";
// Tests: bin/lib/check-migration-blocks.js
// Tags: TL2, bin, pre-commit, migration-blocks, spawn-count, real-git, node-precommit, scope:issue-specific
// #2507: run({argv:["--staged", ...], readStaged}) reads each staged file through readStaged (the
// pre-commit snapshot) instead of one `git show :file` per file. Without readStaged the old git
// path stays. execFileSync is wrapped before the module loads (it destructures it at require time).
const { caseBegin, caseEnd, isolate, gitInit } = require("../lib/harness");

const assert = require("node:assert");
const cp = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { after, test } = require("node:test");

const MODULE = path.join(__dirname, "..", "..", "bin", "lib", "check-migration-blocks.js");
const ENV_DROP = ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_PREFIX", "CLAUDE_CODE_SESSION_ID"];

const calls = [];
const realExecFileSync = cp.execFileSync;
cp.execFileSync = function recorded(cmd, args, ...rest) {
  calls.push([cmd, ...(args || [])].join(" "));
  return realExecFileSync.call(this, cmd, args, ...rest);
};
delete require.cache[require.resolve(MODULE)];
const { run } = require(MODULE);
cp.execFileSync = realExecFileSync;

const restore = isolate();
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "f2507-migr-"));
after(() => {
  restore();
  fs.rmSync(TMP, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
});

const ENV = { ...process.env };
for (const k of ENV_DROP) delete ENV[k];

let seq = 0;
function git(dir, ...args) {
  const r = cp.spawnSync("git", ["-C", dir, ...args], { encoding: "utf8", env: ENV });
  assert.strictEqual(r.status, 0, `git ${args.join(" ")}: ${r.stderr}`);
  return r.stdout;
}
function write(dir, rel, body) {
  const file = path.join(dir, rel);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, body);
}

// Marker lines are assembled so this file never holds a block line itself. Synthetic descriptions.
const BAD = `// --- ${"BEGIN"} temporary: fixture shim ---\nconst x = 1;\n// --- ${"END"} temporary: fixture shim ---\n`;
const GOOD = "const x = 1;\n";
const BAD_LINE = (f) => `${f}:1: error: migration block description missing arrow (→ or ->) or 'migration' keyword: "fixture shim"`;

// repo(staged, worktree) — every path staged with staged[path], then overwritten with worktree[path].
function repo(staged, worktree = {}) {
  seq += 1;
  const dir = path.join(TMP, `r${seq}`);
  fs.mkdirSync(dir, { recursive: true });
  gitInit(dir);
  for (const [f, body] of Object.entries(staged)) write(dir, f, body);
  git(dir, "add", "-A");
  for (const [f, body] of Object.entries(worktree)) write(dir, f, body);
  return dir;
}

// check(dir, files, readStaged) -> { rc, out, err, gitCalls }
function check(dir, files, readStaged) {
  let out = "";
  let err = "";
  calls.length = 0;
  const rc = run({ argv: ["--staged", ...files], cwd: dir, env: ENV, readStaged,
    stdout: { write: (s) => { out += s; } }, stderr: { write: (s) => { err += s; } } });
  return { rc, out, err, gitCalls: calls.slice() };
}
const fromMap = (map, seen = []) => (rel) => (seen.push(rel), map[rel] == null ? null : Buffer.from(map[rel]));

caseBegin("readstaged-no-git-show", "bin/lib/check-migration-blocks.js");
test("1 with readStaged no file is read through git show, for 1 or 12 files", () => {
  const counts = [1, 12].map((n) => {
    const staged = {};
    for (let i = 0; i < n; i++) staged[`src/m${i}.js`] = GOOD;
    const r = check(repo(staged), Object.keys(staged), fromMap(staged));
    assert.strictEqual(r.rc, 0, r.out + r.err);
    assert.deepStrictEqual(r.gitCalls.filter((c) => / show /.test(c)), [], r.gitCalls.join("; "));
    return r.gitCalls.length;
  });
  assert.strictEqual(counts[1], counts[0], "the git call count does not grow with the file count");
});
caseEnd();

caseBegin("verdict-from-staged-content", "bin/lib/check-migration-blocks.js");
test("2 the verdict follows the staged content, not the working tree", () => {
  const dirty = repo({ "a.js": BAD }, { "a.js": GOOD });
  const seen = [];
  const r = check(dirty, ["a.js"], fromMap({ "a.js": BAD }, seen));
  assert.strictEqual(r.rc, 1);
  assert.strictEqual(r.out, `${BAD_LINE("a.js")}\n`);
  assert.deepStrictEqual(seen, ["a.js"]);
  const clean = repo({ "b/c.js": GOOD }, { "b/c.js": BAD });
  const seen2 = [];
  assert.strictEqual(check(clean, ["b/c.js"], fromMap({ "b/c.js": GOOD }, seen2)).rc, 0);
  assert.deepStrictEqual(seen2, ["b/c.js"], "readStaged gets the repo-relative path with '/'");
});
caseEnd();

caseBegin("unreadable-staged-skipped", "bin/lib/check-migration-blocks.js");
test("3 a file readStaged cannot read is skipped, as an unreadable git show was", () => {
  const dir = repo({ "a.js": BAD, "d.js": BAD });
  const r = check(dir, ["a.js", "d.js"], fromMap({ "d.js": BAD }));
  assert.strictEqual(r.rc, 1);
  assert.strictEqual(r.out, `${BAD_LINE("d.js")}\n`);
  const legacy = check(dir, ["a.js", "gone.js"], undefined);
  assert.strictEqual(legacy.rc, 1, "git path: a path missing from the index is skipped");
  assert.strictEqual(legacy.out, `${BAD_LINE("a.js")}\n`);
});
caseEnd();

caseBegin("no-readstaged-backward-compatible", "bin/lib/check-migration-blocks.js");
test("4 without readStaged the git show path stays and reaches the same output", () => {
  const dir = repo({ "a.js": BAD, "b.js": GOOD }, { "a.js": GOOD });
  const viaGit = check(dir, ["a.js", "b.js"], undefined);
  assert.strictEqual(viaGit.gitCalls.filter((c) => / show :/.test(c)).length, 2, viaGit.gitCalls.join("; "));
  const viaRead = check(dir, ["a.js", "b.js"], fromMap({ "a.js": BAD, "b.js": GOOD }));
  assert.deepStrictEqual([viaGit.rc, viaGit.out, viaGit.err], [viaRead.rc, viaRead.out, viaRead.err]);
  assert.strictEqual(viaGit.rc, 1);
});
caseEnd();
