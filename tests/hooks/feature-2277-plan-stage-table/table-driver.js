"use strict";
// #2277 driver: the plan-stage table (rows, reverse lookups, steps.js agreement), the
// completion matrix (3 stages x approved / no record / stale approval, via --advance and
// the clarify-intent completion sentinel), the intent `## Issues` digest exclusion, and
// the per-stage off waiver. Modes: table | complete | digest | off.

const path = require("path");
const F = require("../feature-2277-plan-approval-gate/fixture");

const STEPS = ["clarify_intent", "outline", "detail"];
const ROWS = {
  clarify_intent: { suffix: "intent", sentinel: "WORKFLOW_CONFIRM_INTENT", confirmFlag: "CONFIRM_INTENT",
    offWaivable: false, nextSkill: "make-outline-plan", digestExcludes: ["Issues"] },
  outline: { suffix: "outline", sentinel: "WORKFLOW_CONFIRM_OUTLINE", confirmFlag: "CONFIRM_OUTLINE",
    offWaivable: true, nextSkill: "make-detail-plan", digestExcludes: [] },
  detail: { suffix: "detail", sentinel: "WORKFLOW_CONFIRM_DETAIL", confirmFlag: "CONFIRM_DETAIL",
    offWaivable: true, nextSkill: "write-tests", digestExcludes: [] },
};
const NEXT_STEP = "bin/workflow/next-step";
const MARK = "hooks/workflow-mark.js";

function loadTable() {
  try { return require(path.join(F.ROOT, "hooks/workflow-state/plan-stage-table.js")); } catch (e) {
    F.check("plan-stage-table module loads", false, e.code || e.message);
    return null;
  }
}

// The table is whichever exported plain object is keyed by exactly the 3 gated steps.
function findTable(mod) {
  for (const v of Object.values(mod)) {
    if (v && typeof v === "object" && !Array.isArray(v) &&
        Object.keys(v).sort().join(",") === STEPS.slice().sort().join(",")) return v;
  }
  return null;
}

function modeTable() {
  const CA = require(path.join(F.ROOT, "hooks/workflow-state/completion-approval.js"));
  F.check("APPROVAL_GATED_STEPS is exactly the 3 stages",
    JSON.stringify(CA.APPROVAL_GATED_STEPS) === JSON.stringify(STEPS), JSON.stringify(CA.APPROVAL_GATED_STEPS));
  const mod = loadTable();
  if (!mod) return;
  const table = findTable(mod);
  F.check("an exported table is keyed by exactly the 3 gated steps", !!table, Object.keys(mod).join(","));
  for (const step of STEPS) {
    const row = table && table[step];
    for (const [k, v] of Object.entries(ROWS[step])) {
      F.check(`row ${step}.${k}`, row && JSON.stringify(row[k]) === JSON.stringify(v), JSON.stringify(row && row[k]));
    }
  }
  const { STEP_TO_SKILL } = require(path.join(F.ROOT, "bin/workflow/lib/next-step/steps.js"));
  const after = { clarify_intent: "outline", outline: "detail", detail: "write_tests" };
  for (const step of STEPS) {
    const row = table && table[step];
    F.check(`${step}.nextSkill agrees with steps.js STEP_TO_SKILL.${after[step]}`,
      row && row.nextSkill === STEP_TO_SKILL[after[step]], `${row && row.nextSkill} vs ${STEP_TO_SKILL[after[step]]}`);
  }
  const suffixCases = [["intent", "clarify_intent"], ["outline", "outline"], ["detail", "detail"],
    ["tests", null], ["", null], ["clarify_intent", null]];
  for (const [input, want] of suffixCases) {
    let got;
    try { got = mod.stepForSuffix(input); } catch (e) { got = "THREW:" + e.message; }
    F.check(`stepForSuffix(${JSON.stringify(input)})`, want === null ? !got : got === want, String(got));
  }
  const skillCases = [["make-outline-plan", "clarify_intent"], ["agents:make-outline-plan", "clarify_intent"],
    ["make-detail-plan", "outline"], ["agents:make-detail-plan", "outline"], ["write-tests", "detail"],
    ["agents:write-tests", "detail"], ["run-tests", null], ["clarify-intent", null], ["", null]];
  for (const [input, want] of skillCases) {
    let got;
    try { got = mod.priorStepForSkill(input); } catch (e) { got = "THREW:" + e.message; }
    F.check(`priorStepForSkill(${JSON.stringify(input)})`, want === null ? !got : got === want, String(got));
  }
}

