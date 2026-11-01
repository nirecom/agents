"use strict";
// Tests: hooks/workflow-state/glossary-check/scope/artifact.js, bin/check-glossary-drift, hooks/workflow-mark/glossary-accept-handler.js, hooks/workflow-gate/glossary-record-checker.js
// Tags: TL2, hooks, glossary, glossary-check, merge, fingerprint, commit-gate, scope:issue-specific
// #2761 C group: during a merge, --record, stageFingerprint, the GLOSSARY_ACCEPTED grant, the
// commit gate and the completion boundary all see the same narrowed artifact, so their
// fingerprints agree; an undecidable merge state agrees too (every staged path on both sides).
// TL3 gap (what this test does NOT catch):
// - the real commit gate hook firing on a merge commit issued by a claude session.
// Fixtures: tests/lib/glossary-check-fixture.js, tests/bin/feat-2529-glossary-drift/fixture.js,
// tests/hooks/feat-2529-glossary-commit-gate/gate.js, ./feat-2761-glossary-merge/fixture.js.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const { noNewFailures } = require("../lib/case-verdict");

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { after, test } = require("node:test");

const restoreIsolation = isolate();
process.env.CLAUDE_TRANSCRIPT_BASE_DIR = fs.mkdtempSync(path.join(os.tmpdir(), "g2761-transcripts-"));
delete process.env.CLAUDE_PROJECT_DIR;
delete process.env.CLAUDE_CODE_SESSION_ID;
process.chdir(os.tmpdir());

const F = require("../lib/glossary-check-fixture");
const D = require("../bin/feat-2529-glossary-drift/fixture");
const G = require("./feat-2529-glossary-commit-gate/gate");
const M = require("./feat-2761-glossary-merge/fixture");
const { stageFingerprint } = require(path.join(F.ROOT, "hooks/workflow-state/glossary-check/scope"));

const WORD = F.VARIANT;
after(() => {
  restoreIsolation();
  F.finish();
});

function guarded(name, fn) {
  try {
    fn();
  } catch (e) {
    F.check(`${name} ran to the end`, false, (e && e.stack) || e);
  }
}
// The case fails when any F.check inside it (or an exception, via guarded) adds a failure.
const verdict = (label, fn) => () => noNewFailures(F.failureCount, () => guarded(label, fn));

const fpNow = (sid, stage, repo) => stageFingerprint(sid, stage, { repoDir: repo });

// The fingerprint stageFingerprint computes now equals the one the stage's record holds.
function fpAgrees(label, sid, stage, repo, rec) {
  const now = fpNow(sid, stage, repo);
  return F.check(`${label}: stageFingerprint equals the recorded fingerprint`,
    now.ok && !!rec && rec.fingerprint === now.fingerprint, `${JSON.stringify(now)} vs ${rec && rec.fingerprint}`);
}

// Standard merge + a session at docs with review_tests / review_security / review_docs complete.
function completedMergeSession(tag) {
  const repo = F.mkRepo(tag);
  M.standardMerge(repo, WORD);
  const sid = F.seedSession(tag, "docs", { cwd: repo, ownStatus: "complete" });
  F.appendRaw(sid, [F.stepStatusEvent("review_tests", "complete"), F.stepStatusEvent("review_security", "complete")]);
  G.recordReviewScope(sid, repo);
  return { repo, sid };
}

caseBegin("record and stageFingerprint agree during a merge", "bin/check-glossary-drift");
test("C1: record and stageFingerprint agree during a merge", verdict("C1", () => {
  const repo = F.mkRepo("c1");
  M.standardMerge(repo, WORD);
  const sid = F.seedSession("c1", "docs", { cwd: repo });
  const r = F.drift(sid, "docs", repo);
  F.check("C1 --record exits 1 on the resolved file's drift", r.code === 1, `exit=${r.code} ${r.out}${r.err}`);
  const rec = F.recordOf(sid, "docs");
  fpAgrees("C1", sid, "docs", repo, rec);
  F.check("C1 the record's findings come from docs/shared.md only",
    !!rec && rec.findings.length > 0 && rec.findings.every((f) => /docs\/shared\.md/.test(String(f.where || f.path || ""))), JSON.stringify(rec && rec.findings));
}));
caseEnd();

