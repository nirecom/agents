#!/usr/bin/env node
"use strict";
// Tests: hooks/lib/markdown-fence.js, bin/lib/glossary-drift.js, bin/lib/glossary-format/entries.js, hooks/lib/intent-glossary.js
// Tags: TL2, bin, glossary, markdown, scope:issue-specific
// #2529 review fix: the three Markdown scanners of #2529 (drift excluded contexts, glossary
// entry parse, intent Glossary section) follow CommonMark fences: a fence closes only on the
// same delimiter character at least as long as its opener with no info string; the other
// delimiter inside a fence is content. Before the fix any ``` or ~~~ line toggled the state.
// Also: the drift pass reads an HTML-comment opener inside an inline code span as literal text.

// TL3 gap: none — the scanners are pure functions over a string.

const { caseBegin, caseEnd } = require("../lib/harness");
const { noNewFailures } = require("../lib/case-verdict");
const { after, test } = require("node:test");
const c = require("./feat-2529-glossary-provenance/common");

const { check, eq, ok, totals, mod } = c;
const fails = () => totals.failed;
after(() => process.stdout.write(`Total: ${totals.passed} passed, ${totals.failed} failed\n`));
const fence = () => mod("hooks/lib/markdown-fence.js");
const drift = () => mod("bin/lib/glossary-drift.js");
const entries = () => mod("bin/lib/glossary-format/entries.js");
const intent = () => mod("hooks/lib/intent-glossary.js");

const SECRET = "Work Flow inside";
const VISIBLE = "Work Flow outside";
// Each body: an opener, an inner line that must NOT close it, SECRET, the real closer, VISIBLE.
const SHAPES = [
  ["tilde-inside-backtick-fence", ["```", "~~~", SECRET, "```", VISIBLE]],
  ["backticks-inside-tilde-fence", ["~~~", "```", SECRET, "~~~", VISIBLE]],
  ["longer-opener-ignores-shorter-run", ["````", "```", SECRET, "````", VISIBLE]],
  ["closer-with-info-string-does-not-close", ["```", "```js", SECRET, "```", VISIBLE]],
  ["longer-closer-closes", ["~~~", SECRET, "~~~~~", VISIBLE]],
];

caseBegin("fence-step-commonmark-rules", "hooks/lib/markdown-fence.js");
test("fence-step-commonmark-rules", () => noNewFailures(fails, () => {
  check("fenceStep: open / content / close for each delimiter shape", () => {
    const { fenceStep } = fence();
    eq(JSON.stringify(fenceStep("```js", null)), JSON.stringify({ fence: "```", marker: true }), "backtick opener with info");
    eq(JSON.stringify(fenceStep("~~~", "```")), JSON.stringify({ fence: "```", marker: false }), "tilde inside backtick fence");
    eq(JSON.stringify(fenceStep("```", "~~~")), JSON.stringify({ fence: "~~~", marker: false }), "backticks inside tilde fence");
    eq(JSON.stringify(fenceStep("```", "````")), JSON.stringify({ fence: "````", marker: false }), "shorter run inside longer fence");
    eq(JSON.stringify(fenceStep("`````  ", "````")), JSON.stringify({ fence: null, marker: true }), "longer closer");
    eq(JSON.stringify(fenceStep("``` x `", null)), JSON.stringify({ fence: null, marker: false }), "backtick info string with a backtick is no opener");
    eq(JSON.stringify(fenceStep("  - ```", null)), JSON.stringify({ fence: null, marker: false }), "a list marker before the run is no opener");
    eq(JSON.stringify(fenceStep("   ~~~", null)), JSON.stringify({ fence: "~~~", marker: true }), "indented opener");
  });
}));
caseEnd();

caseBegin("fence-drift-markdown-pass", "bin/lib/glossary-drift.js");
test("fence-drift-markdown-pass", () => noNewFailures(fails, () => {
  for (const [name, body] of SHAPES) {
    check(`drift ${name}: the fenced line is blanked, the line after the closer is kept`, () => {
      const out = drift().extractCheckableText(body.join("\n"), "markdown").split("\n");
      eq(out.length, body.length, "line count preserved");
      ok(out.slice(0, -1).every((l) => l.trim() === ""), `fenced lines: ${JSON.stringify(out)}`);
      eq(out[out.length - 1], VISIBLE, "after the closer");
    });
  }
  check("drift: an unclosed fence runs to the end of the text", () => {
    const out = drift().extractCheckableText(["````", "```", VISIBLE].join("\n"), "markdown");
    eq(out.trim(), "", `out: ${JSON.stringify(out)}`);
  });
  check("drift: a variant inside a tilde-in-backtick fence is not reported", () => {
    const text = drift().extractCheckableText(["```", "~~~", "the work-flow here", "```", "the work-flow there"].join("\n"), "markdown");
    const hits = drift().findVariants(text, ["work flow"]);
    eq(JSON.stringify(hits.map((h) => h.line)), "[5]", JSON.stringify(hits));
  });
}));
caseEnd();

