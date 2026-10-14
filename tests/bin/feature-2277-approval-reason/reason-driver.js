"use strict";
// #2277 recovery driver: an unapproved gated `complete` reads as pending in the effective
// state, the approval-aware current step, next-step's `awaiting-plan-approval:` reason that
// returns before the inconsistency scan, `--gate`, and approvalWaitFor itself.
// Modes: effective | current | nextstep | gate | reason. PASS|name / FAIL|name|detail lines.

const path = require("path");
const F = require("../../hooks/feature-2277-plan-approval-gate/fixture");

const NEXT_STEP = "bin/workflow/next-step";
const TOP = { closes_issues: [1] };

function load(rel) {
  try { return require(path.join(F.ROOT, rel)); } catch (e) {
    F.check(`${rel} loads`, false, e.code || e.message);
    return null;
  }
}

// A session that ran ahead: `upTo` and every earlier step recorded complete; each gated
// step approved unless named in `unapproved` ("none" = no record, "stale" = hash mismatch).
const ORDER = ["workflow_init", "clarify_intent", "research", "outline", "detail"];
function ranAhead(tag, upTo, unapproved) {
  const sid = F.newSid(tag);
  const steps = {};
  const approvals = [];
  const last = ORDER.indexOf(upTo);
  ORDER.forEach((s, i) => { steps[s] = i <= last ? "complete" : "pending"; });
  for (const [step, suffix] of Object.entries(F.SUFFIX)) {
    if (ORDER.indexOf(step) > last) continue;
    F.writePlan(sid, suffix);
    const how = (unapproved || {})[step];
    if (how === "none") continue;
    approvals.push({ step, sha: how === "stale" ? "stale" : "impl" });
  }
  F.writeState(sid, steps, approvals, TOP);
  return sid;
}

function readState(sid) { return load("hooks/workflow-state").readState(sid); }

function modeEffective() {
  const ES = load("hooks/workflow-state/effective-state.js");
  if (!ES) return;
  const snap = (sid) => {
    try { return ES.reconcileEffectiveState(readState(sid), sid, { repoDir: process.cwd() }).steps; } catch (e) {
      return { threw: e.message };
    }
  };
  const cases = [
    ["clarify_intent no record", ranAhead("eff-ci", "research", { clarify_intent: "none" }), "clarify_intent"],
    ["clarify_intent hash mismatch", ranAhead("eff-cis", "research", { clarify_intent: "stale" }), "clarify_intent"],
    ["outline no record", ranAhead("eff-ol", "outline", { outline: "none" }), "outline"],
    ["outline hash mismatch", ranAhead("eff-ols", "outline", { outline: "stale" }), "outline"],
    ["detail no record", ranAhead("eff-dt", "detail", { detail: "none" }), "detail"],
  ];
  for (const [name, sid, step] of cases) {
    const got = snap(sid)[step] || {};
    F.check(`effective: ${name} reads pending`, got.status === "pending", JSON.stringify(got));
    F.check(`effective: ${name} resolved_from unapproved-complete`, got.resolved_from === "unapproved-complete", JSON.stringify(got));
    F.check(`effective: ${name} leaves the record complete (read-only)`, F.readStep(sid, step) === "complete", F.readStep(sid, step));
  }
  const ok = ranAhead("eff-ok", "detail", {});
  for (const step of ["clarify_intent", "outline", "detail"]) {
    const got = snap(ok)[step] || {};
    F.check(`effective: approved ${step} stays complete from state`,
      got.status === "complete" && got.resolved_from === "state", JSON.stringify(got));
  }
  // Downstream records are NOT rolled back: re-approval resumes from the recorded position.
  const ahead = ranAhead("eff-down", "detail", { clarify_intent: "none" });
  const s = snap(ahead);
  F.check("effective: downstream outline/detail keep their recorded complete",
    (s.outline || {}).status === "complete" && (s.detail || {}).status === "complete", JSON.stringify(s));
  // Evidence alone (intent.md present, clarify_intent pending, no approval) resolves nothing.
  const ev = F.newSid("eff-ev");
  F.writePlan(ev, "intent");
  F.writeState(ev, { workflow_init: "complete", clarify_intent: "pending" }, [], TOP);
  const evs = snap(ev).clarify_intent || {};
  F.check("effective: intent.md evidence without approval does not resolve clarify_intent",
    evs.status !== "complete", JSON.stringify(evs));
}

