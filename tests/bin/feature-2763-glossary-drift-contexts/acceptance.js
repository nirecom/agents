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

module.exports = { run };
