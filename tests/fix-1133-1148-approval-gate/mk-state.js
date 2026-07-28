#!/usr/bin/env node
"use strict";
// Fixture generator for fix-1133-1148-approval-gate tests (NOT a test itself).
// Usage: node mk-state.js '<overrides-json>' [workflow_type] '<extra-top-level-json>'
//   overrides-json : { "<step>": "<status>", ... }  (unlisted steps default to "pending")
//   workflow_type  : "wf-code" (default) | "wf-meta"
//   extra-json     : merged into the top-level state object (e.g. plan_approvals)
// Prints the full state JSON to stdout.

const VALID_STEPS = [
  "workflow_init", "clarify_intent", "research", "outline", "detail",
  "branching_complete", "write_tests", "review_tests", "run_tests",
  "review_security", "docs", "user_verification", "cleanup",
  "pre_final_report_gate",
];

const overrides = JSON.parse(process.argv[2] || "{}");
const workflowType = process.argv[3] || "wf-code";
const extra = JSON.parse(process.argv[4] || "{}");

const TS = "2026-06-20T10:00:00.000Z";
const steps = {};
for (const s of VALID_STEPS) {
  const status = overrides[s] || "pending";
  steps[s] = { status, updated_at: status === "pending" ? null : TS };
}

const state = {
  version: 1,
  session_id: "gen",
  created_at: TS,
  closes_issues: [1133],
  workflow_type: workflowType,
  steps,
  ...extra,
};

process.stdout.write(JSON.stringify(state, null, 2));