caseBegin("commit gate judges the narrowed stages", "hooks/workflow-gate/glossary-record-checker.js");
test("C2: commit gate judges the narrowed stages", verdict("C2", () => {
  const s = completedMergeSession("c2");
  G.recordOk("C2 docs", F.drift(s.sid, "docs", s.repo), 1);
  const after = G.scan(s.sid, s.repo);
  G.blocks("C2 docs record with the resolved file's finding", after, "review_docs", "glossary-findings-unresolved", "docs");
  G.passes("C2 review_security without a record (code empty after subtraction)", after, "review_security");
  G.passes("C2 review_tests without a record (tests empty after subtraction)", after, "review_tests");
  F.check("C2 matching grant written", F.grantFindings(s.sid, "docs"), "no record to grant");
  G.passes("C2 docs after the grant", G.scan(s.sid, s.repo), "review_docs");
}));
caseEnd();

caseBegin("completion boundary still asks for a record of an empty narrowed stage", "hooks/workflow-state/glossary-check/scope/artifact.js");
test("C3: completion boundary still asks for a record of an empty narrowed stage", verdict("C3", () => {
  const repo = F.mkRepo("c3");
  M.standardMerge(repo, WORD);
  const sid = F.seedSession("c3", "code", { cwd: repo });
  const first = F.completeInProcess(sid, "review_security", repo);
  F.check("C3 review_security complete without a record is refused with glossary-check-missing",
    F.refusedWith(first, "glossary-check-missing"), JSON.stringify(first));
  const r = F.drift(sid, "code", repo);
  F.check("C3 --record of the empty code stage exits 0 with no finding",
    r.code === 0 && !!F.recordOf(sid, "code") && F.recordOf(sid, "code").findings.length === 0, `exit=${r.code} ${r.out}${r.err}`);
  const second = F.completeInProcess(sid, "review_security", repo);
  F.check("C3 review_security completes after the empty record", second.ok === true && F.statusOf(sid, "review_security") === "complete",
    JSON.stringify(second));
}));
caseEnd();

caseBegin("GLOSSARY_ACCEPTED grant binds to the narrowed fingerprint", "hooks/workflow-mark/glossary-accept-handler.js");
test("C4: GLOSSARY_ACCEPTED grant binds to the narrowed fingerprint", verdict("C4", () => {
  const variant = D.TERM.replace(/ /g, "-");
  const repo = D.mkRepo("c4");
  M.standardMerge(repo, variant);
  const sid = D.newSid("c4");
  D.writeIntent(sid);
  D.seedAt(sid, "review_docs", repo);
  const r = D.drift(sid, "docs", repo, true);
  const rec = D.recordOf(sid, "docs");
  F.check("C4 precondition: --record wrote a docs record with a finding", D.reached(r) && !!rec && rec.findings.length > 0, `exit=${r.code} ${r.all}`);
  fpAgrees("C4 record", sid, "docs", repo, rec);
  const m = D.mark(sid, D.accepted(D.TERM, "stage=docs", "user accepted this spelling"), repo);
  const grants = (D.recordOf(sid, "docs") || {}).grants || [];
  F.check("C4 the grant's fingerprint is the record's fingerprint",
    grants.length === 1 && !!rec && grants[0].fingerprint === rec.fingerprint, `${JSON.stringify(grants)} ${m.all}`);
  fpAgrees("C4 grant", sid, "docs", repo, { fingerprint: grants[0] && grants[0].fingerprint });
  D.appendRaw(sid, [D.statusEvent("review_docs", "complete")]);
  G.passes("C4 commit gate after the grant", G.scan(sid, repo), "review_docs");
}));
caseEnd();

caseBegin("undecidable merge state agrees between record and gate", "hooks/workflow-gate/glossary-record-checker.js");
test("C5: undecidable merge state agrees between record and gate", verdict("C5", () => {
  const repo = F.mkRepo("c5");
  M.standardMerge(repo, WORD);
  M.corruptMergeHead(repo);
  const sid = F.seedSession("c5", "docs", { cwd: repo, ownStatus: "complete" });
  G.recordOk("C5 docs (undecidable)", F.drift(sid, "docs", repo), 1);
  const rec = F.recordOf(sid, "docs");
  fpAgrees("C5", sid, "docs", repo, rec);
  F.check("C5 the record holds the docs/main-only.md finding (every staged path scanned)",
    !!rec && rec.findings.some((f) => /docs\/main-only\.md/.test(String(f.where || f.path || ""))), JSON.stringify(rec && rec.findings));
  const gate = G.scan(sid, repo);
  F.check("C5 the gate does not call the record stale", !/glossary-check-stale/.test(G.reasonOf(gate, "review_docs")), G.reasonOf(gate, "review_docs"));
  F.check("C5 matching grant written", F.grantFindings(sid, "docs"), "no record to grant");
  G.passes("C5 docs after the grant", G.scan(sid, repo), "review_docs");
}));
caseEnd();
