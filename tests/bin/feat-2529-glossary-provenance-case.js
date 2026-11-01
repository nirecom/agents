#!/usr/bin/env node
"use strict";
// Tests: bin/lib/glossary-provenance.js, bin/check-glossary-provenance
// Tags: TL1, TL2, bin, glossary, provenance, case-rename, fingerprint, scope:issue-specific
// #2529 review fix: provenance matching and the operations fingerprint are case-exact on the term,
// as computeOperations is. Intent rows approving `Alpha -> alpha` must not authorize the staged
// `alpha -> Alpha`, and the two directions must not share a fingerprint (so no grant carries over).
// Split from feat-2529-glossary-provenance.js for the per-file time budget; same fixture library.

const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");
const { after, test } = require("node:test");
const { caseBegin, caseEnd } = require("../lib/harness");
const { noNewFailures } = require("../lib/case-verdict");
const C = require("./feat-2529-glossary-provenance/common");

const { check, eq, ok, mod, DEFS, glossaryText } = C;
const fails = () => C.totals.failed;
after(() => process.stdout.write(`Total: ${C.totals.passed} passed, ${C.totals.failed} failed\n`));
const gp = () => mod("bin/lib/glossary-provenance.js");
const P_USER = "docs/glossary/user.md";
const P_INT = "docs/glossary/internal.md";

function sets(userEntries) {
  const texts = { [P_USER]: glossaryText("user", userEntries), [P_INT]: glossaryText("internal", [["kilo", DEFS.kilo]]) };
  return gp().readTermSets((p) => texts[p.replace(/\\/g, "/")], [P_USER, P_INT]);
}
const row = (term, category, operation, definition) => ({ term, category, operation, definition: definition || "" });
const reasons = (res) => (res && res.unmatched ? res.unmatched : []).map((u) => `${u.term}/${u.operation}/${u.category}:${u.reason}`).sort();
const lowerToUpper = () => gp().computeOperations(sets([["alpha", DEFS.alpha]]), sets([["Alpha", DEFS.alpha]]));
const upperToLower = () => gp().computeOperations(sets([["Alpha", DEFS.alpha]]), sets([["alpha", DEFS.alpha]]));
const forwardRows = () => [row("alpha", "user", "delete"), row("Alpha", "user", "add", DEFS.alpha)];
const reverseRows = () => [row("Alpha", "user", "delete"), row("alpha", "user", "add", DEFS.alpha)];

caseBegin("case-exact-rows-authorize-only-their-own-direction", "bin/lib/glossary-provenance.js");
test("case-exact-rows-authorize-only-their-own-direction", () => noNewFailures(fails, () => {
  check("rows approving alpha -> Alpha match the staged alpha -> Alpha", () => {
    eq(reasons(gp().matchOperations(lowerToUpper(), forwardRows(), [])), []);
  });
  check("rows approving Alpha -> alpha do not authorize the staged alpha -> Alpha", () => {
    eq(reasons(gp().matchOperations(lowerToUpper(), reverseRows(), [])),
      ["Alpha/add/user:not-in-intent", "alpha/delete/user:not-in-intent"]);
  });
  check("rows approving alpha -> Alpha do not authorize the staged Alpha -> alpha", () => {
    eq(reasons(gp().matchOperations(upperToLower(), forwardRows(), [])),
      ["Alpha/delete/user:not-in-intent", "alpha/add/user:not-in-intent"]);
  });
  check("a redefine row spelled in another case does not match the redefine", () => {
    const ops = gp().computeOperations(sets([["Alpha", DEFS.alpha]]), sets([["Alpha", "The first fixture term!"]]));
    eq(reasons(gp().matchOperations(ops, [row("alpha", "user", "redefine", "The first fixture term!")], [])),
      ["Alpha/redefine/user:not-in-intent"]);
  });
}));
caseEnd();

caseBegin("case-exact-ops-fingerprint-separates-the-two-directions", "bin/lib/glossary-provenance.js");
test("case-exact-ops-fingerprint-separates-the-two-directions", () => noNewFailures(fails, () => {
  check("opsFingerprint of alpha -> Alpha differs from Alpha -> alpha", () => {
    const f1 = gp().opsFingerprint(lowerToUpper());
    const f2 = gp().opsFingerprint(upperToLower());
    ok(/^[0-9a-f]{64}$/.test(f1) && /^[0-9a-f]{64}$/.test(f2), `want sha256 hex, got ${f1} / ${f2}`);
    ok(f1 !== f2, "both directions share one fingerprint");
  });
  check("opsFingerprint stays order-independent for one direction", () => {
    eq(gp().opsFingerprint(lowerToUpper().slice().reverse()), gp().opsFingerprint(lowerToUpper()));
  });
}));
caseEnd();

