"use strict";
// Schema rules of the repo settings file (.agents.json). Each validator returns
// { state: "ok", value } with the defaults applied, or { state: "malformed", errors }.
// Schema and state meanings: docs/architecture/claude-code/repo-settings-file.md.

const CATEGORIZATIONS = ["flat", "by-target", "by-type"];
const SWITCHES = ["on", "off"];
const TESTS_KEYS = ["dir", "categorization", "categories", "supportDirs", "testHarness", "caseMarker"];
const MIGRATE_KEYS = ["tracker", "issues", "tests"];
const MIGRATE_VALUES = ["done"];

const isObj = (v) => v !== null && typeof v === "object" && !Array.isArray(v);
// One path segment: no separator, not "." / "..", not empty.
const isSegment = (v) => typeof v === "string" && v !== "" && v !== "." && v !== ".." && !/[\\/]/.test(v);

function checkCategories(t, errors) {
  if (t.categorization === "flat") {
    if (t.categories !== undefined) errors.push("tests.categories: not allowed when categorization is flat");
    return [];
  }
  if (!Array.isArray(t.categories) || t.categories.length === 0) {
    errors.push(`tests.categories: ${t.categorization} needs one or more categories`);
    return [];
  }
  const out = [];
  t.categories.forEach((c, i) => {
    const at = `tests.categories[${i}]`;
    if (!isObj(c)) return errors.push(`${at}: must be an object`);
    for (const k of Object.keys(c)) if (k !== "dir" && k !== "covers") errors.push(`${at}.${k}: unknown key`);
    if (!isSegment(c.dir)) errors.push(`${at}.dir: must be one path segment`);
    if (t.categorization === "by-target") {
      const ok = Array.isArray(c.covers) && c.covers.length > 0 && c.covers.every((p) => typeof p === "string" && p !== "");
      if (!ok) errors.push(`${at}.covers: by-target needs a non-empty list of paths`);
    } else if (c.covers !== undefined) {
      errors.push(`${at}.covers: not allowed when categorization is by-type`);
    }
    out.push(c.dir);
  });
  return out;
}

function validateTests(t) {
  if (!isObj(t)) return { state: "malformed", errors: ["tests: must be an object"] };
  const errors = [];
  for (const k of Object.keys(t)) if (!TESTS_KEYS.includes(k)) errors.push(`tests.${k}: unknown key`);
  if (!CATEGORIZATIONS.includes(t.categorization)) errors.push(`tests.categorization: must be one of ${CATEGORIZATIONS.join(" / ")}`);
  if (t.dir !== undefined && !isSegment(t.dir)) errors.push("tests.dir: must be one path segment");
  for (const k of ["testHarness", "caseMarker"]) {
    if (!SWITCHES.includes(t[k])) errors.push(`tests.${k}: must be on or off`);
  }
  const supportDirs = t.supportDirs === undefined ? [] : t.supportDirs;
  if (!Array.isArray(supportDirs) || !supportDirs.every(isSegment)) errors.push("tests.supportDirs: must be a list of path segments");
  const cats = CATEGORIZATIONS.includes(t.categorization) ? checkCategories(t, errors) : [];
  const all = [...cats, ...(Array.isArray(supportDirs) ? supportDirs : [])];
  const seen = new Set();
  const dup = new Set();
  for (const d of all) {
    if (seen.has(d)) dup.add(d);
    else seen.add(d);
  }
  if (dup.size) errors.push(`tests: duplicate dir ${[...dup].join(" ")} across categories and supportDirs`);
  if (errors.length) return { state: "malformed", errors };
  const value = {
    dir: t.dir === undefined ? "tests" : t.dir,
    categorization: t.categorization,
    supportDirs: [...supportDirs],
    testHarness: t.testHarness,
    caseMarker: t.caseMarker,
  };
  if (t.categorization !== "flat") value.categories = t.categories.map((c) => ({ ...c }));
  return { state: "ok", value };
}

function validateMigrate(m) {
  if (!isObj(m)) return { state: "malformed", errors: ["migrate: must be an object"] };
  const errors = [];
  for (const [k, v] of Object.entries(m)) {
    if (!MIGRATE_KEYS.includes(k)) errors.push(`migrate.${k}: unknown key (one of ${MIGRATE_KEYS.join(" / ")})`);
    else if (!MIGRATE_VALUES.includes(v)) errors.push(`migrate.${k}: must be ${MIGRATE_VALUES.join(" / ")}`);
  }
  return errors.length ? { state: "malformed", errors } : { state: "ok", value: { ...m } };
}

// validateDoc(doc) — { tests, migrate } section results of a parsed file; unknown sections are ignored.
function validateDoc(doc) {
  if (!isObj(doc)) {
    const bad = { state: "malformed", errors: ["the file must hold a JSON object"] };
    return { tests: bad, migrate: bad };
  }
  return {
    tests: doc.tests === undefined ? { state: "missing" } : validateTests(doc.tests),
    migrate: doc.migrate === undefined ? { state: "missing" } : validateMigrate(doc.migrate),
  };
}

module.exports = { CATEGORIZATIONS, MIGRATE_KEYS, isObj, validateTests, validateMigrate, validateDoc };
