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

// SSOT for "has the user pre-waived the CONFIRM gate for this stage?".
// stage is the bare suffix ("intent" | "outline" | "detail").
function isConfirmOffForStage(stage) {
  const flagName = getConfirmFlagName(stage);
  if (!flagName) return false;
  const raw = process.env[flagName];
  if (raw == null) return false;
  return OFF_LITERALS.has(raw.toLowerCase());
}

// Config-file-only variant of isConfirmOffForStage.
// Reads CONFIRM_<STAGE> from the parsed .env FILE contents and NEVER from
// process.env, so an inline `CONFIRM_OUTLINE=off node bin/workflow/...` prefix on
// a model-issued Bash command cannot waive the gate. Use this — not
// isConfirmOffForStage — for any decision made in a process the Bash tool can
// spawn (bin/workflow/next-step, bin/workflow/reconcile-state). Hook processes
// launched by Claude Code itself keep using isConfirmOffForStage: their env is
// inherited from the Claude Code process, not from a forgeable command prefix.
function isConfirmOffForStageFromFile(stage) {
  const flagName = getConfirmFlagName(stage);
  if (!flagName) return false;
  let fileEnv;
  try {
    const { readDefaultEnvFile } = require("./load-env");
    fileEnv = readDefaultEnvFile();
  } catch (_) {
    return false; // fail-closed: unreadable config never waives the gate
  }
  const raw = fileEnv ? fileEnv[flagName] : undefined;
  if (raw == null) return false;
  return OFF_LITERALS.has(String(raw).toLowerCase());
}

function isConfirmOff(filePath) {
  const suffix = getSuffix(filePath);
  if (!suffix) return false;
  return isConfirmOffForStage(suffix);
}

module.exports = {
  getSuffix,
  getConfirmFlagName,
  isConfirmOff,
  isConfirmOffForStage,
  isConfirmOffForStageFromFile,
};
