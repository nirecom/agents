"use strict";
// prose-context-table part of tests/bin/feature-2763-glossary-drift-contexts.js (#2763).
// Holds no case markers; the entrypoint wraps run() in one.
// Rows: [name, format, text, [[term, variant]], terms] — each row names its own terms so one
// window cannot also hit a shorter term of the same row.

const { runTable } = require("./identifier");

const DETAIL_PLURAL = "detail" + "s";
const STEP_TERMS = ["workflow step", "step table", "in-skill step"];

const TOLERATED = [
  ["regular plural of a one-word term", "markdown", `the implementation ${DETAIL_PLURAL} here`, [], ["detail"]],
  ["regular plural of a common word", "markdown", "GitHub workflows run here", [], ["workflow"]],
  ["plural of sentinel", "markdown", "the sentinels here", [], ["sentinel"]],
  ["plural of a multi-word term", "markdown", "the confirm gates here", [], ["confirm gate"]],
  ["plural of workflow step", "markdown", "the workflow steps here", [], ["workflow", "workflow step"]],
  ["sentence start and plural", "markdown", "Sentinels start this line.", [], ["sentinel"]],
  ["sentence start, multi-word plural", "markdown", "Workflow steps run first.", [], ["workflow step"]],
  ["heading title case and plural", "markdown", `## ${"Detail"}s`, [], ["detail"]],
  ["heading title case, multi-word plural", "markdown", "## Workflow Steps", [], ["workflow", "workflow step"]],
  ["table header row", "markdown", "| Workflow Steps | Sentinels |\n|---|---|\n| a | b |", [], ["workflow step", "sentinel"]],
  ["schema heading Steps", "markdown", "## Steps", [], STEP_TERMS],
  ["plural of a -us term", "markdown", "the statuses here", [], ["status"]],
];

const STILL_DRIFT = [
  ["mid-sentence case", "markdown", "the Workflow steps here", [["workflow step", "Workflow steps"]], ["workflow step"]],
  ["mid-sentence capital plural (control for sentence start)", "markdown", "the Sentinels here", [["sentinel", "Sentinels"]], ["sentinel"]],
  ["table body row first cell", "markdown", "| a | b |\n|---|---|\n| Workflow Steps | x |", [["workflow step", "Workflow Steps"]], ["workflow step"]],
  ["hyphen for a space", "markdown", "the confirm-gate here", [["confirm gate", "confirm-gate"]], ["confirm gate"]],
  ["hyphen split and plural", "markdown", "the work-flows here", [["workflow", "work-flows"]], ["workflow"]],
  ["heading keeps hyphen against space", "markdown", "# Plan Sync", [["plan-sync", "Plan Sync"]], ["plan-sync"]],
  ["heading keeps space against hyphen", "markdown", "## Confirm-Gates", [["confirm gate", "Confirm-Gates"]], ["confirm gate"]],
  ["space-split identifier", "markdown", "the agents main root here", [["AGENTS_MAIN_ROOT", "agents main root"]], ["AGENTS_MAIN_ROOT"]],
  ["merged multi-word term", "markdown", "the confirmgate here", [["confirm gate", "confirmgate"]], ["confirm gate"]],
];

function run(F) {
  runTable(F, "prose tolerated", TOLERATED);
  runTable(F, "prose drift", STILL_DRIFT);
}

module.exports = { run };
