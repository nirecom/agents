"use strict";
// Frontmatter gate of the tests-frontmatter check (#2507 D7; ports _precommit_check_tests_frontmatter
// of hooks/lib/precommit-tests-frontmatter.sh). Staged tests/ entrypoints go through the --staged
// frontmatter check with the staged blobs taken from the snapshot, judged against every parent
// commit (HEAD, or MERGE_HEAD during a merge, #2812).

const fs = require("fs");
const path = require("path");
const R = require("../../../lib/test-gates/registry");
const FM = require("../../../lib/test-gates/frontmatter");
const FP = require("../../../lib/test-gates/frontmatter/parents");
const { toWindowsPath } = require("../../../lib/branch-diff");
const { out, err } = require("../../output");
const { parentsOf } = require("./parents");

const rootOf = (context) => String(context.repoTop).replace(/\\/g, "/");

function readDisk(abs) {
  try {
    const p = toWindowsPath(abs);
    return fs.statSync(p).isFile() ? fs.readFileSync(p) : null;
  } catch {
    return null;
  }
}

// io(context, snapshot, tests, par) — par: the shared merge parents (./parents.js, #2812).
function io(context, snapshot, tests, par) {
  const repoRoot = String(context.repoTop).replace(/\\/g, "/");
  return {
    repoRoot,
    relOf: (f) => f,
    staged: (rel) => snapshot.content(rel),
    work: (f) => readDisk(path.join(context.repoTop, f)),
    head: (rel) => snapshot.headContent(rel),
    isFile: (abs) => readDisk(abs) !== null,
    parents: FP.parentsIo(tests, par.record, par.blobs),
  };
}

// selectTests(files, root) -> { tests, messages } or null when the registry is unreadable. Placement
// comes from root's .agents.json tests section (#2473): support dirs, the runner and a category's
// suite subfiles are not tests; a subfile outside every category is still checked (legacy).
function selectTests(files, root) {
  const tests = [];
  const messages = [];
  for (const f of files) {
    const p = R.placementOf(root, f);
    if (p.kind === "outside" || p.kind === "support" || p.kind === "runner") continue;
    if (!R.tryReg()) return null;
    const m = R.match(f);
    if (!m || (p.kind === "suite-subfile" && p.category !== null)) continue;
    if (m.status !== "supported") {
      if (p.kind === "category") messages.push(err(`UNSUPPORTED: ${f} (language: ${m.id}; not checked)`));
      continue;
    }
    tests.push(f);
  }
  return { tests, messages };
}

function summaries(lines, root) {
  const l = R.layoutFor(root);
  const msgs = [];
  if (lines.some((l) => /^FLAT_TEST_[A-Z_]*REJECTED:/.test(l))) {
    const labels = R.reg().entries.filter((e) => e.status === "supported").map((e) => R.fieldValue(e, "diagnostics.nameLabel")).filter(Boolean);
    msgs.push("Commit blocked: new test entrypoint placed directly under tests/.");
    const cats = R.categoriesFor(root);
    msgs.push(`A test entrypoint (${labels.join(" / ")}) must live under ${l.dir}/<category>/ (categories: ${cats.join(" ")}).`);
    const shapeEntry = R.reg().entries.find((e) => e.status === "supported" && R.fieldValue(e, "newFileNameShape"));
    const example = shapeEntry ? `${l.dir}/${cats[0]}/${R.fieldValue(shapeEntry, "newFileNameShape")}` : `${l.dir}/${cats[0]}/`;
    msgs.push(`Move it into the matching category dir, e.g. ${example}.`);
  }
  if (lines.some((l) => /MISSING_TESTS_HEADER|INVALID_TESTS_TOKEN|MISSING_SCOPE_TAG|MISSING_HARNESS_SOURCE/.test(l))) {
    msgs.push("Commit blocked: staged test file(s) fail frontmatter validation.");
    msgs.push("Each file must have '# Tests: <path>' (comma-separated tokens) and '# Tags: ... scope:...'.");
  }
  if (lines.some((l) => /^HIGH: .* code=SELF_IMPLEMENTED_HARNESS/.test(l))) {
    msgs.push("Commit blocked: test file(s) add a self-implemented harness the parent commit(s) do not have.");
    msgs.push("Load the language's helper library (tests/lib/harness.*) and use its counters and helpers instead.");
  }
  return msgs.map(out);
}

// gate({ context, snapshot, files }) -> { block, messages }.
function gate({ context, snapshot, files }) {
  const root = rootOf(context);
  const sel = selectTests(files, root);
  if (!sel) return { block: false, messages: [err("pre-commit: test language registry not readable — frontmatter check skipped (commit continues)")] };
  if (sel.tests.length === 0) return { block: false, messages: sel.messages };
  const par = parentsOf({ context, snapshot, files });
  const fio = io(context, snapshot, sel.tests, par);
  const uninit = R.uninitializedWarn(root);
  const msgs = [...par.note(), ...sel.messages, ...(uninit ? [err(uninit)] : [])];
  const r = FM.stagedCheck(sel.tests, fio);
  if (r.rc === 0) return { block: false, messages: [...msgs, ...r.lines.filter((l) => /^WARN: .* code=/.test(l)).map(err)] };
  return { block: true, messages: [...msgs, ...r.lines.map(out), out(""), ...summaries(r.lines, root)] };
}

module.exports = { gate };
