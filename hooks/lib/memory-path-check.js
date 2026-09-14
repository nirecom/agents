// Pure memory-directory hit detection. Consumer: hooks/block-memory-direct.js.
"use strict";

const os = require("os");
const path = require("path");
const { isUnderPath } = require("./path-match");
const { normalizeCwd } = require("./path-normalize");
const { parse } = require("./command-ir");
const { collectWriteTargetsFromSegments, SHELL_CONFIG_VERB_SET } = require("./bash-write-targets");

const MEMORY_DIR = path.join(os.homedir(), ".claude", "projects", "c--git-agents", "memory");

// MEMORY_DIR is Windows drive-letter form (path.join on win32), but Claude Code
// hooks under Git Bash deliver paths in MSYS2 POSIX drive-letter form (a leading
// slash then the drive letter), which isUnderPath would miss. normalizeCwd
// converts that form to Windows drive-letter form (no-op on other platforms).
function hitsMemory(filePath) {
  return isUnderPath(normalizeCwd(filePath) || filePath, MEMORY_DIR);
}

function bashHitsMemory(cmd) {
  if (!cmd || typeof cmd !== "string") return false;
  const ir = parse(cmd);
  if (!ir || ir.parseFailure) return false;
  const { targets } = collectWriteTargetsFromSegments(ir.segments, { verbs: SHELL_CONFIG_VERB_SET });
  if (!targets) return false;
  return targets.some((t) => isUnderPath(normalizeCwd(t.path) || t.path, MEMORY_DIR));
}

module.exports = { MEMORY_DIR, hitsMemory, bashHitsMemory };