// Round 5: an HTML-comment opener inside an inline code span is literal text, not a comment.
caseBegin("drift-comment-opener-in-code-span", "bin/lib/glossary-drift.js");
test("drift-comment-opener-in-code-span", () => noNewFailures(fails, () => {
  check("drift: `<!--` inside a code span opens no comment; the prose after it is still scanned", () => {
    const src = "Use `<!--` literally. glossary-drift";
    const out = drift().extractCheckableText(src, "markdown");
    ok(out.includes("literally. glossary-drift"), `out: ${JSON.stringify(out)}`);
    ok(!out.includes("<!--"), `the code span itself is blanked: ${JSON.stringify(out)}`);
    const next = drift().extractCheckableText([src, "the glossary-drift next line"].join("\n"), "markdown").split("\n");
    eq(next[1], "the glossary-drift next line", "no comment carried to the next line");
  });
  check("drift: a real comment still blanks, and inside it a backtick does not hide the closer", () => {
    const out = drift().extractCheckableText("a <!-- `hidden --> shown` tail", "markdown");
    ok(!out.includes("hidden"), `comment body blanked: ${JSON.stringify(out)}`);
    ok(out.includes("tail"), `text after the closer kept: ${JSON.stringify(out)}`);
  });
}));
caseEnd();

const glossary = (fenced) => ["# Glossary — user terms", "", "### alpha", "- **Definition**: A term.", "", ...fenced, ""].join("\n");
caseBegin("fence-glossary-entry-parse", "bin/lib/glossary-format/entries.js");
test("fence-glossary-entry-parse", () => noNewFailures(fails, () => {
  for (const [name, body] of SHAPES) {
    check(`entries ${name}: an entry heading inside the fence is no entry and no fence error`, () => {
      const lines = body.map((l) => (l === SECRET ? "### beta" : l === VISIBLE ? "" : l));
      const r = entries().parseGlossaryFile(glossary(lines));
      eq(r.entries.map((e) => e.term).join(","), "alpha", "entries");
      eq(JSON.stringify(r.errors), "[]", "errors");
    });
  }
  check("entries: a longer opener closed only by a shorter run is an unclosed fence", () => {
    const r = entries().parseGlossaryFile(glossary(["````", "### beta", "```"]));
    ok(r.errors.includes("unclosed code fence"), JSON.stringify(r.errors));
    eq(r.entries.map((e) => e.term).join(","), "alpha", "entries");
  });
}));
caseEnd();

const intentText = (fenced) => ["# Intent", "", "## Issues", "", "- #1", "", ...fenced, "", "## Glossary", ""].join("\n");
caseBegin("fence-intent-glossary-section", "hooks/lib/intent-glossary.js");
test("fence-intent-glossary-section", () => noNewFailures(fails, () => {
  for (const [name, body] of SHAPES) {
    check(`intent ${name}: a ## Glossary line inside the fence is no section heading`, () => {
      const lines = body.map((l) => (l === SECRET ? "## Glossary" : l === VISIBLE ? "" : l));
      const text = intentText(lines);
      const r = intent().parseIntentGlossary(text);
      const real = text.split("\n").lastIndexOf("## Glossary") + 1;
      eq(JSON.stringify(r.glossaryLines), JSON.stringify([real]), "glossary heading lines");
    });
  }
}));
caseEnd();

// #2529 C2 inflow: a `### <term>` heading holding a shell-active character is a format error.
const headingFile = (term) => ["# Glossary — user terms", "", `### ${term}`, "",
  "- **Definition**: A fixture term.", "- **Related**: [README.md](../../README.md)", ""].join("\n");
const headingCases = [
  ["$(x)", "bad$(x)term"], ["backtick", "bad`x`term"], ["double quote", "bad\"term"], ["backslash", "bad\\term"],
  ["semicolon", "bad;term"], ["pipe", "bad|term"], ["ampersand", "bad&term"], ["equals", "bad=term"],
  ["less-than", "bad<term"], ["greater-than", "bad>term"],
].map(([name, term]) => ({ name, term, forbidden: true }))
  .concat([{ name: "safe heading (control)", term: "user's glossary-term_2", forbidden: false }]);
caseBegin("glossary-heading-forbidden-character", "bin/lib/glossary-format/entries.js");
test("glossary-heading-forbidden-character", () => noNewFailures(fails, () => {
  for (const hc of headingCases) {
    check(`checkGlossaryFile heading ${hc.name}: ${hc.forbidden ? "forbidden character error" : "no error"}`, () => {
      const errs = entries().checkGlossaryFile(headingFile(hc.term));
      if (hc.forbidden) ok(errs.some((e) => /forbidden character/.test(e)), `${hc.name}: errors ${JSON.stringify(errs)}`);
      else eq(JSON.stringify(errs), "[]", `${hc.name}: errors`);
    });
  }
}));
caseEnd();
