"use strict";
// NODE_OPTIONS --require preload for tests/hooks/feature-2811-confirm-continue-active.js: makes the
// receipt writes of hooks/lib/presentation-receipt.js fail inside the spawned Stop hook.
// CC_MARK_FAULT is a comma list of modes:
//   mark    - throw on the temp-file write of a receipt body that carries continuedAt (the mark write).
//   receipt - throw on the temp-file write of a receipt body, for every step or only CC_MARK_FAULT_STEP.
const fs = require("fs");

const modes = String(process.env.CC_MARK_FAULT || "").split(",").filter(Boolean);
const faultStep = process.env.CC_MARK_FAULT_STEP || "";
const original = fs.writeFileSync;

fs.writeFileSync = function (file, data, ...rest) {
  const f = String(file);
  if (f.includes(".confirm-plan-receipt-") && f.endsWith(".tmp")) {
    const body = typeof data === "string" ? data : String(data);
    const receiptHit = modes.includes("receipt") && (!faultStep || f.includes(`.confirm-plan-receipt-${faultStep}.json`));
    const markHit = modes.includes("mark") && body.includes("continuedAt");
    if (receiptHit || markHit) {
      const e = new Error("EACCES: injected receipt write fault");
      e.code = "EACCES";
      throw e;
    }
  }
  return original.call(this, file, data, ...rest);
};
