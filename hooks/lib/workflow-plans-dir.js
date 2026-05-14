"use strict";
const os = require("os");
const path = require("path");
const { loadDefaultEnv } = require("./load-env");

let _envLoaded = false;

function getWorkflowPlansDir() {
  if (!_envLoaded) { try { loadDefaultEnv(); } catch (_) {} _envLoaded = true; }
  const raw = process.env.WORKFLOW_PLANS_DIR;
  if (raw && raw.length) {
    const v = raw.trim();
    if (v.length === 0) return path.join(os.homedir(), ".workflow-plans");
    if (!path.isAbsolute(v)) {
      throw new Error(
        `WORKFLOW_PLANS_DIR must be an absolute path (tilde is not expanded). Got: ${v}`
      );
    }
    return v;
  }
  return path.join(os.homedir(), ".workflow-plans");
}

module.exports = { getWorkflowPlansDir };
