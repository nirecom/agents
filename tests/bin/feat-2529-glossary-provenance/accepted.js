"use strict";
// Tests: bin/check-glossary-provenance, hooks/workflow-mark/glossary-accept-handler.js
// Tags: TL2, bin, hooks, glossary, provenance, sentinel, grant, scope:issue-specific
// T3-6: a provenance BLOCK records blocked + fingerprint; GLOSSARY_ACCEPTED grants are bound to
// {norm, operation, category} and to the record's fingerprint, so another operation is not
// covered, a staged definition change blocks again, and stale grants are dropped on rewrite.

const { caseBegin, caseEnd } = require("../../lib/harness");
const { check, eq, ok, DEFS, mkRepo, stageUser, stageInternal, approvedSession, provRecord, blockedOf, prov, accept, has } = require("./common");

const BETA = "An accepted fixture term.";
const OTHER_ROW = [["gamma", "user", "add", "Unrelated term."]];
function handAdd(tag, def) {
  const repo = mkRepo(tag);
  stageUser(repo, [["alpha", DEFS.alpha], ["beta", def || BETA], ["omega", DEFS.omega]]);
  return repo;
}

caseBegin("t3-6-block-record-and-grant", "hooks/workflow-mark/glossary-accept-handler.js");
function blockRecordAndGrant() {
  const repo = handAdd("acc");
  const sid = approvedSession("acc", OTHER_ROW, { cwd: repo });
  let first;
  check("T3-6 a hand-written add with no intent row blocks (exit 1)", () => {
    first = prov(repo, sid);
    eq(first.code, 1, `exit (out: ${first.all})`);
  });
  check("T3-6 the block records blocked (beta add user) and a fingerprint", () => {
    const rec = provRecord(sid);
    ok(rec && typeof rec.fingerprint === "string" && rec.fingerprint.length > 0, `record: ${JSON.stringify(rec)}`);
    ok(has(rec.blocked || [], "beta", "add", "user", "not-in-intent"), `blocked: ${JSON.stringify(rec.blocked)}`);
  });
  check("T3-6 the block output gives the narrow echo form with op= and cat=", () => {
    ok(first && /WORKFLOW_GLOSSARY_ACCEPTED: term=beta op=add cat=user — /.test(first.all), `output: ${first && first.all}`);
  });
  check("T3-6 an ACCEPTED bound to another category grants nothing; the gate still blocks", () => {
    accept(sid, repo, "beta", "op=add cat=internal");
    eq(prov(repo, sid).code, 1, "exit after a non-matching grant");
  });
  check("T3-6 an ACCEPTED bound to another operation grants nothing; the gate still blocks", () => {
    accept(sid, repo, "beta", "op=delete cat=user");
    eq(prov(repo, sid).code, 1, "exit after a non-matching grant");
  });
  check("T3-6 GLOSSARY_ACCEPTED for beta add user, then the gate passes", () => {
    eq(accept(sid, repo, "beta", "op=add cat=user").code, 0, "hook exit");
    const r = prov(repo, sid);
    eq(r.code, 0, `exit (out: ${r.all})`);
  });
  check("T3-6 a staged definition change after the grant changes the fingerprint and blocks again", () => {
    stageUser(repo, [["alpha", DEFS.alpha], ["beta", "An accepted fixture term, revised."], ["omega", DEFS.omega]]);
    const r = prov(repo, sid);
    eq(r.code, 1, `exit (out: ${r.all})`);
  });
  check("T3-6 the rewritten record keeps no grant whose fingerprint differs", () => {
    const rec = provRecord(sid);
    ok(rec, "no record");
    const stale = (rec.grants || []).filter((g) => g.fingerprint !== rec.fingerprint);
    eq(stale, [], "stale grants");
  });
}
caseEnd();

caseBegin("t3-6-narrow-grants-on-a-move", "hooks/workflow-mark/glossary-accept-handler.js");
function movePair(tag) {
  const repo = mkRepo(tag);
  stageUser(repo, [["alpha", DEFS.alpha]]);
  stageInternal(repo, [["kilo", DEFS.kilo], ["omega", DEFS.omega]]);
  return { repo, sid: approvedSession(tag, [], { cwd: repo }) };
}

