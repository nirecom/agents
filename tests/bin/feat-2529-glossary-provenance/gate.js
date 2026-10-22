"use strict";
// Tests: hooks/workflow-gate/review-docs-checker.js, bin/review-doc-gates, bin/review-doc-glossary, hooks/workflow-gate/commit-gate-steps.js
// Tags: TL2, hooks, bin, glossary, provenance, commit-gate, scope:issue-specific
// T3-4: --session travels review-docs-checker -> review-doc-gates -> review-doc-glossary ->
// check-glossary-provenance; a hand-written add stops at the commit gate; a sid that fails
// SESSION_ID_VALID_RE is not forwarded, so the CLI resolves the env session as B.

const { caseBegin, caseEnd } = require("../../lib/harness");
const fs = require("fs");
const path = require("path");
const { check, eq, ok, ROOT, DEFS, mkRepo, stageUser, approvedSession, provRecord, blockedOf, runBash, has } = require("./common");

const BETA = "A gate fixture term.";
function handAdd(tag) {
  const repo = mkRepo(tag);
  stageUser(repo, [["alpha", DEFS.alpha], ["beta", BETA], ["omega", DEFS.omega]]);
  return repo;
}
const checker = () => require(path.join(ROOT, "hooks/workflow-gate/review-docs-checker.js"));
function gate(repo, sessionId) {
  return checker().checkReviewDocs("review_docs", { status: "complete" }, { repoDir: repo, sessionId });
}

caseBegin("t3-4-checker-forwards-the-session", "hooks/workflow-gate/review-docs-checker.js");
function checkerForwardsSession() {
  const repo = handAdd("gate-row");
  const withRow = approvedSession("gate-row", [["beta", "user", "add", BETA]], { cwd: repo });
  check("T3-4 checker: a valid sid whose approved intent has the add row -> skip", () => {
    eq(gate(repo, withRow).action, "skip", "action");
  });

  const repo2 = handAdd("gate-norow");
  const noRow = approvedSession("gate-norow", [["gamma", "user", "add", "Another term."]], { cwd: repo2 });
  check("T3-4 checker: a hand-written add with no intent row is blocked at the commit gate", () => {
    const g = gate(repo2, noRow);
    eq(g.action, "block", `action (${JSON.stringify(g)})`);
    eq(g.reason, "doc-gates-failed", "reason");
  });
  check("T3-4 checker: the block was judged on the forwarded session (blocked beta add user: not-in-intent)", () => {
    ok(has(blockedOf(noRow), "beta", "add", "user", "not-in-intent"), `record: ${JSON.stringify(provRecord(noRow))}`);
    eq(provRecord(noRow).session_source, "explicit", "session_source");
  });
}
caseEnd();

caseBegin("t3-4-invalid-sid-falls-to-b", "hooks/workflow-gate/review-docs-checker.js");
function invalidSidFallsToB() {
  const repo = handAdd("gate-bad-sid");
  const envSid = approvedSession("gate-bad-sid", [["beta", "user", "add", BETA]], { cwd: repo });
  check("T3-4 checker: an invalid sid is not forwarded; the CLI records B on the env session", () => {
    const saved = process.env.CLAUDE_CODE_SESSION_ID;
    process.env.CLAUDE_CODE_SESSION_ID = envSid;
    let g;
    try { g = gate(repo, "not a valid/sid"); } finally {
      if (saved === undefined) delete process.env.CLAUDE_CODE_SESSION_ID;
      else process.env.CLAUDE_CODE_SESSION_ID = saved;
    }
    eq(g.action, "block", `action (${JSON.stringify(g)})`);
    const rec = provRecord(envSid);
    ok(rec && rec.session_source === "env", `record: ${JSON.stringify(rec)}`);
    ok(has(rec.blocked || [], "beta", "add", "user", "session-unverified"), `blocked: ${JSON.stringify(rec.blocked)}`);
  });
}
caseEnd();

caseBegin("t3-4-doc-gate-scripts-forward-the-session", "bin/review-doc-gates");
function scriptsForwardSession() {
  const repo = handAdd("gates-cli");
  const withRow = approvedSession("gates-cli-row", [["beta", "user", "add", BETA]], { cwd: repo });
  const noRow = approvedSession("gates-cli-norow", [], { cwd: repo });
  for (const script of ["bin/review-doc-gates", "bin/review-doc-glossary"]) {
    check(`T3-4 ${script} --staged --session <sid without the row> blocks (exit 1)`, () => {
      const r = runBash(script, ["--staged", "--session", noRow], { cwd: repo });
      eq(r.code, 1, `exit (out: ${r.all})`);
    });
    check(`T3-4 ${script} --staged --session <sid with the row> passes (exit 0)`, () => {
      const r = runBash(script, ["--staged", "--session", withRow], { cwd: repo });
      eq(r.code, 0, `exit (out: ${r.all})`);
    });
  }
}
caseEnd();

caseBegin("t3-4-session-wiring-in-source", "hooks/workflow-gate/commit-gate-steps.js");
function staticWiring() {
  const read = (rel) => fs.readFileSync(path.join(ROOT, rel), "utf8");
  check("T3-4 review-doc-gates hands --session to review-doc-glossary only", () => {
    const lines = read("bin/review-doc-gates").split(/\r?\n/);
    const call = (name) => lines.filter((l) => l.includes(`/${name}"`) && !/^\s*#/.test(l));
    ok(call("review-doc-glossary").some((l) => /session/i.test(l)), "review-doc-glossary call carries no session");
    ok(call("review-doc-size").length > 0 && call("review-doc-size").every((l) => !/session/i.test(l)), "review-doc-size gets the session");
    ok(call("review-doc-heading-order").length > 0 && call("review-doc-heading-order").every((l) => !/session/i.test(l)), "review-doc-heading-order gets the session");
  });
  check("T3-4 commit-gate-steps passes sessionId to checkReviewDocs", () => {
    ok(/checkReviewDocs\([^)]*sessionId/.test(read("hooks/workflow-gate/commit-gate-steps.js")), "no sessionId in the checkReviewDocs call");
  });
}
caseEnd();

module.exports = { checkerForwardsSession, invalidSidFallsToB, scriptsForwardSession, staticWiring };
