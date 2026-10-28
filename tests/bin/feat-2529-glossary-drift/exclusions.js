"use strict";
// lang-check: ignore — Japanese fixture strings are test data for Japanese term matching.
// T5-2 part of tests/bin/feat-2529-glossary-drift.js (#2529). Holds no case markers; the
// entrypoint wraps run() in one.
// One artifact per format carries a variant inside every excluded context, one per line, plus a
// control line that must give DRIFT; each excluded line is asserted to give none, so a skipped
// scan (no DRIFT at all) fails on the control line instead of passing.

// [label, line] in file order; a bare string is structure, not asserted.
const MARKDOWN = [
  "---", ["frontmatter", "title: glossary-drift notes"], "---",
  "# Outline", "",
  ["exact match", "Mid-line the glossary drift is spelled exactly."],
  ["inline code", "Mid-line use `glossary-drift` as a literal."],
  "```text", ["fenced block", "mid-line glossary-drift inside a fence"], "```",
  ["link URL", "See [the page](https://example.com/q?glossary-drift) for more."],
  ["link anchor", "See [the section](#glossary-drifts) below."],
  ["HTML comment", "Mid-line <!-- glossary-drift --> comment."],
  ["sentinel notation", "Mid-line <<WORKFLOW_GLOSSARY_ACCEPTED: term=glossary-drift stage=outline — fixture>> here."],
  ["path-shaped word", "Mid-line see hooks/glossary-drift.js for the path."],
  ["sentence start: line head", "Glossary drift starts this line."],
  ["sentence start: after a period", "Done here. Glossary drift follows a period."],
  ["sentence start: list marker", "- Glossary drift after a list marker."],
  ["sentence start: heading marker", "## Glossary drift heading"],
  ["Japanese exact match", "ここでは用語揺れを正しく書く。"],
  ["Japanese near spelling (exact match only)", "ここでは用語ゆれと書いても対象外。"],
  ["CONTROL", "Mid-line the glossary-drift control line."],
];

function layout(spec) {
  const text = spec.map((x) => (typeof x === "string" ? x : x[1])).join("\n") + "\n";
  const labelled = [];
  spec.forEach((x, i) => { if (typeof x !== "string") labelled.push({ label: x[0], line: i + 1 }); });
  return { text, labelled };
}

function assertLines(F, title, r, labelled, tail) {
  const found = F.driftLines(r.all).filter((d) => d.file.endsWith(tail));
  F.check(`T5-2 ${title}: check-glossary-drift runs and exits 1 (control line)`, F.reached(r) && r.code === 1, `code=${r.code} ${r.all}`);
  for (const { label, line } of labelled) {
    const at = found.filter((d) => d.line === line);
    if (label === "CONTROL") F.check(`T5-2 ${title}: control line ${line} gives DRIFT`, at.length > 0, r.all);
    else F.check(`T5-2 ${title}: ${label} (line ${line}) gives no DRIFT`, F.reached(r) && at.length === 0, JSON.stringify(at));
  }
}

function markdownContexts(F) {
  const repo = F.mkRepo("x-md");
  const sid = F.newSid("x-md");
  const { text, labelled } = layout(MARKDOWN);
  F.writePlan(sid, "outline", text);
  F.seedAt(sid, "outline", repo);
  assertLines(F, "markdown (outline)", F.drift(sid, "outline", repo, false), labelled, `${sid}-outline.md`);
}

// code format: only the comment body is scanned; string literals and identifiers are not.
const CODE = [
  "\"use strict\";",
  ["string literal outside a comment", "const label = \"glossary-drift\";"],
  ["string literal (case + plural) outside a comment", "const other = \"Glossary Drifts\";"],
  ["identifier outside a comment", "const glossary_drifts = 1;"],
  ["CONTROL", "// a mid-line glossary-drift comment"],
  "module.exports = { label, other, glossary_drifts };",
];
function codeContexts(F) {
  const repo = F.mkRepo("x-code");
  const sid = F.newSid("x-code");
  const { text, labelled } = layout(CODE);
  F.stageFile(repo, "bin/a.js", text);
  F.seedAt(sid, "review_security", repo);
  assertLines(F, "code comments (code stage)", F.drift(sid, "code", repo, false), labelled, "bin/a.js");
}

// A sequence spelled exactly like another combined-glossary term (glossary file or intent row) is
// that term, not a variant; a case-only difference from it is not an exact match.
const OTHER_TERM = [
  "# Outline", "",
  ["exact spelling of another glossary-file term", "Mid-line the concern-ledger is another glossary term."],
  ["exact spelling of an intent-row term", "Mid-line the Glossary-Drift is an intent term."],
  ["CONTROL", "Mid-line the glossary-Drift differs in case only."],
];
function otherTerm(F) {
  const files = Object.assign({}, F.GLOSSARY_FILES, {
    "docs/glossary/internal.md": `# Glossary — internal terms\n\n${F.entry(F.TERM2, "The per-round list of review concerns.")}\n` +
      F.entry("concern-ledger", "The CLI that edits the concern ledger."),
  });
  const repo = F.mkRepo("x-other", files);
  const sid = F.newSid("x-other");
  F.writeIntent(sid, { rows: [
    [F.TERM, "user", "add", "A spelling that differs from the glossary term."],
    ["Glossary-Drift", "session", "add", "The fixture's capitalised session term."],
  ] });
  const { text, labelled } = layout(OTHER_TERM);
  F.writePlan(sid, "outline", text);
  F.seedAt(sid, "outline", repo);
  const r = F.drift(sid, "outline", repo, false);
  assertLines(F, "another term's exact spelling (outline)", r, labelled, `${sid}-outline.md`);
  const caseOnly = labelled.find((x) => x.label === "CONTROL").line;
  const ledger = F.driftLines(r.all).filter((d) => d.line === caseOnly && d.variant === "glossary-Drift");
  F.check("T5-2 another term: the case-only sequence is reported as the variant glossary-Drift", ledger.length > 0, r.all);
}

function run(F) {
  markdownContexts(F);
  codeContexts(F);
  otherTerm(F);
}

module.exports = { run };
