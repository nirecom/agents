"use strict";
// hooks/lib/next-step-spawn.js — the one way a hook runs bin/workflow/next-step (#2461). It always
// passes --jev-cache-only: a hook never starts a Jev query of its own and only reads the advice
// the main conversation's own next-step run cached. The env is inherited on purpose:
// WORKFLOW_STATE_DIR decides where the workflow state lives.

const fs = require("fs");
const path = require("path");

const NEXT_STEP_PATH = path.join(__dirname, "..", "..", "bin", "workflow", "next-step");
const CACHE_ONLY_FLAG = "--jev-cache-only";

// spawnNextStep(args, {timeout, stderr}) -> the spawnSync result, or null when next-step is missing.
// stderr: "pipe" keeps next-step's stderr; the default discards it.
function spawnNextStep(args, opts = {}) {
  if (!fs.existsSync(NEXT_STEP_PATH)) return null;
  return require("child_process").spawnSync(process.execPath, [NEXT_STEP_PATH, ...args, CACHE_ONLY_FLAG], {
    timeout: opts.timeout,
    encoding: "utf8",
    stdio: ["ignore", "pipe", opts.stderr === "pipe" ? "pipe" : "ignore"],
  });
}

module.exports = { NEXT_STEP_PATH, CACHE_ONLY_FLAG, spawnNextStep };
