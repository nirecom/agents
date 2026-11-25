"use strict";
// Issue #3145 — WORKFLOW_THIS_PR_FINDING_ACCEPTED.
//
//   echo "<<WORKFLOW_THIS_PR_FINDING_ACCEPTED: key=<8hex> <reason>>>"
// The user settles one open this-pr finding: writes ` <!-- user-accepted: <reason> -->` on that
// key's entry in the session's WORKTREE_NOTES.md (resolved from the trusted repo dir, never from
// the command). Only a key that is open now is written; anything else is UNAPPLIED, file unchanged.

const { THIS_PR_FINDING_ACCEPTED_RE_DQ, THIS_PR_FINDING_ACCEPTED_LOOKSLIKE } = require("../lib/sentinel-patterns");
const { sanitizeLine } = require("../lib/output-sanitize");
const { validateSkipReason } = require("./skip-reason");

const LABEL = "WORKFLOW_THIS_PR_FINDING_ACCEPTED";
const FORM = "echo \"<<WORKFLOW_THIS_PR_FINDING_ACCEPTED: key=<8hex> <reason>>>\" (<reason> must not contain > ( ) ` ; | &)";

// Lazy: the notes libs reach workflow-state, which workflow-mark.js loads first.
function libs() {
  return {
    open: require("../../bin/lib/this-pr-open"),
    sections: require("../lib/worktree-notes-sections"),
    write: require("../lib/worktree-notes-write"),
  };
}

// -> { ok: true, message } | { ok: false, why }
function accept(sessionId, key, reason) {
  const L = libs();
  const res = L.open.resolveSessionNotesPath(sessionId);
  if (res.error) return { ok: false, why: `notes not resolved (${res.error})` };
  const r = L.open.readOpenThisPr(res.path);
  if (r.state !== "ok") return { ok: false, why: r.state === "absent" ? "no WORKTREE_NOTES.md in this worktree" : r.reason };
  const hit = r.open.find((o) => o.key === key);
  if (!hit) return { ok: false, why: `key=${key} is not an unsettled this-pr finding (already settled, other-scope, or unknown)` };
  const fs = require("fs");
  const text = fs.readFileSync(res.path, "utf8");
  const next = L.sections.markEntryUserAccepted(text, hit.lineNumber, reason);
  if (next === text) return { ok: false, why: "the reason is empty after sanitizing" };
  let failure = null;
  if (!L.write.writeNotesAtomic(res.path, next, (m) => { failure = m; })) return { ok: false, why: failure || "write failed" };
  return { ok: true, message: `key=${key} (${hit.reason}) settled as user-accepted` };
}

function handle(ctx) {
  const { cmd, sessionId, pushMessage, pushUnapplied } = ctx;
  const m = cmd.match(THIS_PR_FINDING_ACCEPTED_RE_DQ);
  if (!m) {
    if (!THIS_PR_FINDING_ACCEPTED_LOOKSLIKE.test(cmd)) return false;
    pushUnapplied(`workflow-mark: malformed ${LABEL} — expected ${FORM}; notes unchanged.`);
    return true;
  }
  const v = validateSkipReason(sanitizeLine(m[2]));
  if (!v.ok) {
    pushUnapplied(`workflow-mark: ${LABEL} rejected — ${v.msg} Notes unchanged.`);
    return true;
  }
  if (!sessionId) {
    pushUnapplied(`workflow-mark: could not resolve session_id — ${LABEL} NOT recorded.`);
    return true;
  }
  try {
    const r = accept(sessionId, m[1], v.reason);
    if (!r.ok) pushUnapplied(`workflow-mark: ${LABEL} rejected — ${r.why}. Notes unchanged.`);
    else pushMessage(`[workflow] ${LABEL}: ${r.message}.`);
  } catch (e) {
    pushUnapplied(`workflow-mark: ${LABEL} failed — ${e.message}. Notes unchanged.`);
  }
  return true;
}

module.exports = { handle };
