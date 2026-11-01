"use strict";
// Text builders for tests/bin/feature-2763-glossary-fields.js (#2763 S2): glossary files with the
// optional Identifier / Homographs bullets, and intent Glossary tables in the V2 and V3 forms.

const RELATED = "- **Related**: [README.md](../../README.md)";
const V2_HEADER = "| Term | Category | Operation | Definition |\n|---|---|---|---|";
const V3_HEADER = "| Term | Category | Operation | Definition | Identifier | Homographs |\n|---|---|---|---|---|---|";

const tick = (list) => list.map((s) => `\`${s}\``).join(", ");

// entry(term, def, { identifiers, homographs, extra }) -> one `### term` block; a list becomes a
// backticked value, a string is written as given (for the malformed-value rows).
function entry(term, def, o) {
  const opt = o || {};
  const lines = [`### ${term}`, "", `- **Definition**: ${def}`];
  const field = (key, v) => {
    if (v === undefined) return;
    lines.push(`- **${key}**: ${Array.isArray(v) ? tick(v) : v}`.replace(/\s+$/, ""));
  };
  field("Identifier", opt.identifiers);
  field("Homographs", opt.homographs);
  for (const x of opt.extra || []) lines.push(x);
  lines.push(RELATED);
  return lines.join("\n") + "\n";
}

// file(title, entries) -> a whole glossary file; entries must already be in term order.
function file(title, entries) {
  return `# Glossary — ${title} terms\n\n${entries.join("\n")}`;
}

// intent(table) -> an intent whose ## Glossary holds `table` (header included).
function intent(table) {
  return `# Intent\n\n**Title:** fields fixture\n\n**PM type:** waterfall\n\n## Issues\n\n- #1: fixture\n\n` +
    `## Glossary\n\n${table}\n\n## Goal\n\nDeclare spellings.\n`;
}

// v3Row(term, category, operation, def, identifiers, homographs) -> one V3 table row.
function v3Row(term, category, operation, def, identifiers, homographs) {
  const cell = (v) => (Array.isArray(v) ? tick(v) : (v || ""));
  return `| ${term} | ${category} | ${operation} | ${def} | ${cell(identifiers)} | ${cell(homographs)} |`;
}
const v2Row = (term, category, operation, def) => `| ${term} | ${category} | ${operation} | ${def} |`;

const v3 = (rows) => intent(`${V3_HEADER}\n${rows.join("\n")}`);
const v2 = (rows) => intent(`${V2_HEADER}\n${rows.join("\n")}`);

module.exports = { entry, file, intent, v2, v3, v2Row, v3Row, V2_HEADER, V3_HEADER };
