"use strict";
// tests/lib/plan-approval-fixture.js
// Since #2277 a gated `complete` (clarify_intent / outline / detail) counts only with a valid
// plan-approval record and there is no migration, so fixtures carry one built by the real
// computeArtifactSha / recordPlanApproval. The plan artifact is written into the pinned
// WORKFLOW_PLANS_DIR only when absent.
// CLI: approve <sid> <step...> (live, real writer) | inject <state-file> <step...> (raw v1/v2 file)
//      | inject-complete <state-file> <step...> (only steps recorded complete and unapproved)
//      | plan <sid> <step...> (artifact only). Prints "ok", or one "ERR:<reason>" line + exit 1.
const fs = require("fs");
const path = require("path");

const ROOT = path.resolve(__dirname, "..", "..");
const CA = () => require(path.join(ROOT, "hooks/workflow-state/completion-approval.js"));
const TABLE = () => require(path.join(ROOT, "hooks/workflow-state/plan-stage-table.js"));

function plansDir() {
  const d = process.env.WORKFLOW_PLANS_DIR;
  if (!d) throw new Error("WORKFLOW_PLANS_DIR must be pinned");
  return d;
}

// ensurePlan(sid, step) -> absolute artifact path; writes a minimal body only when absent.
function ensurePlan(sid, step) {
  const row = TABLE().rowFor(step);
  if (!row) throw new Error("not an approval-gated step: " + step);
  fs.mkdirSync(plansDir(), { recursive: true });
  const p = path.join(plansDir(), `${sid}-${row.suffix}.md`);
  if (!fs.existsSync(p)) fs.writeFileSync(p, `# ${row.suffix} fixture\n\n## Body\n\nfixture ${sid}\n`);
  return p;
}

function shaFor(sid, step) {
  ensurePlan(sid, step);
  const sha = CA().computeArtifactSha(sid, step);
  if (!sha) throw new Error(`computeArtifactSha(${sid}, ${step}) returned null`);
  return sha;
}

// Same fields confirm-approval-handler.js records for a confirm-sentinel approval.
function approvalFields(sid, step) {
  const sha = shaFor(sid, step);
  return {
    source: "confirm-sentinel", reason: "fixture approval", artifact_sha256: sha,
    artifact_session_id: sid, artifact_hash_status: "recorded",
  };
}

// approveLive(sid, step): appends the approval through the real writer.
function approveLive(sid, step) {
  const sha = shaFor(sid, step);
  CA().recordPlanApproval(sid, step, {
    source: "confirm-sentinel", reason: "fixture approval",
    artifactSha: sha, artifactHashStatus: "recorded",
  });
}

// injectInto(stateObj, sid, step): v2 (events[]) gets a plan_approval event; v1 gets a
// plan_approvals map entry (migrated by v1-to-v2 like any legacy record). Mutates and returns.
function injectInto(state, sid, step) {
  const f = approvalFields(sid, step);
  if (Array.isArray(state.events)) {
    const seq = state.events.reduce((m, e) => Math.max(m, Number(e.seq) || 0), 0) + 1;
    const at = (state.events[state.events.length - 1] || {}).at || new Date().toISOString();
    state.events.push(Object.assign({ kind: "plan_approval", step }, f,
      { at, seq, provenance: "declared", origin: "test-fixture" }));
  } else {
    state.plan_approvals = Object.assign({}, state.plan_approvals,
      { [step]: Object.assign({}, f, { recorded_at: state.created_at || new Date().toISOString() }) });
  }
  return state;
}

// Raw status / approval presence of a state file as written (v1 maps or v2 events).
function rawStatus(state, step) {
  if (Array.isArray(state.events)) {
    const hit = state.events.filter((e) => e.kind === "step_status" && e.step === step).pop();
    return hit ? hit.status : "pending";
  }
  return ((state.steps || {})[step] || {}).status || "pending";
}
function rawHasApproval(state, step) {
  if (Array.isArray(state.events)) return state.events.some((e) => e.kind === "plan_approval" && e.step === step);
  return !!(state.plan_approvals && state.plan_approvals[step]);
}

// injectFile(file, steps, onlyUnapprovedComplete): onlyUnapprovedComplete skips a step that is not
// recorded complete or already carries an approval, so a case's own approval is never overridden.
function injectFile(file, steps, onlyUnapprovedComplete) {
  const state = JSON.parse(fs.readFileSync(file, "utf8"));
  const sid = state.session_id && state.session_id !== "gen"
    ? state.session_id : path.basename(file).replace(/\.json$/, "");
  for (const step of steps) {
    if (onlyUnapprovedComplete && (rawStatus(state, step) !== "complete" || rawHasApproval(state, step))) continue;
    injectInto(state, sid, step);
  }
  fs.writeFileSync(file, JSON.stringify(state, null, 2));
}

module.exports = { ensurePlan, approvalFields, approveLive, injectInto, injectFile };

if (require.main === module) {
  const [mode, target, ...steps] = process.argv.slice(2);
  try {
    if (!target || steps.length === 0) throw new Error("usage: <approve|inject|plan> <sid|state-file> <step...>");
    if (mode === "approve") for (const s of steps) approveLive(target, s);
    else if (mode === "inject") injectFile(target, steps, false);
    else if (mode === "inject-complete") injectFile(target, steps, true);
    else if (mode === "plan") for (const s of steps) ensurePlan(target, s);
    else throw new Error("unknown mode " + mode);
    process.stdout.write("ok");
  } catch (e) {
    process.stdout.write("ERR:" + String((e && e.message) || e).split("\n")[0]);
    process.exit(1);
  }
}
