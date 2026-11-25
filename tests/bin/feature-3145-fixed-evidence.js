"use strict";
// tests/bin/feature-3145-fixed-evidence.js
// Tests: bin/lib/fixed-evidence.js, bin/lib/this-pr-open.js, bin/worktree-notes-triage.js
// Tags: worktree-notes, this-pr, fixed-evidence, git, merge-base, dispose, temp-repo, scope:issue-specific, TL2
// #3145 S10: a this-pr `disposed: fixed` must be backed by a change to its loc since the base point
// (the entry's base when it is an ancestor of HEAD, else the merge-base with origin's default).
// Real temp git repos through defaultGitRunner; stub runners only for git failures.
// TL3 gap: a fix verified on a CI host with a shallow clone (missing merge-base) is not covered.

const { caseBegin, caseEnd } = require("../lib/harness");
const { test } = require("node:test");
const assert = require("node:assert");
const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");
const F = require("../lib/this-pr-notes-fixture");

const TMP = F.setup("t3145-fixed");
const LIB = path.join(F.ROOT, "bin", "lib");
const M = require(path.join(F.ROOT, "hooks", "lib", "worktree-notes-sections.js"));
const fwd = (p) => p.replace(/\\/g, "/");
const COMMIT = ["-c", "user.email=t@example.invalid", "-c", "user.name=t", "-c", "commit.gpgsign=false", "commit", "-q", "-m"];
const FIXED = "<!-- disposed: fixed -->";
const parse = (line) => M.scanSection(`## BugsFound\n${line}\n`, "BugsFound").entries[0];

let n = 0;
// repo(o) -> { dir, c0 }: main branch with src/a.js, src/b.js, docs/x.md; topic branch checked out.
// o.origin: "head" (origin/main + origin/HEAD), "ref" (origin/main only), "none".
function repo(o) {
  const x = Object.assign({ origin: "head", branch: "main" }, o);
  const dir = path.join(TMP, `r${++n}`);
  fs.mkdirSync(path.join(dir, "src"), { recursive: true });
  fs.mkdirSync(path.join(dir, "docs"));
  F.git(dir, ["init", "-q", "-b", x.branch]);
  F.git(dir, ["config", "core.hooksPath", "/dev/null"]);
  for (const f of ["src/a.js", "src/b.js", "docs/x.md"]) fs.writeFileSync(path.join(dir, f), `${f}\n`);
  F.git(dir, ["add", "-A"]);
  F.git(dir, COMMIT.concat("c0"));
  const c0 = F.git(dir, ["rev-parse", "HEAD"]);
  if (x.origin !== "none") F.git(dir, ["update-ref", "refs/remotes/origin/main", c0]);
  if (x.origin === "head") F.git(dir, ["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"]);
  if (x.branch !== "topic") F.git(dir, ["checkout", "-q", "-b", "topic"]);
  return { dir, c0 };
}
const touch = (dir, f, s) => fs.writeFileSync(path.join(dir, f), s || `changed ${f}\n`);
function commitAll(dir, msg) {
  F.git(dir, ["add", "-A"]);
  F.git(dir, COMMIT.concat(msg));
  return F.git(dir, ["rev-parse", "HEAD"]);
}
const fixedEntry = (o) => parse(F.entry("fix", Object.assign({ terminal: FIXED }, o)));

caseBegin("change-set-and-loc-matching", "bin/lib/fixed-evidence.js");
test("fixedEvidence: committed / uncommitted / untracked loc changes pass; no change or another file fails", () => {
  const { fixedEvidence, defaultGitRunner } = require(path.join(LIB, "fixed-evidence.js"));
  const check = (dir, o) => fixedEvidence(fixedEntry(o), defaultGitRunner(dir));

  const committed = repo();
  touch(committed.dir, "src/a.js");
  commitAll(committed.dir, "fix a");
  assert.deepStrictEqual(check(committed.dir, { loc: "src/a.js:3", base: committed.c0 }), { ok: true }, "committed, :line");

  const dirty = repo();
  touch(dirty.dir, "src/a.js");
  assert.deepStrictEqual(check(dirty.dir, { loc: "src/a.js:3-5", base: dirty.c0 }), { ok: true }, "uncommitted, :a-b");
  assert.deepStrictEqual(check(dirty.dir, { loc: "src", base: dirty.c0 }), { ok: true }, "directory loc covers a change under it");
  assert.deepStrictEqual(check(dirty.dir, { loc: `${fwd(path.join(dirty.dir, "src", "a.js"))}:3`, base: dirty.c0 }), { ok: true }, "absolute loc inside the repo");
  const otherFile = check(dirty.dir, { loc: "src/b.js", base: dirty.c0 });
  assert.strictEqual(otherFile.ok, false, "only another file changed");
  assert.ok(otherFile.reason && String(otherFile.path).includes("src/b.js"), `reason and path: ${JSON.stringify(otherFile)}`);
  assert.strictEqual(check(dirty.dir, { loc: "docs", base: dirty.c0 }).ok, false, "directory without changes");

  const untracked = repo();
  touch(untracked.dir, "src/new.js");
  assert.deepStrictEqual(check(untracked.dir, { loc: "src/new.js", base: untracked.c0 }), { ok: true }, "new untracked file");

  const clean = repo();
  assert.strictEqual(check(clean.dir, { loc: "src/a.js", base: clean.c0 }).ok, false, "no change at all");
  assert.strictEqual(check(clean.dir, { base: clean.c0 }).ok, false, "loc-less, empty change set");
  assert.strictEqual(check(clean.dir, { loc: "../outside/a.js", base: clean.c0 }).ok, false, "path escape, empty change set");
  touch(clean.dir, "WORKTREE_NOTES.md", "# Worktree Notes\n");
  assert.strictEqual(check(clean.dir, { base: clean.c0 }).ok, false, "the notes file alone is not a change");
  const outside = fwd(path.join(TMP, "elsewhere", "a.js"));
  assert.strictEqual(check(clean.dir, { loc: outside, base: clean.c0 }).ok, false, "absolute loc outside the repo = no loc, nothing changed");
  touch(clean.dir, "docs/x.md");
  assert.deepStrictEqual(check(clean.dir, { base: clean.c0 }), { ok: true }, "loc-less, something changed");
  assert.deepStrictEqual(check(clean.dir, { loc: `${outside}:7`, base: clean.c0 }), { ok: true }, "absolute loc outside the repo = no loc, something changed");
});
caseEnd();