// Seeds a session sitting at `step` with every earlier gated stage approved.
function atStage(step, tag) {
  const sid = F.newSid(tag);
  const steps = { workflow_init: "complete", clarify_intent: "pending" };
  const approvals = [];
  F.writePlan(sid, "intent");
  if (step !== "clarify_intent") {
    Object.assign(steps, { clarify_intent: "complete", research: "complete", outline: "pending" });
    approvals.push({ step: "clarify_intent" });
    F.writePlan(sid, "outline");
  }
  if (step === "detail") {
    Object.assign(steps, { outline: "complete", detail: "pending" });
    approvals.push({ step: "outline" });
    F.writePlan(sid, "detail");
  }
  F.writeState(sid, steps, approvals);
  return sid;
}

function mark(sid, command, env) {
  return F.runNode(MARK, [], JSON.stringify({ session_id: sid, tool_name: "Bash", tool_input: { command },
    tool_response: { exit_code: 0, stdout: "", stderr: "" } }), env);
}
function advance(sid, step, env) {
  return F.runNode(NEXT_STEP, ["--session", sid, "--advance", "--step", step, "--complete"], "", env);
}

function prepare(step, variant) {
  const sid = atStage(step, variant);
  const row = ROWS[step];
  if (variant === "approved" || variant === "stale") mark(sid, `echo "<<${row.sentinel}: approved in fixture>>"`);
  if (variant === "stale") F.writePlan(sid, row.suffix, F.PLAN_BODY[row.suffix].replace("fixture", "rewritten after approval"));
  return sid;
}

function judge(name, step, variant, r, sid) {
  const status = F.readStep(sid, step);
  const row = ROWS[step];
  if (variant === "approved") {
    F.check(`${name}: ${step} becomes complete`, status === "complete", `status=${status} exit=${r.code} ${r.err}`);
    return;
  }
  const text = r.out + r.err;
  F.check(`${name}: ${step} is NOT complete`, status !== "complete", `status=${status}`);
  F.check(`${name}: guidance names ${row.sentinel}`, text.includes(row.sentinel), text);
  if (!row.offWaivable) F.check(`${name}: guidance offers no ${row.confirmFlag}=off`, !text.includes(row.confirmFlag + "=off"), text);
}

function modeComplete() {
  for (const step of STEPS) {
    for (const variant of ["approved", "norecord", "stale"]) {
      let sid = prepare(step, variant);
      F.check(`advance ${step} ${variant}: precondition pending`, F.readStep(sid, step) === "pending", F.readStep(sid, step));
      const r = advance(sid, step);
      if (variant !== "approved") F.check(`advance ${step} ${variant}: exits non-zero`, r.code !== 0, `exit=${r.code}`);
      else F.check(`advance ${step} approved: exits 0`, r.code === 0, `exit=${r.code} ${r.err}`);
      judge(`advance ${step} ${variant}`, step, variant, r, sid);
      if (step !== "clarify_intent") continue;
      sid = prepare(step, variant);
      judge(`sentinel ${step} ${variant}`, step, variant, mark(sid, 'echo "<<WORKFLOW_CLARIFY_INTENT_COMPLETE>>"'), sid);
    }
  }
}

function verdictAfterEdit(step, edit) {
  const CA = require(path.join(F.ROOT, "hooks/workflow-state/completion-approval.js"));
  const WS = require(path.join(F.ROOT, "hooks/workflow-state"));
  const sid = F.newSid("digest");
  const suffix = ROWS[step].suffix;
  F.writePlan(sid, suffix);
  F.writeState(sid, { [step]: "pending" }, [{ step }]);
  const before = F.implSha(sid, step);
  F.writePlan(sid, suffix, edit(F.PLAN_BODY[suffix]));
  return { before, after: F.implSha(sid, step), v: CA.evaluateCompletionApproval(sid, step, WS.readState(sid)) };
}

