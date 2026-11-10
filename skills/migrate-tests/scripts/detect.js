#!/usr/bin/env node
"use strict";
// detect(root) — proposes the .agents.json tests section from what <root>/tests already holds.
// Files directly under tests/ only → categorization flat; any subdirectory → by-target / by-type
// candidates (by-target first when every subdirectory names a top-level source dir). One existing
// test without a load statement of the agents test harness (a mention in a comment or string does
// not count) → testHarness and caseMarker off.
// Each subdirectory holding tests becomes a category (by-target: covers its same-named source dir);
// every other directory directly under tests/ becomes a supportDir. `sections[<candidate>]` is the
// whole tests section ready for `bin/repo-settings --write-tests`. `uncoveredTests` lists the test
// files that section cannot place (a stray file beside categories, a deep file with no entrypoint).
// CLI: node detect.js [--root <dir>] → the proposal as JSON on stdout.

const fs = require("fs");
const path = require("path");
const HOOKS_LIB = path.join(__dirname, "..", "..", "..", "hooks", "lib");
const { nativePath, placementIn } = require(path.join(HOOKS_LIB, "repo-settings"));
const { entriesWhere } = require(path.join(HOOKS_LIB, "test-language-registry"));
const { translateEre } = require(path.join(HOOKS_LIB, "ere", "translate"));

const TESTS_DIR = "tests";
const TEST_FILE_RE = /\.(sh|bash|js|cjs|mjs|ps1|py)$/i;
const HELPER_DIRS = new Set(["lib", "fixtures", "fixture", "helpers", "golden", "node_modules"]);
// A harness load is a line-anchored load statement: the registry's helperLibrary regexes, except the
// js one, whose `^[^/]*require(` also accepts a require(...) inside a string literal.
const JS_LOAD_RE = /^\s*(?:(?:(?:const|let|var)\s+[^=]+=\s*)?require\(\s*|import\s+(?:[^'"]+\s+from\s+)?)["'][^"']*\/harness(?:\.[cm]?js)?["']/;
const LOAD_RES = [
  JS_LOAD_RE,
  ...entriesWhere("helper-library")
    .filter((e) => !/\.js$/.test(e.helperLibrary.path))
    .flatMap((e) => [e.helperLibrary.sourceRegex, e.helperLibrary.sharedSourceRegex])
    .filter(Boolean)
    .map(translateEre)
    .filter((t) => t.status === "ok")
    .map((t) => t.regex),
];
const COMMENT_RE = /^\s*(#|\/\/)/;
const loadsHarness = (text) =>
  text.split(/\r?\n/).some((l) => !COMMENT_RE.test(l) && LOAD_RES.some((re) => re.test(l)));

function walk(dir, rel, out) {
  let ents;
  try {
    ents = fs.readdirSync(dir, { withFileTypes: true });
  } catch {
    return;
  }
  for (const e of ents) {
    const r = rel ? `${rel}/${e.name}` : e.name;
    if (e.isDirectory()) {
      if (!HELPER_DIRS.has(e.name)) walk(path.join(dir, e.name), r, out);
    } else if (TEST_FILE_RE.test(e.name)) {
      out.push(r);
    }
  }
}

// A suite subfile `a/x/y` counts as placed when `files` holds an entrypoint `a/x.<ext>` beside its dir.
function hasEntrypoint(files, f) {
  const segs = f.split("/");
  const prefix = [...segs.slice(0, -2), `${segs[segs.length - 2]}.`].join("/");
  return files.some((e) => e.startsWith(prefix) && !e.slice(prefix.length).includes("/"));
}

// uncoveredTests(section, files) — the test files no consumer of the proposed section treats as a test.
function uncoveredTests(section, files) {
  if (!section) return [];
  const out = [];
  for (const f of files) {
    const rel = `${TESTS_DIR}/${f}`;
    const { kind } = placementIn(section, rel);
    const strayFlat = kind === "flat" && section.categorization !== "flat";
    if (strayFlat || (kind === "suite-subfile" && !hasEntrypoint(files, f))) out.push({ path: rel, placement: kind });
  }
  return out.sort((a, b) => (a.path < b.path ? -1 : 1));
}

function detect(rootArg) {
  const root = path.resolve(nativePath(String(rootArg || process.cwd())));
  const testsRoot = path.join(root, TESTS_DIR);
  const files = [];
  walk(testsRoot, "", files);
  const subdirs = [...new Set(files.filter((f) => f.includes("/")).map((f) => f.split("/")[0]))];
  let candidates = ["flat"];
  if (subdirs.length > 0) {
    const allTargets = subdirs.every((d) => fs.existsSync(path.join(root, d)));
    candidates = allTargets ? ["by-target", "by-type"] : ["by-type", "by-target"];
  }
  const usesHarness = (f) => {
    try {
      return loadsHarness(fs.readFileSync(path.join(testsRoot, ...f.split("/")), "utf8"));
    } catch {
      return false;
    }
  };
  const harness = files.length > 0 && files.every(usesHarness) ? "on" : "off";
  let topDirs = [];
  try {
    topDirs = fs.readdirSync(testsRoot, { withFileTypes: true }).filter((e) => e.isDirectory()).map((e) => e.name);
  } catch {
    topDirs = [];
  }
  const supportDirs = topDirs.filter((d) => !subdirs.includes(d)).sort();
  const sections = {};
  for (const c of candidates) {
    const s = { dir: TESTS_DIR, categorization: c };
    if (c === "by-target") s.categories = subdirs.map((d) => ({ dir: d, covers: [d] }));
    if (c === "by-type") s.categories = subdirs.map((d) => ({ dir: d }));
    s.supportDirs = supportDirs;
    s.testHarness = harness;
    s.caseMarker = harness;
    sections[c] = s;
  }
  return {
    ...sections[candidates[0]],
    candidates,
    sections,
    testFiles: files.length,
    uncoveredTests: uncoveredTests(sections[candidates[0]], files),
  };
}

module.exports = { detect };

if (require.main === module) {
  const i = process.argv.indexOf("--root");
  process.stdout.write(`${JSON.stringify(detect(i > 0 ? process.argv[i + 1] : process.cwd()), null, 2)}\n`);
}