caseBegin("base-point-selection", "bin/lib/fixed-evidence.js");
test("base honored when it is an ancestor; missing / unknown / rebased base falls back to the merge-base", () => {
  const { fixedEvidence, defaultGitRunner } = require(path.join(LIB, "fixed-evidence.js"));
  const check = (dir, o) => fixedEvidence(fixedEntry(Object.assign({ loc: "src/a.js" }, o)), defaultGitRunner(dir));

  const honored = repo();
  touch(honored.dir, "src/a.js");
  const c1 = commitAll(honored.dir, "a before the finding");
  assert.strictEqual(check(honored.dir, { base: c1 }).ok, false, "a.js unchanged since an ancestor base");
  assert.deepStrictEqual(check(honored.dir, {}), { ok: true }, "no base: merge-base with origin/HEAD sees the a.js change");
  assert.deepStrictEqual(check(honored.dir, { base: "f".repeat(40) }), { ok: true }, "unknown sha: merge-base fallback");

  const rebased = repo();
  touch(rebased.dir, "docs/x.md");
  const gone = commitAll(rebased.dir, "dropped by rebase");
  F.git(rebased.dir, ["reset", "-q", "--hard", rebased.c0]);
  touch(rebased.dir, "src/a.js");
  commitAll(rebased.dir, "fix a");
  assert.ok(spawnSync("git", ["-C", rebased.dir, "cat-file", "-e", gone]).status === 0, "the rebased-away commit still exists");
  assert.deepStrictEqual(check(rebased.dir, { base: gone }), { ok: true }, "non-ancestor base: merge-base fallback");

  const noHead = repo({ origin: "ref" });
  touch(noHead.dir, "src/a.js");
  assert.deepStrictEqual(check(noHead.dir, {}), { ok: true }, "no origin/HEAD: DEFAULT_BRANCHES fallback");

  const lonely = repo({ origin: "none", branch: "topic" });
  touch(lonely.dir, "src/a.js");
  const r = check(lonely.dir, {});
  assert.deepStrictEqual([r.ok, r.reason], [false, "no-base"], `no base point: ${JSON.stringify(r)}`);
});
caseEnd();

caseBegin("git-failures-and-runner", "bin/lib/fixed-evidence.js");
test("git failures give ok:false; defaultGitRunner never throws", () => {
  const { fixedEvidence, defaultGitRunner } = require(path.join(LIB, "fixed-evidence.js"));
  const e = fixedEntry({ loc: "src/a.js", base: "a".repeat(40) });
  assert.strictEqual(fixedEvidence(e, () => ({ status: 1, stdout: "" })).ok, false, "every git call fails");
  assert.strictEqual(fixedEvidence(e, () => null).ok, false, "runner returns null");
  const diffFails = (args) => (args.includes("--is-ancestor") ? { status: 0, stdout: "" } : { status: 128, stdout: "" });
  assert.deepStrictEqual([fixedEvidence(e, diffFails).ok, fixedEvidence(e, diffFails).reason], [false, "git-unavailable"], "diff fails after a good base");

  const plain = path.join(TMP, "not-a-repo");
  fs.mkdirSync(plain);
  const run = defaultGitRunner(plain);
  let res;
  assert.doesNotThrow(() => { res = run(["rev-parse", "HEAD"]); }, "no throw outside a repo");
  assert.notStrictEqual(res && res.status, 0, "non-zero status outside a repo");
  assert.strictEqual(fixedEvidence(e, run).ok, false, "outside a repo");
  const good = repo();
  assert.strictEqual(defaultGitRunner(good.dir)(["rev-parse", "HEAD"]).stdout.trim(), good.c0, "runner binds -C <dir>");
});
caseEnd();

