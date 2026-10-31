"use strict";
// Orchestrator part of tests/hooks/feature-2507-precommit-node.js (#2507). Synthetic entries and
// stub checks drive orchestrator.run({ entries, context, snapshot, loadCheck }) -> rc (0 pass,
// 1 block, 10 CONFIRM_WARN); fs.writeSync is captured so markers and stub calls share one log.
const assert = require("node:assert");
const { test } = require("node:test");

function entry(name, over = {}) {
  return { name, order: 0, failMode: "closed", agentsRepoOnly: false, mergeNarrowable: false, visibilityGated: false, readSource: "snapshot", mutatesIndex: false, ...over };
}

// harness(F, specs) — entries plus a loadCheck whose stubs log `run:<name>` with the files they got.
function harness(F, specs, { context = {}, files = ["a.txt", "b.txt"] } = {}) {
  const entries = specs.map(([name, over], i) => entry(name, { ...over, order: i }));
  const behaviours = Object.fromEntries(specs.map(([name, , fn]) => [name, fn || (() => ({ verdict: "pass", messages: [] }))]));
  const calls = [];
  const snapshot = { invalidations: 0, files: () => files.slice(), invalidate() { this.invalidations += 1; calls.push({ event: "invalidate" }); } };
  const ctx = { isAgentsRepo: true, merge: { state: "not-merging" }, visibility: { kills: 0, kill() { this.kills += 1; } }, ...context };
  const loadCheck = (e) => ({
    run: async (input) => {
      calls.push({ event: `run:${e.name}`, files: input && input.files });
      return behaviours[e.name](input);
    },
  });
  const go = () => F.capture(async (log) => {
    const origPush = calls.push.bind(calls);
    calls.push = (row) => { log.push(row); return origPush(row); };
    return F.fresh("orchestrator.js").run({ entries, context: ctx, snapshot, loadCheck });
  });
  return { calls, snapshot, ctx, go };
}

const markersOf = (log) => log.filter((r) => r.fd === 2 && /^pre-commit-section: /.test(r.text)).map((r) => r.text.trim().slice(20));
const stderrOf = (log) => log.filter((r) => r.fd === 2).map((r) => r.text).join("");

function failModeMapping(F) {
  test("a closed check that throws blocks with 'pre-commit: <name> failed (<error>). Commit blocked'", async () => {
    const h = harness(F, [["alpha", { failMode: "closed" }, () => { throw new Error("boom-alpha"); }], ["beta"]]);
    const { value, log } = await h.go();
    assert.strictEqual(value, 1);
    assert.match(stderrOf(log), /pre-commit: alpha failed \(boom-alpha\)\. Commit blocked/);
    assert.ok(!h.calls.some((c) => c.event === "run:beta"), "no check runs after a block");
  });
  test("an open check that throws prints a diagnostic and the run continues", async () => {
    const h = harness(F, [["alpha", { failMode: "open" }, () => { throw new Error("boom-open"); }], ["beta"]]);
    const { value, log } = await h.go();
    assert.strictEqual(value, 0);
    assert.match(stderrOf(log), /alpha/);
    assert.match(stderrOf(log), /boom-open/);
    assert.doesNotMatch(stderrOf(log), /Commit blocked/);
    assert.ok(h.calls.some((c) => c.event === "run:beta"));
  });
  test("a block verdict stops the run with rc 1 and kills the pending visibility probe", async () => {
    const h = harness(F, [["alpha", {}, () => ({ verdict: "block", messages: [{ stream: "stdout", text: "blocked-alpha" }] })], ["beta"]]);
    const { value, log } = await h.go();
    assert.strictEqual(value, 1);
    assert.ok(log.some((r) => r.fd === 1 && r.text.includes("blocked-alpha")), "stdout message written");
    assert.strictEqual(h.ctx.visibility.kills, 1);
    assert.deepStrictEqual(markersOf(log), ["alpha"]);
  });
  test("a warn verdict prints and continues; confirm-warn ends with rc 10 (CONFIRM_WARN)", async () => {
    const h = harness(F, [["alpha", {}, () => ({ verdict: "warn", messages: [{ stream: "stderr", text: "warned" }] })], ["omega", {}, () => ({ verdict: "confirm-warn", messages: [] })]]);
    const { value, log } = await h.go();
    assert.strictEqual(value, 10);
    assert.match(stderrOf(log), /warned/);
  });
}

