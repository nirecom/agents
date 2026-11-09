"use strict";
// --require preload for the #2936 S12 tests, loaded into confirm-checkpoint.js next to the #2729
// publish-mode preload. Inert unless one of its variables is set:
//   CC_RECOVER_LOG=<file>  appends one line per recoverReceipt call ({"call":n}, then {"written":bool});
//   CC_RECOVER_FAULT=throw recoverReceipt throws; =require-fails the receipt-recovery module fails to load;
//   CC_CONT_FAIL=1         confirm-checkpoint.js's own require of lib/confirm-continuation fails
//                          (its emitDeny fallback); other requirers still load the module.
const fs = require("fs");
const Module = require("module");

const LOG = process.env.CC_RECOVER_LOG || "";
const FAULT = process.env.CC_RECOVER_FAULT || "";
const CONT_FAIL = process.env.CC_CONT_FAIL === "1";
const RECOVERY_RE = /(^|[\\/])receipt-recovery(\.js)?$/;
const CONT_RE = /(^|[\\/])confirm-continuation(\.js)?$/;
const note = (o) => { if (LOG) try { fs.appendFileSync(LOG, JSON.stringify(o) + "\n"); } catch (_) { /* the count then reads 0 */ } };

if (LOG || FAULT || CONT_FAIL) {
  const wrapped = new WeakSet();
  let calls = 0;
  const orig = Module._load;
  Module._load = function (request, parent, ...rest) {
    const req = String(request);
    const fromCheckpoint = parent && /[\\/]confirm-checkpoint\.js$/.test(String(parent.filename || ""));
    if (RECOVERY_RE.test(req) && FAULT === "require-fails") throw new Error("fault: receipt-recovery require");
    if (CONT_FAIL && fromCheckpoint && CONT_RE.test(req)) throw new Error("fault: confirm-continuation require");
    const mod = orig.call(this, request, parent, ...rest);
    if (RECOVERY_RE.test(req) && mod && typeof mod.recoverReceipt === "function" && !wrapped.has(mod)) {
      wrapped.add(mod);
      const real = mod.recoverReceipt;
      mod.recoverReceipt = function (...args) {
        calls += 1;
        note({ call: calls });
        if (FAULT === "throw") throw new Error("fault: recoverReceipt");
        const r = real.apply(this, args);
        note({ written: !!(r && r.written) });
        return r;
      };
    }
    return mod;
  };
}
