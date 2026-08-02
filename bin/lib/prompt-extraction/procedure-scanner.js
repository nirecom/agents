"use strict";
// bin/lib/prompt-extraction/procedure-scanner.js
// rules/prompt.md §1.3 detection: inline procedures of MORE THAN 3 steps.
//
// Counting axes (CPR-3 — kept separate on purpose):
//   * section  — a markdown heading opens a new section and resets every series
//   * prefix   — "numbered" and each label prefix (WE, SC, WF-CODE, ...) count apart
//   * identity — the same full label inside one section counts once (cross-refs)
// Sub-bullets and prose between steps do NOT reset a series.

const { fenceMask } = require("./fence-scanner");

const HEADING_RE = /^#{1,6} /;
const NUMBERED_RE = /^\s*\d+\.\s/;
const LABEL_RE =
  /^\s*(?:[-*]\s*)?(?:\*\*)?([A-Z][A-Z0-9]*(?:-[A-Z][A-Z0-9]*)*)-(\d+)([a-z])?\b/;
const STEP_THRESHOLD = 3; // violation at STEP_THRESHOLD + 1 steps

/**
 * @param {string[]} lines
 * @returns {{violations: Array<{line: number, sectionHeading: string,
 *                               stepCount: number, prefix: string}>}}
 */
function scanProcedures(lines) {
  const mask = fenceMask(lines);
  const violations = [];
  let heading = "(document)";
  let series = new Map();

  for (let i = 0; i < lines.length; i += 1) {
    if (mask[i]) continue;
    const line = lines[i];

    if (HEADING_RE.test(line)) {
      heading = line.replace(/^#+\s*/, "").trim();
      series = new Map();
      continue;
    }

    let prefix = null;
    let label = null;
    if (NUMBERED_RE.test(line)) {
      prefix = "numbered";
    } else {
      const m = LABEL_RE.exec(line);
      if (m) {
        prefix = m[1];
        label = `${m[1]}-${m[2]}${m[3] || ""}`;
      }
    }
    if (prefix === null) continue;

    let s = series.get(prefix);
    if (!s) {
      s = {
        firstLine: i + 1,
        labels: new Set(),
        count: 0,
        reported: false,
      };
      series.set(prefix, s);
    }
    if (label !== null) {
      if (s.labels.has(label)) continue;
      s.labels.add(label);
    }
    s.count += 1;
    if (s.count > STEP_THRESHOLD && !s.reported) {
      s.reported = true;
      violations.push({
        line: s.firstLine,
        sectionHeading: heading,
        stepCount: s.count,
        prefix,
      });
    }
  }

  return { violations };
}

module.exports = { scanProcedures };