function snapshotRebuild(F) {
  test("indexChanged from a mutatesIndex check rebuilds the snapshot before the next check", async () => {
    const h = harness(F, [["mut", { mutatesIndex: true }, () => ({ verdict: "pass", messages: [], indexChanged: true })], ["next"]]);
    await h.go();
    const order = h.calls.map((c) => c.event);
    assert.deepStrictEqual(order, ["run:mut", "invalidate", "run:next"]);
  });
  test("no rebuild when the mutating check reports no index change", async () => {
    const h = harness(F, [["mut", { mutatesIndex: true }, () => ({ verdict: "pass", messages: [] })], ["next"]]);
    await h.go();
    assert.strictEqual(h.snapshot.invalidations, 0);
  });
}

function mergeNarrowing(F) {
  const specs = [["narrow", { mergeNarrowable: true }], ["wide", { mergeNarrowable: false }]];
  const filesOf = (h, name) => h.calls.find((c) => c.event === `run:${name}`).files;
  test("merging: a mergeNarrowable check gets the staged set minus the MERGE_HEAD paths, others get all", async () => {
    const h = harness(F, specs, { context: { merge: { state: "merging", mergeHead: "x", paths: new Set(["a.txt"]) } } });
    await h.go();
    assert.deepStrictEqual(filesOf(h, "narrow"), ["b.txt"]);
    assert.deepStrictEqual(filesOf(h, "wide"), ["a.txt", "b.txt"]);
  });
  test("undecidable merge state narrows nothing", async () => {
    const h = harness(F, specs, { context: { merge: { state: "undecidable", reason: "fixture" } } });
    await h.go();
    assert.deepStrictEqual(filesOf(h, "narrow"), ["a.txt", "b.txt"]);
  });
}

function agentsRepoOnly(F) {
  test("outside the agents repo an agentsRepoOnly check prints its marker and does not run", async () => {
    const h = harness(F, [["only", { agentsRepoOnly: true }], ["any"]], { context: { isAgentsRepo: false } });
    const { value, log } = await h.go();
    assert.strictEqual(value, 0);
    assert.deepStrictEqual(markersOf(log), ["only", "any"]);
    assert.deepStrictEqual(h.calls.map((c) => c.event), ["run:any"]);
  });
}

function markerBeforeCheck(F) {
  test("output.marker writes 'pre-commit-section: <name>' through fs.writeSync on fd 2", async () => {
    const { log } = await F.capture(async () => F.fresh("output.js").marker("alpha"));
    assert.deepStrictEqual(log, [{ fd: 2, text: "pre-commit-section: alpha\n" }]);
  });
  test("each marker is written before its check runs, in entry order", async () => {
    const h = harness(F, [["one"], ["two"]]);
    const { log } = await h.go();
    const seq = log.map((r) => r.event || (/^pre-commit-section: /.test(r.text || "") ? `marker:${r.text.trim().slice(20)}` : null)).filter(Boolean);
    assert.deepStrictEqual(seq, ["marker:one", "run:one", "marker:two", "run:two"]);
  });
  test("skip-rest ends the run with rc 0 and no later marker", async () => {
    const h = harness(F, [["vis", {}, () => ({ verdict: "skip-rest", messages: [] })], ["gated", { visibilityGated: true }]]);
    const { value, log } = await h.go();
    assert.strictEqual(value, 0);
    assert.deepStrictEqual(markersOf(log), ["vis"]);
  });
}

module.exports = { failModeMapping, snapshotRebuild, mergeNarrowing, agentsRepoOnly, markerBeforeCheck };
