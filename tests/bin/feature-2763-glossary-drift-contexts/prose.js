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

// Plan S4-3: Homographs. A record the gate accepts (statuses for statusline) never changes the
// candidates; the mechanism (prose only, literal match) is pinned with records the gate refuses.
const homo = (term, homographs) => ({ term, identifiers: [], homographs });
const STATUSES = homo("statusline", ["statuses"]);
const PLAIN_RAW = homo("statusline", ["status-lines"]);
const IDENT_RAW = homo("status_line", ["status-lines"]);
const HOMOGRAPHS = [
  ["gate-accepted homograph keeps separator drift", "markdown", "the status-lines here", [["statusline", "status-lines"]], [STATUSES]],
  ["gate-accepted homograph control", "markdown", "the statuses here", [], [STATUSES]],
  ["plain term: literal homograph in prose", "markdown", "the status-lines here", [], [PLAIN_RAW]],
  ["plain term: sentence-start capital is not the literal homograph", "markdown", "Status-lines are here",
    [["statusline", "Status-lines"]], [PLAIN_RAW]],
  ["identifier term: literal homograph in prose", "markdown", "the status-lines here", [], [IDENT_RAW]],
  ["identifier term: no homograph declared (control)", "markdown", "the status-lines here",
    [["status_line", "status-lines"]], [homo("status_line", [])]],
  ["identifier term: homograph inside a code span stays drift", "markdown", "the `status-lines` here",
    [["status_line", "status-lines"]], [IDENT_RAW]],
  ["identifier term: sentence-start capital stays drift", "markdown", "Status-lines are here",
    [["status_line", "Status-lines"]], [IDENT_RAW]],
  ["identifier term: another word form stays drift", "markdown", "the status lines here",
    [["status_line", "status lines"]], [IDENT_RAW]],
  // Plan S3-4(b): a capital-word window is caps mode, where Homographs are not consulted.
  ["identifier term: literal homograph in prose (control for caps)", "markdown", "the status line here", [],
    [homo("STATUS_LINE", ["status line"])]],
  ["identifier term: caps-mode window ignores a literal homograph", "markdown", "the STATUS LINE here",
    [["STATUS_LINE", "STATUS LINE"]], [homo("STATUS_LINE", ["STATUS LINE"])]],
];

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

function runHomographs(F) {
  runTable(F, "prose background", BACKGROUND);
  runTable(F, "prose homographs", HOMOGRAPHS);
  const terms = glossaryTerms();
  F.check("real glossary has terms", terms.length > 10, String(terms.length));
  runTable(F, "prose schema", [["detail-plan schema headings", "markdown", SCHEMA_DOC, [], terms]]);
}

module.exports = { run, runHomographs };
