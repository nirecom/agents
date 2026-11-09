"use strict";
// askuser-dialog-levels.js — the AskUserQuestion dialog ID classification (#2764). The table
// askuser-dialog-levels.json is the SSOT: each dialog ID has an auto user-input risk level, and a
// low ID names the workflow steps it may be auto-answered in. Shared by
// hooks/lib/askuser-jev-decide.js and bin/lib/check-askuser-dialog-ids.js.

const fs = require("fs");
const path = require("path");

const TABLE_PATH = path.join(__dirname, "askuser-dialog-levels.json");
const DIALOG_ID_RE = /^[a-z0-9-]{1,40}\.[a-z0-9_-]{1,40}$/;
const NUMBERED_SUFFIX_RE = /_\d+$/;
const LEVELS = Object.freeze(["low", "high"]);

// normalizeDialogId(raw) -> the trimmed ID with one trailing _<digits> dropped, or null when absent.
function normalizeDialogId(raw) {
  if (typeof raw !== "string") return null;
  const t = raw.trim();
  return t ? t.replace(NUMBERED_SUFFIX_RE, "") : null;
}

// loadTable(file) -> the dialogs array; throws when the file is unreadable or not {dialogs: [...]}.
function loadTable(file = TABLE_PATH) {
  const t = JSON.parse(fs.readFileSync(file, "utf8"));
  if (!t || typeof t !== "object" || !Array.isArray(t.dialogs)) throw new Error(`${file}: "dialogs" is not an array`);
  return t.dialogs;
}

// rowProblems(row, stepNames) -> the reasons a row is invalid (empty when valid).
function rowProblems(row, stepNames) {
  if (!row || typeof row !== "object" || Array.isArray(row)) return ["the row is not an object"];
  const out = [];
  if (typeof row.id !== "string" || !DIALOG_ID_RE.test(row.id)) out.push("id is not <namespace>.<name>");
  else if (NUMBERED_SUFFIX_RE.test(row.id)) out.push("id ends with _<digits>");
  if (!LEVELS.includes(row.level)) out.push(`level is not one of ${LEVELS.join("/")}`);
  if (row.level === "low" && (!Array.isArray(row.steps) || row.steps.length === 0)) out.push("a low row needs steps");
  if (row.level === "high" && row.steps !== undefined) out.push("a high row has no steps");
  if (Array.isArray(row.steps)) {
    for (const s of row.steps) if (!stepNames.includes(s)) out.push(`unknown step ${JSON.stringify(s)}`);
  }
  return out;
}

let cache = null;
function index() {
  if (cache) return cache;
  const map = new Map();
  for (const r of loadTable()) {
    if (!r || typeof r.id !== "string") continue;
    const prev = map.get(r.id);
    // A duplicated ID reads as high when any of its rows is high: the checker reports the duplicate.
    if (prev && prev.level === "high") continue;
    map.set(r.id, { level: r.level, steps: Array.isArray(r.steps) ? r.steps.slice() : [] });
  }
  cache = map;
  return cache;
}

// classify(id) -> {level, steps} for a well-formed ID in the table, otherwise null.
function classify(id) {
  if (typeof id !== "string" || !DIALOG_ID_RE.test(id)) return null;
  const hit = index().get(id);
  if (!hit) return null;
  return hit.level === "low" ? { level: "low", steps: hit.steps.slice() } : { level: hit.level };
}

module.exports = { TABLE_PATH, DIALOG_ID_RE, LEVELS, normalizeDialogId, loadTable, rowProblems, classify };
