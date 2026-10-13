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
// so a PR of an earlier use of that name, or one that lacks a local commit not yet pushed, must
// not certify this HEAD: OPEN and MERGED stand only when the PR's head commit is the local HEAD
// (NONE otherwise; UNKNOWN when the forge reported no head commit or HEAD is unreadable).
function stateForLocalHead(repoDir, state, headOid) {
  if (state !== "OPEN" && state !== "MERGED") return state;
  const oid = typeof headOid === "string" ? headOid.trim().toLowerCase() : "";
  if (!/^[0-9a-f]{40,64}$/.test(oid)) return "UNKNOWN";
  const head = localHead(repoDir);
  if (!head) return "UNKNOWN";
  return head === oid ? state : "NONE";
}

module.exports = { PR_STATE_VALUES, isPrPresentOrUnknown, stateForLocalHead };
