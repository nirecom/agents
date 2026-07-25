"use strict";
// OFF-clearance helpers for enforce-override-handlers (#1608):
//   consumeOffClearance() — single-use token consumption on OFF activation
//   handleEmergencyOff()  — EMERGENCY sentinel branch (Phase1 examination bypass)
// Split out of enforce-override-handlers.js to keep that file under the size limit.

const fs = require("fs");
const path = require("path");
const {
  ENFORCE_WORKFLOW_OFF_EMERGENCY_RE_DQ, ENFORCE_WORKFLOW_OFF_EMERGENCY_LOOKSLIKE_RE,
  ENFORCE_WORKTREE_OFF_EMERGENCY_RE_DQ, ENFORCE_WORKTREE_OFF_EMERGENCY_LOOKSLIKE_RE,
} = require("../../lib/sentinel-patterns");
const { getWorkflowDir } = require("../../lib/workflow-state");

const SID_RE = /^[A-Za-z0-9_-]+$/;

// appendAudit(sessionId, finding): NON-BLOCKING audit write. Audit loss must never
// block an already-approved override, but the audit trail is load-bearing for this
// feature's trust model — so a dropped entry is announced on stderr, never swallowed.
function appendAudit(sessionId, finding) {
  try {
    const { appendFinding } = require("../../lib/supervisor-state-writer");
    if (appendFinding(sessionId, finding) === false) {
      process.stderr.write(
        `workflow-mark: WARNING — OFF-clearance audit entry rejected ` +
          `(record_type=${finding && finding.record_type}, sid=${sessionId}). Override still applied.\n`
      );
    }
  } catch (e) {
    process.stderr.write(
      `workflow-mark: WARNING — OFF-clearance audit write failed ` +
        `(record_type=${finding && finding.record_type}, sid=${sessionId}): ` +
        `${(e && e.message) || String(e)}. Override still applied.\n`
    );
  }
}

// resolveClearanceWsid(): the workflow session id, resolved exactly the way
// hooks/supervisor-off-proposal-shim.js resolves it, so consumption can reach the
// same fallback-keyed token the shim may have used to authorize the activation.
function resolveClearanceWsid() {
  try {
    const { resolveWorkflowSessionId } = require("../../lib/resolve-workflow-session-id");
    return resolveWorkflowSessionId() || null;
  } catch (_e) {
    return null;
  }
}

// unlinkClearance(sid): read-then-unlink one <sid>.off-clearance token.
// Returns { status: "consumed", token } | { status: "absent" } | { status: "error" }.
function unlinkClearance(sid) {
  let token = null;
  try {
    const tokenPath = path.join(getWorkflowDir(), `${sid}.off-clearance`);
    try {
      token = JSON.parse(fs.readFileSync(tokenPath, "utf8"));
    } catch (_e) { token = null; }
    fs.unlinkSync(tokenPath);
  } catch (e) {
    if (e && e.code === "ENOENT") return { status: "absent" };
    return { status: "error" };
  }
  return { status: "consumed", token };
}

// consumeOffClearance(target, sessionId): unlink the token that authorized this OFF
// activation and record an off_clearance_consumed audit entry keyed to whichever
// session id actually owned it. The shim may authorize on a FALLBACK token keyed to
// the resolved workflow session id, so consumption mirrors that fallback — otherwise
// a single-use token would survive its own use.
// Single-use: a granted clearance authorizes exactly one OFF activation.
// Fail-open — ENOENT and I/O errors are swallowed so a missing token never blocks an
// already-approved override.
function consumeOffClearance(target, sessionId) {
  if (!sessionId || !SID_RE.test(sessionId)) return;
  let auditSid = sessionId;
  let result = unlinkClearance(sessionId);
  if (result.status === "absent") {
    const wsid = resolveClearanceWsid();
    if (wsid && wsid !== sessionId && SID_RE.test(wsid)) {
      const fallback = unlinkClearance(wsid);
      if (fallback.status !== "absent") {
        result = fallback;
        auditSid = wsid;
      }
    }
  }
  if (result.status !== "consumed") return; // absent (e.g. emergency path) or I/O error
  const token = result.token;
  appendAudit(auditSid, {
    categories: ["workflow"],
    severity: "notice",
    detail:
      `off_clearance consumed target=${target} ` +
      `category=${(token && token.category) || "unknown"} single-use token unlinked`,
    reporter: "off-clearance-examiner",
    record_type: "off_clearance_consumed",
  });
}

