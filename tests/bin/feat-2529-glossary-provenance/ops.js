"use strict";
// Tests: bin/lib/glossary-provenance.js
// Tags: TL1, bin, glossary, provenance, unit, scope:issue-specific
// T3-1: the pure provenance functions — readTermSets / normalizeDefinition / computeOperations /
// opsFingerprint / matchOperations / checkIntentRows — over in-memory glossary texts.

const { check, eq, ok, mod, DEFS, glossaryText, U0, I0 } = require("./common");

const P_USER = "docs/glossary/user.md";
const P_INT = "docs/glossary/internal.md";
const gp = () => mod("bin/lib/glossary-provenance.js");

// sets(userEntries, internalEntries) — a term set read through readTermSets from texts.
function sets(u, i) {
  const texts = { [P_USER]: glossaryText("user", u), [P_INT]: glossaryText("internal", i) };
  return gp().readTermSets((p) => texts[p.replace(/\\/g, "/")], [P_USER, P_INT]);
}
const row = (term, category, operation, definition) => ({ term, category, operation, definition: definition || "" });
const reasons = (res) => (res && res.unmatched ? res.unmatched : []).map((u) => `${u.term}/${u.operation}/${u.category}:${u.reason}`);

const BETA = "A fresh fixture term.";
const ALPHA2 = "The first fixture term!";

function opsOf(u, i) {
  return gp().computeOperations(sets(U0(), I0()), sets(u, i));
}
const opKeys = (ops) => ops.map((o) => `${o.term}/${o.operation}/${o.category}`).sort();

function readAndNormalize() {
  check("T3-1 normalizeDefinition collapses whitespace runs and trims, keeping case", () => {
    eq(gp().normalizeDefinition("  The   First\tterm.  "), "The First term.");
  });
  check("T3-1 readTermSets maps each category to its terms and normalized definitions", () => {
    const s = sets(U0(), I0());
    ok(s.user instanceof Map && s.internal instanceof Map, "user / internal must be Maps");
    eq(s.user.get("alpha"), DEFS.alpha, "user alpha");
    eq(s.internal.get("kilo"), DEFS.kilo, "internal kilo");
    eq(s.user.has("kilo"), false, "kilo is internal only");
  });
}

function threeOpsByCategory() {
  const addNext = [U0().concat([["beta", BETA]]).sort(), I0()];
  const delNext = [[["alpha", DEFS.alpha]], I0()];
  const redNext = [[["alpha", ALPHA2], ["omega", DEFS.omega]], I0()];
  const cases = [
    ["add", "beta", addNext, BETA],
    ["delete", "omega", delNext, ""],
    ["redefine", "alpha", redNext, ALPHA2],
  ];
  for (const [op, term, next, def] of cases) {
    check(`T3-1 ${op}: the diff is one ${op} of '${term}' in user`, () => {
      eq(opKeys(opsOf(next[0], next[1])), [`${term}/${op}/user`]);
    });
    check(`T3-1 ${op}: an intent row with the same category matches`, () => {
      eq(reasons(gp().matchOperations(opsOf(next[0], next[1]), [row(term, "user", op, def)], [])), []);
    });
    check(`T3-1 ${op}: an intent row with another category is category-mismatch`, () => {
      eq(reasons(gp().matchOperations(opsOf(next[0], next[1]), [row(term, "internal", op, def)], [])), [`${term}/${op}/user:category-mismatch`]);
    });
    check(`T3-1 ${op}: a session intent row is session-term`, () => {
      eq(reasons(gp().matchOperations(opsOf(next[0], next[1]), [row(term, "session", op, def)], [])), [`${term}/${op}/user:session-term`]);
    });
  }
  check("T3-1 an operation with no intent row is not-in-intent", () => {
    eq(reasons(gp().matchOperations(opsOf(addNext[0], addNext[1]), [], [])), ["beta/add/user:not-in-intent"]);
  });
}

function pairsAndNoOps() {
  check("T3-1 a rename (delete alpha + add alef) matches its two intent rows", () => {
    const ops = opsOf([["alef", DEFS.alpha], ["omega", DEFS.omega]], I0());
    eq(opKeys(ops), ["alef/add/user", "alpha/delete/user"]);
    eq(reasons(gp().matchOperations(ops, [row("alpha", "user", "delete"), row("alef", "user", "add", DEFS.alpha)], [])), []);
  });
  check("T3-1 a category move (omega user -> internal) matches its delete + add pair", () => {
    const ops = opsOf([["alpha", DEFS.alpha]], [["kilo", DEFS.kilo], ["omega", DEFS.omega]]);
    eq(opKeys(ops), ["omega/add/internal", "omega/delete/user"]);
    eq(reasons(gp().matchOperations(ops, [row("omega", "user", "delete"), row("omega", "internal", "add", DEFS.omega)], [])), []);
  });
  check("T3-1 a one-character definition change is one redefine", () => {
    eq(opKeys(opsOf([["alpha", ALPHA2], ["omega", DEFS.omega]], I0())), ["alpha/redefine/user"]);
  });
  check("T3-1 a whitespace-only definition change is zero operations", () => {
    eq(opsOf([["alpha", "The   first  fixture\tterm."], ["omega", DEFS.omega]], I0()), []);
  });
  check("T3-1 a Related change is zero operations", () => {
    eq(opsOf([["alpha", DEFS.alpha, "[guide](../guide.md)"], ["omega", DEFS.omega]], I0()), []);
  });
  check("T3-1 an entry order change is zero operations", () => {
    eq(opsOf([["omega", DEFS.omega], ["alpha", DEFS.alpha]], I0()), []);
  });
}

