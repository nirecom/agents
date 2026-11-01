"use strict";
// next-step's output writer (split out of verdict.js, #2527 4-4): the 4-line contract plus
// the optional SKIP_HINT, WAIT, gate and note lines, then exit 0.

// #2527: the DELIVERY_PATH_MISMATCH advisory line, set once the profile is known.
let noteLine = "";

function setNoteLine(line) {
  noteLine = line || "";
}

function emit(action, skill, hint, reason, skipHint, gateLine, wait) {
  let out =
    "ACTION=" + action + "\n" +
    "NEXT_SKILL=" + (skill || "") + "\n" +
    "NEXT_HINT='" + (hint || "") + "'\n" +
    "REASON='" + (reason || "") + "'\n";
  // #485: optional advisory SKIP_HINT line — appended ONLY when non-empty, so the
  // 4-line contract is byte-identical on every other step. Value is a fixed
  // sentinel literal (no quotes/whitespace) → unquoted SKIP_HINT=<value> form.
  if (skipHint) {
    out += "SKIP_HINT=" + skipHint + "\n";
  }
  // #2527 4-4: WAIT=<kind> names a wait on a human outside the session (the C4 stop guard reads it).
  if (wait) out += "WAIT=" + wait + "\n";
  if (gateLine) out += gateLine + "\n";
  if (noteLine) out += noteLine + "\n";
  // #2461: JEV_ADVICE / JEV_ADVICE_REASON (wait-on-invoke) only on invoke; ACTION itself never changes.
  if (action === "invoke") {
    try { out += require("./wait-on-invoke").adviceLines(); } catch (_e) { /* fail-open: no advice */ }
  }
  process.stdout.write(out);
  process.exit(0);
}

module.exports = { emit, setNoteLine };
