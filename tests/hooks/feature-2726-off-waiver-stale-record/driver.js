"use strict";
// #2726 driver: CONFIRM_<STAGE>=off in the config FILE waives the gate whatever approval record
// is on file (a stale confirm-sentinel hash included), and the four readers agree on one verdict:
// evaluateCompletionApproval / checkPlanApproval (in a child, so each config root loads fresh),
// next-step, next-step --gate and confirm-checkpoint. Modes: off-stale | on-none | intent.
// Prints PASS|name / FAIL|name|detail lines.
const path = require("path");
const { spawnSync } = require("child_process");

// --inproc <sid> <step>: runs inside a child whose AGENTS_MAIN_ROOT is the case's config root.
if (process.argv[2] === "--inproc") {
  const ROOT = path.resolve(__dirname, "..", "..", "..");
  const out = {};
  try {
    const CA = require(path.join(ROOT, "hooks/workflow-state/completion-approval.js"));
    const WS = require(path.join(ROOT, "hooks/workflow-state"));
    out.eval = CA.evaluateCompletionApproval(process.argv[3], process.argv[4], WS.readState(process.argv[3]));
  } catch (e) { out.eval = { threw: e.message }; }
  try {
    const PA = require(path.join(ROOT, "hooks/workflow-state/plan-approval-check.js"));
    out.check = PA.checkPlanApproval(process.argv[3], process.argv[4]);
  } catch (e) { out.check = { threw: e.message }; }
  process.stdout.write(JSON.stringify(out));
  process.exit(0);
}

const R = require("../feature-2729-presentation-receipt/fixture");
const { F, check, show } = R;

const ORDER = ["workflow_init", "clarify_intent", "research", "outline", "detail"];
const STAGE_OF = { clarify_intent: "intent", outline: "outline", detail: "detail" };
const SENT = { clarify_intent: "WORKFLOW_CONFIRM_INTENT", outline: "WORKFLOW_CONFIRM_OUTLINE", detail: "WORKFLOW_CONFIRM_DETAIL" };

// session(step, status, record) -> sid: every earlier step complete (gated ones approved at the
// current sha), `step` at `status`, its own approval absent ("none") or a stale confirm-sentinel hash.
function session(step, status, record) {
  const sid = R.uuidSid(2726);
  const steps = {};
  const approvals = [];
  const last = ORDER.indexOf(step);
  ORDER.forEach((s, i) => { if (i < last) steps[s] = "complete"; });
  steps[step] = status;
  for (const s of ORDER.slice(0, last + 1)) {
    if (!STAGE_OF[s]) continue;
    F.writePlan(sid, STAGE_OF[s]);
    if (s !== step) approvals.push({ step: s });
  }
  if (record === "stale") approvals.push({ step, sha: "stale" });
  F.writeState(sid, steps, approvals, { closes_issues: [1] });
  return sid;
}

function inproc(cfgDir, sid, step) {
  const r = spawnSync(process.execPath, [__filename, "--inproc", sid, step], {
    env: R.CE.childEnvWith(cfgDir), encoding: "utf8", timeout: 60000,
  });
  try { return JSON.parse(r.stdout); } catch (_) { return { eval: {}, check: {}, raw: r.stdout + r.stderr }; }
}

function parse(out) {
  const kv = {};
  for (const line of String(out).split(/\r?\n/)) {
    const m = line.match(/^([A-Z_]+)=(.*)$/);
    if (m) kv[m[1]] = m[2].replace(/^'(.*)'$/, "$1").replace(/^"(.*)"$/, "$1");
  }
  return kv;
}

// Spawned with childEnvWith alone: F.runNode merges process.env back in, and this process may
// already carry a CONFIRM_* value a required module injected from the shell's config root.
function nextStep(cfgDir, sid, extra) {
  const env = R.CE.childEnvWith(cfgDir);
  delete env.CLAUDE_CODE_SESSION_ID;
  const r = spawnSync(process.execPath, [path.join(R.ROOT, "bin/workflow/next-step")].concat(extra || [], ["--session", sid]), {
    input: "", env, encoding: "utf8", timeout: 60000,
  });
  return Object.assign(parse(r.stdout || ""), { _d: `exit=${r.status} out=${r.stdout} err=${r.stderr}` });
}

const offCfg = (step) => R.cfg({ [`CONFIRM_${STAGE_OF[step].toUpperCase()}`]: "off" });