// writeMarker(kind, sessionId, payload): atomic marker write; throws on failure.
function writeMarker(kind, sessionId, payload) {
  const dir = getWorkflowDir();
  fs.mkdirSync(dir, { recursive: true });
  const markerPath = path.join(dir, `${sessionId}.${kind}`);
  const tmp = markerPath + ".tmp";
  fs.writeFileSync(tmp, JSON.stringify(payload), { mode: 0o600 });
  fs.renameSync(tmp, markerPath);
  return markerPath;
}

// handleEmergencyOff(ctx): EMERGENCY sentinel branch. Returns true when the command
// was an emergency sentinel (handled), false otherwise.
// The emergency path deliberately BYPASSES the Phase1 clearance examination — it is
// the escape when the examiner itself is broken. It is human-gated by settings.json
// `ask` (the model cannot self-approve) and always leaves an audit entry.
function handleEmergencyOff(ctx) {
  const { cmd, sessionId, pushMessage, signalFatal } = ctx;

  const wfMatch = cmd.match(ENFORCE_WORKFLOW_OFF_EMERGENCY_RE_DQ);
  const wtMatch = wfMatch ? null : cmd.match(ENFORCE_WORKTREE_OFF_EMERGENCY_RE_DQ);
  const looksLike =
    !wfMatch && !wtMatch &&
    (ENFORCE_WORKFLOW_OFF_EMERGENCY_LOOKSLIKE_RE.test(cmd) ||
      ENFORCE_WORKTREE_OFF_EMERGENCY_LOOKSLIKE_RE.test(cmd));

  if (looksLike) {
    pushMessage(
      `workflow-mark: malformed EMERGENCY OFF sentinel — ` +
        `expected: echo "<<WORKFLOW_ENFORCE_WORKFLOW_OFF_EMERGENCY: {reason}>>" ` +
        `(reason: >=3 non-space chars, no '>')`
    );
    return true;
  }
  if (!wfMatch && !wtMatch) return false;

  const target = wfMatch ? "workflow" : "worktree";
  const kind = wfMatch ? "workflow-off" : "worktree-off";
  const reason = (wfMatch || wtMatch)[1];

  if (!sessionId) {
    signalFatal(`workflow-mark: could not resolve session_id — EMERGENCY OFF sentinel NOT applied.`);
    return true;
  }
  if (!SID_RE.test(sessionId)) {
    signalFatal(`workflow-mark: invalid session_id format — EMERGENCY OFF sentinel NOT applied.`);
    return true;
  }

  let markerPath;
  try {
    markerPath = writeMarker(kind, sessionId, {
      reason,
      emergency: true,
      set_at: new Date().toISOString(),
    });
  } catch (e) {
    signalFatal(
      `workflow-mark: failed to write EMERGENCY ${target} override marker — ${e.message}. Override NOT applied.`
    );
    return true;
  }

  appendAudit(sessionId, {
    categories: ["workflow"],
    severity: "warning",
    detail: `emergency OFF activated target=${target} (Phase1 examination bypassed) reason=${reason}`,
    reporter: "off-clearance-examiner",
    record_type: "escape_hatch_event",
  });

  try {
    const { reportSentinel } = require("../../lib/supervisor-emit");
    reportSentinel(target === "workflow" ? "WORKFLOW_OFF" : "WORKTREE_OFF", reason, sessionId);
  } catch (_e) { /* fail-open */ }

  pushMessage(
    `workflow-mark: EMERGENCY ${target} override applied (marker: ${markerPath}). ` +
      `Phase1 examination was bypassed and the activation is recorded in the audit trail. ` +
      `Restore with: echo "<<WORKFLOW_ENFORCE_${target === "workflow" ? "WORKFLOW" : "WORKTREE"}_ON: {reason}>>"`
  );
  return true;
}

module.exports = { consumeOffClearance, handleEmergencyOff };
