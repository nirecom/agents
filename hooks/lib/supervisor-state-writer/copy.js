"use strict";

// #2304 — copy a session upstream's supervisor state beside the downstream's
// copied workflow state, so findings and audit verdicts travel with the session.
// Only `session_id` is rewritten; every other field is carried verbatim.
// Never throws: the outcome is reported, and inheritance treats it as advisory.

const fs = require("fs");
const { getStatePath, writeAtomic } = require("./shared");
const { withSessionStateLock } = require("./lock");

// copySupervisorState(fromSid, toSid) -> "copied" | "absent" | "failed".
function copySupervisorState(fromSid, toSid) {
  let raw;
  try {
    raw = fs.readFileSync(getStatePath(fromSid), "utf8");
  } catch (e) {
    return e && e.code === "ENOENT" ? "absent" : "failed";
  }
  try {
    const state = JSON.parse(raw);
    if (!state || typeof state !== "object" || Array.isArray(state)) return "failed";
    if (Object.prototype.hasOwnProperty.call(state, "session_id")) state.session_id = toSid;
    const ok = withSessionStateLock(toSid, () => {
      writeAtomic(getStatePath(toSid, { forWrite: true }), state);
      return true;
    });
    return ok === true ? "copied" : "failed";
  } catch (_) {
    return "failed";
  }
}

module.exports = { copySupervisorState };
