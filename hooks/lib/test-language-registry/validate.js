"use strict";
// Schema validation for test-language-registry.json; the reader (../test-language-registry.js)
// calls validate(table, repoRoot, opts) once per load. repoRoot is the reader's own checkout,
// which is where launch.wrapper must exist.

const fs = require("fs");
const path = require("path");

const STATUSES = ["supported", "recognized-only"];
const ID_RE = /^[a-z0-9-]+$/;
const PATTERN_RE = /^[A-Za-z0-9._*-]+$/;
const FUNCTION_RE = /^[A-Za-z_][A-Za-z0-9_]*$/;
const FLAT_REJECT_RE = /^FLAT_TEST_[A-Z_]*REJECTED$/;
const VERSION_RE = /^\d+(\.\d+){0,2}$/;
const INTERPRETER_RE = /^[A-Za-z0-9._+-]+$/;
const MARKER_WORDING = ["markerName", "markerWrapHint", "markerMissingHint", "markerUncertainHint", "markerDoc"];
// {wrapper} is not one of these: it names the launcher's own file, so a suite may use it too.
const PATH_PLACEHOLDERS = ["{path}", "{nativePath}", "{nativePathSq}"];

function fail(where, what) {
  throw new Error(`test-language-registry: ${where}: ${what}`);
}

const isObj = (v) => v !== null && typeof v === "object" && !Array.isArray(v);
const isStr = (v) => typeof v === "string";
const nullOr = (v, test) => v === null || v === undefined || test(v);
const isRelative = (p) => p !== "" && !/^([/\\]|[A-Za-z]:)/.test(p) && !p.split(/[/\\]/).includes("..");

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

// existOpts carries checkRepoFile's options when the part file must exist, null when only its shape counts.
function checkPart(ref, where, repoRoot, existOpts) {
  if (ref === null || ref === undefined) return;
  if (!isObj(ref)) fail(where, "must be {file, function} or null");
  checkRepoFile(ref.file, `${where}.file`, repoRoot, existOpts || { repoFiles: false });
  if (!isStr(ref.function) || !FUNCTION_RE.test(ref.function)) fail(`${where}.function`, "must be a bash function name");
}

const absent = (v) => v === null || v === undefined;

// The fields every supported entry carries in the real table; opts.complete === false lets a
// fixture table that predates them still load.
function checkRequired(e, where, opts) {
  if (e.status !== "supported" || opts.complete === false) return;
  for (const k of ["codeLanguage", "newFileNameShape", "notationDoc", "envClearLine"]) {
    if (absent(e[k])) fail(`${where}.${k}`, "is required for a supported entry");
  }
  if (isObj(e.diagnostics) && absent(e.diagnostics.markerWrapHint)) {
    fail(`${where}.diagnostics.markerWrapHint`, "is required for a supported entry");
  }
}

function checkArgs(args, where, { required, suite, wrapper, minVersion }) {
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
    if (!wrapper && a.includes("{wrapper}")) fail(`${where}[${i}]`, "{wrapper} needs launch.wrapper");
    if (!minVersion && a.includes("{minVersion}")) fail(`${where}[${i}]`, "{minVersion} needs launch.minVersion");
  });
}

function checkWrapper(w, where, repoRoot) {
  if (w === null || w === undefined) return false;
  plain(w, where);
  if (!isRelative(w)) fail(where, "must be a path relative to the repository root, without ..");
  if (!fs.existsSync(path.join(repoRoot, w))) fail(where, `${w} does not exist under ${repoRoot}`);
  return true;
}

function checkMinVersion(m, where) {
  if (m === null || m === undefined) return false;
  if (!isObj(m)) fail(where, "must be {runtime, version} or null");
  if (plain(m.runtime, `${where}.runtime`) === "") fail(`${where}.runtime`, "must not be empty");
  if (!isStr(m.version) || !VERSION_RE.test(m.version)) fail(`${where}.version`, "must be <major>[.<minor>[.<patch>]]");
  return true;
}

