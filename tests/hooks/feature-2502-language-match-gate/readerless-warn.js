"use strict";
// #2502 S3-5 (user decision 2026-10-24): a NEW tests/ file at a case-marker placement whose
// registry entry has no caseMarkerReader (today the recognized-only test-naming-convention entry,
// e.g. test_foo.rb) gets one CASE_MARKER_READER_UNSUPPORTED WARN at edit time (approve +
// additionalContext) and at commit time (rc 0 + stderr), helper library or not. No WARN for a
// file no entry matches, an existing file, or one under tests/_archive/ or tests/lib/.
// The entrypoint feature-2502-language-match-gate-existing.js passes its fixture helpers in
// ({ mkRepo, runHook, runPrecommitCaseMarkers, git, writeRel }).
const assert = require("node:assert");
const os = require("node:os");
const path = require("node:path");
const { test } = require("node:test");

const CODE = "code=CASE_MARKER_READER_UNSUPPORTED";
const BODY = "# Tests: bin/foo.rb\n# Tags: scope:common\nputs 1\n";
const NEW_RL = ["tests/bin/test_foo.rb", "tests/test_foo.rb"];

const warnLines = (text) => String(text).split(/\r?\n/).filter((l) => l.includes(CODE));
const abs = (repo, rel) => path.join(repo, ...rel.split("/"));
const writeOf = (repo, rel) => ({ tool_name: "Write", cwd: repo, tool_input: { file_path: abs(repo, rel), content: BODY } });
const hookShow = (r) => `decision=${r.decision} reason=[${r.reason}] context=[${r.context}] ${r.raw}`;
const noTemp = (text) => ![os.tmpdir(), os.tmpdir().replace(/\\/g, "/")].some((t) => text.includes(t));

function editTimeWarn(h) {
  test("a new reader-less tests/ file is approved with one CASE_MARKER_READER_UNSUPPORTED line in the notice", () => {
    const runs = NEW_RL.map((rel) => ({ rel, repo: h.mkRepo() }));
    runs.push({ rel: NEW_RL[0], repo: h.mkRepo({}, { noHelpers: true }) });
    for (const { rel, repo } of runs) {
      const r = h.runHook(writeOf(repo, rel));
      assert.strictEqual(r.decision, "approve", hookShow(r));
      const w = warnLines(r.context);
      assert.strictEqual(w.length, 1, `want one ${CODE} line for ${rel}: ${hookShow(r)}`);
      assert.ok(w[0].includes(`${rel}: `) && w[0].includes("no test case reader for this language"), hookShow(r));
      assert.ok(noTemp(r.context), `temp path leaked: ${hookShow(r)}`);
    }
  });
}

function commitTimeWarn(h) {
  test("a staged new reader-less tests/ file passes the case-marker gate with one WARN naming its rel path", () => {
    const runs = NEW_RL.map((rel) => ({ rel, repo: h.mkRepo() }));
    runs.push({ rel: NEW_RL[0], repo: h.mkRepo({}, { noHelpers: true }) });
    for (const { rel, repo } of runs) {
      h.writeRel(repo, rel, BODY);
      h.git(repo, "add", "--", rel);
      const p = h.runPrecommitCaseMarkers(repo);
      const pshow = `rc=${p.rc} stdout=[${p.stdout}] stderr=[${p.stderr}]`;
      assert.strictEqual(p.rc, 0, pshow);
      const w = warnLines(p.stderr);
      assert.strictEqual(w.length, 1, `want one ${CODE} line for ${rel}: ${pshow}`);
      assert.ok(w[0].startsWith(`WARN: ${rel}: `), pshow);
      assert.ok(noTemp(p.stderr + p.stdout), `temp path leaked: ${pshow}`);
      assert.strictEqual(warnLines(p.stdout).length, 0, pshow);
    }
  });
}

// Negatives: a new file no entry matches, an existing reader-less file edited, and new
// reader-less files under tests/_archive/ and tests/lib/.
const OLD = "tests/bin/test_old.rb";
const NEG_NEW = ["tests/bin/fixture.json", "tests/_archive/test_foo.rb", "tests/lib/test_foo.rb"];

function editTimeNegatives(h) {
  test("(control) unmatched, existing, archive or lib files are approved at edit time without CASE_MARKER_READER_UNSUPPORTED", () => {
    const repo = h.mkRepo({ [OLD]: BODY });
    const inputs = NEG_NEW.map((rel) => writeOf(repo, rel));
    inputs.push({ tool_name: "Edit", cwd: repo, tool_input: { file_path: abs(repo, OLD), old_string: "puts 1\n", new_string: "puts 2\n" } });
    for (const input of inputs) {
      const r = h.runHook(input);
      assert.strictEqual(r.decision, "approve", `${input.tool_input.file_path}: ${hookShow(r)}`);
      assert.strictEqual(warnLines(r.context + r.reason).length, 0, `${input.tool_input.file_path}: ${hookShow(r)}`);
    }
  });
}

function commitTimeNegatives(h) {
  test("(control) no CASE_MARKER_READER_UNSUPPORTED at commit time for unmatched, existing, archive or lib files", () => {
    const repo = h.mkRepo({ [OLD]: BODY });
    h.writeRel(repo, OLD, BODY.replace("puts 1", "puts 2"));
    for (const rel of NEG_NEW) h.writeRel(repo, rel, rel.endsWith(".json") ? "{}\n" : BODY);
    h.git(repo, "add", "--", OLD, ...NEG_NEW);
    const p = h.runPrecommitCaseMarkers(repo);
    const pshow = `rc=${p.rc} stdout=[${p.stdout}] stderr=[${p.stderr}]`;
    assert.strictEqual(p.rc, 0, pshow);
    assert.strictEqual(warnLines(p.stdout + p.stderr).length, 0, pshow);
  });
}

module.exports = { editTimeWarn, commitTimeWarn, editTimeNegatives, commitTimeNegatives };
