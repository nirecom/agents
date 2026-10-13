"use strict";
// PR/MR state vocabulary shared by every codehost descriptor (#2527): each
// prStateForBranch answers OPEN | MERGED | CLOSED | NONE | UNKNOWN, and
// hasOpenPrForBranch is derived from it here so the fail-open rule is one fact.

const PR_STATE_VALUES = Object.freeze(["OPEN", "MERGED", "CLOSED", "NONE", "UNKNOWN"]);

// hasOpenPrForBranch contract: an OPEN or MERGED PR counts, and an unknown answer
// fails open (true) so the premature USER_VERIFIED guard never relaxes on a gh error.
function isPrPresentOrUnknown(state) {
  return state === "OPEN" || state === "MERGED" || state === "UNKNOWN";
}

function localHead(repoDir) {
  try {
    const r = require("child_process").spawnSync("git", ["-C", repoDir, "rev-parse", "HEAD"],
      { encoding: "utf8", timeout: 5000, windowsHide: true });
    if (!r || r.error || r.status !== 0) return "";
    return (r.stdout || "").trim().toLowerCase();
  } catch (e) {
    return "";
  }
}

// stateForLocalHead(repoDir, state, headOid) -> state. The forge answers for the branch NAME,
// so a MERGED PR of an earlier use of that name must not certify this HEAD: MERGED stands only
// when the PR's head commit is the local HEAD (NONE otherwise; UNKNOWN when HEAD is unreadable).
// A forge that reported no head commit is taken at its word.
function stateForLocalHead(repoDir, state, headOid) {
  if (state !== "MERGED") return state;
  const oid = typeof headOid === "string" ? headOid.trim().toLowerCase() : "";
  if (!oid) return state;
  const head = localHead(repoDir);
  if (!head) return "UNKNOWN";
  return head === oid ? state : "NONE";
}

module.exports = { PR_STATE_VALUES, isPrPresentOrUnknown, stateForLocalHead };