caseBegin("dispose-fixed-cli-gate", "bin/worktree-notes-triage.js");
test("dispose fixed on a this-pr entry without a change exits 2 and writes nothing; other is not verified", () => {
  const BIN = path.join(F.ROOT, "bin", "worktree-notes-triage.js");
  const triage = (args) => spawnSync(process.execPath, [BIN].concat(args), { cwd: TMP, encoding: "utf8", timeout: 60000, env: Object.assign({}, process.env) });
  const r = repo();
  const notes = F.writeNotes(r.dir, { BugsFound: [F.entry("t", { loc: "src/a.js", base: r.c0 }), F.entry("o", { loc: "src/a.js", scope: "other" })] });
  const before = fs.readFileSync(notes, "utf8");
  const refused = triage(["dispose", fwd(notes), "4", "fixed"]);
  assert.strictEqual(refused.status, 2, `${refused.stdout}${refused.stderr}`);
  assert.ok(/src\/a\.js/.test(`${refused.stdout}${refused.stderr}`), "refusal names the loc");
  assert.strictEqual(fs.readFileSync(notes, "utf8"), before, "nothing written");
  assert.strictEqual(triage(["dispose", fwd(notes), "5", "fixed"]).status, 0, "other entry: not verified");
  touch(r.dir, "src/a.js");
  assert.strictEqual(triage(["dispose", fwd(notes), "4", "fixed"]).status, 0, "after changing the loc");
  assert.ok(fs.readFileSync(notes, "utf8").split("\n")[3].endsWith(FIXED), "fixed written");
});
caseEnd();

caseBegin("read-open-verifies-hand-edited-fixed", "bin/lib/this-pr-open.js");
test("a hand-edited fixed reads fixed-unverified; user-accepted settles it; other fixed is never open", () => {
  const { readOpenThisPr } = require(path.join(LIB, "this-pr-open.js"));
  const r = repo();
  const notes = F.writeNotes(r.dir, { BugsFound: [
    F.entry("hand fixed", { loc: "src/a.js", base: r.c0, terminal: FIXED }),
    F.entry("other fixed", { loc: "src/b.js", scope: "other", terminal: FIXED }),
  ] });
  const open = readOpenThisPr(notes, {});
  assert.deepStrictEqual(open.open.map((o) => [o.body, o.reason]), [["hand fixed", "fixed-unverified"]], "default runner verifies");
  fs.writeFileSync(notes, M.markEntryUserAccepted(fs.readFileSync(notes, "utf8"), 4, "fixed in a sibling file"));
  assert.deepStrictEqual(readOpenThisPr(notes, {}).open, [], "user-accepted settles");
});
caseEnd();

caseBegin("default-branches-env-override", "bin/lib/fixed-evidence.js");
test("DEFAULT_BRANCHES env overrides the merge-base fallback branches (origin/<b>, then local <b>)", () => {
  const { fixedEvidence, defaultGitRunner } = require(path.join(LIB, "fixed-evidence.js"));
  const check = (dir) => fixedEvidence(fixedEntry({ loc: "src/a.js" }), defaultGitRunner(dir));
  const saved = process.env.DEFAULT_BRANCHES;
  const setEnv = (v) => { if (v === undefined) delete process.env.DEFAULT_BRANCHES; else process.env.DEFAULT_BRANCHES = v; };
  try {
    // Local-only default branch `trunk`: neither origin nor main/master exists.
    const local = repo({ origin: "none", branch: "trunk" });
    touch(local.dir, "src/a.js");
    setEnv(undefined);
    assert.deepStrictEqual([check(local.dir).ok, check(local.dir).reason], [false, "no-base"], "built-in main/master: no base point");
    setEnv(" develop , trunk ");
    assert.deepStrictEqual(check(local.dir), { ok: true }, "env names trunk (trimmed list): local trunk is the fallback");
    setEnv("develop");
    assert.strictEqual(check(local.dir).reason, "no-base", "env replaces the built-ins: develop alone finds nothing");
    // origin/trunk without origin/HEAD: the env list is tried against origin first.
    const remote = repo({ origin: "none", branch: "trunk" });
    F.git(remote.dir, ["update-ref", "refs/remotes/origin/trunk", remote.c0]);
    F.git(remote.dir, ["branch", "-q", "-D", "trunk"]);
    touch(remote.dir, "src/a.js");
    setEnv(undefined);
    assert.strictEqual(check(remote.dir).reason, "no-base", "origin/trunk is invisible to the built-ins");
    setEnv("trunk");
    assert.deepStrictEqual(check(remote.dir), { ok: true }, "origin/trunk via the env list");
  } finally {
    setEnv(saved);
  }
});
caseEnd();
