"use strict";
// Test-language registry reader: loads and validates test-language-registry.json (the one
// table that says which file names are tests in which language and how each is handled).
// Hooks call it directly; bash reaches it through bin/test-language-registry.
// The table is swapped only by the loadRegistry(file) argument; there is no env override.

const fs = require("fs");
const path = require("path");

const DEFAULT_FILE = path.join(__dirname, "test-language-registry.json");
const STATUSES = ["supported", "recognized-only"];
const ID_RE = /^[a-z0-9-]+$/;
const PATTERN_RE = /^[A-Za-z0-9._*-]+$/;
const FUNCTION_RE = /^[A-Za-z_][A-Za-z0-9_]*$/;
const FLAT_REJECT_RE = /^FLAT_TEST_[A-Z_]*REJECTED$/;
const DEFAULT_FLAT_REJECT_CODE = "FLAT_TEST_REJECTED";
const PATH_PLACEHOLDERS = ["{path}", "{nativePath}", "{nativePathSq}"];
const SHELL_FIELDS = [
  "nameStrip.prefix", "nameStrip.suffix", "siblingSuiteDir", "header.commentPrefix",
  "launch.unit", "launch.requires", "launch.timeoutSeconds", "launch.suiteRootMarker",
  "caseMarkerReader.file", "caseMarkerReader.function",
  "caseEmbedRules.file", "caseEmbedRules.function",
  "tableDrivenDetector.file", "tableDrivenDetector.function",
  "helperLibrary.path", "helperLibrary.sourceRegex",
  "diagnostics.nameLabel", "diagnostics.flatRejectCode",
];

const cache = new Map();
const matchers = new WeakMap();

// Git Bash hands over /c/... paths, which Node's fs cannot open on Windows.
function nativePath(p) {
  const m = process.platform === "win32" && /^\/([a-zA-Z])(\/.*)?$/.exec(p);
  return m ? `${m[1].toUpperCase()}:${m[2] || "/"}` : p;
}

function fail(where, what) {
  throw new Error(`test-language-registry: ${where}: ${what}`);
}

const isObj = (v) => v !== null && typeof v === "object" && !Array.isArray(v);
const isStr = (v) => typeof v === "string";
const nullOr = (v, test) => v === null || v === undefined || test(v);

// Every string that reaches the tab-separated shell dump must stay on one field.
function plain(v, where) {
  if (!isStr(v) || /[\t\r\n]/.test(v)) fail(where, "must be a string without tabs or newlines");
  return v;
}

function checkPattern(p, where) {
  plain(p, where);
  if (!PATTERN_RE.test(p)) fail(where, `pattern ${JSON.stringify(p)} uses characters outside A-Za-z0-9._- and *`);
  const stars = p.split("*").length - 1;
  if (stars > 2) fail(where, `pattern ${JSON.stringify(p)} has more than two *`);
  if (p.includes("**")) fail(where, `pattern ${JSON.stringify(p)} has adjacent *`);
}

function checkPart(ref, where) {
  if (ref === null || ref === undefined) return;
  if (!isObj(ref)) fail(where, "must be {file, function} or null");
  const file = plain(ref.file, `${where}.file`);
  if (file === "" || /^([/\\]|[A-Za-z]:)/.test(file) || file.split(/[/\\]/).includes("..")) {
    fail(`${where}.file`, "must be a path relative to the repository root");
  }
  if (!isStr(ref.function) || !FUNCTION_RE.test(ref.function)) fail(`${where}.function`, "must be a bash function name");
}

function checkArgs(args, where, { required, suite }) {
  if (args === null || args === undefined) {
    if (required) fail(where, "is required");
    return;
  }
  if (!Array.isArray(args) || args.length === 0) fail(where, "must be a non-empty array of strings");
  args.forEach((a, i) => {
    plain(a, `${where}[${i}]`);
    if (suite && PATH_PLACEHOLDERS.some((ph) => a.includes(ph))) {
      fail(`${where}[${i}]`, "a suite runs in its suite root and takes no {path} placeholders");
    }
  });
}

function checkLaunch(l, where, status) {
  if (l === null || l === undefined) {
    if (status === "supported") fail(where, "is required for a supported entry");
    return;
  }
  if (!isObj(l)) fail(where, "must be an object or null");
  if (l.unit !== "file" && l.unit !== "suite") fail(`${where}.unit`, "must be file or suite");
  const suite = l.unit === "suite";
  if (!nullOr(l.requires, (v) => plain(v, `${where}.requires`) !== "")) fail(`${where}.requires`, "must not be empty");
  if (!nullOr(l.timeoutSeconds, (v) => Number.isInteger(v) && v > 0)) fail(`${where}.timeoutSeconds`, "must be a positive integer or null");
  checkArgs(l.prepare, `${where}.prepare`, { required: false, suite });
  checkArgs(l.command, `${where}.command`, { required: true, suite });
  if (suite) {
    const m = l.suiteRootMarker;
    if (!isStr(m) || m === "" || /[/\\]/.test(m)) fail(`${where}.suiteRootMarker`, "a suite needs a file name marking its root");
    plain(m, `${where}.suiteRootMarker`);
  }
}

