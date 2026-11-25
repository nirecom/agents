"use strict";
// Tests: bin/lib/pm-field/write.js, bin/lib/tracker-fields/backfill.js
// Tags: TL2, scope:issue-specific, feature-3142, pm-field, projects-v2
// #3142 Step 9: createPmField.prepare resolves the board once per repo (resolveBoard), starts ensure-board-card
// with toInternalEnv(board) over the spawn env, starts nothing for a repo whose board is not resolved
// (cardFailure board-<status>), and records budget-exhausted for a ref the deadline left unstarted; resolveCard
// returns that reason before no-card. backfillPm names the budget-exhausted count and the re-run.
// TL3 gap (what this test does NOT catch):
// - the real ensure-board-card.sh and readCards against GitHub; spawn, readCards and resolveBoard are stubbed.

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const assert = require("node:assert");
const cp = require("node:child_process");
const path = require("node:path");
const { test, after } = require("node:test");

const restore = isolate();
const X = require("../lib/pm-s3-fixture");
const { P, F } = X;
after(() => { restore(); });

const WRITE = path.join(P.ROOT, "bin", "lib", "pm-field", "write.js");
const RESOLVE = path.join(P.ROOT, "bin", "lib", "project-board", "resolve.js");
const R = require(path.join(P.ROOT, "bin", "lib", "pm-field", "read.js"));
const { refKey } = require(path.join(P.ROOT, "bin", "lib", "forge-issue-links.js"));
const brief = (r) => JSON.stringify(r).slice(0, 600);
const ref = (repo, number) => ({ repo, number });
// who(spawns) -> "o/r#1 o/s#3": names the starts without dumping their (inherited, real) env.
const who = (spawns) => [].concat(spawns).map((s) => `${s.repo}#${s.number}`).join(" ");
const board = (repo, status) => ({ status: status || "resolved", owner: repo.split("/")[0], number: 3,
  projectId: `PVT_${repo.replace(/\W/g, "_")}`, fieldIds: {}, candidates: status ? ["o#3", "o#4"] : [] });

// withPrepare(boards, onEnsure, fn) — write.js loaded fresh with spawnSync, readCards and resolveBoard stubbed and
// Date.now on a test clock; fn({io, spawns, resolves, clock}). A ref started by ensure-board-card has a card on
// the re-read. onEnsure(spawn, clock) runs at each ensure-board-card start.
function withPrepare(boards, onEnsure, fn) {
  const saved = { spawnSync: cp.spawnSync, readCards: R.readCards, now: Date.now, write: require.cache[WRITE] };
  const spawns = [];
  const resolves = [];
  const clock = { t: 0 };
  const resolveBoard = (repo, opts) => { resolves.push({ repo, opts }); return boards[repo]; };
  let real = null;
  try { real = require(RESOLVE); } catch (_) { real = null; }
  const savedResolve = real ? real.resolveBoard : undefined;
  if (real) real.resolveBoard = resolveBoard;
  cp.spawnSync = (cmd, argv, opts) => {
    const args = (argv || []).map(String);
    if (args.some((a) => /ensure-board-card\.sh$/.test(a))) {
      const i = args.indexOf("--repo");
      const s = { repo: args[i + 1], number: Number(args[args.length - 1]), env: (opts && opts.env) || {} };
      spawns.push(s);
      if (onEnsure) onEnsure(s, clock);
    }
    return { status: 0, stdout: "", stderr: "", signal: null };
  };
  const started = (r) => spawns.some((s) => s.repo === r.repo && s.number === r.number);
  let reads = 0;
  R.readCards = (refs) => {
    reads += 1;
    return { ok: true, results: Object.fromEntries(refs.map((r) => [refKey(r.repo, r.number),
      reads > 1 && started(r) ? { ok: true, itemId: `PVTI_${r.number}`, projectId: "PVT_x", fieldId: "PVTF_pm" } : { ok: false, reason: "no-card" }])) };
  };
  Date.now = () => clock.t;
  try {
    delete require.cache[WRITE];
    const W = require(WRITE);
    const io = W.createPmField({ deadlineAt: 1000, resolveBoard });
    return fn({ io, spawns, resolves, clock });
  } finally {
    Object.assign(cp, { spawnSync: saved.spawnSync });
    R.readCards = saved.readCards;
    Date.now = saved.now;
    if (real) real.resolveBoard = savedResolve;
    if (saved.write) require.cache[WRITE] = saved.write; else delete require.cache[WRITE];
  }
}

