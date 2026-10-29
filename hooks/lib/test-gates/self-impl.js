"use strict";
// The one window onto the caseEmbedRules self-impl op (#2507 D7; ports tsi_report of
// bin/lib/test-self-impl-window.sh). report(file, matchPath) -> { rc, stdout, stderr }:
// rc 0 answered (`line\tkind\tdetail` rows); 3 no entry matches or it has no caseEmbedRules;
// 69 the part's runtime is not installed; 70 the part cannot be reached; else the part's failure.

const R = require("./registry");
const P = require("./parts");

function report(file, matchPath) {
  let m;
  try {
    m = R.match(matchPath === undefined ? file : matchPath);
  } catch {
    return { rc: 3, stdout: "", stderr: "" };
  }
  if (!m || !R.partOf(m.entry, "caseEmbedRules")) return { rc: 3, stdout: "", stderr: "" };
  return P.embed(m.entry, "self-impl", file);
}

module.exports = { report };