function checkLaunch(l, where, status, repoRoot) {
  if (l === null || l === undefined) {
    if (status === "supported") fail(where, "is required for a supported entry");
    return;
  }
  if (!isObj(l)) fail(where, "must be an object or null");
  if (l.unit !== "file" && l.unit !== "suite") fail(`${where}.unit`, "must be file or suite");
  const suite = l.unit === "suite";
  if (!nullOr(l.requires, (v) => plain(v, `${where}.requires`) !== "")) fail(`${where}.requires`, "must not be empty");
  const posInt = (v) => Number.isInteger(v) && v > 0;
  if (!nullOr(l.timeoutSeconds, posInt)) fail(`${where}.timeoutSeconds`, "must be a positive integer or null");
  const wrapper = checkWrapper(l.wrapper, `${where}.wrapper`, repoRoot);
  const minVersion = checkMinVersion(l.minVersion, `${where}.minVersion`);
  checkArgs(l.prepare, `${where}.prepare`, { required: false, suite, wrapper, minVersion });
  checkArgs(l.command, `${where}.command`, { required: true, suite, wrapper, minVersion });
  if (suite) {
    const m = l.suiteRootMarker;
    if (!isStr(m) || m === "" || /[/\\]/.test(m)) fail(`${where}.suiteRootMarker`, "a suite needs a file name marking its root");
    plain(m, `${where}.suiteRootMarker`);
  }
}

function checkRepoFile(p, where, repoRoot, opts) {
  plain(p, where);
  if (!isRelative(p)) fail(where, "must be a path relative to the repository root, without ..");
  if (opts.repoFiles !== false && !fs.existsSync(path.join(repoRoot, p))) fail(where, `${p} does not exist under ${repoRoot}`);
}

// Can two star-only globs match one common string? * is zero-or-more, as the bash [[ == ]]
// match in bin/lib/test-route-destination/language.sh reads sourcePatterns.
function globsOverlap(a, b) {
  const seen = new Set();
  const walk = (i, j) => {
    if (seen.has(`${i},${j}`)) return false;
    seen.add(`${i},${j}`);
    if (i === a.length && j === b.length) return true;
    if (a[i] === "*") return walk(i + 1, j) || (j < b.length && walk(i, j + 1));
    if (b[j] === "*") return walk(i, j + 1) || (i < a.length && walk(i + 1, j));
    return i < a.length && j < b.length && a[i] === b[j] && walk(i + 1, j + 1);
  };
  return walk(0, 0);
}

// One code file maps to one test language, so no basename may fit source patterns of two entries.
function checkCodeLanguage(c, where, seenSources) {
  if (c === null || c === undefined) return;
  if (!isObj(c)) fail(where, "must be {sourcePatterns, shebangInterpreters} or null");
  const sources = `${where}.sourcePatterns`;
  if (!Array.isArray(c.sourcePatterns) || c.sourcePatterns.length === 0) fail(sources, "must be a non-empty array of patterns");
  c.sourcePatterns.forEach((p, j) => {
    checkPattern(p, `${sources}[${j}]`);
    const hit = seenSources.find((s) => globsOverlap(p, s.pattern));
    if (hit) fail(`${sources}[${j}]`, `pattern ${JSON.stringify(p)} overlaps ${JSON.stringify(hit.pattern)} claimed by ${hit.where}`);
  });
  c.sourcePatterns.forEach((p) => seenSources.push({ pattern: p, where: sources }));
  const shebangs = `${where}.shebangInterpreters`;
  if (!Array.isArray(c.shebangInterpreters)) fail(shebangs, "must be an array of interpreter names");
  c.shebangInterpreters.forEach((s, j) => {
    if (!isStr(s) || !INTERPRETER_RE.test(s)) fail(`${shebangs}[${j}]`, "must be a command name of A-Za-z0-9._+-");
  });
}