function fingerprints() {
  const a = { term: "beta", category: "user", operation: "add", definition: BETA };
  const b = { term: "omega", category: "user", operation: "delete", definition: "" };
  check("T3-1 opsFingerprint does not depend on the operation order", () => {
    const f1 = gp().opsFingerprint([a, b]);
    ok(typeof f1 === "string" && /^[0-9a-f]{64}$/.test(f1), `want a sha256 hex, got ${f1}`);
    eq(gp().opsFingerprint([b, a]), f1, "reordered fingerprint");
  });
  check("T3-1 opsFingerprint changes with a one-character definition change", () => {
    const f1 = gp().opsFingerprint([a]);
    const f2 = gp().opsFingerprint([Object.assign({}, a, { definition: BETA.replace(".", "!") })]);
    ok(f1 !== f2, "same fingerprint for different definitions");
  });
  check("T3-1 opsFingerprint ignores a whitespace-only definition difference", () => {
    eq(gp().opsFingerprint([Object.assign({}, a, { definition: "A  fresh   fixture term." })]), gp().opsFingerprint([a]));
  });
}

function definitionMatching() {
  const redNext = [[["alpha", ALPHA2], ["omega", DEFS.omega]], I0()];
  const addNext = [U0().concat([["beta", BETA]]).sort(), I0()];
  check("T3-1 a redefine whose definition differs by one character is definition-mismatch", () => {
    eq(reasons(gp().matchOperations(opsOf(...redNext), [row("alpha", "user", "redefine", "The first fixture term?")], [])),
      ["alpha/redefine/user:definition-mismatch"]);
  });
  check("T3-1 a redefine matching up to whitespace runs passes", () => {
    eq(reasons(gp().matchOperations(opsOf(...redNext), [row("alpha", "user", "redefine", "The  first fixture   term!")], [])), []);
  });
  check("T3-1 an add whose definition differs is definition-mismatch", () => {
    eq(reasons(gp().matchOperations(opsOf(...addNext), [row("beta", "user", "add", "Another definition.")], [])),
      ["beta/add/user:definition-mismatch"]);
  });
  check("T3-1 a delete compares no definition (an empty intent Definition passes)", () => {
    eq(reasons(gp().matchOperations(opsOf([["alpha", DEFS.alpha]], I0()), [row("omega", "user", "delete", "")], [])), []);
  });
  check("T3-1 a same-category delete and re-add with a new definition diffs as one redefine", () => {
    // before: alpha (DEFS.alpha); after: alpha removed and written back with ALPHA2
    const ops = opsOf([["alpha", ALPHA2], ["omega", DEFS.omega]], I0());
    eq(opKeys(ops), ["alpha/redefine/user"]);
    eq(reasons(gp().matchOperations(ops, [row("alpha", "user", "redefine", ALPHA2)], [])), []);
  });
  check("T3-1 a grant covers only its {norm, operation, category}", () => {
    const ops = opsOf(...addNext);
    eq(reasons(gp().matchOperations(ops, [], [{ norm: "beta", operation: "add", category: "user" }])), []);
    eq(reasons(gp().matchOperations(ops, [], [{ norm: "beta", operation: "delete", category: "user" }])), ["beta/add/user:not-in-intent"]);
    eq(reasons(gp().matchOperations(ops, [], [{ norm: "beta", operation: "add", category: "internal" }])), ["beta/add/user:not-in-intent"]);
  });
}

