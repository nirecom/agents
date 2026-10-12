"use strict";
// Schema validation for test-language-registry.json; the reader (../test-language-registry.js)
// calls validate(table, repoRoot) once per load. repoRoot is the reader's own checkout, which
// is where launch.wrapper must exist.

const fs = require("fs");
const path = require("path");

const STATUSES = ["supported", "recognized-only"];
const ID_RE = /^[a-z0-9-]+$/;
const PATTERN_RE = /^[A-Za-z0-9._*-]+$/;
const FUNCTION_RE = /^[A-Za-z_][A-Za-z0-9_]*$/;
const FLAT_REJECT_RE = /^FLAT_TEST_[A-Z_]*REJECTED$/;
const VERSION_RE = /^\d+(\.\d+){0,2}$/;
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

function checkPart(ref, where) {
  if (ref === null || ref === undefined) return;
  if (!isObj(ref)) fail(where, "must be {file, function} or null");
  const file = plain(ref.file, `${where}.file`);
  if (!isRelative(file)) fail(`${where}.file`, "must be a path relative to the repository root");
  if (!isStr(ref.function) || !FUNCTION_RE.test(ref.function)) fail(`${where}.function`, "must be a bash function name");
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

function checkEntry(e, i, seen, repoRoot) {
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

function validate(t, repoRoot) {
  if (!isObj(t)) fail("table", "must be a JSON object");
  if (t.schema !== 1) fail("schema", "must be 1");
  if (!Number.isInteger(t.headerMaxLines) || t.headerMaxLines < 1) fail("headerMaxLines", "must be a positive integer");
  if (!Array.isArray(t.entries) || t.entries.length === 0) fail("entries", "must be a non-empty array");
  const seen = new Set();
  t.entries.forEach((e, i) => checkEntry(e, i, seen, repoRoot));
  const fb = t.tableDrivenFallbackEntry;
  if (fb !== undefined && fb !== null) {
    const e = t.entries.find((x) => x.id === fb);
    if (!e) fail("tableDrivenFallbackEntry", `no entry has id ${JSON.stringify(fb)}`);
    if (!e.tableDrivenDetector) fail("tableDrivenFallbackEntry", `entry ${fb} has no tableDrivenDetector`);
  }
  return t;
}

module.exports = { STATUSES, fail, validate };