function modeDigest() {
  const issuesOnly = (b) => b.replace("- #1 fixture\n", "- #1 fixture\n- #2 CREATED:2 backfilled\n");
  let r = verdictAfterEdit("clarify_intent", issuesOnly);
  F.check("intent sha is computable", typeof r.before === "string" && r.before.length === 64, String(r.before));
  F.check("intent: editing only ## Issues keeps the approval", r.v.approved === true && typeof r.before === "string" && r.before === r.after, JSON.stringify(r.v));
  r = verdictAfterEdit("clarify_intent", (b) => b.replace("fixture goal", "another goal"));
  F.check("intent: editing ## Goal breaks the hash", r.v.approved === false && r.v.code === "artifact-hash-mismatch", JSON.stringify(r.v));
  r = verdictAfterEdit("clarify_intent", (b) => b.replace("## Constraints\n\nnone", "## Constraints\n\nchanged"));
  F.check("intent: the section AFTER ## Issues is still hashed", r.v.approved === false && r.v.code === "artifact-hash-mismatch", JSON.stringify(r.v));
  for (const step of ["outline", "detail"]) {
    r = verdictAfterEdit(step, issuesOnly);
    F.check(`${step}: editing ## Issues breaks the hash (full-text digest)`,
      r.v.approved === false && r.v.code === "artifact-hash-mismatch", JSON.stringify(r.v));
  }
}

function modeOff() {
  const offRoot = F.configRoot("table-off", ["CONFIRM_INTENT=off", "CONFIRM_OUTLINE=off", "CONFIRM_DETAIL=off"]);
  const env = { AGENTS_MAIN_ROOT: offRoot };
  for (const step of STEPS) {
    const sid = prepare(step, "norecord");
    const r = advance(sid, step, env);
    const status = F.readStep(sid, step);
    if (ROWS[step].offWaivable) {
      F.check(`off: ${ROWS[step].confirmFlag}=off still waives ${step}`, r.code === 0 && status === "complete", `exit=${r.code} status=${status} ${r.err}`);
    } else {
      F.check(`off: CONFIRM_INTENT=off does NOT waive clarify_intent`, r.code !== 0 && status !== "complete", `exit=${r.code} status=${status}`);
    }
  }
  const sid = prepare("clarify_intent", "norecord");
  mark(sid, 'echo "<<WORKFLOW_CLARIFY_INTENT_COMPLETE>>"', env);
  F.check("off: the completion sentinel with CONFIRM_INTENT=off leaves clarify_intent pending",
    F.readStep(sid, "clarify_intent") !== "complete", F.readStep(sid, "clarify_intent"));
}

// A STORED confirm-flag-off record only proves a waiver for offWaivable rows. Run with
// AGENTS_MAIN_ROOT pointing at a CONFIRM_INTENT=off config root for the "pinned" variant.
function modeStoredOff() {
  const CA = require(path.join(F.ROOT, "hooks/workflow-state/completion-approval.js"));
  const WS = require(path.join(F.ROOT, "hooks/workflow-state"));
  const pinned = process.argv[3] === "pinned";
  const verdict = (step) => {
    const sid = F.newSid("storedoff");
    F.writePlan(sid, ROWS[step].suffix);
    F.writeState(sid, { [step]: "pending" }, [{ step, source: "confirm-flag-off" }]);
    return CA.evaluateCompletionApproval(sid, step, WS.readState(sid));
  };
  const tag = pinned ? "CONFIRM_INTENT=off pinned, " : "";
  const v = verdict("clarify_intent");
  F.check(`stored-off: ${tag}clarify_intent record is rejected as no-approval-record`,
    v.approved === false && v.code === "no-approval-record", JSON.stringify(v));
  if (pinned) return;
  for (const step of ["outline", "detail"]) {
    const w = verdict(step);
    F.check(`stored-off: ${step} record still approves (HASH_EXEMPT)`, w.approved === true, JSON.stringify(w));
  }
}

const mode = process.argv[2];
const MODES = { table: modeTable, complete: modeComplete, digest: modeDigest, off: modeOff, storedoff: modeStoredOff };
if (!MODES[mode]) { console.log(`FAIL|driver|unknown mode ${mode}`); process.exit(0); }
MODES[mode]();
