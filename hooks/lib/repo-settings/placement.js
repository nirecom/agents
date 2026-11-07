"use strict";
// Where a repo-relative path sits in the tests tree a tests section describes. Kinds:
//   category       <dir>/<category>/<file> (by-target / by-type)
//   flat           <dir>/<file>
//   support        anything under <dir>/<supportDir>/
//   suite-subfile  deeper than an entrypoint; `category` names its category dir, null otherwise
//   runner         <dir>/run-all.sh
//   outside        not under <dir>/

const RUNNER = "run-all.sh";

const norm = (rel) => String(rel).replace(/\\/g, "/").replace(/^\.\//, "");

// placementIn(tests, rel) — { kind, category } for a validated (or fallback) tests value.
function placementIn(tests, rel) {
  const p = norm(rel);
  const prefix = `${tests.dir}/`;
  if (!p.startsWith(prefix)) return { kind: "outside", category: null };
  const rest = p.slice(prefix.length);
  if (rest === RUNNER) return { kind: "runner", category: null };
  const segs = rest.split("/");
  if (segs.length === 1) return { kind: "flat", category: null };
  if ((tests.supportDirs || []).includes(segs[0])) return { kind: "support", category: null };
  const cats = (tests.categories || []).map((c) => c.dir);
  if (cats.includes(segs[0])) {
    return { kind: segs.length === 2 ? "category" : "suite-subfile", category: segs[0] };
  }
  return { kind: "suite-subfile", category: null };
}

// testDirs(tests) — the directories (repo-relative) that hold test entrypoints.
function testDirs(tests) {
  if (tests.categorization === "flat") return [tests.dir];
  return (tests.categories || []).map((c) => `${tests.dir}/${c.dir}`);
}

// placementOf(root, rel) — the placement under root's tests section, or null when it is not ok.
function placementOf(root, rel) {
  const t = require("./load").load(root).tests;
  return t.state === "ok" ? placementIn(t.value, rel) : null;
}

// testDirsOf(root) — testDirs of root's tests section, or null when it is not ok.
function testDirsOf(root) {
  const t = require("./load").load(root).tests;
  return t.state === "ok" ? testDirs(t.value) : null;
}

module.exports = { RUNNER, placementIn, testDirs, placementOf, testDirsOf };
