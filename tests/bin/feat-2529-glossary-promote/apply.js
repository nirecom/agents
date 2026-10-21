"use strict";
// Tests: bin/glossary-promote
// Tags: TL2, bin, glossary, provenance, promote, scope:issue-specific
// T3-5 apply: promote applies add / delete / redefine rows of the approved intent, prints
// every counter, keeps an add of an existing same-category term as SKIPPED_EXISTING, and a
// same-category definition rewrite goes through one redefine row (delete + add is refused).

const { check, eq, ok, promote, snapshot, unchanged, userTerms, internalTerms, counters, session, readFile } = require("./lib");

function appliesAllOperations() {
  const NEW_ALPHA = "The first fixture term, redefined.";
  const rows = [
    ["beta", "user", "add", "A promoted user term."],
    ["lima", "internal", "add", "A promoted internal term."],
    ["omega", "user", "delete", ""],
    ["alpha", "user", "redefine", NEW_ALPHA],
    ["scratch", "session", "add", "A session-only term."],
  ];
  const { repo, intent } = session("apply", rows);
  let r;
  check("T3-5 add + delete + redefine + session rows: exit 0 with every counter", () => {
    r = promote(intent, repo);
    eq(r.code, 0, `exit (out: ${r.all})`);
    eq(counters(r.out), { ADDED: 2, DELETED: 1, REDEFINED: 1, SKIPPED_EXISTING: 0, SKIPPED_SESSION: 1 }, "counters");
  });
  check("T3-5 the user file loses omega, gains beta and carries the new alpha definition", () => {
    const u = userTerms(repo);
    ok(!("omega" in u), `omega still present: ${JSON.stringify(u)}`);
    eq(u.beta, "A promoted user term.", "beta definition");
    eq(u.alpha, NEW_ALPHA, "alpha definition");
  });
  check("T3-5 the internal file gains lima and keeps kilo; no session term is written", () => {
    const i = internalTerms(repo);
    eq(Object.keys(i).sort(), ["kilo", "lima"], "internal terms");
    ok(!/scratch/.test(readFile(repo, "docs/glossary/user.md") + readFile(repo, "docs/glossary/internal.md")), "session term written");
  });
  check("T3-5 a redefine keeps the entry's Related line", () => {
    const text = readFile(repo, "docs/glossary/user.md") || "";
    const at = text.indexOf("### alpha");
    const next = text.indexOf("\n### ", at + 1);
    const block = at < 0 ? "" : text.slice(at, next < 0 ? undefined : next);
    ok(/- \*\*Related\*\*: \[README\.md\]\(\.\.\/\.\.\/README\.md\)/.test(block), `alpha entry: ${block}`);
  });
}

function skippedExisting() {
  const { repo, intent } = session("skip-existing", [["alpha", "user", "add", "A differently worded alpha."]]);
  const before = snapshot(repo);
  check("T3-5 an add of a term already in the same category is SKIPPED_EXISTING, not a block", () => {
    const r = promote(intent, repo);
    eq(r.code, 0, `exit (out: ${r.all})`);
    eq(counters(r.out).SKIPPED_EXISTING, 1, "SKIPPED_EXISTING");
    eq(counters(r.out).ADDED, 0, "ADDED");
    unchanged(repo, before);
  });
}

function sameCategoryRewrite() {
  const NEW = "The first fixture term, rebuilt.";
  const pair = session("use-redefine", [["alpha", "user", "delete", ""], ["alpha", "user", "add", NEW]]);
  const before = snapshot(pair.repo);
  check("T3-5 a same-category delete + add pair is refused (use-redefine) and nothing is written", () => {
    const r = promote(pair.intent, pair.repo);
    eq(r.code, 1, `exit (out: ${r.all})`);
    ok(/use-redefine|intent-unreadable/.test(r.err), `stderr: ${r.err}`);
    unchanged(pair.repo, before);
  });
  const one = session("redefine-row", [["alpha", "user", "redefine", NEW]]);
  check("T3-5 the same rewrite as one redefine row replaces the definition (REDEFINED=1)", () => {
    const r = promote(one.intent, one.repo);
    eq(r.code, 0, `exit (out: ${r.all})`);
    eq(counters(r.out).REDEFINED, 1, "REDEFINED");
    eq(userTerms(one.repo).alpha, NEW, "alpha definition");
  });
}

// headings(text) — every `### ` heading exactly as written.
const headings = (text) => String(text || "").split(/\r?\n/).filter((l) => /^### /.test(l)).map((l) => l.slice(4).trim());

function caseOnlyRename() {
  const NEW = "The first fixture term, now capitalized.";
  const { repo, intent } = session("case-rename", [["alpha", "user", "delete", ""], ["Alpha", "user", "add", NEW]]);
  let r;
  check("T3-5 a case-only rename pair (alpha delete + Alpha add) applies: exit 0, ADDED=1 DELETED=1", () => {
    r = promote(intent, repo);
    eq(r.code, 0, `exit (out: ${r.all})`);
    const n = counters(r.out);
    eq([n.ADDED, n.DELETED, n.REDEFINED, n.SKIPPED_EXISTING], [1, 1, 0, 0], "ADDED / DELETED / REDEFINED / SKIPPED_EXISTING");
  });
  check("T3-5 after the case-only rename the user file has heading Alpha with the new definition and no alpha", () => {
    const text = readFile(repo, "docs/glossary/user.md");
    const hs = headings(text);
    ok(hs.includes("Alpha") && !hs.includes("alpha"), `headings: ${JSON.stringify(hs)}`);
    eq(userTerms(repo).alpha, NEW, "Alpha definition");
  });
}

module.exports = { appliesAllOperations, skippedExisting, sameCategoryRewrite, caseOnlyRename };
