"use strict";
// Synchronous writers of the pre-commit body (#2507). fs.writeSync is looked up at call time so a
// caller that patches it (tests) sees every write. Marker format contract:
// docs/architecture/claude-code/worker-dispatch/commit-push.md

const fs = require("fs");

function writeFd(fd, text) {
  try {
    fs.writeSync(fd, text);
  } catch (_) {
    // A closed stream must not stop the hook: the output is diagnostic.
  }
}

function marker(name) {
  writeFd(2, `pre-commit-section: ${name}\n`);
}

// writeMessages(messages) — each { stream, text } as one line on fd 1 (stdout) or fd 2 (stderr).
function writeMessages(messages) {
  for (const m of messages || []) {
    if (!m) continue;
    const text = String(m.text);
    writeFd(m.stream === "stdout" ? 1 : 2, text.endsWith("\n") ? text : `${text}\n`);
  }
}

const out = (text) => ({ stream: "stdout", text });
const err = (text) => ({ stream: "stderr", text });

// linesOf(text) — captured child output as message lines, trailing newline dropped.
function linesOf(text) {
  const s = String(text || "").replace(/\r?\n$/, "");
  return s === "" ? [] : s.split(/\r?\n/);
}

module.exports = { marker, writeMessages, writeFd, out, err, linesOf };
