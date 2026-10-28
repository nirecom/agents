"use strict";
// Tests: bin/lib/glossary-provenance.js, hooks/workflow-state/completion-approval.js, bin/check-glossary-provenance
// Tags: TL2, bin, glossary, provenance, approval, toctou, scope:issue-specific
// T3-7: the intent rows are pinned to the CONFIRM_INTENT-approved bytes — any `## Glossary`
// change after approval is P/intent-modified, a missing / non-confirm / inherited / unreadable
// approval is P/intent-unapproved, `## Issues` edits stay approved, and the sha and the parse
// come from one read of the same bytes.

const { caseBegin, caseEnd } = require("../../lib/harness");
const fs = require("fs");
const { check, eq, ok, DEFS, mkRepo, stageUser, newSid, intentPath, statePath, intentText, writeIntent,
  intentSha, writeState, approvedSession, reapprove, blockedOf, provRecord, prov, accept, has, mod } = require("./common");

const gp = () => mod("bin/lib/glossary-provenance.js");
const ROWS = [["beta", "user", "add", "A pinned fixture term."], ["omega", "user", "delete", ""]];
const termsOf = (res) => ((res && res.rows) || []).map((r) => `${String(r.term).toLowerCase()}/${r.operation}`).sort();

caseBegin("t3-7-approved-bytes-are-read", "bin/lib/glossary-provenance.js");
function approvedBytes() {
  const sid = approvedSession("pin-ok", ROWS);
  check("T3-7 the approved intent.md as is: loadIntentGlossary returns its rows and the approval sha", () => {
    const res = gp().loadIntentGlossary(sid);
    eq(res && res.ok, true, `result: ${JSON.stringify(res)}`);
    eq(termsOf(res), ["beta/add", "omega/delete"], "rows");
    eq(res.approvalSha, intentSha(sid), "approvalSha");
  });
}
caseEnd();

caseBegin("t3-7-glossary-change-after-approval", "bin/lib/glossary-provenance.js");
function modifiedAfterApproval() {
  const variants = [
    ["a row added", ROWS.concat([["gamma", "user", "add", "Late row."]])],
    ["a row removed", ROWS.slice(0, 1)],
    ["a definition changed", [["beta", "user", "add", "A pinned fixture term, changed."], ROWS[1]]],
  ];
  for (const [name, rows] of variants) {
    const sid = approvedSession("pin-mod", ROWS);
    writeIntent(sid, rows);
    check(`T3-7 ${name} after approval -> case P, intent-modified`, () => {
      const res = gp().loadIntentGlossary(sid);
      eq(res && [res.ok, res.case, res.reason], [false, "P", "intent-modified"], `result: ${JSON.stringify(res)}`);
    });
  }
  const sid = approvedSession("pin-issues", ROWS);
  writeIntent(sid, ROWS, { issues: "- #1 fixture\n- #2 back-filled after approval" });
  check("T3-7 an `## Issues`-only change after approval stays approved", () => {
    const res = gp().loadIntentGlossary(sid);
    eq(res && res.ok, true, `result: ${JSON.stringify(res)}`);
  });
}
caseEnd();

caseBegin("t3-7-intent-modified-at-the-gate", "bin/check-glossary-provenance");
function modifiedAtTheGate() {
  const repo = mkRepo("pin-cli");
  stageUser(repo, [["alpha", DEFS.alpha], ["beta", "A pinned fixture term."], ["omega", DEFS.omega]]);
  const sid = approvedSession("pin-cli", [["gamma", "user", "add", "Unrelated."]], { cwd: repo });
  writeIntent(sid, [["beta", "user", "add", "A pinned fixture term."]]);
  check("T3-7 a row added after approval does not admit the matching hand-written add (intent-modified)", () => {
    const r = prov(repo, sid);
    eq(r.code, 1, `exit (out: ${r.all})`);
    ok(has(blockedOf(sid), "beta", "add", "user", "intent-modified"), `record: ${JSON.stringify(provRecord(sid))}`);
  });
  check("T3-7 GLOSSARY_ACCEPTED on the intent-modified block, then the gate passes", () => {
    eq(accept(sid, repo, "beta", "op=add cat=user").code, 0, "hook exit");
    eq(prov(repo, sid).code, 0, "re-run exit");
  });
  check("T3-7 CONFIRM_INTENT taken again over the new intent: the new rows are matched", () => {
    const repo2 = mkRepo("pin-reapprove");
    stageUser(repo2, [["alpha", DEFS.alpha], ["beta", "A pinned fixture term."], ["omega", DEFS.omega]]);
    const sid2 = approvedSession("pin-reapprove", [["gamma", "user", "add", "Unrelated."]], { cwd: repo2 });
    writeIntent(sid2, [["beta", "user", "add", "A pinned fixture term."]]);
    reapprove(sid2);
    const res = gp().loadIntentGlossary(sid2);
    eq(res && res.ok, true, `result: ${JSON.stringify(res)}`);
    eq(prov(repo2, sid2).code, 0, "gate exit after re-approval");
  });
}
caseEnd();

