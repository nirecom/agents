"use strict";
// Maps plan file path → CONFIRM_* flag name and reads the resolved value.
// Does NOT call loadDefaultEnv() — caller (hook) loads .env once at startup.

const path = require("path");
const { getWorkflowPlansDir } = require("./workflow-plans-dir");
const { normalizeSlashes, getBasename } = require("./path-match");

function isDirectChild(filePath, plansDir) {
  const f = normalizeSlashes(filePath);
  const d = normalizeSlashes(plansDir).replace(/\/+$/, "");
  const parent = path.posix.dirname(f);
  return process.platform === "win32"
    ? parent.toLowerCase() === d.toLowerCase()
    : parent === d;
}

function getSuffix(filePath) {
  if (!filePath) return null;
  let plansDir;
  try { plansDir = getWorkflowPlansDir(); } catch { return null; }
  if (!isDirectChild(filePath, plansDir)) return null;
  const m = /^.+-(intent|outline|detail)\.md$/.exec(getBasename(filePath));
  return m ? m[1] : null;
}

function getConfirmFlagName(suffix) {
  if (suffix === "intent") return "CONFIRM_INTENT";
  if (suffix === "outline") return "CONFIRM_OUTLINE";
  if (suffix === "detail") return "CONFIRM_DETAIL";
  return null;
}

// Exact (case-insensitive) literals. Whitespace-padded values fail-safe to "on".
const OFF_LITERALS = new Set(["off"]);

function isConfirmOff(filePath) {
  const suffix = getSuffix(filePath);
  if (!suffix) return false;
  const flagName = getConfirmFlagName(suffix);
  const raw = process.env[flagName];
  if (raw == null) return false;
  return OFF_LITERALS.has(raw.toLowerCase());
}

module.exports = { getSuffix, getConfirmFlagName, isConfirmOff };
