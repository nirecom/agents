"use strict";
// SSOT for every issue-provenance marker path (CPR-2).
//
// The markers are minted by a hook (hooks/issue-provenance-mint.js) and read by a
// CLI (bin/github-issues/issue-provenance), so they are keyed on the CC session
// UUID — the identifier both sides actually hold — never on the workflow session
// id, which only exists once /workflow-init has run.
//
// Four markers share the one key:
//   <sid>.issue-provenance            the single-use token (observation layer A)
//   <sid>.issue-provenance-consumed   the consumption record (single-use boundary)
//   <sid>.issue-provenance-result     the decided classification (read-only replay)
//   <sid>.session-transcript          pointer to the session transcript (layer B)

const path = require("path");
const { getWorkflowDir } = require("../workflow-state/state-io");

// Same charset as the workflow state files: rejects path separators, "..",
// wildcards, NUL, newlines — anything that could steer the path.
const SID_RE = /^[A-Za-z0-9_-]+$/;

function isValidKey(sid) {
  return typeof sid === "string" && sid.length > 0 && sid.length <= 128 && SID_RE.test(sid);
}

/**
 * The key set to try, in order. One CC session id yields exactly one key; an
 * unusable id yields none, so callers iterate and simply do nothing when empty.
 * @param {string} ccSessionId
 * @returns {string[]}
 */
function provenanceKeys(ccSessionId) {
  return isValidKey(ccSessionId) ? [ccSessionId] : [];
}

/**
 * @param {string} key a value that passed provenanceKeys()
 * @param {string} [dir] workflow directory (defaults to the resolved one)
 * @returns {{token: string, consumed: string, result: string, transcript: string}}
 */
function provenancePaths(key, dir) {
  if (!isValidKey(key)) throw new Error("invalid provenance key");
  const base = dir || getWorkflowDir();
  return {
    token: path.join(base, key + ".issue-provenance"),
    consumed: path.join(base, key + ".issue-provenance-consumed"),
    result: path.join(base, key + ".issue-provenance-result"),
    transcript: path.join(base, key + ".session-transcript"),
  };
}

module.exports = { provenanceKeys, provenancePaths, isValidKey, SID_RE };
