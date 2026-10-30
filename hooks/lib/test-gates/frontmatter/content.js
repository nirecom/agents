"use strict";
// The checks of one test file's text (#2507 D7; ports check_content and check_harness_source of
// bin/check-test-frontmatter.sh). Each returns the diagnostic lines; none means it passed.

const { translateEre } = require("../../ere/translate");

const TOKEN_VALID = /^[A-Za-z0-9._/-]+$/;
const SCOPE_TAG = /scope:[ \t\n\v\f\r]*(issue-specific|common)/;

// normalizeContent(s) — the text as `$(...)` captures it and printf '%s\n' writes it back.
const normalizeContent = (s) => `${String(s).replace(/\n+$/, "")}\n`;

const trim = (s) => s.replace(/^[ \t\n\v\f\r]+|[ \t\n\v\f\r]+$/g, "");

function testsLines(f, testsLine) {
  const csv = testsLine ? trim(testsLine.slice(testsLine.indexOf("Tests:") + "Tests:".length)) : "";
  if (!csv) return [`MISSING_TESTS_HEADER: ${f}`];
  return csv.split(",").map(trim).filter((t) => t && !TOKEN_VALID.test(t)).map((t) => `INVALID_TESTS_TOKEN: ${f}: ${t}`);
}

function tagsLines(f, tagsLine) {
  if (!tagsLine) return [`MISSING_SCOPE_TAG: ${f} (no # Tags: line)`];
  if (SCOPE_TAG.test(tagsLine)) return [];
  return [`MISSING_SCOPE_TAG: ${f} (# Tags: line lacks scope:issue-specific or scope:common)`];
}

// checkContent(f, testsLine, tagsLine) — the `# Tests:` and `# Tags:` diagnostics of f.
const checkContent = (f, testsLine, tagsLine) => [...testsLines(f, testsLine), ...tagsLines(f, tagsLine)];

// harnessSourced(content, ere) — a line of content matches the helper library's sourceRegex
// (an ERE the JS RegExp cannot hold matches nothing, as a grep that rejects it).
function harnessSourced(content, ere) {
  const t = translateEre(ere);
  if (t.status !== "ok") return false;
  return String(content).split("\n").some((line) => t.regex.test(line));
}

module.exports = { normalizeContent, checkContent, harnessSourced };
