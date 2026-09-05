// Pure memory-directory hit detection. Consumer: hooks/block-memory-direct.js.
"use strict";

const os = require("os");
const path = require("path");
const { isUnderPath } = require("./path-match");
const { parse } = require("./command-ir");
const { collectWriteTargetsFromSegments, SHELL_CONFIG_VERB_SET } = require("./bash-write-targets");

const MEMORY_DIR = path.join(os.homedir(), ".claude", "projects", "c--git-agents", "memory");

function hitsMemory(filePath) {
  return isUnderPath(filePath, MEMORY_DIR);
}

function bashHitsMemory(cmd) {
  if (!cmd || typeof cmd !== "string") return false;
  const ir = parse(cmd);
  if (!ir || ir.parseFailure) return false;
  const { targets } = collectWriteTargetsFromSegments(ir.segments, { verbs: SHELL_CONFIG_VERB_SET });
  if (!targets) return false;
  return targets.some((t) => isUnderPath(t.path, MEMORY_DIR));
}

module.exports = { MEMORY_DIR, hitsMemory, bashHitsMemory };
