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

// blockOf(text, term) — the `### term` entry block, up to the next entry.
function blockOf(text, term) {
  const t = String(text || "");
  const at = t.indexOf(`### ${term}\n`);
  if (at < 0) return "";
  const next = t.indexOf("\n### ", at + 1);
  return t.slice(at, next < 0 ? undefined : next);
}

// #2763 S2-5: a V3 row writes its Identifier / Homographs bullets (order Definition, Identifier,
// Homographs, Related); a V2 redefine row leaves the bullets already in the entry as they are.
const V3_TABLE = "| Term | Category | Operation | Definition | Identifier | Homographs |\n|---|---|---|---|---|---|\n";
function writesIdentifierFields() {
  const NEW = "The first fixture term, declared.";
  const v3 = V3_TABLE +
    "| beta gate | user | add | A promoted gate. | `beta-gate` | `beta gating` |\n" +
    `| alpha | user | redefine | ${NEW} | \`ALPHA\` |  |\n`;
  const { repo, intent } = session("v3-fields", [], { glossary: v3 });
  check("T3-5 V3 add + redefine rows: exit 0, ADDED=1 REDEFINED=1", () => {
    const r = promote(intent, repo);
    eq(r.code, 0, `exit (out: ${r.all})`);
    const n = counters(r.out);
    eq([n.ADDED, n.REDEFINED], [1, 1], "ADDED / REDEFINED");
  });
  check("T3-5 a V3 add writes the Identifier and Homographs bullets between Definition and Related", () => {
    const block = blockOf(readFile(repo, "docs/glossary/user.md"), "beta gate");
    ok(/- \*\*Definition\*\*: A promoted gate\.\n- \*\*Identifier\*\*: `beta-gate`\n- \*\*Homographs\*\*: `beta gating`\n- \*\*Related\*\*:/.test(block),
      `beta gate entry: ${block}`);
  });
  check("T3-5 a V3 redefine writes the Identifier bullet after the new Definition", () => {
    const block = blockOf(readFile(repo, "docs/glossary/user.md"), "alpha");
    ok(new RegExp(`- \\*\\*Definition\\*\\*: ${NEW.replace(/\./g, "\\.")}\\n- \\*\\*Identifier\\*\\*: \`ALPHA\`\\n- \\*\\*Related\\*\\*:`).test(block),
      `alpha entry: ${block}`);
  });

  const c = require("./lib");
  const files = Object.assign({}, c.BASE || {});
  const userKey = "docs/glossary/user.md";
  const tagged = String(files[userKey] || "").replace(/(### alpha\n\n- \*\*Definition\*\*: [^\n]*\n)/, "$1- **Identifier**: `ALPHA`\n");
  const repo2 = c.mkRepo("v2-keeps-fields", Object.assign(files, { [userKey]: tagged }));
  const sid2 = c.approvedSession("v2-keeps-fields", [["alpha", "user", "redefine", NEW]], { cwd: repo2 });
  check("T3-5 a V2 redefine row keeps the Identifier bullet already in the entry", () => {
    ok(/Identifier/.test(tagged), `fixture alpha entry carries an Identifier: ${tagged}`);
    const r = promote(c.intentPath(sid2), repo2);
    eq(r.code, 0, `exit (out: ${r.all})`);
    const block = blockOf(readFile(repo2, userKey), "alpha");
    ok(block.includes(`- **Definition**: ${NEW}`) && block.includes("- **Identifier**: `ALPHA`"), `alpha entry: ${block}`);
  });
}

// #2763 S2-5: an empty V3 cell writes no bullet; on a redefine it removes the bullet already there.
function emptyCellsWriteNoFields() {
  const NEW = "The first fixture term, cleared.";
  const c = require("./lib");
  const userKey = "docs/glossary/user.md";
  const files = Object.assign({}, c.BASE || {});
  const tagged = String(files[userKey] || "").replace(/(### alpha\n\n- \*\*Definition\*\*: [^\n]*\n)/, "$1- **Identifier**: `ALPHA`\n");
  const repo = c.mkRepo("v3-empty-cells", Object.assign(files, { [userKey]: tagged }));
  const v3 = V3_TABLE + "| gamma gate | user | add | A plain gate. |  |  |\n" + `| alpha | user | redefine | ${NEW} |  |  |\n`;
  const sid = c.approvedSession("v3-empty-cells", [], { cwd: repo, glossary: v3 });
  check("T3-5 V3 add + redefine rows with empty cells: exit 0, ADDED=1 REDEFINED=1", () => {
    ok(/Identifier/.test(tagged), `fixture alpha entry carries an Identifier: ${tagged}`);
    const r = promote(c.intentPath(sid), repo);
    eq(r.code, 0, `exit (out: ${r.all})`);
    const n = counters(r.out);
    eq([n.ADDED, n.REDEFINED], [1, 1], "ADDED / REDEFINED");
  });
  check("T3-5 a V3 add with both cells empty writes no Identifier or Homographs bullet", () => {
    const block = blockOf(readFile(repo, userKey), "gamma gate");
    ok(/- \*\*Definition\*\*: A plain gate\.\n- \*\*Related\*\*:/.test(block) && !/Identifier|Homographs/.test(block),
      `gamma gate entry: ${block}`);
  });
  check("T3-5 a V3 redefine with an empty Identifier cell removes the existing Identifier bullet", () => {
    const block = blockOf(readFile(repo, userKey), "alpha");
    ok(block.includes(`- **Definition**: ${NEW}`) && !/Identifier/.test(block), `alpha entry: ${block}`);
  });
}

module.exports = { appliesAllOperations, skippedExisting, sameCategoryRewrite, caseOnlyRename, writesIdentifierFields,
  emptyCellsWriteNoFields };
