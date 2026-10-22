"use strict";
// Test-language registry reader: loads and validates test-language-registry.json (the one
// table that says which file names are tests in which language and how each is handled).
// Hooks call it directly; bash reaches it through bin/test-language-registry.
// The table is swapped only by the loadRegistry(file) argument; there is no env override.

const fs = require("fs");
const path = require("path");
const { STATUSES, fail, validate } = require("./test-language-registry/validate");

const DEFAULT_FILE = path.join(__dirname, "test-language-registry.json");
// launch.wrapper resolves against this reader's checkout, whichever table it reads.
const REPO_ROOT = path.join(__dirname, "..", "..");
const DEFAULT_FLAT_REJECT_CODE = "FLAT_TEST_REJECTED";
const SHELL_FIELDS = [
  "nameStrip.prefix", "nameStrip.suffix", "issueNamePrefix", "siblingSuiteDir", "header.commentPrefix",
  "launch.unit", "launch.requires", "launch.timeoutSeconds", "launch.suiteRootMarker",
  "launch.wrapper", "launch.minVersion",
  "caseMarkerReader.file", "caseMarkerReader.function",
  "caseEmbedRules.file", "caseEmbedRules.function",
  "tableDrivenDetector.file", "tableDrivenDetector.function",
  "envClearLine.file", "envClearLine.function",
  "helperLibrary.path", "helperLibrary.sourceRegex",
  "diagnostics.nameLabel", "diagnostics.flatRejectCode",
  "diagnostics.markerName", "diagnostics.markerWrapHint", "diagnostics.markerMissingHint",
  "diagnostics.markerUncertainHint", "diagnostics.markerDoc",
  "codeLanguage.sourcePatterns", "codeLanguage.shebangInterpreters", "newFileNameShape", "notationDoc",
];

const cache = new Map();
const matchers = new WeakMap();

// Git Bash hands over /<drive>/... paths, which Node's fs cannot open on Windows.
function nativePath(p) {
  const m = process.platform === "win32" && /^\/([a-zA-Z])(\/.*)?$/.exec(p);
  return m ? `${m[1].toUpperCase()}:${m[2] || "/"}` : p;
}

function loadRegistry(file) {
  const abs = path.resolve(nativePath(file || DEFAULT_FILE));
  if (cache.has(abs)) return cache.get(abs);
  let t;
  try {
    t = JSON.parse(fs.readFileSync(abs, "utf8"));
  } catch (e) {
    fail(abs, `cannot read the table (${String(e.message).split("\n")[0]})`);
  }
  // helperLibrary.path, notationDoc and the parts are not opened by this reader, so a checkout
  // without the test tree or the skills still loads, as does a fixture table without the fields a
  // supported entry needs; validate() without the options checks both.
  validate(t, REPO_ROOT, { repoFiles: false, complete: false });
  cache.set(abs, t);
  return t;
}

function tryLoadRegistry(file) {
  try {
    return loadRegistry(file);
  } catch (e) {
    process.stderr.write(`[test-language-registry] ${String(e.message).replace(/\s*\n\s*/g, " ")}\n`);
    return null;
  }
}

const globOf = (p) => p.replace(/\*/g, "?*");
const globsOf = (entry) => entry.patterns.map(globOf);

function matcherOf(entry) {
  if (!matchers.has(entry)) {
    const res = entry.patterns.map((p) => new RegExp(`^${p.split("*").map((s) => s.replace(/[.-]/g, "\\$&")).join("[\\s\\S]+")}$`));
    matchers.set(entry, (name) => res.some((re) => re.test(name)));
  }
  return matchers.get(entry);
}

// Resolves one language: supported entries first, then table order.
function matchBasename(name, reg = loadRegistry()) {
  for (const status of STATUSES) {
    for (const entry of reg.entries) {
      if (entry.status === status && matcherOf(entry)(name)) return { id: entry.id, status, entry };
    }
  }
  return null;
}

