"use strict";
// The one helper that decides where Claude Code keeps its transcript directories.
// Honors CLAUDE_TRANSCRIPT_BASE_DIR (tests and relocated profiles).

const os = require("os");
const path = require("path");

function encodeCwd(cwd) {
  return path.resolve(cwd).toLowerCase().replace(/[^a-zA-Z0-9]/g, "-");
}

function getTranscriptBase() {
  return (
    process.env.CLAUDE_TRANSCRIPT_BASE_DIR ||
    path.join(os.homedir(), ".claude", "projects")
  );
}

module.exports = { encodeCwd, getTranscriptBase };
