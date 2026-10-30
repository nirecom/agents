"use strict";
// Output text of the outbound scanner, word for word what bin/scan-outbound.sh printed:
// one `file:line: [kind] match` row per finding and the summary after the last file.

const findingLine = (f) => `${f.file}:${f.line}: [${f.kind}] ${f.matched}`;

// counts(findings) -> { hard, warn }
function counts(findings) {
  const warn = findings.filter((f) => f.severity === "warn").length;
  return { hard: findings.length - warn, warn };
}

// summaryLines({hard, warn}) -> the lines after the findings ([] when clean).
function summaryLines({ hard, warn }) {
  if (hard > 0) return ["", `Found ${hard} hard violation(s), ${warn} warning(s)`];
  if (warn > 0) return ["", `Found ${warn} warning(s) (no hard violation)`];
  return [];
}

// rcOf({hard, warn}) -> 1 hard, 2 warn only, 0 clean.
const rcOf = ({ hard, warn }) => (hard > 0 ? 1 : warn > 0 ? 2 : 0);

const verdictOf = ({ hard, warn }) => (hard > 0 ? "block" : warn > 0 ? "warn" : "pass");

// incompleteLine(reason) -> the stderr line of a scan that cannot run (rc 4).
const incompleteLine = (reason) => `Error: ${reason} — cannot scan`;

module.exports = { findingLine, counts, summaryLines, rcOf, verdictOf, incompleteLine };
