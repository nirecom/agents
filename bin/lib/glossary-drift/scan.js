"use strict";
// bin/lib/glossary-drift/scan.js — the drift findings of one text (findDrift: the prose layer and
// the identifier layer merged in line / column order) and of one loadStageInputs result.
// Matching rules SSOT: docs/architecture/claude-code/glossary-check.md#matching-rules.

const { normalizeTerm } = require("../../../hooks/lib/glossary-term");
const { extractLayers } = require("./extract");
const { indexTerms } = require("./terms");
const { findVariants } = require("./match");

function driftWith(text, format, index) {
  const { prose, ident, commentLines } = extractLayers(text, format);
  return findVariants(prose, null, { index, commentLines })
    .concat(findVariants(ident, null, { index, layer: "ident" }))
    .sort((a, b) => a.line - b.line || a.col - b.col);
}

// findDrift(text, format, terms) -> [{ term, variant, line }]; format: "markdown" | "code".
function findDrift(text, format, terms) {
  return driftWith(text, format, indexTerms(terms)).map(({ term, variant, line }) => ({ term, variant, line }));
}

// scanStageInputs(inputs) -> [{ term, norm, variant, path, line, where }] over the artifact files
// of one loadStageInputs result; a file's lineMap maps a range line back to its file line. A
// term an intent row deletes is no canonical term, even while the glossary file still lists it;
// an add / redefine row of the same term (a category move) keeps it. A delete row matches its own
// spelling only (case-insensitive), so deleting "workflows" leaves a distinct "workflow" heading.
const spellingKey = (s) => String(s == null ? "" : s).trim().toLowerCase();
function scanStageInputs(inputs) {
  const rows = (inputs && inputs.intentRows && inputs.intentRows.rows) || [];
  const kept = rows.filter((r) => r.operation !== "delete");
  const keptKeys = new Set(kept.map((r) => spellingKey(r.term)));
  const deleted = new Set(rows.filter((r) => r.operation === "delete").map((r) => spellingKey(r.term))
    .filter((k) => !keptKeys.has(k)));
  const terms = [...((inputs && inputs.glossary && inputs.glossary.terms) || [])]
    .concat(kept.map((r) => r.term))
    .filter((t) => !deleted.has(spellingKey(t)));
  const index = indexTerms(terms);
  const hits = [];
  for (const file of (inputs && inputs.artifact && inputs.artifact.files) || []) {
    if (typeof file.text !== "string" || file.text === "") continue;
    for (const v of driftWith(file.text, file.kind, index)) {
      const line = Array.isArray(file.lineMap) && file.lineMap[v.line - 1] ? file.lineMap[v.line - 1] : v.line;
      hits.push({ term: v.term, norm: normalizeTerm(v.term), variant: v.variant, path: file.path, line, where: `${file.path}:${line}` });
    }
  }
  return hits;
}

module.exports = { findDrift, scanStageInputs };
