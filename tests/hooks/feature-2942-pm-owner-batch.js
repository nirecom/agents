#!/usr/bin/env node
"use strict";
// Tests: hooks/lib/pm-instructions/role.js, hooks/lib/pm-instructions/owner-child.js
// Tags: TL2, scope:issue-specific, hooks, pm-session, pm-instructions, session-start, post-compact, pm-field, owner-batch, issue-2942
// #2942 S21: the workflow role's owner lookup asks `bin/pm-state owner` once for every issue local state could
// not decide, under one SPAWN_CAP_MS slice that, with the tree-kill margin, fits the 5 s PostCompact deadline.
// The world is tests/hooks/feature-3019-pm-instructions/world.js; owner spawns are counted by ./feature-2942-pm-owner-batch/spawn-probe.js.
// TL3 gap (what this test does NOT catch):
// - a real Claude Code host running the SessionStart / PostCompact hooks against a live GitHub Projects v2 field
// - a partial forge failure inside one real batched GraphQL call (the fake gh fails the whole call)

const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { test, after } = require("node:test");
const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const W8 = require("./feature-3019-pm-instructions/world");

const { P, MD_ENV, fixtureMd, makeShared, makeWorld } = W8;
const ROLE = path.join(W8.ROOT, "hooks", "lib", "pm-instructions", "role.js");
const PROBE = path.join(__dirname, "feature-2942-pm-owner-batch", "spawn-probe.js");
const POST_COMPACT_DEADLINE_MS = 5000;
const TREE_KILL_MARGIN_MS = 1000;

const restore = isolate();
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "pm-owner-batch-"));
after(() => {
  restore();
  fs.rmSync(TMP, { recursive: true, force: true });
});
process.env.CLAUDE_TRANSCRIPT_BASE_DIR = path.join(TMP, "transcripts-top");
fs.mkdirSync(process.env.CLAUDE_TRANSCRIPT_BASE_DIR);
const S = makeShared(TMP);

// Two PMs, neither listing the issue in its state: the PM field alone owns #4961 (PM-batchA) and #4962 (PM-batchB).
const w = makeWorld(S, "batch");
const md = { [MD_ENV]: S.md("batch", fixtureMd()) };
const sidA = P.uuid(0x29422101);
const sidB = P.uuid(0x29422102);
const wf = P.uuid(0x29422103);
w.pm(sidA, P.pm({ tag: "PM-batchA", issues: [] }));
w.pm(sidB, P.pm({ tag: "PM-batchB", issues: [] }));
w.plain(wf);
w.intent(wf, ["#4961", "#4962"]);
w.field({ "o/r#4961": "PM-batchA", "o/r#4962": "PM-batchB" });

// hookCounted(file, event) -> {r, spawns}: the hook run with the spawn probe preloaded; spawns are the argv
// lists of every `bin/pm-state owner` process the run started.
let n = 0;
function hookCounted(file, event) {
  const log = path.join(TMP, `spawns-${++n}.log`);
  fs.writeFileSync(log, "");
  const r = w.hook(file, wf, event, Object.assign({ NODE_OPTIONS: `--require "${P.fwd(PROBE)}"`, PM_SPAWN_PROBE_LOG: log }, md));
  const spawns = fs.readFileSync(log, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l));
  return { r, spawns };
}
const bad = (r) => `code=${r.code} ms=${r.ms} ctx=${JSON.stringify(r.ctx.slice(-800))} err=${JSON.stringify(r.err.slice(0, 300))}`;
const issueArgs = (argv) => argv.filter((a, i) => argv[i - 1] === "--issue");
const HOOKS = [["session-start.js", "SessionStart"], ["post-compact.js", "PostCompact"]];

caseBegin("owner-batch-spawn-cap", "hooks/lib/pm-instructions/role.js");
test("B1 SPAWN_CAP_MS is 3000: one slice for the single batched owner spawn", () => {
  assert.strictEqual(require(ROLE).SPAWN_CAP_MS, 3000);
});
test("B2 SPAWN_CAP_MS + the tree-kill margin fits the 5000 ms PostCompact deadline", () => {
  const cap = require(ROLE).SPAWN_CAP_MS;
  const margin = Number(/const TREE_KILL_MARGIN_MS = (\d+);/.exec(fs.readFileSync(ROLE, "utf8"))[1]);
  assert.strictEqual(margin, TREE_KILL_MARGIN_MS);
  assert.ok(cap + margin <= POST_COMPACT_DEADLINE_MS, `${cap} + ${margin} > ${POST_COMPACT_DEADLINE_MS}`);
});
caseEnd();