// Any selfIdentifying entry counts: test_a.sh resolves to bash yet is named like a test.
function matchesSelfIdentifying(name, reg = loadRegistry()) {
  return reg.entries.some((e) => e.selfIdentifying && matcherOf(e)(name));
}

function stripName(name, reg = loadRegistry()) {
  const m = matchBasename(name, reg);
  const ns = (m && m.entry.nameStrip) || {};
  const pre = ns.prefix || "";
  const suf = ns.suffix || "";
  if (!m || !name.startsWith(pre) || !name.endsWith(suf) || name.length <= pre.length + suf.length) return name;
  return name.slice(pre.length, name.length - suf.length);
}

const headerMaxLines = (reg = loadRegistry()) => reg.headerMaxLines;

// Conditions are decided by which fields an entry has, never by its id.
const CONDITIONS = {
  supported: (e) => e.status === "supported",
  "recognized-only": (e) => e.status === "recognized-only",
  "case-marker": (e) => e.status === "supported" && !!e.caseMarkerReader,
  "table-driven": (e) => !!e.tableDrivenDetector,
  "helper-library": (e) => e.status === "supported" && !!e.helperLibrary,
};

function entriesWhere(cond, reg = loadRegistry()) {
  const test = typeof cond === "function" ? cond : CONDITIONS[cond];
  if (!test) throw new Error(`test-language-registry: unknown condition ${cond}`);
  return reg.entries.filter(test);
}

function fieldValue(entry, name) {
  if (name === "diagnostics.flatRejectCode" && entry.status === "supported") {
    return (entry.diagnostics && entry.diagnostics.flatRejectCode) || DEFAULT_FLAT_REJECT_CODE;
  }
  const v = name.split(".").reduce((o, k) => (o === null || o === undefined ? undefined : o[k]), entry);
  // One label for display and the unrunnable marker; the launcher takes the version after ">=".
  if (name === "launch.minVersion") return v ? `${v.runtime}>=${v.version}` : undefined;
  if (typeof v === "boolean") return v ? "1" : "0";
  if (Array.isArray(v)) return v.length ? v.join(",") : undefined;
  return v === null || v === undefined || v === "" ? undefined : String(v);
}

// One tab-separated record per line; bash reads it without eval.
function toShellDump(reg = loadRegistry()) {
  const out = [
    `schema\t${reg.schema}`,
    `headerMaxLines\t${reg.headerMaxLines}`,
    `tableDrivenFallbackEntry\t${reg.tableDrivenFallbackEntry || ""}`,
    `testLanguageExceptions\t${(reg.testLanguageExceptions || []).join(" ")}`,
  ];
  for (const e of reg.entries) {
    out.push(`entry\t${e.id}\t${e.status}\t${e.selfIdentifying ? 1 : 0}`);
    for (const p of e.patterns) out.push(`pattern\t${e.id}\t${p}`);
    for (const g of globsOf(e)) out.push(`glob\t${e.id}\t${g}`);
    for (const f of SHELL_FIELDS) {
      const v = fieldValue(e, f);
      if (v !== undefined) out.push(`field\t${e.id}\t${f}\t${v}`);
    }
    for (const kind of ["prepare", "command"]) {
      for (const a of (e.launch && e.launch[kind]) || []) out.push(`arg\t${e.id}\t${kind}\t${a}`);
    }
  }
  return out.join("\n") + "\n";
}

function toJson(reg = loadRegistry()) {
  const entries = reg.entries.map((e) => Object.assign({}, e, { globs: globsOf(e) }));
  return JSON.stringify(Object.assign({}, reg, { entries }), null, 2) + "\n";
}

module.exports = {
  DEFAULT_FILE,
  loadRegistry,
  tryLoadRegistry,
  matchBasename,
  matchesSelfIdentifying,
  globsOf,
  stripName,
  headerMaxLines,
  entriesWhere,
  toShellDump,
  toJson,
};