function narrowGrants() {
  const { repo, sid } = movePair("move");
  check("T3-6 a move pending (omega delete user + add internal) blocks both, with one narrow echo per pending", () => {
    const r = prov(repo, sid);
    eq(r.code, 1, `exit (out: ${r.all})`);
    ok(has(blockedOf(sid), "omega", "delete", "user") && has(blockedOf(sid), "omega", "add", "internal"), `blocked: ${JSON.stringify(blockedOf(sid))}`);
    ok(/term=omega op=delete cat=user — /.test(r.all) && /term=omega op=add cat=internal — /.test(r.all), `echo examples: ${r.all}`);
  });
  check("T3-6 ACCEPTED op=add cat=internal passes the add only; the delete still blocks", () => {
    eq(accept(sid, repo, "omega", "op=add cat=internal").code, 0, "hook exit");
    const r = prov(repo, sid);
    eq(r.code, 1, `exit (out: ${r.all})`);
    ok(/term=omega op=delete cat=user/.test(r.all), `the delete must still be pending: ${r.all}`);
    ok(!/term=omega op=add cat=internal/.test(r.all), `the add must no longer be pending: ${r.all}`);
  });
  check("T3-6 adding ACCEPTED op=delete cat=user passes both", () => {
    eq(accept(sid, repo, "omega", "op=delete cat=user").code, 0, "hook exit");
    eq(prov(repo, sid).code, 0, "exit");
  });

  const bare = movePair("move-bare");
  check("T3-6 a bare ACCEPTED (no op= / cat=) passes both pendings of the term", () => {
    eq(prov(bare.repo, bare.sid).code, 1, "first run exit");
    eq(accept(bare.sid, bare.repo, "omega", "").code, 0, "hook exit");
    eq(prov(bare.repo, bare.sid).code, 0, "re-run exit");
  });
}
caseEnd();

caseBegin("t3-6-b-grants-follow-the-same-rules", "bin/check-glossary-provenance");
function bGrantSameRules() {
  const repo = handAdd("acc-b");
  const sid = approvedSession("acc-b", [["beta", "user", "add", BETA]], { cwd: repo });
  const env = { env: { CLAUDE_CODE_SESSION_ID: sid } };
  check("T3-6 B: a grant on the env session passes the env-only re-run", () => {
    eq(prov(repo, null, env).code, 1, "B exit");
    eq(accept(sid, repo, "beta", "op=add cat=user").code, 0, "hook exit");
    eq(prov(repo, null, env).code, 0, "re-run exit");
  });
  check("T3-6 B: a staged definition change after the grant blocks the env-only run again", () => {
    stageUser(repo, [["alpha", DEFS.alpha], ["beta", "An accepted fixture term (B revised)."], ["omega", DEFS.omega]]);
    eq(prov(repo, null, env).code, 1, "exit");
    const rec = provRecord(sid);
    eq((rec.grants || []).filter((g) => g.fingerprint !== rec.fingerprint), [], "stale grants");
  });
}
caseEnd();

// #2770: a grant moves to the new fingerprint when only ops changed and the blocked set did not
// grow or change; a new blocked entry for the granted norm drops it.
const GAMMA_ROW = [["gamma", "user", "add", "Unrelated term."]];
function grantedBeta(tag) {
  const repo = handAdd(tag);
  const sid = approvedSession(tag, GAMMA_ROW, { cwd: repo });
  eq(prov(repo, sid).code, 1, "precondition: beta blocks");
  eq(accept(sid, repo, "beta", "op=add cat=user").code, 0, "precondition: hook exit");
  eq(prov(repo, sid).code, 0, "precondition: the grant passes");
  return { repo, sid };
}

function carryOnUnchangedBlocked() {
  check("#2770 an unrelated declared add staged after the grant: the gate still passes", () => {
    const { repo, sid } = grantedBeta("carry");
    stageUser(repo, [["alpha", DEFS.alpha], ["beta", BETA], ["gamma", "Unrelated term."], ["omega", DEFS.omega]]);
    const r = prov(repo, sid);
    eq(r.code, 0, `exit (out: ${r.all})`);
    const rec = provRecord(sid) || {};
    const g = (rec.grants || []).filter((x) => x.norm === "beta" && x.fingerprint === rec.fingerprint);
    eq(g.length, 1, `grant on the new fingerprint: ${JSON.stringify(rec)}`);
  });
  check("#2770 a new blocked entry for the granted term after the grant: blocks and drops the grant", () => {
    const { repo, sid } = grantedBeta("nocarry");
    stageInternal(repo, [["kilo", DEFS.kilo], ["beta", BETA]]);
    const r = prov(repo, sid);
    eq(r.code, 1, `exit (out: ${r.all})`);
    eq((provRecord(sid) || {}).grants || [], [], "grants");
  });
}

module.exports = { blockRecordAndGrant, narrowGrants, bGrantSameRules, carryOnUnchangedBlocked };
