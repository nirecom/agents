"use strict";
// #2729 Gap 3 driver: CONFIRM_DETAIL=off in $AGENTS_MAIN_ROOT/.env, current step detail, run end
// to end through the real CLI and hooks: next-step --gate, show-plan-link after the detail Write,
// the Stop guard with the link mid-summary, and next-step --advance --step detail --complete.
// Modes: off-none | off-stale (approval record absent / stale hash) | export-only.
const path = require("path");
const { spawnSync } = require("child_process");

const R = require("../../hooks/feature-2729-presentation-receipt/fixture");
const { F, check, show } = R;
const WS = require(path.join(R.ROOT, "hooks/workflow-state"));

const ORDER = ["workflow_init", "clarify_intent", "research", "outline", "detail"];
const STAGE_OF = { clarify_intent: "intent", outline: "outline", detail: "detail" };

// session(record) -> sid at detail (pending), earlier gated steps approved; detail's own approval
// absent ("none") or a stale confirm-sentinel hash ("stale").
function session(record) {
  const sid = R.uuidSid(2729);
  const steps = {};
  const approvals = [];
  ORDER.forEach((s) => { steps[s] = s === "detail" ? "pending" : "complete"; });
  for (const s of ORDER) {
    if (!STAGE_OF[s]) continue;
    F.writePlan(sid, STAGE_OF[s]);
    if (s !== "detail") approvals.push({ step: s });
  }
  if (record === "stale") approvals.push({ step: "detail", sha: "stale" });
  F.writeState(sid, steps, approvals, { closes_issues: [1] });
  return sid;
}

function kv(out) {
  const o = {};
  for (const line of String(out).split(/\r?\n/)) {
    const m = line.match(/^([A-Z_]+)=(.*)$/);
    if (m) o[m[1]] = m[2].replace(/^'(.*)'$/, "$1").replace(/^"(.*)"$/, "$1");
  }
  return o;
}

// nextStep(cfgDir, sid, args, exported) -> parsed KEY=VAL + {_rc, _d}. Spawned with childEnvWith
// alone (never merged with this process's env), plus `exported` as real exports.
function nextStep(cfgDir, sid, args, exported) {
  const env = Object.assign(R.CE.childEnvWith(cfgDir), exported || {});
  delete env.CLAUDE_CODE_SESSION_ID;
  const r = spawnSync(process.execPath, [path.join(R.ROOT, "bin/workflow/next-step")].concat(args || [], ["--session", sid]), {
    input: "", env, encoding: "utf8", timeout: 60000,
  });
  return Object.assign(kv(r.stdout || ""), { _rc: r.status, _d: `exit=${r.status} out=${r.stdout} err=${r.stderr}` });
}

// showPlanLink(cfgDir, sid, abs) -> parsed PostToolUse output of the detail Write.
function showPlanLink(cfgDir, sid, abs) {
  const input = { tool_name: "Write", tool_input: { file_path: abs }, tool_response: { success: true }, session_id: sid, hook_event_name: "PostToolUse" };
  const r = spawnSync(process.execPath, [path.join(R.ROOT, "hooks/show-plan-link.js")], {
    input: JSON.stringify(input), env: R.envFor({ cfg: cfgDir }), encoding: "utf8", timeout: 60000, cwd: R.TDIR,
  });
  let json = {};
  try { json = JSON.parse(r.stdout || "{}"); } catch (_) { json = { unparsed: r.stdout }; }
  const ctx = (json.hookSpecificOutput && json.hookSpecificOutput.additionalContext) || "";
  return { rc: r.status, ctx, json };
}

// The detail Write turn whose summary carries the link mid-text and ends in prose.
function summaryTurn(sid, l) {
  const closing = `Detail plan written. Summary of the steps:\n\n- step 1\n- step 2\n\n${l.urlLine}\n\nCONFIRM_DETAIL is off, so I continue to the tests next.`;
  return R.writeTranscript(sid, [
    R.U("write the detail plan", `u-prompt-${sid.slice(0, 8)}`),
    R.A("a-w1", R.W(l.plan, "w1")), R.TR("w1", "u-tr1"),
    R.A("a-anchor", R.T(closing)),
  ]);
}

function offPath(record) {
  const cfg = R.cfg({ CONFIRM_DETAIL: "off" });
  const sid = session(record);
  const l = R.linesFor(sid, "detail");
  const tag = `.env CONFIRM_DETAIL=off, ${record} record`;

  const g = nextStep(cfg, sid, ["--gate"]);
  check(`${tag}: 1. next-step --gate proceeds`, g.GATE_ACTION === "proceed", g._d);

  const sp = showPlanLink(cfg, sid, l.plan);
  check(`${tag}: 2. show-plan-link names the detail plan`, sp.ctx.includes("detail:"), show(sp.json));
  check(`${tag}: 2. show-plan-link gives the OFF wording (no end-of-turn duty)`,
    !/End this turn's last text block/.test(sp.ctx) && /summary/i.test(sp.ctx), sp.ctx);

  const st = R.stop(sid, summaryTurn(sid, l), { cfg });
  check(`${tag}: 3. Stop with the link mid-summary does not block`, st.rc === 0 && !st.blocked, show({ rc: st.rc, out: st.out, err: st.err }));
  check(`${tag}: 3. Stop writes no presentation receipt`, !R.receiptExists(sid, "detail"), show(R.readReceiptRaw(sid, "detail")));

  const adv = nextStep(cfg, sid, ["--advance", "--step", "detail", "--complete"]);
  const state = WS.readState(sid) || {};
  const status = state.steps && state.steps.detail && (state.steps.detail.status || state.steps.detail);
  check(`${tag}: 4. --advance --step detail --complete passes without waiting for approval`,
    adv._rc === 0 && !/awaiting-plan-approval/.test(adv._d) && status === "complete", `status=${show(status)} ${adv._d}`);
}

function exportOnly() {
  const sid = session("none");
  const g = nextStep(R.cfg(), sid, ["--gate"], { CONFIRM_DETAIL: "off" });
  check("export CONFIRM_DETAIL=off with .env on: next-step --gate asks", g.GATE_ACTION === "ask", g._d);
}

const MODES = { "off-none": () => offPath("none"), "off-stale": () => offPath("stale"), "export-only": exportOnly };
const mode = process.argv[2];
if (!MODES[mode]) { console.log(`FAIL|driver|unknown mode ${mode}`); process.exit(0); }
MODES[mode]();
