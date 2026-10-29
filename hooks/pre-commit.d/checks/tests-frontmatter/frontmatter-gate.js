"use strict";
// Frontmatter gate of the tests-frontmatter check (#2507 D7; ports _precommit_check_tests_frontmatter
// of hooks/lib/precommit-tests-frontmatter.sh). Staged tests/ entrypoints go through the --staged
// frontmatter check with the staged and HEAD blobs taken from the snapshot.

const fs = require("fs");
const path = require("path");
const R = require("../../../lib/test-gates/registry");
const FM = require("../../../lib/test-gates/frontmatter");
const { toWindowsPath } = require("../../../lib/branch-diff");
const { out, err } = require("../../output");

const SUITE_SUBFILE = /^tests\/(hooks|bin|skills|agents|install|tests)\/[^/]*\//;
const PLACED = /^tests\/(hooks|bin|skills|agents|install|tests)\//;
const EXCLUDED = /^tests\/(_archive|lib)\//;

function readDisk(abs) {
  try {
    const p = toWindowsPath(abs);
    return fs.statSync(p).isFile() ? fs.readFileSync(p) : null;
  } catch {
    return null;
  }
}

function io(context, snapshot) {
  const repoRoot = String(context.repoTop).replace(/\\/g, "/");
  return {
    repoRoot,
    relOf: (f) => f,
    staged: (rel) => snapshot.content(rel),
    work: (f) => readDisk(path.join(context.repoTop, f)),
    head: (rel) => snapshot.headContent(rel),
    isFile: (abs) => readDisk(abs) !== null,
  };
}

// selectTests(files) -> { tests, messages } or null when the registry is unreadable.
function selectTests(files) {
  const tests = [];
  const messages = [];
  for (const f of files) {
    if (EXCLUDED.test(f) || f === "tests/run-all.sh" || !f.startsWith("tests/")) continue;
    if (!R.tryReg()) return null;
    const m = R.match(f);
    if (!m || SUITE_SUBFILE.test(f)) continue;
    if (m.status !== "supported") {
      if (PLACED.test(f)) messages.push(err(`UNSUPPORTED: ${f} (language: ${m.id}; not checked)`));
      continue;
    }
    tests.push(f);
  }
  return { tests, messages };
}

function summaries(lines) {
  const msgs = [];
  if (lines.some((l) => /^FLAT_TEST_[A-Z_]*REJECTED:/.test(l))) {
    const labels = R.reg().entries.filter((e) => e.status === "supported").map((e) => R.fieldValue(e, "diagnostics.nameLabel")).filter(Boolean);
    msgs.push("Commit blocked: new test entrypoint placed directly under tests/.");
    msgs.push(`A test entrypoint (${labels.join(" / ")}) must live under tests/<category>/ (categories: ${R.CATEGORIES.join(" ")}).`);
    msgs.push("Move it into the matching category dir, e.g. tests/hooks/<name>.sh.");
  }
  if (lines.some((l) => /MISSING_TESTS_HEADER|INVALID_TESTS_TOKEN|MISSING_SCOPE_TAG|MISSING_HARNESS_SOURCE/.test(l))) {
    msgs.push("Commit blocked: staged test file(s) fail frontmatter validation.");
    msgs.push("Each file must have '# Tests: <path>' (comma-separated tokens) and '# Tags: ... scope:...'.");
  }
  if (lines.some((l) => /^HIGH: .* code=SELF_IMPLEMENTED_HARNESS/.test(l))) {
    msgs.push("Commit blocked: test file(s) add a self-implemented harness HEAD does not have.");
    msgs.push("Load the language's helper library (tests/lib/harness.*) and use its counters and helpers instead.");
  }
  return msgs.map(out);
}

// gate({ context, snapshot, files }) -> { block, messages }.
function gate({ context, snapshot, files }) {
  const sel = selectTests(files);
  if (!sel) return { block: false, messages: [err("pre-commit: test language registry not readable — frontmatter check skipped (commit continues)")] };
  if (sel.tests.length === 0) return { block: false, messages: sel.messages };
  const r = FM.stagedCheck(sel.tests, io(context, snapshot));
  if (r.rc === 0) return { block: false, messages: [...sel.messages, ...r.lines.filter((l) => /^WARN: .* code=/.test(l)).map(err)] };
  return { block: true, messages: [...sel.messages, ...r.lines.map(out), out(""), ...summaries(r.lines)] };
}

module.exports = { gate };