// S-C2: a heading's case is part of the term; only identical bytes diff as zero operations.
function caseOnlyRename() {
  check("T3-1 a case-only heading rename (alpha -> Alpha) is a delete of the old term + an add of the new term", () => {
    const ops = opsOf([["Alpha", DEFS.alpha], ["omega", DEFS.omega]], I0());
    eq(opKeys(ops), ["Alpha/add/user", "alpha/delete/user"]);
    const add = ops.find((o) => o.operation === "add");
    eq(add && add.definition, DEFS.alpha, "the add carries the unchanged definition");
  });
  check("T3-1 an unchanged heading (identical bytes) is zero operations", () => {
    eq(opsOf(U0(), I0()), []);
  });
  check("T3-1 a rename that differs in more than case (alpha -> Alpine) is still a delete + an add", () => {
    const ops = opsOf([["Alpine", DEFS.alpha], ["omega", DEFS.omega]], I0());
    eq(ops.map((o) => `${String(o.term).toLowerCase()}/${o.operation}/${o.category}`).sort(), ["alpha/delete/user", "alpine/add/user"]);
  });
}

const rowReasons = (list) => (list || []).map((r) => `${r.term}/${r.operation}/${r.category}:${r.reason}`).sort();

function intentRowChecks() {
  check("T3-1 checkIntentRows: a same-term same-category delete + add returns use-redefine on both rows", () => {
    const res = gp().checkIntentRows(sets(U0(), I0()), [row("alpha", "user", "delete"), row("alpha", "user", "add", ALPHA2)]);
    eq(rowReasons(res), ["alpha/add/user:use-redefine", "alpha/delete/user:use-redefine"]);
  });
  check("T3-1 checkIntentRows: a category move pair passes", () => {
    eq(rowReasons(gp().checkIntentRows(sets(U0(), I0()), [row("omega", "internal", "add", DEFS.omega), row("omega", "user", "delete")])), []);
  });
  check("T3-1 checkIntentRows: delete-absent / redefine-absent / redefine-no-change / category-mismatch / category-conflict", () => {
    const s = sets(U0(), I0());
    eq(rowReasons(gp().checkIntentRows(s, [row("zulu", "user", "delete")])), ["zulu/delete/user:delete-absent"]);
    eq(rowReasons(gp().checkIntentRows(s, [row("zulu", "user", "redefine", "x y z")])), ["zulu/redefine/user:redefine-absent"]);
    eq(rowReasons(gp().checkIntentRows(s, [row("alpha", "user", "redefine", " The first  fixture term. ")])), ["alpha/redefine/user:redefine-no-change"]);
    eq(rowReasons(gp().checkIntentRows(s, [row("kilo", "user", "delete")])), ["kilo/delete/user:category-mismatch"]);
    eq(rowReasons(gp().checkIntentRows(s, [row("kilo", "user", "redefine", "New kilo.")])), ["kilo/redefine/user:category-mismatch"]);
    eq(rowReasons(gp().checkIntentRows(s, [row("kilo", "user", "add", "New kilo.")])), ["kilo/add/user:category-conflict"]);
  });
  check("T3-1 checkIntentRows: an add of a term already in the same category is not a block; session rows are ignored", () => {
    eq(rowReasons(gp().checkIntentRows(sets(U0(), I0()), [row("alpha", "user", "add", DEFS.alpha), row("sess", "session", "add", "S.")])), []);
  });
}

// A case-only rename's rows (alpha delete + Alpha add) are a legitimate rename, not a rewrite:
// use-redefine pairs only a delete and an add whose terms are identical as written.
function caseOnlyRenameRows() {
  const renameRows = () => [row("alpha", "user", "delete"), row("Alpha", "user", "add", DEFS.alpha)];
  check("T3-1 checkIntentRows: a case-only rename pair (alpha delete + Alpha add) is not use-redefine", () => {
    eq(rowReasons(gp().checkIntentRows(sets(U0(), I0()), renameRows())), []);
  });
  check("T3-1 matchOperations: the case-only rename's delete + add ops match its two intent rows", () => {
    const ops = opsOf([["Alpha", DEFS.alpha], ["omega", DEFS.omega]], I0());
    eq(opKeys(ops), ["Alpha/add/user", "alpha/delete/user"]);
    eq(reasons(gp().matchOperations(ops, renameRows(), [])), []);
  });
  check("T3-1 checkIntentRows: an identically spelled delete + add pair is still use-redefine on both rows", () => {
    const res = gp().checkIntentRows(sets(U0(), I0()), [row("alpha", "user", "delete"), row("alpha", "user", "add", DEFS.alpha)]);
    eq(rowReasons(res), ["alpha/add/user:use-redefine", "alpha/delete/user:use-redefine"]);
  });
  check("T3-1 checkIntentRows: a delete + add differing in case and category (omega user -> Omega internal) is a move, not a pair", () => {
    eq(rowReasons(gp().checkIntentRows(sets(U0(), I0()), [row("omega", "user", "delete"), row("Omega", "internal", "add", DEFS.omega)])), []);
  });
}

module.exports = { readAndNormalize, threeOpsByCategory, pairsAndNoOps, caseOnlyRename, caseOnlyRenameRows, fingerprints, definitionMatching, intentRowChecks };
