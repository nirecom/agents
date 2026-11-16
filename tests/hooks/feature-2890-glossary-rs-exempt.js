"use strict";
// Tests: hooks/workflow-state/glossary-check/scope/artifact.js, bin/check-glossary-drift
// Tags: TL2, hooks, glossary, glossary-check, append-only, scope:issue-specific
// #2890: the append-only records (docs/changelog/, docs/history/, docs/history.md, root CHANGELOG.md)
// are stream records that are never rewritten, so a drift finding there cannot be fixed; they must
// never enter an R-S scope, whatever step classify() gives them. Look-alikes and the retired
// changelog/ stay in. classify is a constant in R1, so the exclusion is checked apart from it.
// TL3 gap (what this test does NOT catch):
// - a real commit of a records-only change pushed through the commit gate by a claude session.
// Fixture: tests/lib/glossary-check-fixture.js.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const { noNewFailures } = require("../lib/case-verdict");

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { after, test } = require("node:test");

const restoreIsolation = isolate();
process.env.CLAUDE_TRANSCRIPT_BASE_DIR = fs.mkdtempSync(path.join(os.tmpdir(), "g2890-transcripts-"));
delete process.env.CLAUDE_PROJECT_DIR;
delete process.env.CLAUDE_CODE_SESSION_ID;
process.chdir(os.tmpdir());

const F = require("../lib/glossary-check-fixture");
const { loadStepInputs } = require(path.join(F.ROOT, "hooks/workflow-state/glossary-check/scope"));

const WORD = F.VARIANT;
const BODY = `# Note\n\nEach ${WORD} is checked.\n`;
const DRIFT_RE = /DRIFT: (\S+) "([^"]*)" -> "([^"]*)" at (.+):(\d+)\s*$/;
const driftFiles = (text) => String(text).split(/\r?\n/).map((l) => DRIFT_RE.exec(l)).filter(Boolean).map((m) => F.slash(m[4]));

// An exception inside a case counts as one failure, so the verdict sees it.
function guarded(name, fn) {
  try {
    fn();
  } catch (e) {
    F.check(`${name} ran to the end`, false, (e && e.stack) || e);
  }
}
const verdict = (label, fn) => () => noNewFailures(F.failureCount, () => guarded(label, fn));
after(() => {
  restoreIsolation();
  F.finish();
});

function load(sid, step, repoDir) {
  const r = loadStepInputs(sid, step, { repoDir });
  if (!r.ok) throw new Error(`loadStepInputs(${step}) failed: ${r.error} ${r.detail || ""}`);
  return r;
}
const pathsOf = (loaded) => loaded.artifact.files.map((f) => f.path);
const dry = (sid, step, cwd) => F.drift(sid, step, cwd, false);

const RECORDS = ["CHANGELOG.md", "docs/changelog/2026.md", "docs/history.md", "docs/history/2025.md"];
// No case variant: on a case-insensitive file system docs/Changelog/ is the docs/changelog/ record dir.
const LOOKALIKES = ["changelog/2026.md", "docs/changelog-x.md", "docs/historyx.md", "sub/CHANGELOG.md", "tests/foo-changelog.md"];

caseBegin("append-only records are left out of every staged-file scope", "hooks/workflow-state/glossary-check/scope/artifact.js");
test("R1: append-only records are left out of every staged-file scope", verdict("R1", () => {
  const { artifactRS } = require(path.join(F.ROOT, "hooks/workflow-state/glossary-check/scope/artifact.js"));
  const repo = F.mkRepo("r1");
  for (const rel of RECORDS.concat(LOOKALIKES)) F.stageFile(repo, rel, BODY);
  for (const step of ["review_docs", "review_security"]) {
    const r = artifactRS(repo, step, () => step);
    const got = r.ok ? r.artifact.files.map((f) => f.path) : [];
    F.check(`R1 ${step}: scope is exactly the look-alikes`, r.ok && JSON.stringify(got) === JSON.stringify([...LOOKALIKES].sort()), JSON.stringify(r.ok ? got : r));
  }
}));
caseEnd();

caseBegin("a records-only commit leaves the docs scope empty and the drift check quiet", "bin/check-glossary-drift");
test("R2: a records-only commit leaves the docs scope empty and the drift check quiet", verdict("R2", () => {
  const repo = F.mkRepo("r2");
  for (const rel of ["docs/changelog/2026.md", "docs/history/2025.md", "docs/history.md"]) F.stageFile(repo, rel, BODY);
  const sid = F.seedSession("r2", "review_docs", { cwd: repo });
  const docs = load(sid, "review_docs", repo);
  F.check("R2 review_docs scope is empty", docs.artifact.empty === true && pathsOf(docs).length === 0, JSON.stringify(pathsOf(docs)));
  const d = dry(sid, "review_docs", repo);
  F.check("R2 check-glossary-drift --step review_docs exits 0 with no DRIFT line", d.code === 0 && driftFiles(d.out).length === 0, `exit=${d.code} ${d.out}${d.err}`);
  F.stageFile(repo, "docs/changelog-notes.md", BODY);
  const control = dry(sid, "review_docs", repo);
  F.check("R2 control: a look-alike docs file is still reported", control.code === 1 && driftFiles(control.out).includes("docs/changelog-notes.md"), `exit=${control.code} ${control.out}`);
}));
caseEnd();
