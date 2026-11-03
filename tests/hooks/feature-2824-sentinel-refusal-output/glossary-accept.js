"use strict";
// glossary-accept-handler refusals (#2824 Step 2): malformed bodies and a grant with nothing pending are UNAPPLIED.

const G = (body) => `echo "<<WORKFLOW_GLOSSARY_ACCEPTED${body}>>"`;

function refusals(X) {
  const sid = X.seedInit("ga");
  X.expectUnapplied("bare (LOOKSLIKE)", sid, G(""), /malformed/i);
  X.expectUnapplied("reason too short", sid, G(": term=widget — ab"), /malformed.*reason too short/i);
  X.expectUnapplied("nothing pending", sid, G(": term=widget — the user accepted this wording"), /rejected — nothing pending/);
  // The catch path: a state file that is not JSON makes the grant writer throw.
  X.expectUnapplied("state write fails", X.corruptState("ga-corrupt"), G(": term=widget — the user accepted this wording"),
    /failed to write state[\s\S]*NOT recorded/);
  X.check();
}

module.exports = { refusals };