function modeCurrent() {
  const CS = load("hooks/workflow-state/current-step.js");
  if (!CS) return;
  const want = [
    ["clarify_intent", ranAhead("cur-ci", "outline", { clarify_intent: "none" })],
    ["outline", ranAhead("cur-ol", "detail", { outline: "stale" })],
    ["detail", ranAhead("cur-dt", "detail", { detail: "none" })],
  ];
  for (const [step, sid] of want) {
    let got;
    try { got = CS.resolveCurrentStep(readState(sid), {}); } catch (e) { got = "THREW:" + e.message; }
    F.check(`resolveCurrentStep: first unapproved ${step}`, got === step, String(got));
    F.check(`resolveCurrentEffectiveStep: first unapproved ${step}`, CS.resolveCurrentEffectiveStep(sid) === step,
      String(CS.resolveCurrentEffectiveStep(sid)));
  }
  const ok = ranAhead("cur-ok", "detail", {});
  F.check("resolveCurrentStep: fully approved session moves past detail",
    CS.resolveCurrentEffectiveStep(ok) === "branching_complete", String(CS.resolveCurrentEffectiveStep(ok)));
}

function parse(out) {
  const kv = {};
  for (const line of out.split(/\r?\n/)) {
    const m = line.match(/^([A-Z_]+)=(.*)$/);
    // next-step quotes REASON with single quotes; --gate (gate-mode.js) uses double quotes.
    if (m) kv[m[1]] = m[2].replace(/^'(.*)'$/, "$1").replace(/^"(.*)"$/, "$1");
  }
  return kv;
}

function nextStep(sid, extra) {
  const r = F.runNode(NEXT_STEP, (extra || []).concat(["--session", sid]), "");
  return Object.assign(parse(r.out), { _r: r });
}

function expectAwaiting(name, sid, step, sentinel) {
  const kv = nextStep(sid);
  const detail = `exit=${kv._r.code} out=${kv._r.out} err=${kv._r.err}`;
  F.check(`${name}: ACTION=invoke (not abort)`, kv.ACTION === "invoke", detail);
  F.check(`${name}: REASON awaiting-plan-approval: ${step}`, kv.REASON === "awaiting-plan-approval: " + step, detail);
  F.check(`${name}: NEXT_HINT names ${sentinel}`, (kv.NEXT_HINT || "").includes(sentinel), detail);
}

function modeNextStep() {
  expectAwaiting("intent unapproved, research+outline complete",
    ranAhead("ns-ci", "outline", { clarify_intent: "none" }), "clarify_intent", "WORKFLOW_CONFIRM_INTENT");
  expectAwaiting("intent unapproved, ran ahead through detail",
    ranAhead("ns-ci2", "detail", { clarify_intent: "none" }), "clarify_intent", "WORKFLOW_CONFIRM_INTENT");
  expectAwaiting("outline hash mismatch, detail complete",
    ranAhead("ns-ol", "detail", { outline: "stale" }), "outline", "WORKFLOW_CONFIRM_OUTLINE");
  expectAwaiting("detail unapproved", ranAhead("ns-dt", "detail", { detail: "none" }), "detail", "WORKFLOW_CONFIRM_DETAIL");
  // Re-approval: the same layout with the approval on record resumes from the recorded position.
  const sid = ranAhead("ns-re", "outline", {});
  const kv = nextStep(sid);
  const detail = `exit=${kv._r.code} out=${kv._r.out}`;
  F.check("after approval: no awaiting-plan-approval reason", !/^awaiting-plan-approval/.test(kv.REASON || ""), detail);
  F.check("after approval: proceeds to make-detail-plan", kv.ACTION === "invoke" && kv.NEXT_SKILL === "make-detail-plan", detail);
}

function modeGate() {
  const cases = [
    ["clarify_intent", ranAhead("gt-ci", "outline", { clarify_intent: "none" })],
    ["outline", ranAhead("gt-ol", "detail", { outline: "stale" })],
  ];
  for (const [step, sid] of cases) {
    const kv = nextStep(sid, ["--gate"]);
    const detail = `exit=${kv._r.code} out=${kv._r.out} err=${kv._r.err}`;
    F.check(`--gate: unapproved ${step} is the gated step`, (kv.REASON || "").startsWith(step + ":"), detail);
    F.check(`--gate: unapproved ${step} asks`, kv.GATE_ACTION === "ask", detail);
  }
}

