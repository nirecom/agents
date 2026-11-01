"use strict";
// acceptance-through-the-cli part of tests/bin/feature-2763-glossary-drift-contexts.js (#2763,
// #2767). Holds no case markers; the entrypoint wraps run() in one.
// The reported false positives go through the real bin/check-glossary-drift: the tests stage keeps
// only the two true identifier drifts, the detail stage is clean, the docs stage control drifts.

const ROOT_ID = "AGENTS_MAIN_ROOT";
const TERMS = { user: [ROOT_ID, "detail", "intent", "outline"], internal: ["allow-deny hook", "Jev", "RTK", "WF-CODE"] };

function glossaryFiles(F) {
  const body = (title, terms) => `# Glossary — ${title} terms\n\n${terms.map((t) => F.entry(t, "A fixture term.")).join("\n")}`;
  return { "docs/glossary/user.md": body("user", TERMS.user), "docs/glossary/internal.md": body("internal", TERMS.internal) };
}

const lineOf = (text, needle) => text.split("\n").findIndex((l) => l.includes(needle)) + 1;

const TESTS_LINES = [
  "// Tags: TL2, allow-deny-hook",
  `// the implementation ${"detail"}s are here`,
  "// see CONFIRM_{INTENT,OUTLINE,DETAIL} here",
  "// used only when JEV=on",
  "// pipe the output through rtk here",
  "// set the wf-code value",
  "// set AGENT_MAIN_ROOT first",
  "// the agents main root here",
];

function testsStage(F) {
  const repo = F.mkRepo("c-tests", glossaryFiles(F));
  const sid = F.newSid("c-tests");
  const text = `"use strict";\n${TESTS_LINES.join("\n")}\nmodule.exports = 1;\n`;
  F.stageFile(repo, "tests/x.js", text);
  F.seedAt(sid, F.STAGE_STEP.tests, repo);
  const r = F.drift(sid, "tests", repo, false);
  F.check("acceptance tests stage: exit 1", F.reached(r) && r.code === 1, `code=${r.code} ${r.all}`);
  const found = F.driftLines(r.all);
  const want = [
    { variant: "AGENT_MAIN_ROOT", line: lineOf(text, "AGENT_MAIN_ROOT") },
    { variant: "agents main root", line: lineOf(text, "agents main root") },
  ];
  F.check("acceptance tests stage: exactly two DRIFT lines", found.length === 2, JSON.stringify(found));
  for (const w of want) {
    const hit = found.find((d) => d.variant === w.variant && d.term === ROOT_ID && d.line === w.line && d.file.endsWith("tests/x.js"));
    F.check(`acceptance tests stage: DRIFT "${w.variant}" -> "${ROOT_ID}" at tests/x.js:${w.line}`, !!hit, JSON.stringify(found));
  }
}

function detailStage(F) {
  const repo = F.mkRepo("c-detail", glossaryFiles(F));
  const sid = F.newSid("c-detail");
  F.writePlan(sid, "detail", "# Plan\n\n## Steps\n\n- one\n\n## Details\n\nSet the `wf-code` value; skip with WORKFLOW_DETAIL_NOT_NEEDED.\n");
  F.seedAt(sid, F.STAGE_STEP.detail, repo);
  const r = F.drift(sid, "detail", repo, false);
  F.check("acceptance detail stage: exit 0 and no DRIFT",
    F.reached(r) && r.code === 0 && F.driftLines(r.all).length === 0, `code=${r.code} ${r.all}`);
}

