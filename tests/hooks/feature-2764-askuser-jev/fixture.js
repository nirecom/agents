"use strict";
// Test-only scaffolding for tests/hooks/feature-2764-askuser-jev.js (#2764): the workflow-state
// seeds (one per current step the dialog ID cases need), the AskUserQuestion hook driver, and the
// route-log reader. Built on tests/hooks/feature-2461-jev/fixture.js. Holds no cases of its own.

const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const F = require("../feature-2461-jev/fixture");

const HOOK = "hooks/pre-tool-use-askuser-jev.js";
const STEPS = require(F.lib("hooks/workflow-state/state-io/core.js")).VALID_STEPS;
const ERROR_PRELOAD = F.fwd(path.join(__dirname, "jev-error-preload.js"));
const LEVELS_PRELOAD = F.fwd(path.join(__dirname, "levels-preload.js"));
const { MULTI_ROW } = require("./levels-preload-row");
const between = (from, to) => STEPS.slice(STEPS.indexOf(from), STEPS.indexOf(to)).map((s) => [s, "skipped"]);
// started + every step from research up to (not including) `to` skipped: `to` is current.
const upTo = (to) => (sc, sid) => { F.seedStarted(sc, sid); F.markSteps(sc, sid, between("research", to)); };
function statePath(sc, sid) {
  const o = F.nodeEval(sc, null, `console.log(JSON.stringify({ p: require(${JSON.stringify(F.lib("hooks/workflow-state/state-io/core.js"))}).getStatePath(process.argv[2]) }));`, [sid], { JEV: "off" });
  if (o.status !== 0 || !o.json) throw new Error(`getStatePath failed: ${o.stderr}`);
  return o.json.p;
}

// SEED[name](sc, sid) — the state each name leaves; the premise case pins the step it reads as.
const SEED = {
  started: (sc, sid) => F.seedStarted(sc, sid),
  approvalWait: (sc, sid) => {
    F.markSteps(sc, sid, [["workflow_init", "complete"]]);
    fs.writeFileSync(path.join(sc.plans, `${sid}-intent.md`), "# Intent\n\n## Goal\n\nx\n\n## Issues\n\n- #1 x\n");
  },
  userVerification: upTo("user_verification"),
  runTests: upTo("run_tests"),
  writeCode: upTo("write_code"),
  workflowInit: (sc, sid) => F.markSteps(sc, sid, [["workflow_init", "in_progress"]]),
  noStep: (sc, sid) => {
    F.seedStarted(sc, sid);
    F.markSteps(sc, sid, between("research", "final_report"));
  },
  none: () => {},
  corrupt: (sc, sid) => {
    const p = statePath(sc, sid);
    fs.mkdirSync(path.dirname(p), { recursive: true });
    fs.writeFileSync(p, "{not json");
  },
};

const Q = (question, labels, multiSelect = false) => ({
  question, header: "Pick", multiSelect, options: labels.map((l) => ({ label: l, description: `use ${l}` })),
});
const ONE = [Q("Which output format should the report use?", ["Markdown", "HTML", "CSV"])];
const TWO = [ONE[0], Q("Where should the report be written?", ["stdout", "a file"])];
const meta = (source) => ({ source });
// grid(nq, no): nq questions of no options each, every question and label distinct.
const grid = (nq, no) => Array.from({ length: nq }, (_q, i) => Q(`Grid question ${i}?`, Array.from({ length: no }, (_o, j) => `G${i}-${j}`)));

const routesLog = (sc) => path.join(sc.state, "logs", "askuser-routes.jsonl");
const routes = (sc) => F.records(sc, routesLog(sc));

// makeAsk(ROOT, mock) -> ask(name, {questions, source, seed, extra, entries, toolInput, sid, preload, transcriptPath})
// -> {o, out (hookSpecificOutput|null), q (Jev queries), sc, sid, rec (the one route record|undefined), recs}.
// source sets metadata.source; toolInput replaces the whole tool input; sid null drops session_id;
// preload true = the error preload, "levels" = the multi-step row preload; transcriptPath replaces
// the written transcript's path, null drops transcript_path.
function makeAsk(ROOT, mock) {
  return function ask(name, opt = {}) {
    const base = F.scene(ROOT, name);
    const sc = Object.assign({}, base, { cwd: base.proj });
    const sid = F.newSid();
    SEED[opt.seed || "runTests"](sc, sid);
    const questions = opt.questions || ONE;
    const toolInput = opt.toolInput || (opt.source === undefined ? { questions } : { questions, metadata: meta(opt.source) });
    const tp = F.writeTranscript(sc, "t", opt.entries || [F.U("write the summary report"), F.A(F.T("One choice first."), F.TU("AskUserQuestion", toolInput))]);
    const input = { cwd: F.fwd(sc.cwd), hook_event_name: "PreToolUse", tool_name: "AskUserQuestion", tool_input: toolInput };
    if (opt.transcriptPath !== null) input.transcript_path = opt.transcriptPath === undefined ? tp : opt.transcriptPath;
    if (opt.sid !== null) input.session_id = sid;
    const pre = opt.preload === "levels" ? LEVELS_PRELOAD : opt.preload ? ERROR_PRELOAD : null;
    const extra = Object.assign({}, pre ? { NODE_OPTIONS: `--require "${pre}"` } : {}, opt.extra || {});
    const before = mock.count("systemone");
    const o = F.runHook(sc, mock, HOOK, input, extra);
    const out = o.json && o.json.hookSpecificOutput ? o.json.hookSpecificOutput : null;
    const recs = routes(sc);
    return { o, out, q: mock.count("systemone") - before, sc, sid, recs, rec: recs[0] };
  };
}

// declined(r): the hook exits 0 with no decision, so the dialog reaches the user.
function declined(r) {
  assert.strictEqual(r.o.status, 0, r.o.stderr.slice(0, 300));
  assert.strictEqual(r.out, null, `no decision (stdout ${r.o.stdout.slice(0, 300)})`);
}

// routed(r, want): exactly one route record whose fields equal want (keys absent from want are not compared).
function routed(r, want) {
  assert.strictEqual(r.recs.length, 1, `one route record (got ${JSON.stringify(r.recs)}; stderr ${r.o.stderr.slice(0, 300)})`);
  const got = Object.fromEntries(Object.keys(want).map((k) => [k, r.rec[k]]));
  assert.deepStrictEqual(got, want);
}

// noDialogText(rec, qs): the record holds neither the question text nor any option label.
function noDialogText(rec, qs) {
  const text = JSON.stringify(rec);
  for (const q of qs) {
    assert.ok(!text.includes(q.question), `the record omits the question "${q.question}"`);
    for (const o of q.options) assert.ok(!text.includes(o.label), `the record omits the label ${o.label}`);
  }
}

module.exports = { HOOK, STEPS, SEED, MULTI_ROW, Q, ONE, TWO, grid, meta, routesLog, routes, makeAsk, declined, routed, noDialogText };
