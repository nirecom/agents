"use strict";
// hooks/lib/no-receipt-hint.js — the no-receipt deny's hint (#2936), shared by confirm-continuation.js
// and confirm-checkpoint.js's own fallback. No dependencies, so the fallback can always load it.

const NO_RECEIPT_HINT = "the Stop hook records the presentation when the turn ends and may have timed out before it did; " +
  "to check, look in presentation-receipt-log.jsonl for a \"write\" record of this step after that turn — none means it was never recorded";

module.exports = { NO_RECEIPT_HINT };
