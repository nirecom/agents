"use strict";
const fs = require("fs");
const { markerPathFor } = require("./worktree-cleanup-marker");

function isWorktreeEndEnv(sessionId) {
  const p = markerPathFor(sessionId);
  if (!p) return false;
  try {
    fs.accessSync(p, fs.constants.F_OK);
    return true;
  } catch (_) {
    return false;
  }
}

module.exports = { isWorktreeEndEnv };
