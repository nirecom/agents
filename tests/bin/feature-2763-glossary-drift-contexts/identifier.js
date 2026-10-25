"use strict";
// identifier-context-table part of tests/bin/feature-2763-glossary-drift-contexts.js (#2763).
// Holds no case markers; the entrypoint wraps run() / runSingular() in one each.
// Rows: [name, format, text, [[term, variant]]], asserted through findDrift(text, format, terms).
// Every drifted spelling sits in a string literal (comments are scanned at commit).

const TERMS = ["AGENTS_MAIN_ROOT", "WORKTREE_NOTES", "WF-CODE", "RTK", "Jev", "PM type", "detail", "intent",
  "outline", "allow-deny hook", "confirm gate", "workflow step"];
const ROOT_ID = "AGENTS_MAIN_ROOT";
const LONG_ID = "FOO_NOTE_TASK_ITEM_DIR";
const LONG_PLURAL = "FOO_NOTES_TASKS_ITEMS_DIR";
const LONG_SPLIT = "foo notes tasks items dir";
const LONG_LINE = Array.from({ length: 300 }, (_, i) => `alpha${i % 7} beta gamma`).join(" ");
const code = (comment) => `"use strict";\n${comment}\nmodule.exports = 1;\n`;

const ROWS = [
  ["exact identifier spelling (control)", "markdown", "set AGENTS_MAIN_ROOT here", []],
  ["exact identifier spelling in a code span (control)", "markdown", "set `AGENTS_MAIN_ROOT` here", []],
  ["word-form drift in a code span", "markdown", "set `AGENT_MAIN_ROOT` here", [[ROOT_ID, "AGENT_MAIN_ROOT"]]],
  ["word-form drift without backticks", "markdown", "set AGENT_MAIN_ROOT here", [[ROOT_ID, "AGENT_MAIN_ROOT"]]],
  ["singular of a plural identifier term", "markdown", "set WORKTREE_NOTE here", [["WORKTREE_NOTES", "WORKTREE_NOTE"]]],
  ["lower-case payload key in a code span (naming convention)", "markdown", "the `agents_main_root` payload key", []],
  ["merged capitals (naming convention)", "markdown", "set AGENTSMAINROOT here", []],
  ["mixed underscore and hyphen (naming convention)", "markdown", "set AGENTS_MAIN-ROOT here", []],
  ["space-split inside a code span", "markdown", "set `agents main root` here", [[ROOT_ID, "agents main root"]]],
  ["space-split run of capital words", "markdown", "set AGENTS MAIN ROOT here", [[ROOT_ID, "AGENTS MAIN ROOT"]]],
  ["lower-case value in a code span", "markdown", "the `wf-code` value", []],
  ["lower-case binary name in a code span", "markdown", "the `rtk` binary", []],
  ["brace expansion in a code span", "markdown", "the `CONFIRM_{INTENT,OUTLINE,DETAIL}` gates", []],
  ["brace expansion without backticks", "markdown", "the CONFIRM_{INTENT,OUTLINE,DETAIL} gates", []],
  ["leading brace expansion", "markdown", "emit {RESEARCH,OUTLINE,DETAIL,WRITE_TESTS}_NOT_NEEDED here", []],
  ["lower-case brace expansion", "markdown", "the confirm_{intent,outline} keys", []],
  ["sentinel name", "markdown", "emit WORKFLOW_DETAIL_NOT_NEEDED here", []],
  ["assignment value", "markdown", "used only when JEV=on", []],
  ["single capital word of a lower-case term", "markdown", "the OUTLINE stage", []],
  ["dollar variable", "markdown", "read $outlines here", []],
  ["capital words split at the wrong separator", "markdown", "the WF CODE value", [["WF-CODE", "WF CODE"]]],
  ["capital-led term hyphenated", "markdown", "the PM-type here", [["PM type", "PM-type"]]],
  ["camelCase (not a variant)", "markdown", "set agentsMainRoot here", []],
  ["Tags line in a code comment", "code", code("// Tags: TL2, allow-deny-hook, confirm-gate"), []],
  ["Tags line in markdown", "markdown", "# Tags: allow-deny-hook", []],
  ["mid-line kebab in a code comment (control)", "code", code("// a mid-line allow-deny-hook here"), [["allow-deny hook", "allow-deny-hook"]]],
  ["code comment: lower-case acronym", "code", code("// pipe the output through rtk here"), []],
  ["code comment: lower-case acronym, same separator", "code", code("// set the wf-code value"), []],
  ["code comment: identifier word-form drift", "code", code("// set AGENT_MAIN_ROOT first"), [[ROOT_ID, "AGENT_MAIN_ROOT"]]],
  ["code comment: space-split identifier", "code", code("// the agents main root here"), [[ROOT_ID, "agents main root"]]],
  ["code comment: mid-sentence case of a lower-case term", "code", code("// the Workflow Step here"), [["workflow step", "Workflow Step"]]],
  ["code comment: acronym not all lower case", "code", code("// the Rtk binary"), [["RTK", "Rtk"]]],
  ["code comment: acronym with another separator", "code", code("// the wf code value"), [["WF-CODE", "wf code"]]],
  ["code comment: exact lower-case term (control)", "code", code("// the outline here"), []],
  ["markdown: lower-case acronym stays drift", "markdown", "the rtk binary", [["RTK", "rtk"]]],
  ["empty text", "markdown", "", []],
  ["prose finding before a code-span finding", "markdown", "set AGENT_MAIN_ROOT and `WORKTREE_NOTE` here",
    [[ROOT_ID, "AGENT_MAIN_ROOT"], ["WORKTREE_NOTES", "WORKTREE_NOTE"]]],
  ["code-span finding before a prose finding", "markdown", "set `WORKTREE_NOTE` and AGENT_MAIN_ROOT here",
    [["WORKTREE_NOTES", "WORKTREE_NOTE"], [ROOT_ID, "AGENT_MAIN_ROOT"]]],
  ["findings in line order", "markdown", "first `WORKTREE_NOTE` here\nthen AGENT_MAIN_ROOT here",
    [["WORKTREE_NOTES", "WORKTREE_NOTE"], [ROOT_ID, "AGENT_MAIN_ROOT"]]],
  // Plan S5-1/S5-4: only "_" terms enter identifierSpellings, so a code span never matches a plain term.
  ["plain term hyphenated in a code span", "markdown", "the `confirm-gate` value", []],
  ["plain term hyphenated in prose (symmetric pair)", "markdown", "the confirm-gate value", [["confirm gate", "confirm-gate"]]],
  // Edge cases, following the null-to-empty and de-duplication behavior of the current findVariants.
  ["null text", "markdown", null, []],
  ["undefined text", "markdown", undefined, []],
  ["empty terms", "markdown", "set AGENT_MAIN_ROOT and the confirm-gate here", [], []],
  ["duplicate terms report once", "markdown", "the confirm-gate value", [["confirm gate", "confirm-gate"]],
    ["confirm gate", "confirm gate"]],
  // Plan S3-1: the kept code-span content gets the same sentinel, link, autolink and path blanking.
  ["code span: path with a directory", "markdown", "see `hooks/AGENT_MAIN_ROOT.js` here", []],
  ["code span: file name with an extension", "markdown", "see `AGENT_MAIN_ROOT.json` here", []],
  ["code span: sentinel", "markdown", "emit `<<AGENT_MAIN_ROOT: reason>>` here", []],
  ["code span: autolink", "markdown", "see `<https://example.com/AGENT_MAIN_ROOT>` here", []],
  ["code span: link target", "markdown", "see `[x](AGENT_MAIN_ROOT)` here", []],
  ["code span: bare word-form drift (control)", "markdown", "`see AGENT_MAIN_ROOT here`", [[ROOT_ID, "AGENT_MAIN_ROOT"]]],
  // Plan S5-6 window cap: the fictional term is the longest one, so its raw key sets maxLen alone.
  ["window cap: every identifier word pluralized", "markdown", `set ${LONG_PLURAL} here`, [[LONG_ID, LONG_PLURAL]], [LONG_ID]],
  ["window cap: space-split with every word pluralized", "markdown", `set \`${LONG_SPLIT}\` here`, [[LONG_ID, LONG_SPLIT]], [LONG_ID]],
  ["window cap: long unrelated line", "markdown", LONG_LINE, []],
];