function modeOffStale() {
  for (const step of ["outline", "detail"]) {
    const cfg = offCfg(step);
    for (const status of ["complete", "pending"]) {
      const sid = session(step, status, "stale");
      const v = inproc(cfg, sid, step);
      check(`${step} off + stale record (${status}): evaluateCompletionApproval waives`,
        v.eval.approved === true && v.eval.source === "confirm-flag-off", show(v));
      check(`${step} off + stale record (${status}): checkPlanApproval approved, gate OFF, waived`,
        v.check.verdict === "approved" && v.check.gate === "OFF" && v.check.waived === true, show(v.check));
    }
    const done = session(step, "complete", "stale");
    const ns = nextStep(cfg, done);
    check(`${step} off + stale record: next-step does not wait for plan approval`,
      !/^awaiting-plan-approval/.test(ns.REASON || ""), ns._d);
    const cur = session(step, "pending", "stale");
    const g = nextStep(cfg, cur, ["--gate"]);
    check(`${step} off + stale record: next-step --gate proceeds`, g.GATE_ACTION === "proceed", g._d);
    const e = R.echo(cur, STAGE_OF[step], { cfg });
    check(`${step} off + stale record: confirm-checkpoint emits [confirm-skipped`, e.skipped, show({ rc: e.rc, json: e.json }));
  }
}

function modeOnNone() {
  for (const step of ["clarify_intent", "outline", "detail"]) {
    const cfg = R.cfg();
    const cur = session(step, "pending", "none");
    const v = inproc(cfg, cur, step);
    check(`${step} on + no record: evaluateCompletionApproval unapproved`, v.eval.approved === false, show(v.eval));
    check(`${step} on + no record: checkPlanApproval unapproved, gate ON, not waived`,
      v.check.verdict === "unapproved" && v.check.gate === "ON" && v.check.waived !== true, show(v.check));
    const done = session(step, "complete", "none");
    const ns = nextStep(cfg, done);
    check(`${step} on + no record: next-step waits for plan approval`,
      ns.REASON === "awaiting-plan-approval: " + step && (ns.NEXT_HINT || "").includes(SENT[step]), ns._d);
    const g = nextStep(cfg, cur, ["--gate"]);
    check(`${step} on + no record: next-step --gate asks`, g.GATE_ACTION === "ask", g._d);
    const e = R.echo(cur, STAGE_OF[step], { cfg });
    check(`${step} on + no record: confirm-checkpoint goes to the judge (not skipped)`, e.rc === 0 && !e.skipped, show({ rc: e.rc, json: e.json }));
  }
}

function modeIntent() {
  const cfg = offCfg("clarify_intent");
  for (const status of ["complete", "pending"]) {
    const sid = session("clarify_intent", status, "stale");
    const v = inproc(cfg, sid, "clarify_intent");
    check(`intent off + stale record (${status}): evaluateCompletionApproval stays unapproved`,
      v.eval.approved === false && v.eval.source !== "confirm-flag-off", show(v.eval));
    check(`intent off + stale record (${status}): checkPlanApproval unapproved, gate ON (no off waiver)`,
      v.check.verdict === "unapproved" && v.check.gate === "ON" && v.check.waived !== true, show(v.check));
  }
  const done = session("clarify_intent", "complete", "stale");
  const ns = nextStep(cfg, done);
  check("intent off + stale record: next-step still waits for intent approval",
    ns.REASON === "awaiting-plan-approval: clarify_intent", ns._d);
  const cur = session("clarify_intent", "pending", "stale");
  const g = nextStep(cfg, cur, ["--gate"]);
  check("intent off + stale record: next-step --gate asks", g.GATE_ACTION === "ask", g._d);
  const e = R.echo(cur, "intent", { cfg });
  check("intent off + stale record: confirm-checkpoint goes to the judge (not skipped)", e.rc === 0 && !e.skipped, show({ rc: e.rc, json: e.json }));
  // Positive path: the judge is reachable, not a dead end. The intent presentation turn makes the
  // Stop hook write the receipt; the echo then reaches the dialog and spends the receipt.
  const pos = session("clarify_intent", "pending", "stale");
  const lines = R.linesFor(pos, "intent");
  const tp = R.presentTurn({ sid: pos }, ["intent"], "Here is the intent.\n\n" + lines.urlLine);
  const st = R.stop(pos, tp, { cfg });
  check("intent off + stale record: the presentation turn makes Stop continue and write the receipt",
    st.continued && R.receiptExists(pos, "intent"), show({ rc: st.rc, out: st.out, receipt: R.readReceiptRaw(pos, "intent") }));
  const ep = R.echo(pos, "intent", { cfg, transcriptPath: tp });
  check("intent off + stale record: after the presentation the echo reaches the dialog", ep.dialog, show({ rc: ep.rc, json: ep.json }));
  check("intent off + stale record: the passing echo spends the intent receipt", !R.receiptExists(pos, "intent"), show(R.readReceiptRaw(pos, "intent")));
}

const MODES = { "off-stale": modeOffStale, "on-none": modeOnNone, intent: modeIntent };
const mode = process.argv[2];
if (!MODES[mode]) { console.log(`FAIL|driver|unknown mode ${mode}`); process.exit(0); }
MODES[mode]();
