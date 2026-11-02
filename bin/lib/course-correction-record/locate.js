"use strict";
// locate --session <sid>: the cwd-composed transcript path when its file exists, else the scan
// of every project directory (bin/lib/resume-session/transcript-fallback.js owns both).

const fs = require("fs");
const { locateUpstreamTranscript, discoverUpstreamTranscript } = require("../resume-session/transcript-fallback");
const { SESSION_ID_VALID_RE } = require("../../../hooks/workflow-state/state-io");

function isFile(p) {
  try {
    return fs.statSync(p).isFile();
  } catch {
    return false;
  }
}

// run({session}) -> {code, stdout?, message?}
function run({ session }) {
  if (!SESSION_ID_VALID_RE.test(session)) return { code: 2, message: "--session is not a session id" };
  const composed = locateUpstreamTranscript(session, process.cwd());
  const found = composed && isFile(composed) ? composed : discoverUpstreamTranscript(session);
  if (!found) return { code: 3, message: `no transcript for session ${session}` };
  return { code: 0, stdout: `${found}\n` };
}

module.exports = { run };