function checkEntry(e, i, seen) {
  const where = `entries[${i}]`;
  if (!isObj(e)) fail(where, "must be an object");
  if (!isStr(e.id) || !ID_RE.test(e.id)) fail(`${where}.id`, "must match [a-z0-9-]+");
  if (seen.has(e.id)) fail(`${where}.id`, `duplicate id ${e.id}`);
  seen.add(e.id);
  if (!STATUSES.includes(e.status)) fail(`${where}.status`, `must be one of ${STATUSES.join(", ")}`);
  if (!Array.isArray(e.patterns) || e.patterns.length === 0) fail(`${where}.patterns`, "must be a non-empty array");
  e.patterns.forEach((p, j) => checkPattern(p, `${where}.patterns[${j}]`));
  if (typeof e.selfIdentifying !== "boolean") fail(`${where}.selfIdentifying`, "must be true or false");
  if (!nullOr(e.siblingSuiteDir, (v) => typeof v === "boolean")) fail(`${where}.siblingSuiteDir`, "must be true or false");
  if (!nullOr(e.nameStrip, isObj)) fail(`${where}.nameStrip`, "must be {prefix, suffix}");
  for (const k of ["prefix", "suffix"]) {
    if (e.nameStrip && !nullOr(e.nameStrip[k], isStr)) fail(`${where}.nameStrip.${k}`, "must be a string");
    if (e.nameStrip && isStr(e.nameStrip[k])) plain(e.nameStrip[k], `${where}.nameStrip.${k}`);
  }
  if (!nullOr(e.header, (v) => isObj(v) && plain(v.commentPrefix, `${where}.header.commentPrefix`) !== "")) {
    fail(`${where}.header`, "must be {commentPrefix} or null");
  }
  checkLaunch(e.launch, `${where}.launch`, e.status);
  checkPart(e.caseMarkerReader, `${where}.caseMarkerReader`);
  checkPart(e.caseEmbedRules, `${where}.caseEmbedRules`);
  checkPart(e.tableDrivenDetector, `${where}.tableDrivenDetector`);
  if (!nullOr(e.helperLibrary, isObj)) fail(`${where}.helperLibrary`, "must be {path, sourceRegex} or null");
  if (e.helperLibrary) {
    plain(e.helperLibrary.path, `${where}.helperLibrary.path`);
    plain(e.helperLibrary.sourceRegex, `${where}.helperLibrary.sourceRegex`);
  }
  const d = e.diagnostics === undefined ? {} : e.diagnostics;
  if (!isObj(d)) fail(`${where}.diagnostics`, "must be an object");
  if (e.status === "supported" || d.nameLabel !== undefined) plain(d.nameLabel, `${where}.diagnostics.nameLabel`);
  if (d.flatRejectCode !== undefined && (!isStr(d.flatRejectCode) || !FLAT_REJECT_RE.test(d.flatRejectCode))) {
    fail(`${where}.diagnostics.flatRejectCode`, "must look like FLAT_TEST_<UPPER_>REJECTED");
  }
  if (!nullOr(e.note, isStr)) fail(`${where}.note`, "must be a string");
}

function validate(t) {
  if (!isObj(t)) fail("table", "must be a JSON object");
  if (t.schema !== 1) fail("schema", "must be 1");
  if (!Number.isInteger(t.headerMaxLines) || t.headerMaxLines < 1) fail("headerMaxLines", "must be a positive integer");
  if (!Array.isArray(t.entries) || t.entries.length === 0) fail("entries", "must be a non-empty array");
  const seen = new Set();
  t.entries.forEach((e, i) => checkEntry(e, i, seen));
  const fb = t.tableDrivenFallbackEntry;
  if (fb !== undefined && fb !== null) {
    const e = t.entries.find((x) => x.id === fb);
    if (!e) fail("tableDrivenFallbackEntry", `no entry has id ${JSON.stringify(fb)}`);
    if (!e.tableDrivenDetector) fail("tableDrivenFallbackEntry", `entry ${fb} has no tableDrivenDetector`);
  }
  return t;
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
  validate(t);
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
    const res = entry.patterns.map((p) => new RegExp(`^${p.split("*").map((s) => s.replace(/[.\-]/g, "\\$&")).join("[\\s\\S]+")}$`));
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
  if (typeof v === "boolean") return v ? "1" : "0";
  return v === null || v === undefined || v === "" ? undefined : String(v);
}

// One tab-separated record per line; bash reads it without eval.
function toShellDump(reg = loadRegistry()) {
  const out = [
    `schema\t${reg.schema}`,
    `headerMaxLines\t${reg.headerMaxLines}`,
    `tableDrivenFallbackEntry\t${reg.tableDrivenFallbackEntry || ""}`,
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
