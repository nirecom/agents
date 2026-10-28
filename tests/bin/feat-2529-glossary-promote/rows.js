"use strict";
// Tests: bin/glossary-promote
// Tags: TL2, bin, glossary, provenance, promote, scope:issue-specific
// T3-5 layer 1: intent rows that contradict the glossary files are blocked before any write
// (`  BLOCK: <term> <operation> <category>: <reason>`, files unchanged). A category move is a
// delete (old category) + add (new category) pair and passes in either row order.

const { check, eq, ok, DEFS, promote, snapshot, unchanged, userTerms, internalTerms, counters, blockLine, session } = require("./lib");

// Fixture glossary: user = alpha, omega; internal = kilo.
const BLOCKS = [
  ["delete of an absent term", ["zeta", "user", "delete", ""], "delete-absent"],
  ["redefine of an absent term", ["zeta", "user", "redefine", "A new zeta."], "redefine-absent"],
  ["redefine to the current definition", ["alpha", "user", "redefine", DEFS.alpha], "redefine-no-change"],
  ["redefine differing only in whitespace runs", ["alpha", "user", "redefine", DEFS.alpha.replace(/ /g, "   ")], "redefine-no-change"],
  ["delete of a term only in the other category", ["kilo", "user", "delete", ""], "category-mismatch"],
  ["redefine of a term only in the other category", ["kilo", "user", "redefine", "A new kilo."], "category-mismatch"],
  ["lone add of a term already in the other category", ["kilo", "user", "add", "A user kilo."], "category-conflict"],
];

function layerOneBlocks() {
  for (const [name, row, reason] of BLOCKS) {
    const { repo, intent } = session("l1", [row]);
    const before = snapshot(repo);
    check(`T3-5 layer 1: ${name} -> ${reason}, exit 1, files unchanged`, () => {
      const r = promote(intent, repo);
      eq(r.code, 1, `exit (out: ${r.all})`);
      ok(blockLine(row[0], row[2], row[1], reason).test(r.err), `stderr: ${r.err}`);
      unchanged(repo, before);
    });
  }
}

function moveRows(order) {
  const del = ["omega", "user", "delete", ""];
  const add = ["omega", "internal", "add", DEFS.omega];
  return order === "add-first" ? [add, del] : [del, add];
}

function categoryMove() {
  for (const order of ["delete-first", "add-first"]) {
    const { repo, intent } = session(`move-${order}`, moveRows(order));
    check(`T3-5 a category move pair (${order}) passes: DELETED=1 ADDED=1, omega leaves user and enters internal`, () => {
      const r = promote(intent, repo);
      eq(r.code, 0, `exit (out: ${r.all})`);
      const n = counters(r.out);
      eq([n.DELETED, n.ADDED], [1, 1], "DELETED / ADDED");
      ok(!("omega" in userTerms(repo)), "omega still in user");
      eq(internalTerms(repo).omega, DEFS.omega, "omega in internal");
    });
  }

  const wrong = session("move-wrong-cat", [["omega", "internal", "delete", ""], ["omega", "internal", "add", DEFS.omega]]);
  const wrongBefore = snapshot(wrong.repo);
  check("T3-5 a move pair whose delete names the wrong old category is blocked, files unchanged", () => {
    const r = promote(wrong.intent, wrong.repo);
    eq(r.code, 1, `exit (out: ${r.all})`);
    // With two categories the wrong old category equals the add's, so the row check's
    // use-redefine (reported inside intent-unreadable) can fire before the per-op reason.
    ok(/BLOCK: omega delete internal: (delete-absent|category-mismatch)|use-redefine: 'omega' \(internal\)/.test(r.err), `stderr: ${r.err}`);
    unchanged(wrong.repo, wrongBefore);
  });

  const delOnly = session("move-delete-only", [["omega", "user", "delete", ""]]);
  check("T3-5 the delete half alone passes as a plain delete (DELETED=1)", () => {
    const r = promote(delOnly.intent, delOnly.repo);
    eq(r.code, 0, `exit (out: ${r.all})`);
    eq(counters(r.out).DELETED, 1, "DELETED");
    ok(!("omega" in userTerms(delOnly.repo)), "omega still in user");
  });

  const addOnly = session("move-add-only", [["omega", "internal", "add", DEFS.omega]]);
  const addBefore = snapshot(addOnly.repo);
  check("T3-5 the add half alone is category-conflict, files unchanged", () => {
    const r = promote(addOnly.intent, addOnly.repo);
    eq(r.code, 1, `exit (out: ${r.all})`);
    ok(blockLine("omega", "add", "internal", "category-conflict").test(r.err), `stderr: ${r.err}`);
    unchanged(addOnly.repo, addBefore);
  });
}

module.exports = { layerOneBlocks, categoryMove };
