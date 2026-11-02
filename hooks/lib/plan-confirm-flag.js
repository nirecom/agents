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
  const { PLAN_ARTIFACT_NAMES } = require("../workflow-state/plan-step-table");
  const m = new RegExp(`^.+-(${PLAN_ARTIFACT_NAMES.join("|")})\\.md$`).exec(getBasename(filePath));
  return m ? m[1] : null;
}

// getConfirmFlagName(artifact) -> the CONFIRM_* flag of a plan artifact name, else null. A
// non-plan flag such as CONFIRM_TESTS is named by plan-skip-allowance's CONFIRM_FLAG_OF_STEP.
function getConfirmFlagName(suffix) {
  const T = require("../workflow-state/plan-step-table");
  const row = T.rowFor(T.stepForSuffix(suffix));
  return row ? row.confirmFlag : null;
}

// Reads the named CONFIRM_* flag from the parsed .env FILE only, never process.env, so an
// inline `CONFIRM_OUTLINE=off node bin/...` prefix on a model-issued command cannot waive the gate.
// The value is classified by config-flag's kindOfValue, the one owner of what "off" means.
function isConfirmFlagOffFromFile(flagName) {
  if (typeof flagName !== "string" || !flagName) return false;
  let fileEnv;
  try {
    const { readDefaultEnvFile } = require("./load-env");
    fileEnv = readDefaultEnvFile();
  } catch (_) {
    return false; // fail-closed: unreadable config never waives the gate
  }
  const raw = fileEnv ? fileEnv[flagName] : undefined;
  if (raw == null) return false;
  return require("./config-flag").kindOfValue(String(raw)) === "off";
}

module.exports = {
  getSuffix,
  getConfirmFlagName,
  isConfirmFlagOffFromFile,
};
