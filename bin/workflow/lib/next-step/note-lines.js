"use strict";
// The advisory note lines of next-step's verdict: DELIVERY_PATH_MISMATCH (#2527) and
// GLOSSARY_AFTER_PUSH (#2909), only the non-empty ones, one per line.

const { deliveryPathNoteLine } = require("./delivery-path-note");
const { glossaryAfterPushNoteLine } = require("./glossary-after-push-note");

function noteLinesOf(profile, sid, repoDir, state) {
  return [deliveryPathNoteLine(profile, sid, repoDir), glossaryAfterPushNoteLine(state, sid, repoDir)]
    .filter((l) => l).join("\n");
}

module.exports = { noteLinesOf };
