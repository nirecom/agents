"use strict";
// Inputs 2 (combined glossary) and 3 (intent `## Glossary` rows) of the glossary-check
// fingerprint (#2529 I-FP). The glossary is read from the session's own worktree (#2796), so a
// glossary change on main moves the digest only once the branch takes it in.

const fs = require("fs");
const { toWindowsPath } = require("../../../lib/branch-diff");
const { parseIntentGlossary } = require("../../../lib/intent-glossary");
const { listMainGlossaryFiles } = require("../../../../bin/lib/glossary-format/files");
const { parseGlossaryFile, entryFields } = require("../../../../bin/lib/glossary-format/entries");
const { normalizeDefinition } = require("../../../../bin/lib/glossary-provenance");
const { normalizeTerm } = require("../../../lib/glossary-term");
const { sha256, git } = require("./artifact");

function worktreeRootOf(repoDir) {
  const top = git(repoDir, ["rev-parse", "--show-toplevel"]).toString("utf8").trim();
  if (!top) throw new Error("git rev-parse --show-toplevel: empty output");
  return toWindowsPath(top);
}

// One record per exact term: the entries of one term (in several files) pool their Identifier and
// Short forms spellings. The drift matcher never matches Short forms; they feed termFieldsOf only.
function addRecord(records, e) {
  const { identifiers, shortForms } = entryFields(e);
  const prev = records.get(e.term);
  if (!prev) { records.set(e.term, { term: e.term, identifiers, shortForms }); return; }
  prev.identifiers = [...new Set(prev.identifiers.concat(identifiers))];
  prev.shortForms = [...new Set(prev.shortForms.concat(shortForms))];
}

// termFieldsOf(terms) -> { norm: sha } over the matching fields (heading, Identifier, Short forms)
// of the records sharing that norm (#2962); Definition and Related stay out.
function termFieldsOf(terms) {
  const byNorm = new Map();
  for (const t of Array.isArray(terms) ? terms : []) {
    const norm = normalizeTerm(t.term);
    const key = [t.term, [...(t.identifiers || [])].sort(), [...(t.shortForms || [])].sort()];
    byNorm.set(norm, (byNorm.get(norm) || []).concat([JSON.stringify(key)]));
  }
  const out = Object.create(null); // a norm such as "__proto__" stays an own key
  for (const [norm, keys] of byNorm) out[norm] = sha256(JSON.stringify(keys.sort()));
  return out;
}

// combinedGlossary(opts) -> { ok, files: [{ label, category, sha }], terms, digest, legacy };
// terms are the records { term, identifiers, shortForms } (#2763), one per exact term.
function combinedGlossary(opts) {
  try {
    const listed = listMainGlossaryFiles(worktreeRootOf(opts.repoDir));
    const files = [];
    const records = new Map();
    for (const f of listed.files) {
      const buf = fs.readFileSync(toWindowsPath(f.path));
      files.push({ label: f.label, category: f.category, sha: sha256(buf) });
      for (const e of parseGlossaryFile(buf.toString("utf8")).entries) addRecord(records, e);
    }
    const terms = [...records.values()];
    files.sort((a, b) => (a.label < b.label ? -1 : a.label > b.label ? 1 : 0));
    const legacy = listed.legacy === true;
    const digest = sha256(JSON.stringify([files.map((f) => [f.label, f.sha]), legacy]));
    return { ok: true, files, terms, digest, legacy };
  } catch (e) {
    return { ok: false, error: "glossary-unavailable", detail: e && e.message ? e.message : String(e) };
  }
}

// The term stays case-exact: the drift scan (glossary-drift.js indexTerms) treats the exact
// spelling as the non-variant form, so a case-only change moves the scan and must move the digest.
// A V3 row's fields are part of the approved row (Identifier also feeds the scan); a V1 / V2 row
// keeps the four-value key.
function rowsDigest(rows) {
  const keys = rows.map((r) => {
    const key = [String(r.term), r.category, r.operation, normalizeDefinition(r.definition)];
    if (Array.isArray(r.identifiers)) key.push(r.identifiers, r.shortForms);
    return JSON.stringify(key);
  }).sort();
  return sha256(JSON.stringify(keys));
}

function rowsOfText(text) {
  const rows = typeof text === "string" ? parseIntentGlossary(text).rows : [];
  return { rows, digest: rowsDigest(rows) };
}

// intentRowsOf(sid, rangeText) -> { ok, rows, digest }. rangeText: the intent stage's own
// range; otherwise intent.md is read once here (absent = no rows).
function intentRowsOf(sid, rangeText) {
  if (typeof rangeText === "string") return Object.assign({ ok: true }, rowsOfText(rangeText));
  let text = null;
  try {
    const { resolvePlanArtifactOwner } = require("../../plan-artifact-owner");
    text = fs.readFileSync(toWindowsPath(resolvePlanArtifactOwner(sid, "intent").path), "utf8");
  } catch (e) {
    if (!e || e.code !== "ENOENT") {
      return { ok: false, error: "intent-unreadable", detail: e && e.message ? e.message : String(e) };
    }
  }
  return Object.assign({ ok: true }, rowsOfText(text));
}

module.exports = { worktreeRootOf, combinedGlossary, intentRowsOf, termFieldsOf };
