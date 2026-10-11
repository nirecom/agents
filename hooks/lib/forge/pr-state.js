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

module.exports = { PR_STATE_VALUES, isPrPresentOrUnknown };