function docsStage(F) {
  const repo = F.mkRepo("c-docs", glossaryFiles(F));
  const sid = F.newSid("c-docs");
  // Lines 4-5 are blanked inside the code span (plan S3-1), so the control stays the only finding.
  F.stageFile(repo, "docs/guide.md", "# Guide\n\nSet the agents main root here.\n" +
    "Read `hooks/AGENT_MAIN_ROOT.js` first.\nEmit `<<AGENT_MAIN_ROOT: reason>>` once.\n");
  F.seedAt(sid, F.STAGE_STEP.docs, repo);
  const r = F.drift(sid, "docs", repo, false);
  const found = F.driftLines(r.all);
  F.check("acceptance docs stage (control): exit 1 with one DRIFT at docs/guide.md:3",
    F.reached(r) && r.code === 1 && found.length === 1 && found[0].variant === "agents main root" &&
    found[0].term === ROOT_ID && found[0].line === 3, `code=${r.code} ${r.all}`);
}

function run(F) {
  testsStage(F);
  detailStage(F);
  docsStage(F);
}

// Plan S4-6: a spelling declared by the Identifier bullet of a glossary entry and one declared by
// the Identifier cell of a V3 intent row are both left alone mid-line in a tests-stage comment.
const V3_HEADER = "| Term | Category | Operation | Definition | Identifier | Homographs |\n|---|---|---|---|---|---|";
function declaredStage(F) {
  const files = glossaryFiles(F);
  files["docs/glossary/internal.md"] = files["docs/glossary/internal.md"].replace(
    /(### allow-deny hook\n\n- \*\*Definition\*\*: [^\n]*\n)/, "$1- **Identifier**: `allow-deny-hook`\n");
  const repo = F.mkRepo("c-declared", files);
  const sid = F.newSid("c-declared");
  const intent = F.intentBody({ rows: [] }).replace(/## Glossary\n\n[\s\S]*?\n\n## Goal/,
    `## Glossary\n\n${V3_HEADER}\n| fizz-buzz gate | internal | add | A fixture term. | \`fizz-buzz-gate\` |  |\n\n## Goal`);
  // The V3 term exists only through this replace; without the row the "no DRIFT" below is vacuous.
  F.check("acceptance declared spellings: the intent body carries the V3 fizz-buzz gate row",
    intent.includes(V3_HEADER) && intent.includes("| fizz-buzz gate |"), intent);
  F.writePlan(sid, "intent", intent);
  // Line 4 is the live control: an undeclared spelling of the V3 term drifts, so the term is read.
  const text = `"use strict";\n// a mid-line allow-deny-hook here\n// a mid-line fizz-buzz-gate here\n// the fizz buzz gate here\nmodule.exports = 1;\n`;
  F.stageFile(repo, "tests/x.js", text);
  F.seedAt(sid, F.STAGE_STEP.tests, repo);
  const r = F.drift(sid, "tests", repo, false);
  const found = F.driftLines(r.all);
  F.check("acceptance declared spellings: glossary Identifier and V3 intent Identifier -> exit 1, only the control drifts",
    F.reached(r) && r.code === 1 && found.length === 1 && found[0].term === "fizz-buzz gate" &&
    found[0].variant === "fizz buzz gate" && found[0].line === lineOf(text, "the fizz buzz gate") &&
    found[0].file.endsWith("tests/x.js"), `code=${r.code} ${r.all}`);
}

// Plan S4-6: a 100,000-character run on a staged line goes through the CLI within LIMIT_MS.
const LIMIT_MS = 10000;
function longLineStage(F) {
  const repo = F.mkRepo("c-long", glossaryFiles(F));
  const sid = F.newSid("c-long");
  F.stageFile(repo, "tests/long.js", `"use strict";\n// ${"a".repeat(100000)}\nmodule.exports = 1;\n`);
  F.seedAt(sid, F.STAGE_STEP.tests, repo);
  const start = Date.now();
  const r = F.drift(sid, "tests", repo, false);
  const took = Date.now() - start;
  F.check(`acceptance long line: exit 0 within ${LIMIT_MS} ms`,
    F.reached(r) && r.code === 0 && took < LIMIT_MS, `code=${r.code} took=${took}ms ${String(r.all).slice(0, 400)}`);
}

function runDeclared(F) {
  declaredStage(F);
  longLineStage(F);
}

module.exports = { run, runDeclared };
