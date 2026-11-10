"use strict";
// hooks/confirm-checkpoint/receipt-diagnostic.js — the no-receipt deny finding's detail suffix (#2804),
// moved out of confirm-checkpoint.js unchanged (#2936).

const fs = require("fs");

// receiptDiagnostic(sid, step) -> the expected receipt, whether it exists, and the presentation receipt
// log's last write and any consume after it; "" when it cannot be built.
function receiptDiagnostic(sid, step) {
  try {
    const PR = require("../lib/presentation-receipt");
    const p = PR.receiptPath(sid, step);
    const head = ` [receipt ${p} exists=${fs.existsSync(p)}`;
    const lines = PR.readReceiptLog(sid).filter((l) => l && l.step === step);
    let wi = -1;
    lines.forEach((l, i) => { if (l.event === "write") wi = i; });
    if (wi < 0) return `${head}; no write record]`;
    const at = lines[wi].at;
    const ms = Date.now() - Date.parse(at);
    const elapsed = Number.isNaN(ms) ? "elapsed unknown" : `elapsed ${ms}ms`;
    const consumed = lines.slice(wi + 1).some((l) => l.event === "consume");
    return `${head}; last write at ${at} (${elapsed}); ${consumed ? "a consume record follows it" : "no consume record follows it"}]`;
  } catch (_) {
    return "";
  }
}

module.exports = { receiptDiagnostic };