function checkEntry(e, i, seen, repoRoot, seenSources, opts) {
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
  checkLaunch(e.launch, `${where}.launch`, e.status, repoRoot);
  for (const k of ["caseMarkerReader", "caseEmbedRules", "tableDrivenDetector"]) checkPart(e[k], `${where}.${k}`, repoRoot, null);
  checkPart(e.envClearLine, `${where}.envClearLine`, repoRoot, opts);
  if (!nullOr(e.helperLibrary, isObj)) fail(`${where}.helperLibrary`, "must be {path, sourceRegex} or null");
  if (e.helperLibrary) {
    checkRepoFile(e.helperLibrary.path, `${where}.helperLibrary.path`, repoRoot, opts);
    plain(e.helperLibrary.sourceRegex, `${where}.helperLibrary.sourceRegex`);
  }
  if (!e.caseMarkerReader !== !e.helperLibrary) {
    fail(`${where}.caseMarkerReader`, "caseMarkerReader and helperLibrary come as a pair: set both or neither");
  }
  checkCodeLanguage(e.codeLanguage, `${where}.codeLanguage`, seenSources);
  if (e.newFileNameShape !== null && e.newFileNameShape !== undefined) {
    const shape = plain(e.newFileNameShape, `${where}.newFileNameShape`);
    if (shape === "" || shape.includes(",")) fail(`${where}.newFileNameShape`, "must be one non-empty file name shape without a comma");
  }
  if (e.notationDoc !== null && e.notationDoc !== undefined) checkRepoFile(e.notationDoc, `${where}.notationDoc`, repoRoot, opts);
  const d = e.diagnostics === undefined ? {} : e.diagnostics;
  if (!isObj(d)) fail(`${where}.diagnostics`, "must be an object");
  if (e.status === "supported" || d.nameLabel !== undefined) plain(d.nameLabel, `${where}.diagnostics.nameLabel`);
  if (d.flatRejectCode !== undefined && (!isStr(d.flatRejectCode) || !FLAT_REJECT_RE.test(d.flatRejectCode))) {
    fail(`${where}.diagnostics.flatRejectCode`, "must look like FLAT_TEST_<UPPER_>REJECTED");
  }
  for (const k of MARKER_WORDING) {
    if (d[k] !== undefined && plain(d[k], `${where}.diagnostics.${k}`) === "") fail(`${where}.diagnostics.${k}`, "must not be empty");
  }
  if (!nullOr(e.note, isStr)) fail(`${where}.note`, "must be a string");
  checkRequired(e, where, opts);
}

// opts.repoFiles === false skips the existence of helperLibrary.path, notationDoc and
// envClearLine.file: a checkout that holds the tools without the test tree or the skills still loads the table.
// opts.complete === false skips the fields checkRequired demands of a supported entry.
function validate(t, repoRoot, opts = {}) {
  if (!isObj(t)) fail("table", "must be a JSON object");
  if (t.schema !== 1) fail("schema", "must be 1");
  if (!Number.isInteger(t.headerMaxLines) || t.headerMaxLines < 1) fail("headerMaxLines", "must be a positive integer");
  if (!Array.isArray(t.entries) || t.entries.length === 0) fail("entries", "must be a non-empty array");
  const seen = new Set();
  const seenSources = [];
  t.entries.forEach((e, i) => checkEntry(e, i, seen, repoRoot, seenSources, opts));
  const fb = t.tableDrivenFallbackEntry;
  if (fb !== undefined && fb !== null) {
    const e = t.entries.find((x) => x.id === fb);
    if (!e) fail("tableDrivenFallbackEntry", `no entry has id ${JSON.stringify(fb)}`);
    if (!e.tableDrivenDetector) fail("tableDrivenFallbackEntry", `entry ${fb} has no tableDrivenDetector`);
  }
  return t;
}

module.exports = { STATUSES, fail, validate };
