"use strict";
// Tests: hooks/block-case-markers.js
// Tags: TL2, hooks, test-language-match, block-reason, scope:issue-specific
// Block-reason headings of the edit-time hook: a language-match HIGH goes under its own heading,
// never under the case-marker one. The entrypoint feature-2502-language-match-gate.js passes its
// fixture helpers in ({ mkRepo, bashBody, runHook, MB, ME }).
const assert = require("node:assert");
const path = require("node:path");
const { test } = require("node:test");

const CM_HEADING = "[block-case-markers] New test file(s) fail the case-marker gate:";
const LM_HEADING = "[block-case-markers] Test file(s) fail the language-match gate:";

// headingOf(lines, i) — the nearest heading line above line i, or null.
function headingOf(lines, i) {
  for (let k = i - 1; k >= 0; k--) if (lines[k].startsWith("[block-case-markers]")) return lines[k];
  return null;
}

function write(h, repo, rel, content) {
  return h.runHook({ tool_name: "Write", cwd: repo, tool_input: { file_path: path.join(repo, ...rel.split("/")), content } });
}

function languageMatchOnlyHeading(h) {
  test("an existing file blocked only on a language mismatch gets the language-match heading", () => {
    const rel = "tests/bin/rh1.sh";
    const repo = h.mkRepo({ [rel]: h.bashBody("scope:common", "bin/foo.sh, bin/bar.sh", [["a", "bin/foo.sh"], ["b", "bin/bar.sh"]]) });
    const tail = `echo b\n${h.ME}\n`;
    const r = h.runHook({
      tool_name: "Edit", cwd: repo,
      tool_input: { file_path: path.join(repo, ...rel.split("/")), old_string: tail, new_string: `${tail}${h.MB} "c" "bin/foo.js"\necho c\n${h.ME}\n` },
    });
    const show = `decision=${r.decision} reason=[${r.reason}] ${r.raw}`;
    assert.strictEqual(r.decision, "block", show);
    const lines = r.reason.split("\n");
    const at = lines.indexOf(LM_HEADING);
    assert.ok(at >= 0, `no language-match heading: ${show}`);
    assert.ok((lines[at + 1] || "").includes(`${rel}: `) && lines[at + 1].includes("code=TEST_LANGUAGE_MISMATCH"), show);
    assert.ok(!r.reason.includes("New test file(s) fail the case-marker gate"), show);
  });
}

function bothHeadings(h) {
  test("a new file failing both gates lists each HIGH under its own heading", () => {
    const rel = "tests/bin/rh2.sh";
    const r = write(h, h.mkRepo(), rel, h.bashBody("scope:common", "bin/foo.sh, bin/foo.js"));
    const show = `decision=${r.decision} reason=[${r.reason}] ${r.raw}`;
    assert.strictEqual(r.decision, "block", show);
    const lines = r.reason.split("\n");
    assert.ok(lines.includes(CM_HEADING) && lines.includes(LM_HEADING), show);
    const cm = lines.findIndex((l) => l.includes(`${rel}: `) && l.includes("code=MISSING_CASE_MARKERS"));
    const lm = lines.findIndex((l) => l.includes(`${rel}: `) && l.includes("code=TEST_LANGUAGE_MISMATCH"));
    assert.ok(cm >= 0 && lm >= 0, show);
    assert.strictEqual(headingOf(lines, cm), CM_HEADING, show);
    assert.strictEqual(headingOf(lines, lm), LM_HEADING, show);
  });
}

function caseMarkerOnlyUnchanged(h) {
  test("(control) a new file failing only the case-marker gate keeps today's reason", () => {
    const rel = "tests/bin/rh3.sh";
    const r = write(h, h.mkRepo(), rel, h.bashBody("scope:common", "bin/foo.sh, bin/bar.sh"));
    const show = `decision=${r.decision} reason=[${r.reason}] ${r.raw}`;
    assert.strictEqual(r.decision, "block", show);
    const lines = r.reason.split("\n");
    assert.strictEqual(lines[0], CM_HEADING, show);
    assert.ok(lines[1].startsWith(`  ${rel}: `) && lines[1].includes("code=MISSING_CASE_MARKERS"), show);
    assert.ok(!r.reason.includes("language-match"), show);
  });
}

module.exports = { languageMatchOnlyHeading, bothHeadings, caseMarkerOnlyUnchanged };