function modeReason() {
  const AR = load("bin/workflow/lib/next-step/approval-reason.js");
  if (!AR) return;
  F.check("approvalWaitFor is exported", typeof AR.approvalWaitFor === "function", Object.keys(AR).join(","));
  if (typeof AR.approvalWaitFor !== "function") return;
  const call = (sid, step) => {
    try { return AR.approvalWaitFor(sid, step, readState(sid)); } catch (e) { return { threw: e.message }; }
  };
  const SENT = { clarify_intent: "WORKFLOW_CONFIRM_INTENT", outline: "WORKFLOW_CONFIRM_OUTLINE", detail: "WORKFLOW_CONFIRM_DETAIL" };
  for (const step of Object.keys(SENT)) {
    const sid = ranAhead("ar-" + step.slice(0, 2), step === "clarify_intent" ? "research" : step, { [step]: "none" });
    const r = call(sid, step) || {};
    F.check(`approvalWaitFor ${step} unapproved: reason`, r.reason === "awaiting-plan-approval: " + step, JSON.stringify(r));
    F.check(`approvalWaitFor ${step} unapproved: hint names ${SENT[step]}`, typeof r.hint === "string" && r.hint.includes(SENT[step]), JSON.stringify(r));
    F.check(`approvalWaitFor ${step} unapproved: hint has no single quote`, typeof r.hint === "string" && !r.hint.includes("'"), String(r.hint));
  }
  const ok = ranAhead("ar-ok", "detail", {});
  F.check("approvalWaitFor: approved step -> no wait", !call(ok, "detail"), JSON.stringify(call(ok, "detail")));
  F.check("approvalWaitFor: non-gated step -> no wait", !call(ok, "write_tests"), JSON.stringify(call(ok, "write_tests")));
  const noEv = F.newSid("ar-noev");
  F.writeState(noEv, { workflow_init: "complete", clarify_intent: "pending" }, [], TOP);
  F.check("approvalWaitFor: no intent.md evidence -> no wait", !call(noEv, "clarify_intent"),
    JSON.stringify(call(noEv, "clarify_intent")));
}

// #2650: the hint carries no URL and no path of the session's plan, and names both ways the
// echo comes (the turn-end prompt, or the user's reply).
function modeHint() {
  const AR = load("bin/workflow/lib/next-step/approval-reason.js");
  if (!AR || typeof AR.approvalWaitFor !== "function") { F.check("approvalWaitFor is exported", false, "missing"); return; }
  for (const [step, suffix] of Object.entries(F.SUFFIX)) {
    const sid = ranAhead("ah-" + suffix.slice(0, 2), step === "clarify_intent" ? "research" : step, { [step]: "none" });
    const r = AR.approvalWaitFor(sid, step, readState(sid)) || {};
    const hint = typeof r.hint === "string" ? r.hint : null;
    const plan = path.resolve(F.planPath(sid, suffix));
    const plansDirs = [path.resolve(F.PLANS_DIR), path.resolve(F.PLANS_DIR).replace(/\\/g, "/")];
    F.check(`hint ${step}: present (precondition)`, hint !== null, JSON.stringify(r));
    if (hint === null) continue;
    F.check(`hint ${step}: no URL`, !/https?:\/\//.test(hint), hint);
    F.check(`hint ${step}: no plan path, plans dir, file name or sid`,
      !hint.includes(plan) && !hint.includes(plan.replace(/\\/g, "/")) && !plansDirs.some((d) => hint.includes(d)) &&
      !hint.includes(path.basename(plan)) && !hint.includes(sid), hint);
    F.check(`hint ${step}: the echo follows the turn-end prompt or the user's reply`,
      hint.includes("when the turn-end prompt asks for it") && hint.includes("after the user replies with approval"), hint);
  }
}

// #2650: completion-approval's recoveryFor names the same-turn prompt and the after-reply
// fallback, and carries no URL, no local path and no session id.
function modeRecovery() {
  const CA = load("hooks/workflow-state/completion-approval.js");
  if (!CA || typeof CA.recoveryFor !== "function") { F.check("recoveryFor is exported", false, "missing"); return; }
  for (const [step, suffix] of Object.entries(F.SUFFIX)) {
    const sid = ranAhead("rc-" + suffix.slice(0, 2), step === "clarify_intent" ? "research" : step, { [step]: "none" });
    const text = CA.recoveryFor(step);
    F.check(`recovery ${step}: is a string (precondition)`, typeof text === "string" && text.length > 0, String(text));
    if (typeof text !== "string") continue;
    F.check(`recovery ${step}: same-turn guidance`, text.includes("when the turn-end prompt asks for it"), text);
    F.check(`recovery ${step}: after-reply fallback`, text.includes("Otherwise emit it after the user replies with approval"), text);
    F.check(`recovery ${step}: no URL`, !/https?:\/\//.test(text), text);
    const plan = path.resolve(F.planPath(sid, suffix));
    const dirs = [path.resolve(F.PLANS_DIR), path.resolve(F.STATE_DIR)];
    const local = [plan, ...dirs].flatMap((p) => [p, p.replace(/\\/g, "/")]);
    F.check(`recovery ${step}: no local path`, !local.some((p) => text.includes(p)) && !text.includes(path.basename(plan)) &&
      !/[A-Za-z]:[\\/]|(^|\s)\/[A-Za-z]/.test(text), text);
    F.check(`recovery ${step}: no session id`, !text.includes(sid) &&
      !/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i.test(text), text);
  }
}

const mode = process.argv[2];
const MODES = { effective: modeEffective, current: modeCurrent, nextstep: modeNextStep, gate: modeGate, reason: modeReason, hint: modeHint, recovery: modeRecovery };
if (!MODES[mode]) { console.log(`FAIL|driver|unknown mode ${mode}`); process.exit(0); }
MODES[mode]();
