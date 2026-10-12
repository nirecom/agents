"use strict";
// #2277 driver: checkPlanApproval's 5 verdicts, the check-plan-approval CLI, the
// PreToolUse Skill gate, and its settings.json registration. Modes: check | cli | gate |
// settings. Prints PASS|name / FAIL|name|detail lines for the bash dispatcher.

const fs = require("fs");
const path = require("path");
const F = require("./fixture");

const STEPS = ["clarify_intent", "outline", "detail"];
const CLI = "bin/workflow/check-plan-approval";
const GATE = "hooks/gate-plan-skill-advance.js";

// One session per (step, verdict-scenario). Returns the sid.
function scenario(step, kind) {
  const sid = F.newSid(kind);
  const suffix = F.SUFFIX[step];
  if (kind === "missing") return sid; // no state file at all
  F.writePlan(sid, suffix);
  if (kind === "corrupt") { F.writeCorrupt(sid); return sid; }
  if (kind === "approved") F.writeState(sid, { [step]: "pending" }, [{ step }]);
  else if (kind === "norecord") F.writeState(sid, { [step]: "pending" }, []);
  else if (kind === "edited") {
    F.writeState(sid, { [step]: "pending" }, [{ step }]);
    F.writePlan(sid, suffix, F.PLAN_BODY[suffix].replace("fixture", "edited after approval"));
  } else if (kind === "skipped") F.writeState(sid, { [step]: "skipped" }, []);
  return sid;
}

const EXPECT = {
  approved: "approved", norecord: "unapproved", edited: "unapproved",
  skipped: "skipped", missing: "not-applicable", corrupt: "unknown",
};

function modeCheck() {
  let mod;
  try {
    mod = require(path.join(F.ROOT, "hooks/workflow-state/plan-approval-check.js"));
  } catch (e) {
    F.check("plan-approval-check module loads", false, e.code || e.message);
    return;
  }
  F.check("checkPlanApproval is exported", typeof mod.checkPlanApproval === "function", Object.keys(mod).join(","));
  if (typeof mod.checkPlanApproval !== "function") return;
  for (const step of STEPS) {
    for (const kind of Object.keys(EXPECT)) {
      const sid = scenario(step, kind);
      let r;
      try { r = mod.checkPlanApproval(sid, step); } catch (e) { r = { threw: e.message }; }
      const got = r && r.verdict;
      F.check(`${step} ${kind} -> ${EXPECT[kind]}`, got === EXPECT[kind], JSON.stringify(r));
      if (kind === "norecord") {
        F.check(`${step} norecord code`, r && r.code === "no-approval-record", JSON.stringify(r));
      }
      if (kind === "edited") {
        F.check(`${step} edited code`, r && r.code === "artifact-hash-mismatch", JSON.stringify(r));
      }
    }
  }
}

function cliVerdict(sid, step, extraEnv) {
  const r = F.runNode(CLI, ["--session", sid, "--step", step], "", extraEnv);
  const lines = r.out.split(/\r?\n/).filter((l) => l.length > 0);
  return { r, lines };
}

function modeCli() {
  for (const step of STEPS) {
    for (const kind of Object.keys(EXPECT)) {
      const sid = scenario(step, kind);
      const { r, lines } = cliVerdict(sid, step);
      const want = "APPROVAL=" + EXPECT[kind];
      F.check(`cli ${step} ${kind} prints ${want}`, lines.length === 1 && lines[0] === want,
        `exit=${r.code} out=${r.out} err=${r.err}`);
      F.check(`cli ${step} ${kind} exits 0`, r.code === 0, `exit=${r.code} err=${r.err}`);
    }
  }
  // Off waiver: read from the config FILE only. outline/detail waive; intent never does.
  const offRoot = F.configRoot("all-off", ["CONFIRM_INTENT=off", "CONFIRM_OUTLINE=off", "CONFIRM_DETAIL=off"]);
  const want = { clarify_intent: "APPROVAL=unapproved", outline: "APPROVAL=approved", detail: "APPROVAL=approved" };
  for (const step of STEPS) {
    const sid = scenario(step, "norecord");
    const { r, lines } = cliVerdict(sid, step, { AGENTS_MAIN_ROOT: offRoot });
    F.check(`cli ${step} CONFIRM off in config -> ${want[step]}`, lines[0] === want[step] && r.code === 0,
      `exit=${r.code} out=${r.out} err=${r.err}`);
  }
}

// Skill gate. A pass-through must be a REAL run: exit 0, no module error, no deny.
function runGate(skill, sid) {
  const input = JSON.stringify({
    hook_event_name: "PreToolUse", tool_name: "Skill", tool_input: { skill }, session_id: sid,
  });
  return F.runNode(GATE, [], input);
}

function ranCleanly(r) {
  return r.code === 0 && !/Cannot find module|MODULE_NOT_FOUND/.test(r.err);
}

