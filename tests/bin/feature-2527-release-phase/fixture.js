"use strict";
// Fixture writer for the feature-2527-release-phase suite (not a test): node fixture.js '<spec-json>'.
// Writes <WORKFLOW_STATE_DIR>/<sid>.json as an event-stream state file. Spec keys:
//   sid, version (5), dtype (wf-code), path (pull_request|direct|null), upto (step: every
//   earlier step complete), steps ("a=status;b=status" appended), uvReset, annotate
//   ("step.key=value;..." step_annotation events), entered, lastPushed, cwd, branch,
//   autoMerge ("on"|"off": the AUTO_MERGE_PR value fixed at branching_complete). version 4 writes
//   workflow_type and never names push_branch / merge_to_main.

const fs = require("fs");
const path = require("path");

const spec = JSON.parse(process.argv[2] || "{}");
if (!spec.sid) {
  process.stderr.write("fixture.js: spec.sid is required\n");
  process.exit(2);
}
const version = spec.version === undefined ? 5 : spec.version;
const ORDER_V5 = [
  "workflow_init", "clarify_intent", "research", "outline", "detail", "branching_complete",
  "write_tests", "review_tests", "write_code", "run_tests", "review_security", "docs",
  "review_docs", "push_branch", "user_verification", "merge_to_main", "cleanup",
  "pre_final_report_gate", "final_report",
];
const V5_ONLY = ["push_branch", "merge_to_main"];
const order = version >= 5 ? ORDER_V5 : ORDER_V5.filter((s) => !V5_ONLY.includes(s));
// On the direct path the table skips push_branch and cleanup, so nothing records them.
const tableSkipped = spec.path === "direct" ? ["push_branch", "cleanup"] : [];

const events = [];
let hour = 0;
const at = () => new Date(Date.UTC(2026, 0, 1, hour++)).toISOString();
const push = (ev) => {
  events.push(Object.assign({ seq: events.length + 1, at: at(), provenance: "observed", origin: "fixture-2527-rp" }, ev));
};

const pairs = [];
if (spec.upto) {
  const idx = order.indexOf(spec.upto);
  if (idx < 0) { process.stderr.write("fixture.js: unknown upto step\n"); process.exit(2); }
  for (const s of order.slice(0, idx)) if (!tableSkipped.includes(s)) pairs.push([s, "complete"]);
}
for (const p of String(spec.steps || "").split(";").filter(Boolean)) pairs.push(p.split("="));

let entered = false;
for (const [step, status] of pairs) {
  push({ kind: "step_status", step, status });
  if (spec.entered && !entered && step === "branching_complete") {
    push({ kind: "worktree", transition: "entered", git_branch: spec.branch || "feature/2527-rp",
      cwd: spec.cwd || null, worktree_path: spec.cwd || null, path_source: "tool_input" });
    entered = true;
  }
}
if (spec.uvReset) {
  push({ kind: "step_annotation", step: "user_verification", key: "reset_reason", value: spec.uvReset });
}
for (const a of String(spec.annotate || "").split(";").filter(Boolean)) {
  const [lhs, value] = a.split("=");
  const dot = lhs.indexOf(".");
  push({ kind: "step_annotation", step: lhs.slice(0, dot), key: lhs.slice(dot + 1), value });
}

const out = {
  version,
  session_id: spec.sid,
  created_at: "2026-01-01T00:00:00.000Z",
  session_start_context: { cwd: spec.cwd || null, git_branch: spec.branch || null },
};
if (version >= 5) {
  out.deliverable_type = spec.dtype || "wf-code";
  if (spec.path) {
    out.delivery_path = spec.path;
    out.delivery_path_origin = "branching-handler";
  }
  if (spec.autoMerge) {
    out.auto_merge_pr = spec.autoMerge;
    out.auto_merge_pr_origin = "branching-handler";
    out.auto_merge_pr_source = "config";
  }
} else {
  out.workflow_type = spec.dtype || "wf-code";
}
out.closes_issues = [2527];
out.last_pushed_sha = spec.lastPushed || null;
out.events = events;

const file = path.join(process.env.WORKFLOW_STATE_DIR, spec.sid + ".json");
fs.writeFileSync(file, JSON.stringify(out, null, 2));
// #2277: a gated complete counts only with a plan-approval record; approve the complete ones.
require("../../lib/plan-approval-fixture.js").injectFile(file, ["clarify_intent", "outline", "detail"], true);
