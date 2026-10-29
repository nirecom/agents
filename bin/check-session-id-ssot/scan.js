"use strict";
// The two scans of bin/check-session-id-ssot/main.js (#2507 D7): the path tables, the scopes,
// the SSOT read gate and the retired-relay tombstone. In-process: no child is started.
const fs = require("node:fs");
const path = require("node:path");

const TABLE_REL = "bin/check-session-id-ssot/path-tables.txt";
const SECTIONS = ["[ALLOWLIST]", "[TOMBSTONE_EXEMPT]", "[TOMBSTONE_ISOLATION_FILES_OUTSIDE_TESTS]"];
const SP = "[ \\t\\n\\v\\f\\r]";
const NAMES = "SESSION_ID|CLAUDE_CODE_SESSION_ID";
const READ_RE = new RegExp(`process\\.env\\.(${NAMES})([^A-Za-z0-9_]|$)|process\\.env\\[${SP}*["'](${NAMES})["']${SP}*\\]`, "u");
const WAIVER_RE = new RegExp(`session-id-ssot: waived \\([^)]*\\)${SP}*—${SP}*[^ \\t\\n\\v\\f\\r]`, "u");
const NAMES_FILE = path.join(__dirname, "..", "check-session-id-ssot.sh");

class GuardError extends Error {}

// tombstoneNames() — the "A|B" list of the adapter's TOMBSTONE_NAMES line, the names' one
// spelling (a TOMBSTONE_EXEMPT file); read once.
let names;
function tombstoneNames() {
  if (names !== undefined) return names;
  let text;
  try {
    text = fs.readFileSync(NAMES_FILE, "utf8");
  } catch {
    throw new GuardError(`${NAMES_FILE.replace(/\\/g, "/")}: not readable (retired names)`);
  }
  const m = /^TOMBSTONE_NAMES='([^']+)'\r?$/m.exec(text);
  if (!m) throw new GuardError(`${NAMES_FILE.replace(/\\/g, "/")}: no TOMBSTONE_NAMES line`);
  names = m[1];
  return names;
}

let tombstoneRe;
const tombRe = () => tombstoneRe || (tombstoneRe = new RegExp(`(^|[^A-Za-z0-9_])(${tombstoneNames()})([^A-Za-z0-9_]|$)`, "u"));

const trimSpace = (s) => s.replace(/^[ \t\n\v\f\r]+/, "").replace(/[ \t\n\v\f\r]+$/, "");

function splitLines(text) {
  const lines = text.split("\n");
  if (lines[lines.length - 1] === "") lines.pop();
  return lines;
}

function parseTables(text, label) {
  const t = { "[ALLOWLIST]": [], "[TOMBSTONE_EXEMPT]": [], "[TOMBSTONE_ISOLATION_FILES_OUTSIDE_TESTS]": [] };
  const seen = new Set();
  let section = "";
  for (const raw of splitLines(text)) {
    const line = trimSpace(raw);
    if (line === "" || line.startsWith("#")) continue;
    if (SECTIONS.includes(line)) {
      section = line;
      seen.add(line);
      continue;
    }
    if (line.startsWith("[") && line.endsWith("]")) throw new GuardError(`${label}: unknown section ${line}`);
    if (!section) throw new GuardError(`${label}: entry before any section: ${line}`);
    t[section].push(line);
  }
  for (const s of SECTIONS) if (!seen.has(s)) throw new GuardError(`${label}: section ${s} missing`);
  return { allow: t["[ALLOWLIST]"], exempt: t["[TOMBSTONE_EXEMPT]"], isolation: t["[TOMBSTONE_ISOLATION_FILES_OUTSIDE_TESTS]"] };
}

// loadTables(cwd, guardRoot, notice) — the cwd tree's tables, else the guard's own copy.
function loadTables(cwd, guardRoot, notice) {
  let file = path.join(cwd, TABLE_REL);
  let label = TABLE_REL;
  if (!lexists(file)) {
    file = path.join(guardRoot, TABLE_REL);
    label = file.replace(/\\/g, "/");
    notice(`check-session-id-ssot: no ${TABLE_REL} under the current directory; judging with the guard's own tables`);
  }
  const st = lstat(file);
  if (!st || !st.isFile()) throw new GuardError(`${label}: not a regular file`);
  let text;
  try {
    text = fs.readFileSync(file, "utf8");
  } catch {
    throw new GuardError(`${label}: not readable`);
  }
  return parseTables(text, label);
}

function lstat(p) {
  try {
    return fs.lstatSync(p);
  } catch {
    return null;
  }
}
const lexists = (p) => lstat(p) !== null;

function isFile(abs) {
  try {
    return fs.statSync(abs).isFile();
  } catch {
    return false;
  }
}

const readScope = (f) => !/^(tests|docs|changelog|\.git)\//.test(f) && !f.endsWith(".md");
const tombScope = (f) => !/^(docs\/history\/|changelog\/|tests\/_archive\/|\.git\/)/.test(f) && f !== "docs/history.md" && f !== "CHANGELOG.md";

// select(files, cwd, tables) -> { read, tomb }: the files each scan judges, in argument order.
function select(files, cwd, tables) {
  const read = [];
  const tomb = [];
  for (const f of files) {
    const here = isFile(path.resolve(cwd, f));
    if (here && readScope(f) && !tables.allow.includes(f)) read.push(f);
    if (here && tombScope(f) && !tables.exempt.includes(f)) tomb.push(f);
  }
  return { read, tomb };
}

// readText(cwd, f) — the file as text, or null for one grep -I skips (it holds a NUL).
function readText(cwd, f) {
  let buf;
  try {
    buf = fs.readFileSync(path.resolve(cwd, f));
  } catch {
    throw new GuardError("grep failed (exit 2)");
  }
  return buf.includes(0) ? null : buf.toString("utf8");
}

function hits(text, re) {
  const out = [];
  if (text === null) return out;
  splitLines(text).forEach((line, i) => { if (re.test(line)) out.push({ n: i + 1, line }); });
  return out;
}

const tombstoneHits = (text) => (text !== null && tombstoneNames().split("|").some((n) => text.includes(n)) ? hits(text, tombRe()) : []);
const readHits = (text) => (text !== null && text.includes("process.env") ? hits(text, READ_RE) : []);
const waived = (s) => WAIVER_RE.test(s);

module.exports = {
  GuardError, TABLE_REL, tombstoneNames, loadTables, select, readText, splitLines, tombstoneHits, readHits, waived,
};
