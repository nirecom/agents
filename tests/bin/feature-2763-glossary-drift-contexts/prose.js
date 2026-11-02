"use strict";
// prose-context-table part of tests/bin/feature-2763-glossary-drift-contexts.js (#2763).
// Holds no case markers; the entrypoint wraps run() in one.
// Rows: [name, format, text, [[term, variant]], terms] — each row names its own terms so one
// window cannot also hit a shorter term of the same row.

const fs = require("node:fs");
const path = require("node:path");
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

// Plan S4-2: the three background words, with the term set of the real glossary written per row.
const BG_TERMS = ["presentation turn", "workflow", "workflow step", "detail", "GATE_ACTION"];
const BACKGROUND = [
  ["verb turns (.env.example)", "markdown",
    "# Format: any non-empty value turns no-delete mode on; unset or empty applies deletes (default).", [], BG_TERMS],
  ["verb turns (next-step --gate)", "markdown",
    "next-step --gate turns the recorded step + gate value (+ detail scope change) into one GATE_ACTION.", [], BG_TERMS],
  [".github templates and workflows", "markdown", ".github templates and workflows", [], BG_TERMS],
  ["a one-word term turn is tolerated as a regular plural", "markdown", "the value turns it on", [], ["turn"]],
];

// Short forms are a write-time declaration (the entry gate); the drift check never matches them.
// A record that carries them still indexes its headword only, so a word of a short form in prose
// is no drift, and the headword itself keeps its usual drift.
const short = (term, shortForms) => ({ term, identifiers: [], shortForms });
const DETAIL_PLAN = short("detail plan", ["detail"]);
const WORKFLOW_STEP = short("workflow step", ["step"]);
const SHORT_RECS = [DETAIL_PLAN, WORKFLOW_STEP];
const SHORT_FORMS = [
  ["a short form used as an ordinary word", "markdown", "do it step by step here", [], SHORT_RECS],
  ["a plural of a short form", "markdown", `the implementation ${DETAIL_PLURAL} here`, [], SHORT_RECS],
  ["a capitalised short form mid-sentence", "markdown", "the Detail here", [], SHORT_RECS],
  ["a common word next to a short-form record", "markdown", "GitHub workflows run here", [], SHORT_RECS.concat(["workflow"])],
  ["an inflected form is not folded to the term", "markdown", "the job workflowed here", [], SHORT_RECS.concat(["workflow"])],
  ["the headword itself (control)", "markdown", "the detail plan here", [], SHORT_RECS],
  ["the headword keeps its separator drift", "markdown", "the detail-plan here", [["detail plan", "detail-plan"]], SHORT_RECS],
];

// The term index holds the headword only: no key, exact spelling or record field for a short form.
function runShortFormsIndex(F) {
  const terms = F.mod("bin/lib/glossary-drift/terms.js");
  if (!terms) return;
  const index = terms.indexTerms(SHORT_RECS);
  F.check("indexTerms: exact holds the headwords only",
    JSON.stringify([...index.exact].sort()) === JSON.stringify(["detail plan", "workflow step"]), JSON.stringify([...index.exact]));
  F.check("indexTerms: no plain key for a short form",
    !index.plain.has("detail") && !index.plain.has("step") && index.plain.has("detailplan"), JSON.stringify([...index.plain.keys()]));
  const rec = terms.termRecord(DETAIL_PLAN);
  F.check("termRecord keeps { term, identifiers } and drops Short forms",
    JSON.stringify(rec) === JSON.stringify({ term: "detail plan", identifiers: [] }), JSON.stringify(rec));
}

// Plan S4-4: the fixed detail-plan schema headings, matched against the terms of the real glossary.
function glossaryTerms() {
  const root = path.resolve(__dirname, "..", "..", "..");
  const out = [];
  for (const name of ["user.md", "internal.md"]) {
    const text = fs.readFileSync(path.join(root, "docs", "glossary", name), "utf8");
    for (const m of text.matchAll(/^### (.+?)\s*$/gm)) out.push(m[1]);
  }
  return out;
}
const SCHEMA_DOC = ["Delivery plan", "Background", "Files to modify", "Steps", "Risks & edge cases", "Out of scope"]
  .map((h) => `## ${h}\n\nbody text here.\n`).join("\n");

function runShortForms(F) {
  runTable(F, "prose background", BACKGROUND);
  runTable(F, "prose short forms", SHORT_FORMS);
  runShortFormsIndex(F);
  const terms = glossaryTerms();
  F.check("real glossary has terms", terms.length > 10, String(terms.length));
  runTable(F, "prose schema", [["detail-plan schema headings", "markdown", SCHEMA_DOC, [], terms]]);
}

module.exports = { run, runShortForms };