caseBegin("t3-7-unapproved-intent", "bin/lib/glossary-provenance.js");
function unapproved() {
  const cases = [
    ["no approval record", { approval: false }],
    ["a reset-sentinel approval (no sha)", { approval: { source: "reset-sentinel", artifact_sha256: null, artifact_session_id: null, artifact_hash_status: "unknown" } }],
    ["a session-inherit approval (no sha)", { approval: { source: "session-inherit", artifact_sha256: null, artifact_session_id: null, artifact_hash_status: "unknown" } }],
    ["an approval whose artifact_session_id is another session", { approval: { artifact_session_id: "p2529-someone-else" } }],
  ];
  for (const [name, opts] of cases) {
    const sid = newSid("pin-unapproved");
    writeIntent(sid, ROWS);
    writeState(sid, opts);
    check(`T3-7 ${name} -> case P, intent-unapproved`, () => {
      const res = gp().loadIntentGlossary(sid);
      eq(res && [res.ok, res.case, res.reason], [false, "P", "intent-unapproved"], `result: ${JSON.stringify(res)}`);
    });
  }
  const sid = approvedSession("pin-corrupt", ROWS);
  fs.writeFileSync(statePath(sid), "{ this is not json");
  check("T3-7 a corrupt state file -> case P, intent-unapproved", () => {
    const res = gp().loadIntentGlossary(sid);
    eq(res && [res.ok, res.case, res.reason], [false, "P", "intent-unapproved"], `result: ${JSON.stringify(res)}`);
  });
}
caseEnd();

caseBegin("t3-7-one-read-for-sha-and-parse", "bin/lib/glossary-provenance.js");
function oneReadForShaAndParse() {
  const sid = approvedSession("pin-toctou", ROWS);
  const approved = fs.readFileSync(intentPath(sid));
  writeIntent(sid, ROWS.concat([["swapped", "user", "add", "Swapped in between."]]));
  check("T3-7 content swapped between the sha and the parse is never admitted", () => {
    const real = fs.readFileSync;
    let reads = 0;
    const target = intentPath(sid).replace(/\\/g, "/");
    fs.readFileSync = function stub(p, ...rest) {
      if (typeof p === "string" && p.replace(/\\/g, "/") === target) {
        reads += 1;
        if (reads === 1) return rest.length && (rest[0] === "utf8" || (rest[0] && rest[0].encoding)) ? approved.toString("utf8") : Buffer.from(approved);
      }
      return real.call(fs, p, ...rest);
    };
    let res;
    try { res = gp().loadIntentGlossary(sid); } finally { fs.readFileSync = real; }
    ok(!termsOf(res).includes("swapped/add"), `the swapped row was admitted: ${JSON.stringify(res)}`);
  });
}
caseEnd();

caseBegin("t3-7-artifact-buffer-helpers", "hooks/workflow-state/completion-approval.js");
function artifactBufferHelpers() {
  const ca = () => require("../../../hooks/workflow-state/completion-approval.js");
  const sid = approvedSession("pin-sha", ROWS);
  check("T3-7 shaOfArtifactBuffer over the file bytes equals computeArtifactSha (unchanged behaviour)", () => {
    ok(typeof ca().shaOfArtifactBuffer === "function", "shaOfArtifactBuffer is not exported");
    eq(ca().shaOfArtifactBuffer(fs.readFileSync(intentPath(sid)), "clarify_intent"), ca().computeArtifactSha(sid, "clarify_intent"));
  });
  check("T3-7 artifactRangeOfBuffer drops the `## Issues` section of the intent", () => {
    ok(typeof ca().artifactRangeOfBuffer === "function", "artifactRangeOfBuffer is not exported");
    const range = ca().artifactRangeOfBuffer(Buffer.from(intentText(ROWS, { issues: "- #42 marker-issue" })), "clarify_intent").toString("utf8");
    ok(!range.includes("marker-issue") && range.includes("## Glossary"), `range: ${range}`);
  });
  check("T3-7 an `## Issues`-only change keeps computeArtifactSha", () => {
    const before = ca().computeArtifactSha(sid, "clarify_intent");
    writeIntent(sid, ROWS, { issues: "- #1 fixture\n- #9 added later" });
    eq(ca().computeArtifactSha(sid, "clarify_intent"), before);
  });
}
caseEnd();

module.exports = { approvedBytes, modifiedAfterApproval, modifiedAtTheGate, unapproved, oneReadForShaAndParse, artifactBufferHelpers };
