"use strict";
// Tests: bin/list-staged-review-paths.js
// Tags: TL2, review-tests, review-scope, merge-incoming, scope:issue-specific
// #2842 — the staged listing RT-1 / RT-1a read: `git diff --cached --name-only [--diff-filter=A]`
// minus merge-incoming paths (the same dropMergeIncomingPaths the review scope uses). Docs are
// NOT excluded here; exit 0 ok, 2 usage, 1 git failure.
// TL3 gap (what this test does NOT catch):
// - select-staged-files.sh wiring (tests/bin/feature-2075-append-destination/skill-static-cases.sh S13 / S24)
const { caseBegin, caseEnd, isolate, gitInit } = require("../lib/harness");

const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { after, test } = require("node:test");

const ROOT = path.resolve(__dirname, "..", "..");
const CLI = path.join(ROOT, "bin", "list-staged-review-paths.js");
const restore = isolate();
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "f2842ls-"));
after(() => { restore(); fs.rmSync(TMP, { recursive: true, force: true }); });

const gitOk = (dir, ...a) => {
  const r = spawnSync("git", ["-C", dir, ...a], { encoding: "utf8" });
  assert.strictEqual(r.status, 0, `git ${a.join(" ")}: ${r.stderr}`);
  return r.stdout;
};
const put = (d, rel, body) => {
  fs.mkdirSync(path.dirname(path.join(d, rel)), { recursive: true });
  fs.writeFileSync(path.join(d, rel), `${body}\n`);
};
let seq = 0;
function base() {
  const d = path.join(TMP, `repo-${++seq}`).replace(/\\/g, "/");
  gitInit(d);
  gitOk(d, "config", "user.email", "t@example.invalid");
  gitOk(d, "config", "user.name", "T");
  gitOk(d, "config", "core.autocrlf", "false");
  gitOk(d, "checkout", "-q", "-b", "mainline");
  put(d, "README.md", "seed");
  put(d, "hooks/shared.js", "shared v1");
  gitOk(d, "add", "-A");
  gitOk(d, "commit", "-qm", "base");
  return d;
}
// merging() -> mid-merge of mainline (adds tests/main.sh, changes hooks/shared.js) into feature,
// with the branch's own staged work: an added test, a modified README and an added doc.
function merging() {
  const d = base();
  gitOk(d, "checkout", "-q", "-b", "feature");
  gitOk(d, "checkout", "-q", "mainline");
  put(d, "tests/main.sh", "echo main");
  put(d, "hooks/shared.js", "shared v2");
  gitOk(d, "add", "-A");
  gitOk(d, "commit", "-qm", "main");
  gitOk(d, "checkout", "-q", "feature");
  gitOk(d, "merge", "-q", "--no-commit", "--no-ff", "mainline");
  own(d);
  return d;
}
function own(d) {
  put(d, "tests/branch.sh", "echo branch");
  put(d, "docs/note.md", "note");
  put(d, "README.md", "seed changed");
  gitOk(d, "add", "--", "tests/branch.sh", "docs/note.md", "README.md");
}
const run = (...args) => spawnSync(process.execPath, [CLI, ...args], { cwd: TMP, encoding: "utf8", timeout: 60000 });
const lines = (r) => String(r.stdout || "").split(/\r?\n/).filter(Boolean).sort();

caseBegin("list-staged-review-paths-cli", "bin/list-staged-review-paths.js");
test("L1: usage errors exit 2 (no --repo, --repo without a value, unknown option)", () => {
  assert.ok(fs.existsSync(CLI), "bin/list-staged-review-paths.js exists");
  for (const args of [[], ["--repo"], ["--repo", TMP, "--bogus"]]) {
    const r = run(...args);
    assert.strictEqual(r.status, 2, `[${args.join(" ")}] exits 2: ${r.stderr}`);
  }
});
test("L2: a directory that is not a git repository exits 1", () => {
  assert.ok(fs.existsSync(CLI), "bin/list-staged-review-paths.js exists");
  const nogit = path.join(TMP, "nogit");
  fs.mkdirSync(nogit, { recursive: true });
  const r = run("--repo", nogit);
  assert.strictEqual(r.status, 1, `git failure exits 1: ${r.stderr}`);
});
test("L3: not merging -> exactly git diff --cached --name-only (docs included), and --added-only = --diff-filter=A", () => {
  const d = base();
  own(d);
  const all = run("--repo", d);
  assert.strictEqual(all.status, 0, all.stderr);
  assert.deepStrictEqual(lines(all), gitOk(d, "diff", "--cached", "--name-only").split("\n").filter(Boolean).sort());
  const added = run("--repo", d, "--added-only");
  assert.strictEqual(added.status, 0, added.stderr);
  assert.deepStrictEqual(lines(added), ["docs/note.md", "tests/branch.sh"]);
});
test("L4: merging -> merge-incoming paths are dropped from the default and the --added-only listing", () => {
  const d = merging();
  const all = run("--repo", d);
  assert.strictEqual(all.status, 0, all.stderr);
  assert.deepStrictEqual(lines(all), ["README.md", "docs/note.md", "tests/branch.sh"]);
  const added = run("--repo", d, "--added-only");
  assert.strictEqual(added.status, 0, added.stderr);
  assert.deepStrictEqual(lines(added), ["docs/note.md", "tests/branch.sh"]);
});
test("L5: undecidable merge state (non-OID MERGE_HEAD) drops nothing", () => {
  const d = merging();
  fs.writeFileSync(path.join(d, ".git", "MERGE_HEAD"), "not-an-oid\n");
  const all = run("--repo", d);
  assert.strictEqual(all.status, 0, all.stderr);
  assert.deepStrictEqual(lines(all), ["README.md", "docs/note.md", "hooks/shared.js", "tests/branch.sh", "tests/main.sh"]);
});
test("L6: a staged path containing a newline exits 1 with a diagnostic and lists no path", (t) => {
  const d = base();
  const blob = gitOk(d, "hash-object", "-w", "--stdin").trim();
  const add = spawnSync("git", ["-C", d, "update-index", "--add", "--cacheinfo", `100644,${blob},a\nb.txt`], { encoding: "utf8" });
  if (add.status !== 0) return t.skip(`this git refuses a newline path in the index: ${String(add.stderr).trim()}`);
  const r = run("--repo", d);
  assert.strictEqual(r.status, 1, `newline path exits 1: ${r.stderr}`);
  assert.match(r.stderr, /newline/);
  assert.strictEqual(String(r.stdout || ""), "", "no phantom path is listed");
});
test("L7: nothing staged exits 0 with empty stdout, with and without --added-only", () => {
  const d = base();
  for (const args of [[], ["--added-only"]]) {
    const r = run("--repo", d, ...args);
    assert.strictEqual(r.status, 0, `[${args.join(" ")}] ${r.stderr}`);
    assert.strictEqual(String(r.stdout || ""), "");
  }
});
caseEnd();
