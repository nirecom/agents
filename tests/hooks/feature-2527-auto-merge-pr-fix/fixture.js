"use strict";
// Fixture writer for the #2527 stage-4 suites (not a test): node fixture.js '<spec-json>'.
// Writes <WORKFLOW_STATE_DIR>/<sid>.json as a v5 event-stream state file. Spec keys:
//   sid (required); cwd; path (pull_request|direct — omitted writes no delivery_path);
//   amp (auto_merge_pr value — omitted writes no auto_merge_pr fields, the pre-4-2 shape);
//   ampSource (auto_merge_pr_source: config|default|fallback, default config);
//   upto (a step: every earlier step is written complete); steps ("a=status;b=status");
//   annotate ("step.key=value;..." step_annotation events).
// The top-level names auto_merge_pr / auto_merge_pr_origin / auto_merge_pr_source are the
// state contract of plan 4-2 (projection.js allow-list); auto-merge-pr-fix.sh pins that the
// real branching writer emits exactly these, so a rename surfaces there first.

const fs = require("fs");
const path = require("path");

const spec = JSON.parse(process.argv[2] || "{}");
if (!spec.sid) {
  process.stderr.write("fixture.js: spec.sid is required\n");
  process.exit(2);
}

// Only the steps up to user_verification: no fixture here needs a later step, so the
// release-step rename never reaches these files.
const ORDER = [
  "workflow_init", "clarify_intent", "research", "outline", "detail", "branching_complete",
  "write_tests", "review_tests", "write_code", "run_tests", "review_security", "docs",
  "review_docs", "push_branch", "user_verification",
];
const tableSkipped = spec.path === "direct" ? ["push_branch"] : [];

const events = [];
let hour = 0;
const at = () => new Date(Date.UTC(2026, 0, 1, hour++)).toISOString();
const push = (ev) => {
  events.push(Object.assign({ seq: events.length + 1, at: at(), provenance: "observed", origin: "fixture-2527-amp" }, ev));
};

const pairs = [];
if (spec.upto) {
  const idx = ORDER.indexOf(spec.upto);
  if (idx < 0) {
    process.stderr.write("fixture.js: unknown upto step " + spec.upto + "\n");
    process.exit(2);
  }
  for (const s of ORDER.slice(0, idx)) if (!tableSkipped.includes(s)) pairs.push([s, "complete"]);
}
for (const p of String(spec.steps || "").split(";").filter(Boolean)) pairs.push(p.split("="));
for (const [step, status] of pairs) push({ kind: "step_status", step, status });

for (const a of String(spec.annotate || "").split(";").filter(Boolean)) {
  const eq = a.indexOf("=");
  const lhs = a.slice(0, eq);
  const dot = lhs.indexOf(".");
  push({ kind: "step_annotation", step: lhs.slice(0, dot), key: lhs.slice(dot + 1), value: a.slice(eq + 1) });
}

const out = {
  version: 5,
  session_id: spec.sid,
  created_at: "2026-01-01T00:00:00.000Z",
  session_start_context: { cwd: spec.cwd || null, git_branch: "feature/2527-amp" },
  deliverable_type: "wf-code",
  project_management_type: "waterfall",
};
if (spec.path) {
  out.delivery_path = spec.path;
  out.delivery_path_origin = "branching-handler";
}
if (spec.amp !== undefined) {
  out.auto_merge_pr = spec.amp;
  out.auto_merge_pr_origin = "branching-handler";
  out.auto_merge_pr_source = spec.ampSource || "config";
}
out.closes_issues = [2527];
out.last_pushed_sha = null;
out.events = events;

fs.writeFileSync(path.join(process.env.WORKFLOW_STATE_DIR, spec.sid + ".json"), JSON.stringify(out, null, 2));
