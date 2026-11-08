"use strict";
// In-process parts of tests/bin/feature-2658-session-sync-engine-integrate-6.js (#2658): resolveUnmerged
// keeps the lines a transcript union drops in a conflict sibling, and writeHistoryLocal keeps a line
// appended to ~/.claude/history.jsonl during its own write. Holds no case markers.
const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { test } = require("node:test");
const { jline } = require("./fixtures");

const REL = "p1/t.jsonl";
const FIXED = Date.UTC(2026, 0, 2, 3, 4, 5);
const HOST = os.hostname().split(".")[0];
const FIRST_COPY = `p1/t.sync-conflict-${HOST}-20260102T030405Z.jsonl`;
const GIT_KEYS = ["GIT_CONFIG_GLOBAL", "GIT_CONFIG_NOSYSTEM", "XDG_CONFIG_HOME"];

let seq = 0;

// withFixtureEnv(F, fn) — in-process git runs under the fixture git config, and `new Date()` is FIXED.
async function withFixtureEnv(F, fn) {
  const env = F.gitEnv();
  const saved = GIT_KEYS.map((k) => process.env[k]);
  for (const k of GIT_KEYS) process.env[k] = env[k];
  const RealDate = global.Date;
  global.Date = class extends RealDate {
    constructor(...a) { super(...(a.length ? a : [FIXED])); }
  };
  try {
    return await fn();
  } finally {
    global.Date = RealDate;
    GIT_KEYS.forEach((k, i) => { if (saved[i] === undefined) delete process.env[k]; else process.env[k] = saved[i]; });
  }
}

function initRepo(F, files) {
  seq += 1;
  const dir = path.join(F.TMP, `uh${seq}`, "projects");
  fs.mkdirSync(dir, { recursive: true });
  F.git(dir, ["init", "-q"]);
  F.git(dir, ["config", "core.hooksPath", "/dev/null"]);
  for (const [rel, text] of Object.entries(files)) F.write(path.join(dir, ...rel.split("/")), text);
  F.git(dir, ["add", "-A"]);
  F.git(dir, ["commit", "-q", "-m", "seed"]);
  return { dir, rev: F.git(dir, ["rev-parse", "HEAD"]) };
}

// resolve(F, local, remote, pre) — REL holds remote in the commit and local in W, then resolveUnmerged runs.
function resolve(F, local, remote, pre = {}) {
  const { dir, rev } = initRepo(F, { [REL]: remote });
  for (const [rel, text] of Object.entries(pre)) F.write(path.join(dir, ...rel.split("/")), text);
  F.write(path.join(dir, ...REL.split("/")), local);
  const stats = F.lib("state").newStats();
  F.lib("selfheal").resolveUnmerged(dir, [REL], rev, stats);
  const read = (rel) => fs.readFileSync(path.join(dir, ...rel.split("/")), "utf8");
  const siblings = fs.readdirSync(path.join(dir, "p1")).filter((n) => n.includes(".sync-conflict-")).sort();
  return { stats, read, siblings };
}

const lines = (...ls) => ls.join("\n") + "\n";

function unmergedJsonl(F) {
  test("an unmerged transcript takes the union and its losing same-uuid line goes to one conflict sibling", () => withFixtureEnv(F, () => {
    const lose = jline("x", { v: "a" });
    const win = jline("x", { v: "b" });
    const r = resolve(F, lines(win), lines(lose));
    assert.strictEqual(r.read(REL), lines(win), "the path holds the union with the winning line");
    assert.deepStrictEqual(r.stats.conflicts, [{ path: REL, copy: FIRST_COPY, localMtime: null, remoteTime: null, lostLines: 1 }]);
    assert.strictEqual(r.read(FIRST_COPY), lines(lose), "the sibling holds the losing line");
  }));
  test("an unmerged transcript whose union loses nothing gets no sibling and no conflict", () => withFixtureEnv(F, () => {
    const r = resolve(F, lines(jline("x")), lines(jline("y")));
    assert.strictEqual(r.read(REL), lines(jline("x"), jline("y")));
    assert.deepStrictEqual(r.siblings, []);
    assert.deepStrictEqual(r.stats.conflicts, []);
  }));
  test("lines lost on both sides land deduplicated in one sibling under a free name", () => withFixtureEnv(F, () => {
    const xLose = jline("x", { v: "a" });
    const xWin = jline("x", { v: "z" });
    const yLose = jline("y", { v: "a" });
    const yWin = jline("y", { v: "z" });
    const r = resolve(F, lines(xLose, xLose, yWin), lines(xWin, yLose), { [FIRST_COPY]: "older\n" });
    const numbered = FIRST_COPY.replace(/\.jsonl$/, "-2.jsonl");
    assert.strictEqual(r.read(REL), lines(xWin, yWin));
    assert.deepStrictEqual(r.stats.conflicts, [{ path: REL, copy: numbered, localMtime: null, remoteTime: null, lostLines: 2 }]);
    assert.strictEqual(r.read(numbered), lines(xLose, yLose), "local and remote losers, each once");
    assert.strictEqual(r.read(FIRST_COPY), "older\n", "the taken name keeps its own content");
  }));
}

