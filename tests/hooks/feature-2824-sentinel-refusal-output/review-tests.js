"use strict";
// review-tests-handler refusals (#2824 Step 2): every path that leaves review_tests unrecorded is UNAPPLIED.

const S = (body) => `echo "<<WORKFLOW_${body}>>"`;

function refusals(X) {
  const sid = X.seedInit("rt");
  X.expectUnapplied("COMPLETE without fingerprint", sid, S("REVIEW_TESTS_COMPLETE: no fingerprint given"), /fingerprint/i);
  X.expectUnapplied("WARNINGS without fingerprint", sid, S("REVIEW_TESTS_WARNINGS: gap in coverage"), /fingerprint/i);
  X.expectUnapplied("COMPLETE LOOKSLIKE (bare)", sid, S("REVIEW_TESTS_COMPLETE"), /malformed/i);
  X.expectUnapplied("WARNINGS LOOKSLIKE (bare)", sid, S("REVIEW_TESTS_WARNINGS"), /malformed/i);
  X.expectUnapplied("WARNINGS_ACCEPTED LOOKSLIKE (paren)", sid, S("REVIEW_TESTS_WARNINGS_ACCEPTED: gap (known)"), /malformed/i);
  X.expectUnapplied("WARNINGS_ACCEPTED reason too short", sid, S("REVIEW_TESTS_WARNINGS_ACCEPTED: ab"), /too short/i);
  X.expectUnapplied("WARNINGS_ACCEPTED with nothing to accept", sid,
    S("REVIEW_TESTS_WARNINGS_ACCEPTED: coverage gap accepted by the user"), /state unchanged|nothing to accept/i);
  X.check();
}

module.exports = { refusals };
