#!/usr/bin/env node
"use strict";
// Tests: bin/lib/glossary-format/files.js, bin/lib/glossary-format/cli.js, hooks/workflow-state/glossary-check/scope/sources.js, bin/lib/codex-glossary.sh
// Tags: TL2, bin, glossary, paths, fail-closed, scope:issue-specific
// #2529 review fix: a .md file directly under docs/glossary/ whose name does not parse
// (docs/glossary/misc.md) is never dropped silently by the combined-glossary readers.
// listMainGlossaryFiles throws an error naming the file; the fingerprint reader turns it into
// glossary-unavailable (fail-closed), prompt-data exits 2 with the message on stderr, and the
// codex block keeps its existing fail-open shape (instruction part only). The docs/glossary.md
// index outside the directory stays excluded. The legacy-layout counterpart lives in the
// migration test, tests/bin/feat-2529-glossary-legacy-read.sh (L8).

// TL3 gap: a real codex review run is not driven; codex_glossary_block is sourced and called.

const { caseBegin, caseEnd } = require("../lib/harness");
const { noNewFailures } = require("../lib/case-verdict");
const { spawnSync } = require("child_process");
const fs = require("fs");
const path = require("path");
const { after, test } = require("node:test");
const c = require("./feat-2529-glossary-provenance/common");

const { check, eq, ok, ROOT, TMP, fwd, totals, mod } = c;
const fails = () => totals.failed;
after(() => process.stdout.write(`Total: ${totals.passed} passed, ${totals.failed} failed\n`));
const MISC = "docs/glossary/misc.md";
const UNPARSEABLE = /docs\/glossary\/misc\.md: unparseable glossary file name/;

function codexCfg() {
  const dir = path.join(TMP, "codex-cfg");
  if (fs.existsSync(dir)) return fwd(dir);
  fs.mkdirSync(path.join(dir, "rules"), { recursive: true });
  fs.cpSync(path.join(ROOT, "bin", "lib"), path.join(dir, "bin", "lib"), { recursive: true });
  fs.copyFileSync(path.join(ROOT, "rules", "core-principles.md"), path.join(dir, "rules", "core-principles.md"));
  fs.writeFileSync(path.join(dir, ".env"), "CODE_LANG=english\n");
  return fwd(dir);
}
function codexBlock(projectRoot) {
  const script = 'source "$1/bin/lib/codex-core.sh" >/dev/null 2>&1 || exit 3; ' +
    'source "$1/bin/lib/codex-glossary.sh" >/dev/null 2>&1 || exit 3; ' +
    'declare -F codex_glossary_block >/dev/null || exit 4; codex_glossary_block "$2"';
  const r = spawnSync("bash", ["-c", script, "_", fwd(ROOT), fwd(projectRoot)], {
    cwd: TMP, encoding: "utf8", timeout: 60000, env: c.childEnv({ AGENTS_MAIN_ROOT: codexCfg() }),
  });
  return { code: r.status, out: (r.stdout || "").replace(/\r/g, "") };
}

const files = () => mod("bin/lib/glossary-format/files.js");
const sources = () => mod("hooks/workflow-state/glossary-check/scope/sources.js");

// Fixture repos built by the first two cases and read by the later ones (cases run in order).
let control = null;
let bad = null;

caseBegin("invalid-name-index-outside-the-directory-stays-excluded", "bin/lib/glossary-format/files.js");
test("invalid-name-index-outside-the-directory-stays-excluded", () => noNewFailures(fails, () => {
  control = c.mkRepo("control");
  c.writeFile(control, "docs/glossary.md", "# Glossary\n\nIndex: see docs/glossary/.\n");
  check("control: listMainGlossaryFiles lists the two entry files, not the docs/glossary.md index", () => {
    const listed = files().listMainGlossaryFiles(control);
    eq(listed.files.map((f) => f.label).join(","), "docs/glossary/internal.md,docs/glossary/user.md", "labels");
    eq(listed.legacy, false, "legacy");
  });
  check("control: combinedGlossary reads the glossary (ok)", () => {
    const g = sources().combinedGlossary({ repoDir: control });
    ok(g.ok === true, JSON.stringify(g));
  });
}));
caseEnd();

caseBegin("invalid-name-listMainGlossaryFiles-throws-naming-the-file", "bin/lib/glossary-format/files.js");
test("invalid-name-listMainGlossaryFiles-throws-naming-the-file", () => noNewFailures(fails, () => {
  bad = c.mkRepo("misc");
  c.writeFile(bad, MISC, c.glossaryText("misc", [["zulu", "A misplaced term."]]));
  check("listMainGlossaryFiles throws an error naming docs/glossary/misc.md", () => {
    let err = null;
    try { files().listMainGlossaryFiles(bad); } catch (e) { err = e; }
    ok(err !== null, "no error thrown (misc.md dropped silently)");
    ok(UNPARSEABLE.test(String(err && err.message)), `message: ${err && err.message}`);
  });
  check("the message is the one check-files BLOCKs with (one wording)", () => {
    const blocks = files().checkFileSet([MISC]);
    let err = null;
    try { files().listMainGlossaryFiles(bad); } catch (e) { err = e; }
    eq(String(err && err.message), blocks[0], "message");
  });
}));
caseEnd();

caseBegin("invalid-name-fingerprint-reader-fails-closed", "hooks/workflow-state/glossary-check/scope/sources.js");
test("invalid-name-fingerprint-reader-fails-closed", () => noNewFailures(fails, () => {
  check("combinedGlossary: glossary-unavailable with the file named in detail", () => {
    const g = sources().combinedGlossary({ repoDir: bad });
    eq(g.ok, false, `result: ${JSON.stringify(g)}`);
    eq(g.error, "glossary-unavailable", "error");
    ok(UNPARSEABLE.test(String(g.detail)), `detail: ${g.detail}`);
  });
}));
caseEnd();

caseBegin("invalid-name-prompt-data-exits-2-with-the-message", "bin/lib/glossary-format/cli.js");
test("invalid-name-prompt-data-exits-2-with-the-message", () => noNewFailures(fails, () => {
  check("prompt-data --root: exit 2, stderr names misc.md, no data on stdout", () => {
    const r = c.runNode("bin/lib/glossary-format.js", ["prompt-data", "--root", bad]);
    eq(r.code, 2, `exit (all: ${c.clip(r.all)})`);
    ok(UNPARSEABLE.test(r.err), `stderr: ${c.clip(r.err)}`);
    eq(r.out, "", "stdout");
  });
  check("prompt-data --root on the control repo still exits 0 with data (control)", () => {
    const r = c.runNode("bin/lib/glossary-format.js", ["prompt-data", "--root", control]);
    eq(r.code, 0, `exit (all: ${c.clip(r.all)})`);
    ok(/### alpha/.test(r.out), `out: ${c.clip(r.out)}`);
  });
}));
caseEnd();

caseBegin("invalid-name-codex-block-keeps-its-fail-open-shape", "bin/lib/codex-glossary.sh");
test("invalid-name-codex-block-keeps-its-fail-open-shape", () => noNewFailures(fails, () => {
  check("codex_glossary_block: the instruction part only, no data block, no misc.md term", () => {
    const b = codexBlock(bad);
    eq(b.code, 0, "probe exit (3 = not sourceable, 4 = function absent)");
    ok(!/COMBINED GLOSSARY START/.test(b.out), `block: ${c.clip(b.out)}`);
    ok(!/### zulu/.test(b.out), `block: ${c.clip(b.out)}`);
    ok(b.out.length > 0, "the instruction part is missing");
  });
}));
caseEnd();