const APPROVE_LOWER_TO_UPPER = [["alpha", "user", "delete", ""], ["Alpha", "user", "add", DEFS.alpha]];
const gateCases = [
  { name: "the staged Alpha -> alpha is blocked when the intent approves alpha -> Alpha",
    from: "Alpha", to: "alpha", rows: APPROVE_LOWER_TO_UPPER, code: 1, outRe: /BLOCK:/,
    blocked: ["Alpha/delete/user:not-in-intent", "alpha/add/user:not-in-intent"] },
  { name: "the staged alpha -> Alpha passes when the intent approves alpha -> Alpha",
    from: "alpha", to: "Alpha", rows: APPROVE_LOWER_TO_UPPER, code: 0, outRe: /2 operation\(s\) match the approved intent/,
    blocked: [] },
];
caseBegin("case-exact-gate-judges-each-direction", "bin/check-glossary-provenance");
test("case-exact-gate-judges-each-direction", () => noNewFailures(fails, () => {
  for (const c of gateCases) {
    check(c.name, () => {
      const repo = C.mkRepo("case-dir", { [P_USER]: glossaryText("user", [[c.from, DEFS.alpha]]), [P_INT]: glossaryText("internal", [["kilo", DEFS.kilo]]) });
      C.stageUser(repo, [[c.to, DEFS.alpha]]);
      const sid = C.approvedSession("case-dir", c.rows, { cwd: repo });
      const r = C.prov(repo, sid);
      eq(r.code, c.code, `${c.name}: exit (${r.all})`);
      ok(c.outRe.test(r.out), `${c.name}: stdout lacks ${c.outRe} (${r.all})`);
      if (c.code === 0) ok(!/BLOCK/.test(r.all), `${c.name}: unexpected BLOCK (${r.all})`);
      const blocked = C.blockedOf(sid).map((b) => `${b.term}/${b.operation}/${b.category}:${b.reason}`).sort();
      eq(blocked, c.blocked, `${c.name}: recorded blocked`);
    });
  }
}));
caseEnd();

const SESSION_ONLY = "| Term | Category | Operation | Definition |\n|---|---|---|---|\n| zz | session | add | A session word. |\n";
const payloadCases = [
  { name: "a $(...) heading", tag: "dollar", term: (m) => `x$(touch ${m})` },
  { name: "a backtick heading", tag: "backtick", term: (m) => "x`touch " + m + "`" },
];
caseBegin("copyable-accept-command-does-not-execute-the-term", "bin/check-glossary-provenance");
test("copyable-accept-command-does-not-execute-the-term", () => noNewFailures(fails, () => {
  for (const c of payloadCases) {
    // A forbidden-character term gets no copyable accept command, only a fix-the-heading line;
    // any echo line printed anyway is run, and the payload must still not execute.
    check(`no GLOSSARY_ACCEPTED command is printed for ${c.name}, and its payload never runs`, () => {
      const repo = C.mkRepo(`inj-${c.tag}`, { [P_USER]: glossaryText("user", [["alpha", DEFS.alpha]]), [P_INT]: glossaryText("internal", [["kilo", DEFS.kilo]]) });
      const marker = C.fwd(path.join(C.TMP, `pwned-${c.tag}-${path.basename(repo)}`));
      const term = c.term(marker);
      C.stageUser(repo, [["alpha", DEFS.alpha], [term, "A hostile term."]]);
      const sid = C.approvedSession(`inj-${c.tag}`, [], { cwd: repo, glossary: SESSION_ONLY });
      const r = C.prov(repo, sid);
      ok(r.code !== 0, `${c.name}: the staged hostile heading passed (exit ${r.code}; ${r.all})`);
      const echoes = r.all.split("\n").filter((l) => l.includes("echo "));
      for (const l of echoes) spawnSync("bash", ["-c", l.slice(l.indexOf("echo "))], { cwd: C.TMP, encoding: "utf8", timeout: 30000 });
      ok(!fs.existsSync(marker), `${c.name}: a printed command ran the payload (marker created)`);
      ok(!r.all.split("\n").some((l) => l.includes("echo \"<<WORKFLOW_GLOSSARY_ACCEPTED") && l.includes(term)),
        `${c.name}: a copyable accept command names the hostile term (${r.all})`);
    });
  }
}));
caseEnd();
