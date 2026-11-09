"use strict";
// #2962 part of tests/bin/feat-2529-glossary-promote.js: bin/check-glossary-provenance records,
// on each unmatched (and blocked) entry, `fields_changed` — false for a redefine that changes
// only the Definition, true for a redefine that changes the `Identifier` / `Short forms` fields.
// The batch=definition-only grant keys on it. Holds no case markers.

const c = require("./lib");

// stagedUser(repo) — alpha with a reworded Definition only; omega with a new `Short forms` line.
function stagedUser(repo) {
  const omega = "### omega\n\n- **Definition**: " + c.DEFS.omega + "\n- **Short forms**: `om`\n" +
    "- **Related**: [README.md](../../README.md)\n";
  const text = "# Glossary — user terms\n\n" + c.entry("alpha", "The first fixture term, reworded.") + "\n" + omega;
  c.stage(repo, "docs/glossary/user.md", text);
}

function unmatchedCarriesFieldsChanged() {
  const repo = c.mkRepo("t2962-fc");
  const sid = c.approvedSession("t2962-fc", [], { cwd: repo });
  stagedUser(repo);
  const r = c.prov(repo, sid);
  c.check("fields_changed: two unmatched redefines block the check (exit 1)", () => c.eq(r.code, 1, `exit (${c.clip(r.all)})`));
  const rec = c.provRecord(sid) || {};
  const find = (list, term) => (Array.isArray(list) ? list : []).find((u) => String(u.term).toLowerCase() === term);
  for (const key of ["unmatched", "blocked"]) {
    c.check(`fields_changed: a Definition-only redefine carries fields_changed false in ${key}`, () => {
      const u = find(rec[key], "alpha");
      c.ok(u && u.operation === "redefine", `alpha redefine in ${key}: ${c.show(rec[key])}`);
      c.eq(u.fields_changed, false, "alpha fields_changed");
    });
    c.check(`fields_changed: a Short forms redefine carries fields_changed true in ${key}`, () => {
      const u = find(rec[key], "omega");
      c.ok(u && u.operation === "redefine", `omega redefine in ${key}: ${c.show(rec[key])}`);
      c.eq(u.fields_changed, true, "omega fields_changed");
    });
  }
}

// The per-term BLOCK line of a Definition-only redefine carries `(definition-only)`; a fields
// redefine, an add (zulu) and a delete (kilo) in the same run carry no marker.
function blockLineMarksDefinitionOnly() {
  const repo = c.mkRepo("t2962-mk");
  const sid = c.approvedSession("t2962-mk", [], { cwd: repo });
  const omega = "### omega\n\n- **Definition**: " + c.DEFS.omega + "\n- **Short forms**: `om`\n" +
    "- **Related**: [README.md](../../README.md)\n";
  c.stage(repo, "docs/glossary/user.md", "# Glossary — user terms\n\n" +
    c.entry("alpha", "The first fixture term, reworded.") + "\n" + omega + "\n" + c.entry("zulu", "A new fixture term."));
  c.stage(repo, "docs/glossary/internal.md", c.glossaryText("internal", []));
  const r = c.prov(repo, sid);
  c.check("definition-only marker: the mixed run blocks (exit 1)", () => c.eq(r.code, 1, `exit (${c.clip(r.all)})`));
  const lineOf = (term, op, cat) => String(r.all).split(/\r?\n/).find((l) => new RegExp(`BLOCK: ${term} ${op} ${cat}\\b`).test(l));
  const MARK = "(definition-only)";
  c.check("definition-only marker: a fields_changed false redefine's BLOCK line carries (definition-only)", () => {
    const l = lineOf("alpha", "redefine", "user");
    c.ok(l !== undefined, `alpha BLOCK line: ${c.clip(r.all)}`);
    c.ok(l.includes(MARK), `alpha BLOCK line lacks ${MARK}: ${l}`);
  });
  for (const [term, op, cat] of [["omega", "redefine", "user"], ["zulu", "add", "user"], ["kilo", "delete", "internal"]]) {
    c.check(`definition-only marker: the ${op} ${term} BLOCK line carries no (definition-only)`, () => {
      const l = lineOf(term, op, cat);
      c.ok(l !== undefined, `${term} BLOCK line: ${c.clip(r.all)}`);
      c.ok(!l.includes(MARK), `${term} BLOCK line carries ${MARK}: ${l}`);
    });
  }
}

module.exports = { unmatchedCarriesFieldsChanged, blockLineMarksDefinitionOnly };