// The findDrift export, or null with the red reason logged.
function findDriftOf(F) {
  const drift = F.mod("bin/lib/glossary-drift.js");
  if (!drift) return null;
  if (typeof drift.findDrift !== "function") {
    F.check("bin/lib/glossary-drift.js exports findDrift", false, Object.keys(drift).join(","));
    return null;
  }
  return drift.findDrift;
}

// rows: [name, format, text, want] or [name, format, text, want, terms].
function runTable(F, label, rows, defaultTerms) {
  const findDrift = findDriftOf(F);
  if (!findDrift) return;
  for (const [name, format, text, want, terms] of rows) {
    let got;
    try {
      got = (findDrift(text, format, terms || defaultTerms) || []).map((h) => [h.term, h.variant]);
    } catch (e) {
      got = `threw ${e && e.message}`;
    }
    F.check(`${label} ${name}: ${JSON.stringify(text)} -> ${JSON.stringify(want)}`,
      JSON.stringify(got) === JSON.stringify(want), JSON.stringify(got));
  }
}

function run(F) {
  runTable(F, "identifier", ROWS, TERMS);
}

const SINGULAR_ROWS = [
  ["regular plural", "notes", "note"],
  ["-ies plural", "entries", "entry"],
  ["-es after sh", "pushes", "push"],
  ["-us singular kept", "status", "status"],
  ["-yses plural", "analyses", "analysis"],
  ["already singular", "root", "root"],
];
function runSingular(F) {
  const term = F.mod("hooks/lib/glossary-term.js");
  if (!term) return;
  if (!F.check("hooks/lib/glossary-term.js exports singular", typeof term.singular === "function", Object.keys(term).join(","))) return;
  for (const [name, word, want] of SINGULAR_ROWS) {
    F.check(`singular ${name}: ${word} -> ${want}`, term.singular(word) === want, term.singular(word));
  }
}

module.exports = { run, runSingular, runTable };
