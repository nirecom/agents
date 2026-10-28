#!/usr/bin/env node
"use strict";
// Tests: bin/glossary-promote
// Tags: TL1, TL2, bin, glossary, promote, atomic-write, scope:issue-specific
// #2529 review fix: glossary-promote writes every changed file to a sibling temp first and renames
// them into place only after all temp writes succeeded; a failure removes the temps and leaves the
// originals untouched. writeAll runs in-process with an injected io; the CLI run checks that a
// two-file promotion leaves no temp behind. Split from feat-2529-glossary-promote.js for the
// per-file time budget; same fixture library.

const fs = require("fs");
const path = require("path");
const { caseBegin, caseEnd } = require("../lib/harness");
const L = require("./feat-2529-glossary-promote/lib");

const { check, eq, ok, mod, DEFS } = L;
const promoteMod = () => mod("bin/glossary-promote");
const DIR = "docs/glossary";

const leftovers = (repo) => fs.readdirSync(path.join(repo, DIR)).filter((n) => n.endsWith(".promote-tmp"));
const newTexts = () => new Map([[L.FILES[0], "# user NEW\n"], [L.FILES[1], "# internal NEW\n"]]);

// failingIo(op, nth) — real fs, except the nth call of `op` throws.
function failingIo(op, nth) {
  let calls = 0;
  return Object.assign({}, fs, {
    [op]: (...args) => {
      calls += 1;
      if (calls === nth) throw Object.assign(new Error(`injected ${op} failure`), { code: "EINJECT" });
      return fs[op](...args);
    },
  });
}

function failureLeavesOriginals(label, io) {
  check(`${label}: writeAll throws, originals untouched, no temp left`, () => {
    const repo = L.mkRepo(`atomic-${label}`);
    const before = L.snapshot(repo);
    let thrown = null;
    try { promoteMod().writeAll(repo, L.FILES.slice(), newTexts(), io); } catch (e) { thrown = e; }
    ok(thrown && thrown.code === "EINJECT", `want the injected error, got ${thrown && thrown.message}`);
    L.unchanged(repo, before);
    eq(leftovers(repo), [], "temp files");
  });
}

caseBegin("promote-atomic-temp-write-failure-leaves-originals", "bin/glossary-promote");
failureLeavesOriginals("second-temp-write", failingIo("writeFileSync", 2));
failureLeavesOriginals("first-temp-write", failingIo("writeFileSync", 1));
caseEnd();

caseBegin("promote-atomic-renames-only-after-every-temp-write", "bin/glossary-promote");
check("writeAll writes no destination until every temp is written", () => {
  const repo = L.mkRepo("atomic-order");
  const before = L.snapshot(repo);
  const seen = [];
  const io = Object.assign({}, fs, {
    writeFileSync: (p, t) => { seen.push(["write", L.snapshot(repo)]); return fs.writeFileSync(p, t); },
    renameSync: (a, b) => { seen.push(["rename", null]); return fs.renameSync(a, b); },
  });
  promoteMod().writeAll(repo, L.FILES.slice(), newTexts(), io);
  eq(seen.map((s) => s[0]), ["write", "write", "rename", "rename"], "call order");
  for (const [kind, snap] of seen) if (kind === "write") eq(snap, before, "originals during the temp writes");
  eq(L.snapshot(repo), ["# user NEW\n", "# internal NEW\n"], "files after writeAll");
  eq(leftovers(repo), [], "temp files");
});
failureLeavesOriginals("first-rename", failingIo("renameSync", 1));
caseEnd();

caseBegin("promote-atomic-cli-two-file-promotion-leaves-no-temp", "bin/glossary-promote");
check("a promotion changing user and internal writes both and leaves no temp", () => {
  const s = L.session("atomic-cli", [["beta", "user", "add", "A fresh fixture term."], ["lima", "internal", "add", "A new internal term."]]);
  const r = L.promote(s.intent, s.repo);
  eq(r.code, 0, `exit (${r.all})`);
  eq(L.userTerms(s.repo).beta, "A fresh fixture term.", "user beta");
  eq(L.internalTerms(s.repo).lima, "A new internal term.", "internal lima");
  eq(L.userTerms(s.repo).alpha, DEFS.alpha, "user alpha kept");
  eq(leftovers(s.repo), [], "temp files");
});
caseEnd();

process.stdout.write(`Total: ${L.totals.passed} passed, ${L.totals.failed} failed\n`);
process.exitCode = L.totals.failed === 0 ? 0 : 1;