const hline = (display, timestamp) => JSON.stringify({ display, timestamp });
const A = hline("a", 1);
const B = hline("b", 2);
const C = hline("c", 3);

// pullWithHistory(F, onTmpWrite) — a pull of a remote-less clone whose W .history.jsonl holds B while
// ~/.claude/history.jsonl holds A; onTmpWrite(file, n) runs after the n-th write of history's tmp file.
async function pullWithHistory(F, onTmpWrite) {
  const { dir } = initRepo(F, { ".gitattributes": F.lib("integrate").GITATTRIBUTES });
  const claude = path.join(path.dirname(dir), "claude");
  const plans = path.join(path.dirname(dir), "plans");
  fs.mkdirSync(plans, { recursive: true });
  const file = path.join(claude, "history.jsonl");
  F.write(file, lines(A));
  F.write(path.join(dir, ".history.jsonl"), lines(B));
  const isTmp = (p) => path.dirname(String(p)) === claude && path.basename(String(p)).startsWith(".history.jsonl.session-sync-");
  const realWrite = fs.writeFileSync;
  const realRename = fs.renameSync;
  const seen = { tmpWrites: 0, renames: 0 };
  fs.writeFileSync = function (p, ...rest) {
    const out = realWrite.call(fs, p, ...rest);
    if (isTmp(p)) {
      seen.tmpWrites += 1;
      if (onTmpWrite) onTmpWrite(file, seen.tmpWrites);
    }
    return out;
  };
  fs.renameSync = function (from, to) {
    if (path.resolve(String(to)) === path.resolve(file)) seen.renames += 1;
    return realRename.call(fs, from, to);
  };
  let r;
  try {
    r = await withFixtureEnv(F, () => F.lib("integrate").run({ action: "pull", dir, claudeDir: claude, plansDir: plans, skipFetch: true, waitMs: 0 }));
  } finally {
    fs.writeFileSync = realWrite;
    fs.renameSync = realRename;
  }
  assert.notStrictEqual(r.result, "failed", `pull failed: ${r.error}`);
  const leftovers = fs.readdirSync(claude).filter((n) => n.endsWith(".tmp"));
  return { text: fs.readFileSync(file, "utf8"), seen, leftovers };
}

function historyRace(F) {
  test("a line appended to history.jsonl between the read and the rename survives with the merged lines", async () => {
    const r = await pullWithHistory(F, (file, n) => { if (n === 1) fs.appendFileSync(file, lines(C)); });
    assert.strictEqual(r.text, lines(A, B, C));
    assert.deepStrictEqual(r.seen, { tmpWrites: 2, renames: 1 }, "the text is rebuilt once, then renamed");
    assert.deepStrictEqual(r.leftovers, []);
  });
  test("without a concurrent change history.jsonl is written once and no tmp file is left", async () => {
    const r = await pullWithHistory(F, null);
    assert.strictEqual(r.text, lines(A, B));
    assert.deepStrictEqual(r.seen, { tmpWrites: 1, renames: 1 });
    assert.deepStrictEqual(r.leftovers, []);
  });
  test("a concurrent change that already holds the merged lines leaves the file alone and removes the tmp", async () => {
    const r = await pullWithHistory(F, (file, n) => { if (n === 1) fs.writeFileSync(file, lines(A, B, C)); });
    assert.strictEqual(r.text, lines(A, B, C), "the concurrent writer's text stays");
    assert.deepStrictEqual(r.seen, { tmpWrites: 1, renames: 0 }, "no rebuild write and no rename");
    assert.deepStrictEqual(r.leftovers, []);
  });
}

module.exports = { unmergedJsonl, historyRace };
