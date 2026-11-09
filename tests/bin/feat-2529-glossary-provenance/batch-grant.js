"use strict";
// #2962 part of tests/bin/feat-2529-glossary-provenance-gate.js: a batch=definition-only grant
// written by the real accept hook is consumed by the commit-time provenance check. Holds no case
// markers; the entrypoint wraps the run function in one.

const { check, eq, ok, DEFS, mkRepo, entry, stage, approvedSession, prov, accept, clip } = require("./common");

// alpha: a Definition-only redefine; omega: a redefine that adds a `Short forms` line.
function mixedRepo(tag) {
  const repo = mkRepo(tag);
  const omega = "### omega\n\n- **Definition**: " + DEFS.omega + "\n- **Short forms**: `om`\n" +
    "- **Related**: [README.md](../../README.md)\n";
  stage(repo, "docs/glossary/user.md", "# Glossary — user terms\n\n" + entry("alpha", "The first fixture term, reworded.") + "\n" + omega);
  return repo;
}

const blockLines = (all) => String(all).split(/\r?\n/).filter((l) => /BLOCK: \S+ redefine user\b/.test(l));
const names = (all, term) => blockLines(all).some((l) => new RegExp(`BLOCK: ${term} redefine user\\b`).test(l));

function batchGrantConsumedAtCommit() {
  const repo = mixedRepo("batch-e2e");
  const sid = approvedSession("batch-e2e", [], { cwd: repo });
  let first = null;
  check("batch e2e: the mixed staged change blocks with a BLOCK line for alpha and omega (exit 1)", () => {
    first = prov(repo, sid);
    eq(first.code, 1, `exit (${clip(first.all)})`);
    ok(names(first.all, "alpha") && names(first.all, "omega"), `BLOCK lines: ${clip(first.all)}`);
  });
  check("batch e2e: GLOSSARY_ACCEPTED term=* batch=definition-only covers alpha only; omega still blocks", () => {
    ok(first !== null && first.code === 1, "precondition: the first run blocked");
    const h = accept(sid, repo, "*", "batch=definition-only", "user accepted the reworded definitions");
    eq(h.code, 0, `hook exit (${clip(h.all)})`);
    const r = prov(repo, sid);
    eq(r.code, 1, `exit (${clip(r.all)})`);
    ok(names(r.all, "omega"), `omega BLOCK line: ${clip(r.all)}`);
    ok(!names(r.all, "alpha"), `alpha must be covered by the batch grant: ${clip(r.all)}`);
  });
  check("batch e2e: a per-term GLOSSARY_ACCEPTED for omega then lets the check pass (exit 0)", () => {
    const h = accept(sid, repo, "omega", "op=redefine cat=user");
    eq(h.code, 0, `hook exit (${clip(h.all)})`);
    const r = prov(repo, sid);
    eq(r.code, 0, `exit (${clip(r.all)})`);
  });
}

module.exports = { batchGrantConsumedAtCommit };
