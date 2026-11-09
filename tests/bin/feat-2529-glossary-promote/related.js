"use strict";
// Tests: bin/glossary-promote
// Tags: TL2, bin, glossary, promote, scope:issue-specific
// #2962 part of tests/bin/feat-2529-glossary-promote-atomic.js: glossary-promote takes the
// Related link of each new entry as `--related "<term>=<markdown link>"` and writes it instead of
// `Related: TODO`. A new entry without a pair, or a link of the wrong form, stops promote (exit 1)
// before any file is written; a malformed pair set is usage (exit 2). Holds no case markers.

const { check, eq, ok, LINK, promote, snapshot, unchanged, counters, session, readFile, runNode, fwd } = require("./lib");

const USER = "docs/glossary/user.md";
const INTERNAL = "docs/glossary/internal.md";
const TWO_ADDS = [["beta", "user", "add", "A related fixture term."], ["lima", "internal", "add", "A related internal term."]];

// blockOf(text, term) — the `### term` entry block, up to the next entry.
function blockOf(text, term) {
  const t = String(text || "");
  const at = t.indexOf(`### ${term}\n`);
  if (at < 0) return "";
  const next = t.indexOf("\n### ", at + 1);
  return t.slice(at, next < 0 ? undefined : next);
}
const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

function writesLink() {
  const s = session("rel-ok", TWO_ADDS);
  check("--related: every add given a pair promotes (exit 0, ADDED=2)", () => {
    const r = promote(s.intent, s.repo, { beta: LINK, lima: "[README.md](../../README.md#fixture)" });
    eq(r.code, 0, `exit (out: ${r.all})`);
    eq(counters(r.out).ADDED, 2, "ADDED");
  });
  check("--related: the new entry carries `- **Related**: <link>` and no TODO", () => {
    const beta = blockOf(readFile(s.repo, USER), "beta");
    const lima = blockOf(readFile(s.repo, INTERNAL), "lima");
    ok(new RegExp(`- \\*\\*Related\\*\\*: ${esc(LINK)}\\n?`).test(beta) && !/TODO/.test(beta), `beta entry: ${beta}`);
    ok(/- \*\*Related\*\*: \[README\.md\]\(\.\.\/\.\.\/README\.md#fixture\)/.test(lima) && !/TODO/.test(lima), `lima entry: ${lima}`);
  });
  const ex = session("rel-existing", [["alpha", "user", "add", "A differently worded alpha."]]);
  check("--related: an add of an existing term (SKIPPED_EXISTING) needs no pair", () => {
    const r = promote(ex.intent, ex.repo);
    eq(r.code, 0, `exit (out: ${r.all})`);
    eq(counters(r.out).SKIPPED_EXISTING, 1, "SKIPPED_EXISTING");
  });
}

// (a) an add that is actually written but has no pair: exit 1, nothing written, the terms listed,
// and the way out (hand edit + GLOSSARY_ACCEPTED) on one line.
function missingRelated() {
  for (const [label, related] of [["no pair at all", {}], ["one of two pairs", { beta: LINK }]]) {
    const s = session("rel-missing", TWO_ADDS);
    const before = snapshot(s.repo);
    check(`--related missing (${label}): exit 1, no file written, the term without a pair is named`, () => {
      const r = promote(s.intent, s.repo, related);
      eq(r.code, 1, `exit (out: ${r.all})`);
      unchanged(s.repo, before);
      ok(/\blima\b/.test(r.err), `stderr names lima: ${r.err}`);
      if (!related.beta) ok(/\bbeta\b/.test(r.err), `stderr names beta: ${r.err}`);
      ok(r.err.split("\n").some((l) => /GLOSSARY_ACCEPTED/.test(l) && /hand|by hand|edit/.test(l)), `one exit line: ${r.err}`);
    });
  }
}

// (b) a link of the wrong form: exit 1 before any write.
function malformedLink() {
  const BAD = [["TODO", "beta=TODO"], ["no link", "beta=see the README"], ["two links", `beta=${LINK} ${LINK}`],
    ["empty value", "beta="], ["a line break injecting a bullet", `beta=${LINK}\n- **Definition**: injected`],
    ["a line break injecting an entry", `beta=${LINK}\n### injected\n- **Definition**: x`],
    ["a carriage return inside", `beta=${LINK}\r- **Related**: ${LINK}`], ["a tab inside", `beta=[README.md]\t(../../README.md)`]];
  for (const [label, value] of BAD) {
    const s = session("rel-bad", [TWO_ADDS[0]]);
    const before = snapshot(s.repo);
    check(`--related of the wrong form (${label}): exit 1, no file written`, () => {
      const r = promote(s.intent, s.repo, [value]);
      eq(r.code, 1, `exit (out: ${r.all})`);
      unchanged(s.repo, before);
    });
  }
}

// (c) a redefine keeps the entry's existing Related line and needs no pair.
function redefineKeepsRelated() {
  const NEW = "The first fixture term, re-related.";
  const s = session("rel-redefine", [["alpha", "user", "redefine", NEW]]);
  check("--related: a redefine without a pair keeps the existing Related line", () => {
    const r = promote(s.intent, s.repo);
    eq(r.code, 0, `exit (out: ${r.all})`);
    const block = blockOf(readFile(s.repo, USER), "alpha");
    ok(block.includes(`- **Definition**: ${NEW}`) && new RegExp(`- \\*\\*Related\\*\\*: ${esc(LINK)}`).test(block), `alpha entry: ${block}`);
  });
}

// (d) usage: a duplicate term, a value without `=`, a pair for a term without an add row.
function usage() {
  const rows = [TWO_ADDS[0], ["alpha", "user", "redefine", "The first fixture term, usage."], ["omega", "user", "delete", ""]];
  const CASES = [
    ["the same term twice", [`beta=${LINK}`, `beta=${LINK}`]],
    ["a value without =", ["beta"]],
    ["a pair for a redefine-only term", [`beta=${LINK}`, `alpha=${LINK}`]],
    ["a pair for a delete-only term", [`beta=${LINK}`, `omega=${LINK}`]],
    ["a pair for a term not in the intent", [`beta=${LINK}`, `zeta=${LINK}`]],
    ["an empty term (=link)", [`=${LINK}`]],
    ["a blank term (  =link)", [`  =${LINK}`]],
    ["the same term twice, differing only in case", [`beta=${LINK}`, `BETA=${LINK}`]],
  ];
  for (const [label, values] of CASES) {
    const s = session("rel-usage", rows);
    const before = snapshot(s.repo);
    check(`--related usage (${label}): exit 2, no file written`, () => {
      const r = promote(s.intent, s.repo, values);
      eq(r.code, 2, `exit (out: ${r.all})`);
      unchanged(s.repo, before);
    });
  }
  // A trailing --related with no value cannot be built by promote() (it always pairs a value).
  const s = session("rel-usage-trailing", rows);
  const before = snapshot(s.repo);
  check("--related usage (a trailing --related with no value): exit 2, no file written", () => {
    const r = runNode("bin/glossary-promote", [fwd(s.intent), s.repo, "--related", `beta=${LINK}`, "--related"], { cwd: s.repo });
    eq(r.code, 2, `exit (out: ${r.all})`);
    unchanged(s.repo, before);
  });
}

// (e) the pair's term matches the add row's term case-insensitively; the entry keeps the row's spelling.
function caseInsensitiveTerm() {
  const s = session("rel-case", [TWO_ADDS[0]]);
  check("--related: a pair whose term differs only in case from the add row promotes (exit 0, ADDED=1)", () => {
    const r = promote(s.intent, s.repo, [`BETA=${LINK}`]);
    eq(r.code, 0, `exit (out: ${r.all})`);
    eq(counters(r.out).ADDED, 1, "ADDED");
    const beta = blockOf(readFile(s.repo, USER), "beta");
    ok(new RegExp(`- \\*\\*Related\\*\\*: ${esc(LINK)}`).test(beta) && !/TODO/.test(beta), `beta entry: ${beta}`);
    ok(!/### BETA/.test(readFile(s.repo, USER)), "heading keeps the add row's spelling");
  });
}

module.exports = { writesLink, missingRelated, malformedLink, redefineKeepsRelated, usage, caseInsensitiveTerm };