caseBegin("prepare-resolves-once-per-repo", "bin/lib/pm-field/write.js");
test("P1 one resolveBoard per repo, and each ensure-board-card start carries its repo's board env", () => {
  const boards = { "o/r": board("o/r"), "o/s": board("o/s") };
  withPrepare(boards, null, ({ io, spawns, resolves }) => {
    assert.deepStrictEqual(io.prepare([ref("o/r", 1), ref("o/r", 2), ref("o/s", 3)]), { ok: true });
    assert.deepStrictEqual(resolves.map((x) => x.repo).sort(), ["o/r", "o/s"], brief(resolves));
    assert.strictEqual(spawns.length, 3, who(spawns));
    for (const s of spawns) {
      const b = boards[s.repo];
      assert.strictEqual(s.env._ISSUE_CREATE_INTERNAL_PROJECT_ID, b.projectId, `internal env missing for ${s.repo}#${s.number}`);
      assert.strictEqual(s.env._ISSUE_CREATE_INTERNAL_OWNER, b.owner, who(s));
      assert.strictEqual(String(s.env._ISSUE_CREATE_INTERNAL_PROJECT_NUM), String(b.number), who(s));
      // The board env goes over the inherited env, not in place of it (a copied env keeps Windows' "Path").
      const pathKey = Object.keys(s.env).find((k) => k.toUpperCase() === "PATH");
      assert.strictEqual(pathKey && s.env[pathKey], process.env.PATH, `PATH dropped from the spawn env of ${who(s)}`);
    }
  });
});
test("P2 a repo whose board is ambiguous starts no ensure-board-card and its write fails board-ambiguous", () => {
  const boards = { "o/r": board("o/r"), "o/amb": board("o/amb", "ambiguous") };
  withPrepare(boards, null, ({ io, spawns }) => {
    io.prepare([ref("o/amb", 5), ref("o/r", 1)]);
    assert.deepStrictEqual(spawns.map((s) => `${s.repo}#${s.number}`), ["o/r#1"], who(spawns));
    assert.deepStrictEqual(io.write(ref("o/amb", 5), "PM-a"), { result: "failed", reason: "board-ambiguous" });
  });
});
caseEnd();

caseBegin("prepare-budget-exhausted", "bin/lib/pm-field/write.js");
test("P3 a ref the deadline left unstarted fails budget-exhausted, not no-card", () => {
  const boards = { "o/r": board("o/r") };
  // The first ensure-board-card start uses up the budget; the clock is rewound before the writes.
  withPrepare(boards, (_s, clock) => { clock.t = 1000; }, ({ io, spawns, clock }) => {
    io.prepare([ref("o/r", 1), ref("o/r", 2), ref("o/r", 3)]);
    assert.strictEqual(spawns.length, 1, who(spawns));
    clock.t = 0;
    assert.deepStrictEqual(io.write(ref("o/r", 2), "PM-a"), { result: "failed", reason: "budget-exhausted" });
    assert.deepStrictEqual(io.write(ref("o/r", 3), "PM-a"), { result: "failed", reason: "budget-exhausted" });
    assert.deepStrictEqual(io.write(ref("o/r", 1), "PM-a"), { result: "ok" });
  });
});
caseEnd();

caseBegin("backfill-budget-exhausted-reason", "bin/lib/tracker-fields/backfill.js");
test("P4 the failure reason counts the budget-exhausted writes and asks for a re-run", () => F.alone(() => {
  P.seedPm(P.uuid(0x31420001), P.pm({ tag: "PM-p4", issues: [{ number: 9411, repo: "o/r" }, { number: 9412, repo: "o/r" }, { number: 9413, repo: "o/r" }] }));
  const fld = X.field({});
  const answers = { 9411: "budget-exhausted", 9412: "budget-exhausted", 9413: "HTTP 502" };
  const r = P.load("bin/lib/tracker-fields/backfill.js").backfillPm({
    repo: "o/r", read: fld.read, write: (x) => ({ result: "failed", reason: answers[x.number] }),
  });
  assert.strictEqual(r.ok, false, brief(r));
  assert.strictEqual(r.reason, "3 write(s) failed (2 budget-exhausted; re-run to continue)", brief(r));
}));
test("P5 without a budget-exhausted write the reason stays the plain count", () => F.alone(() => {
  P.seedPm(P.uuid(0x31420002), P.pm({ tag: "PM-p5", issues: [{ number: 9421, repo: "o/r" }] }));
  const fld = X.field({});
  const r = P.load("bin/lib/tracker-fields/backfill.js").backfillPm({
    repo: "o/r", read: fld.read, write: () => ({ result: "failed", reason: "HTTP 502" }),
  });
  assert.strictEqual(r.reason, "1 write(s) failed", brief(r));
}));
caseEnd();
