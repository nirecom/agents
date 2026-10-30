"use strict";
// Case-marker placement of one test file covering several Tests: paths (#2507 D7; ports the loop
// body of bin/check-case-markers.sh). The verdict is the FILE record of case-records.js, so each
// language's reader decides it. judge(file, name) -> { lines: [{ err, text }], high, readerFailed }:
// file is a path or an in-memory file (source.js); name names it and picks the registry entry.

const R = require("./registry");
const S = require("./source");
const { readHeaders } = require("./headers");
const { records } = require("./case-records");

const UNSUPPORTED = (name) => `WARN: ${name}: case markers not checked (no test case reader for this language) code=CASE_MARKER_READER_UNSUPPORTED`;

function readerSupported(name) {
  const m = R.match(name);
  return !!(m && m.status === "supported" && R.fieldValue(m.entry, "caseMarkerReader.file"));
}

function matchedEntry(name) {
  try {
    const m = R.match(name);
    return m ? m.entry : null;
  } catch {
    return null;
  }
}

function judge(file, name) {
  const res = { lines: [], high: false, readerFailed: false };
  const say = (text, err = false) => res.lines.push({ err, text });
  if (R.tryReg() && !readerSupported(name)) {
    say(UNSUPPORTED(name));
    return res;
  }
  let text = "";
  try {
    text = S.textOf(file);
  } catch {
    text = "";
  }
  const prefix = R.commentPrefix(name);
  const testsLine = readHeaders(text, name).tests;
  if (!testsLine) return res;
  const pathCount = testsLine.split(",").length;
  if (pathCount < 2) return res;
  const rec = records(file, name);
  const entry = matchedEntry(name);
  const field = (f) => R.fieldValue(entry, f);
  const state = rec.state === "malformed" && rec.reason === "reader" ? "reader-failed" : rec.state;
  if (state === "none") {
    say(`HIGH: ${name} (${pathCount} paths in ${prefix} Tests: header, no ${field("diagnostics.markerName") || "case"} markers) code=MISSING_CASE_MARKERS`);
    res.high = true;
  } else if (state === "malformed") {
    say(`HIGH: ${name} line ${rec.line}: malformed case marker (${rec.reason}) code=MALFORMED_CASE_MARKER`);
    res.high = true;
  } else if (state === "uncertain") {
    if (rec.reason === "case-embed") say(`WARN: ${name}: case records incomplete (caseEmbedRules deps failed) code=CASE_EMBED_DEPS_FAILED`);
    else {
      const hint = field("diagnostics.markerUncertainHint");
      say(`WARN: ${name} line ${rec.line}: case marker nesting uncertain${hint ? ` (${hint})` : ""} code=UNCERTAIN_CASE_MARKER`);
    }
  } else if (state === "unavailable") {
    say(`WARN: ${name}: case markers not checked (${rec.reason} is not installed) code=CASE_MARKER_RUNTIME_UNAVAILABLE`);
  } else if (state === "unsupported") {
    say(UNSUPPORTED(name));
  } else if (state !== "conforming") {
    say(`check-case-markers.sh: test case reader unavailable: ${name}`, true);
    res.readerFailed = true;
  }
  return res;
}

module.exports = { judge };