caseBegin("owner-batch-hook-names-both-owners", "hooks/lib/pm-instructions/role.js");
for (const [file, event] of HOOKS) {
  test(`B3 ${event}: a workflow session with two field-owned issues names both owners under role=workflow`, () => {
    const r = w.hook(file, wf, event, md);
    assert.strictEqual(r.code, 0, bad(r));
    assert.ok(r.ctx.includes("[pm-instructions role=workflow"), bad(r));
    for (const s of ["PM-batchA", sidA, "PM-batchB", sidB]) assert.ok(r.ctx.includes(s), `missing ${s}: ${bad(r)}`);
  });
}
caseEnd();

caseBegin("owner-batch-single-spawn", "hooks/lib/pm-instructions/owner-child.js");
for (const [file, event] of HOOKS) {
  test(`B4 ${event}: the two issues are looked up by one bin/pm-state owner spawn carrying both`, () => {
    const { r, spawns } = hookCounted(file, event);
    assert.strictEqual(r.code, 0, bad(r));
    for (const s of [sidA, sidB]) assert.ok(r.ctx.includes(s), `missing ${s}: ${bad(r)}`);
    assert.strictEqual(spawns.length, 1, `owner spawns: ${JSON.stringify(spawns)}`);
    const refs = issueArgs(spawns[0]);
    assert.strictEqual(refs.length, 2, JSON.stringify(spawns[0]));
    assert.ok(refs.some((x) => /#4961$/.test(x)) && refs.some((x) => /#4962$/.test(x)), JSON.stringify(spawns[0]));
  });
}
caseEnd();

// One owned issue (#4971) and one whose forge read fails (#4972): `bin/pm-state owner` exits 1 for the batch,
// so the whole batch fails open — no block, no partial owner, one reason line. The SessionStart reason line
// also pins the fractional sliceMs fix: a RangeError from spawnSync was swallowed with no line at all.
const wf2 = makeWorld(S, "batch-partial");
const sidP = P.uuid(0x29422104);
const wfP = P.uuid(0x29422105);
wf2.pm(sidP, P.pm({ tag: "PM-batchP", issues: [] }));
wf2.plain(wfP);
wf2.intent(wfP, ["#4971", "#4972"]);
wf2.setMap({ "o/r#4971": { parent: null, pm: "PM-batchP" }, "o/r#4972": { fail: true } });
const reasonLines = (err) => String(err).split(/\r?\n/).filter((l) => l.startsWith("pm-instructions:"));

caseBegin("owner-batch-partial-failure-fail-open", "hooks/lib/pm-instructions/role.js");
test("B5 library: one undecidable issue in the batch -> no block, no partial owner, exactly one owner-lookup-failed line", () => {
  const r = wf2.probe({ sid: wfP, deadline: "hook" }, md);
  assert.strictEqual(r.value, null, `code=${r.code} value=${JSON.stringify(r.value)} err=${r.err}`);
  const lines = String(r.err).split(/\r?\n/).filter(Boolean);
  assert.strictEqual(lines.length, 1, `stderr: ${JSON.stringify(r.err)}`);
  assert.ok(lines[0].startsWith("pm-instructions: owner lookup failed"), `stderr: ${JSON.stringify(r.err)}`);
  assert.match(lines[0], /exit 1/);
});
for (const [file, event] of HOOKS) {
  test(`B5 ${event}: the failed batch omits the block and any partial owner, and prints exactly one reason line`, () => {
    const r = wf2.hook(file, wfP, event, md);
    assert.strictEqual(r.code, 0, bad(r));
    assert.ok(r.ctx.includes(`Current workflow session_id: ${wfP}`), bad(r));
    assert.ok(!r.ctx.includes("[pm-instructions") && !r.ctx.includes("PM-batchP") && !r.ctx.includes(sidP), bad(r));
    const lines = reasonLines(r.err);
    assert.strictEqual(lines.length, 1, `reason lines: ${JSON.stringify(r.err)}`);
    assert.ok(lines[0].startsWith("pm-instructions: owner lookup failed"), `stderr: ${JSON.stringify(r.err)}`);
  });
}
caseEnd();