function expectPass(name, r) {
  F.check(name + " runs cleanly", ranCleanly(r), `exit=${r.code} err=${r.err}`);
  F.check(name + " passes through (no deny)", ranCleanly(r) && !/"deny"|"block"/.test(r.out), r.out);
  F.check(name + " never emits allow", !/"allow"/.test(r.out), r.out);
}

function expectDeny(name, r, step, sid) {
  let j = null;
  try { j = JSON.parse(r.out.trim()); } catch (_) { j = null; }
  const hso = (j && j.hookSpecificOutput) || {};
  F.check(name + " exits 0", r.code === 0, `exit=${r.code} err=${r.err}`);
  F.check(name + " denies like block-capture-echo",
    j && j.decision === "block" && hso.hookEventName === "PreToolUse" &&
      hso.permissionDecision === "deny" && typeof j.reason === "string" &&
      hso.permissionDecisionReason === j.reason, r.out || r.err);
  const reason = (j && j.reason) || "";
  const confirm = "CONFIRM_" + F.SUFFIX[step].toUpperCase();
  F.check(name + " reason names " + confirm, reason.includes(confirm), reason);
  const plansFwd = F.PLANS_DIR.replace(/\\/g, "/");
  const leaks = /https?:\/\//.test(reason) || reason.replace(/\\/g, "/").includes(plansFwd) ||
    reason.includes(sid) || /\.md\b/.test(reason);
  F.check(name + " reason has no URL / plan path / sid", !leaks, reason);
  F.check(name + " never emits allow", !/"allow"/.test(r.out), r.out);
}

const SKILL_PRIOR = { "make-outline-plan": "clarify_intent", "make-detail-plan": "outline", "write-tests": "detail" };

function modeGate() {
  for (const [skill, prior] of Object.entries(SKILL_PRIOR)) {
    expectPass(`${skill} prior approved`, runGate(skill, scenario(prior, "approved")));
    let sid = scenario(prior, "norecord");
    expectDeny(`${skill} prior no record`, runGate(skill, sid), prior, sid);
    sid = scenario(prior, "edited");
    expectDeny(`${skill} prior hash mismatch`, runGate(skill, sid), prior, sid);
    sid = scenario(prior, "norecord");
    expectDeny(`agents:${skill} prior no record`, runGate("agents:" + skill, sid), prior, sid);
    expectPass(`${skill} prior skipped`, runGate(skill, scenario(prior, "skipped")));
    expectPass(`${skill} no state file (not-applicable)`, runGate(skill, scenario(prior, "missing")));
    expectPass(`${skill} corrupt state (unknown)`, runGate(skill, scenario(prior, "corrupt")));
  }
  // An unrelated skill is never gated, even with every gated stage unapproved.
  const sid = F.newSid("unrelated");
  F.writePlan(sid, "intent"); F.writePlan(sid, "outline"); F.writePlan(sid, "detail");
  F.writeState(sid, { clarify_intent: "pending", outline: "pending", detail: "pending" }, []);
  expectPass("run-tests (unmapped skill)", runGate("run-tests", sid));
  // Non-Skill tool input is ignored.
  const r = F.runNode(GATE, [], JSON.stringify({ tool_name: "Bash", tool_input: { command: "true" }, session_id: sid }));
  expectPass("non-Skill tool", r);
}

function modeSettings() {
  let settings;
  try { settings = JSON.parse(fs.readFileSync(path.join(F.ROOT, "settings.json"), "utf8")); } catch (e) {
    F.check("settings.json parses", false, e.message); return;
  }
  const pre = (settings.hooks && settings.hooks.PreToolUse) || [];
  const hit = pre.filter((e) => e && e.matcher === "Skill").flatMap((e) => e.hooks || [])
    .filter((h) => typeof h.command === "string" && h.command.includes("hooks/gate-plan-skill-advance.js"));
  F.check("PreToolUse matcher Skill registers gate-plan-skill-advance.js", hit.length === 1, JSON.stringify(hit));
  F.check("gate-plan-skill-advance.js timeout is 10", hit.length === 1 && hit[0].timeout === 10, JSON.stringify(hit));
  // The root prefix and the hook path are asserted apart so this file never spells the
  // agents root joined to a code directory (check-root-names structural rule).
  F.check("registered via $AGENTS_MAIN_ROOT",
    hit.length === 1 && hit[0].command.startsWith('node "$AGENTS_MAIN_ROOT/')
      && hit[0].command.endsWith('/gate-plan-skill-advance.js"'),
    JSON.stringify(hit));
}

const mode = process.argv[2];
const MODES = { check: modeCheck, cli: modeCli, gate: modeGate, settings: modeSettings };
if (!MODES[mode]) { console.log(`FAIL|driver|unknown mode ${mode}`); process.exit(0); }
MODES[mode]();
