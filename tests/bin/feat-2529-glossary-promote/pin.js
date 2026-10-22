"use strict";
// Tests: bin/glossary-promote, bin/check-glossary-provenance
// Tags: TL2, bin, glossary, provenance, promote, approval, sentinel, scope:issue-specific
// T3-5 layer 0: promote reads only the CONFIRM_INTENT-approved intent of `<sid>-intent.md`
// in the plans dir. Unapproved / modified intents exit 1 with nothing written, an
// `## Issues`-only edit passes, another basename or location is usage (exit 2), and
// GLOSSARY_ACCEPTED never unblocks promote (named exception) while it does unblock the same
// change hand-edited and checked at commit time.

const { caseBegin, caseEnd } = require("../../lib/harness");
const fs = require("fs");
const path = require("path");
const { check, eq, ok, TMP, DEFS, promote, snapshot, unchanged, userTerms, counters, session, mkRepo,
  newSid, writeIntent, writeState, stageUser, prov, accept } = require("./lib");

const ROWS = [["beta", "user", "add", "A pinned promote term."]];

caseBegin("t3-5-layer-0-approval-pin-and-accepted", "bin/glossary-promote");
function unapprovedAndModified() {
  const repo = mkRepo("p0-unapproved");
  const sid = newSid("p0-unapproved");
  const intent = writeIntent(sid, ROWS);
  writeState(sid, { approval: false, cwd: repo });
  const before = snapshot(repo);
  check("T3-5 layer 0: no approval record -> exit 1 intent-unapproved, files unchanged", () => {
    const r = promote(intent, repo);
    eq(r.code, 1, `exit (out: ${r.all})`);
    ok(/intent-unapproved/.test(r.err), `stderr: ${r.err}`);
    unchanged(repo, before);
  });

  const mod = session("p0-modified", ROWS);
  writeIntent(mod.sid, ROWS.concat([["gamma", "user", "add", "Added after approval."]]));
  const modBefore = snapshot(mod.repo);
  check("T3-5 layer 0: `## Glossary` changed after approval -> exit 1 intent-modified, files unchanged", () => {
    const r = promote(mod.intent, mod.repo);
    eq(r.code, 1, `exit (out: ${r.all})`);
    ok(/intent-modified/.test(r.err), `stderr: ${r.err}`);
    unchanged(mod.repo, modBefore);
  });
  check("T3-5 GLOSSARY_ACCEPTED does not unblock promote (named exception)", () => {
    eq(accept(mod.sid, mod.repo, "gamma", "op=add cat=user").code, 0, "hook exit");
    const r = promote(mod.intent, mod.repo);
    eq(r.code, 1, `exit after ACCEPTED (out: ${r.all})`);
    unchanged(mod.repo, modBefore);
  });
  check("T3-5 the same change hand-edited and staged: the commit-time block is escaped with ACCEPTED", () => {
    stageUser(mod.repo, [["alpha", DEFS.alpha], ["beta", "A pinned promote term."], ["gamma", "Added after approval."], ["omega", DEFS.omega]]);
    const first = prov(mod.repo, mod.sid);
    eq(first.code, 1, `first gate exit (out: ${first.all})`);
    eq(accept(mod.sid, mod.repo, "gamma", "op=add cat=user").code, 0, "hook exit (gamma)");
    eq(accept(mod.sid, mod.repo, "beta", "op=add cat=user").code, 0, "hook exit (beta)");
    const r = prov(mod.repo, mod.sid);
    eq(r.code, 0, `gate exit after ACCEPTED (out: ${r.all})`);
  });
}
caseEnd();

caseBegin("t3-5-layer-0-issues-only-edit", "bin/glossary-promote");
function issuesOnlyEdit() {
  const s = session("p0-issues", ROWS);
  writeIntent(s.sid, ROWS, { issues: "- #1 fixture\n- #2 back-filled after approval" });
  check("T3-5 layer 0: an `## Issues`-only edit after approval still promotes (ADDED=1)", () => {
    const r = promote(s.intent, s.repo);
    eq(r.code, 0, `exit (out: ${r.all})`);
    eq(counters(r.out).ADDED, 1, "ADDED");
    eq(userTerms(s.repo).beta, "A pinned promote term.", "beta definition");
  });
}
caseEnd();

caseBegin("t3-5-intent-basename-is-usage", "bin/glossary-promote");
function basenameIsUsage() {
  const s = session("p0-basename", ROWS);
  const before = snapshot(s.repo);
  const renamed = path.join(TMP, "approved-intent-copy.md");
  fs.copyFileSync(s.intent, renamed);
  check("T3-5 an intent.md whose basename is not <sid>-intent.md exits 2, files unchanged", () => {
    const r = promote(renamed, s.repo);
    eq(r.code, 2, `exit (out: ${r.all})`);
    unchanged(s.repo, before);
  });
  const elsewhere = path.join(TMP, "elsewhere");
  fs.mkdirSync(elsewhere, { recursive: true });
  const copy = path.join(elsewhere, path.basename(s.intent));
  fs.copyFileSync(s.intent, copy);
  check("T3-5 a <sid>-intent.md outside the plans dir (not the session's artifact path) exits 2", () => {
    const r = promote(copy, s.repo);
    eq(r.code, 2, `exit (out: ${r.all})`);
    unchanged(s.repo, before);
  });
  const bad = path.join(TMP, "bad sid-intent.md");
  fs.copyFileSync(s.intent, bad);
  check("T3-5 a basename whose <sid> fails SESSION_ID_VALID_RE exits 2", () => {
    eq(promote(bad, s.repo).code, 2, "exit");
    unchanged(s.repo, before);
  });
}
caseEnd();

module.exports = { unapprovedAndModified, issuesOnlyEdit, basenameIsUsage };
