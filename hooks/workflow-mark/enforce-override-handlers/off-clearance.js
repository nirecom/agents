"use strict";
// OFF-clearance helpers for enforce-override-handlers (#1608):
//   consumeOffClearance() — single-use token consumption on OFF activation
//   handleEmergencyOff()  — EMERGENCY sentinel branch (Phase1 examination bypass)
// Split out of enforce-override-handlers.js to keep that file under the size limit.

const fs = require("fs");
const path = require("path");
const { consumeExactFile } = require("../../lib/consume-exact-file");
const {
  ENFORCE_WORKFLOW_OFF_EMERGENCY_RE_DQ, ENFORCE_WORKFLOW_OFF_EMERGENCY_LOOKSLIKE_RE,
  ENFORCE_WORKTREE_OFF_EMERGENCY_RE_DQ, ENFORCE_WORKTREE_OFF_EMERGENCY_LOOKSLIKE_RE,
} = require("../../lib/sentinel-patterns");
const { getWorkflowDir } = require("../../workflow-state");

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
// Gated here, once, so BOTH callers inherit it (CPR-SSOT): a canonically shaped stem
// is clearance-bearing on the write side by shape alone, so no agent could have forged
// a file named that way under the #2108 write gate; a non-canonical stem is exactly the
// class that gate may let anyone create, so it must never key a fallback clearance.
// The shape rule is imported, never re-spelled.
function resolveClearanceWsid() {
  try {
    const { resolveWorkflowSessionId } = require("../../lib/resolve-workflow-session-id");
    const { SID_CANONICAL_EXACT_RE } = require("../../lib/protected-basenames");
    const wsid = resolveWorkflowSessionId() || null;
    return wsid && SID_CANONICAL_EXACT_RE.test(wsid) ? wsid : null;
  } catch (_e) {
    return null;
  }
}

// readClearance(sid): read (without unlinking) one sid's CLAIMED token file.
// Returns { status: "found"|"malformed"|"absent"|"error", claimedPath, token, raw }.
// "malformed" is distinct from "found with null token" — an unreadable claim
// authorizes nothing and must never stand in for a real one. `raw` is returned
// so a later identity-bound removal (consume-exact-file.js) deletes the exact
// bytes that were inspected here.
function readClearance(sid) {
  const claimedPath = path.join(getWorkflowDir(), `${sid}.off-clearance.claimed`);
  let raw;
  try {
    raw = fs.readFileSync(claimedPath, "utf8");
  } catch (e) {
    if (e && e.code === "ENOENT") return { status: "absent" };
    return { status: "error" };
  }
  let token = null;
  try {
    token = JSON.parse(raw);
  } catch (_e) {
    return { status: "malformed", claimedPath, raw };
  }
  if (!token || typeof token !== "object" || Array.isArray(token)) {
    return { status: "malformed", claimedPath, raw };
  }
  return { status: "found", claimedPath, token, raw };
}

// classifyClaim(token, target): "match" | "mismatch" | "legacy".
//   match    — claim names this exact target (the only positive evidence).
//   mismatch — claim names a different target; authorizes nothing here.
//   legacy   — old shape with no claimed_target; accepted only as a last
//              resort so upgrades don't strand an in-flight claim.
function classifyClaim(token, target) {
  const ct = token && token.claimed_target;
  if (typeof ct !== "string") return "legacy";
  return ct === target ? "match" : "mismatch";
}

// takeExact(filePath, expectedRaw): identity-bound removal — true only when the
// exact bytes previously read were removed by THIS call. A plain read-then-unlink
// races on the PATHNAME: another consumer can remove and recreate the file
// between the read and unlink, so a naive unlink could destroy a live claim that
// was never inspected. "Already gone" (ENOENT) is not success either — another
// consumer took it, so this call must not claim the activation. See
// ../../lib/consume-exact-file.js for the shared exclusion primitive.
function takeExact(filePath, expectedRaw) {
  return consumeExactFile(filePath, expectedRaw) === "consumed";
}

// consumeOffClearance(target, sessionId): unlink the token that authorized this
// OFF activation, keyed to whichever session id actually owned it — the shim
// may grant on a fallback token keyed to the workflow session id, so both
// sessionId and that fallback are checked as candidates. All candidates are
// classified before anything is consumed, so a stale or malformed claim under
// one sid can't be consumed ahead of the real match under the other; a
// malformed claim authorizes nothing and is swept separately (its own audit
// record) so it doesn't wedge future proposals. Single-use; fail-open on I/O
// errors or absence.
function consumeOffClearance(target, sessionId) {
  if (!sessionId || !SID_RE.test(sessionId)) return;
  const candidates = [sessionId];
  const wsid = resolveClearanceWsid();
  if (wsid && wsid !== sessionId && SID_RE.test(wsid)) candidates.push(wsid);

  const scanned = [];
  for (const sid of candidates) {
    const found = readClearance(sid);
    if (found.status === "malformed") {
      scanned.push({
        sid,
        claimedPath: found.claimedPath,
        verdict: "malformed",
        token: null,
        raw: found.raw,
      });
    } else if (found.status === "found") {
      scanned.push({
        sid,
        claimedPath: found.claimedPath,
        verdict: classifyClaim(found.token, target),
        token: found.token,
        raw: found.raw,
      });
    }
  }

  for (const c of scanned) {
    if (c.verdict !== "malformed" || !takeExact(c.claimedPath, c.raw)) continue;
    appendAudit(c.sid, {
      categories: ["workflow"],
      severity: "warning",
      detail:
        `off_clearance malformed claim swept (unreadable contents — authorized nothing) ` +
        `target=${target} sid=${c.sid}; the activation was NOT attributed to it`,
      reporter: "off-clearance-examiner",
      record_type: "off_clearance_malformed_claim_swept",
    });
  }

  const chosen =
    scanned.find((c) => c.verdict === "match") || scanned.find((c) => c.verdict === "legacy");
  if (!chosen) return; // no claim positively matched (e.g. emergency path)
  // Identity-bound: only the exact claim inspected above may be consumed, and only
  // the process that actually removed it may audit the activation as its use.
  if (!takeExact(chosen.claimedPath, chosen.raw)) return; // lost/changed — fail-open, no audit
  const token = chosen.token;
  appendAudit(chosen.sid, {
    categories: ["workflow"],
    severity: "notice",
    detail:
      `off_clearance consumed target=${target} ` +
      `category=${(token && token.category) || "unknown"} ` +
      `claim_shape=${chosen.verdict} ` +
      `claimed token unlinked (single-use enforced at claim time)`,
    reporter: "off-clearance-examiner",
    record_type: "off_clearance_consumed",
  });
}

// --- EMERGENCY provenance ---------------------------------------------------
// The emergency branch bypasses Phase1 examination on the claim that a human
// invoked skills/enforce-workflow-off. hooks/record-off-skill-invocation.js
// (UserPromptSubmit — an event the model cannot trigger) drops a marker when
// the user types the skill's slash command; this consumes it as evidence, not
// a gate — absence never blocks the override, and the value is `unattributed`,
// not an accusation. Contract details live in ../../lib/off-emergency-provenance.js
// (shared with the writer — CPR-SSOT); this file owns only consumption.
const {
  OFF_EMERGENCY_PROVENANCE_SOURCE,
  OFF_EMERGENCY_PROVENANCE_UNATTRIBUTED,
  verifyProvenanceMarker,
} = require("../../lib/off-emergency-provenance");

// readAndClearProvenance(sid, target) -> { attributed, note }
// Attribution is contingent on successfully CONSUMING the marker, not just
// reading it — a marker that can't be removed must not keep vouching for later
// activations. Consumption is identity-bound (../../lib/consume-exact-file.js)
// so concurrent handlers can't both count the same marker: "lost" (someone else
// took it, or it was rewritten since the read) is the ordinary case and carries
// no note; only a real I/O fault does.
function readAndClearProvenance(sid, target) {
  const { EMERGENCY_PROVENANCE_MARKER_KIND } = require("../../lib/protected-basenames");
  const markerPath = path.join(getWorkflowDir(), `${sid}.${EMERGENCY_PROVENANCE_MARKER_KIND}`);
  let raw;
  try {
    raw = fs.readFileSync(markerPath, "utf8");
  } catch (e) {
    if (e && e.code === "ENOENT") return { attributed: false, note: null }; // no marker — the ordinary case
    return {
      attributed: false,
      note: `provenance marker sid=${sid} could not be read — attribution withheld`,
    };
  }

  const outcome = consumeExactFile(markerPath, raw);
  // "lost": another handler consumed these bytes, or the marker was rewritten
  // since the read. Either way THIS call consumed nothing, so it attributes
  // nothing — and nothing is amiss, so it emits no note.
  if (outcome === "lost") return { attributed: false, note: null };
  if (outcome !== "consumed") {
    return {
      attributed: false,
      note: `provenance marker sid=${sid} could not be consumed (removal failed) — attribution withheld`,
    };
  }

  // Only reachable when this call removed exactly `raw`: the bytes attributed
  // below and the bytes consumed above are the same bytes by construction.
  const v = verifyProvenanceMarker(raw, target, Date.now());
  if (v.attributed) return { attributed: true, note: null };
  // Downgrades that are NOT a system fault (stale, corrupt, absent field) are
  // the documented under-attribution behaviour, so they need no audit note
  // beyond provenance=unattributed itself.
  return { attributed: false, note: null };
}

// resolveEmergencyProvenanceDetail(sessionId, target):
//   { provenance: "user_skill_invocation" | "unattributed", notes: string[] }
// Checks the same sid candidates consumeOffClearance() does, so a session whose
// workflow sid differs from the hook sid is attributed correctly (CPR-ORTH).
function resolveEmergencyProvenanceDetail(sessionId, target) {
  const candidates = [];
  if (sessionId && SID_RE.test(sessionId)) candidates.push(sessionId);
  const wsid = resolveClearanceWsid();
  if (wsid && wsid !== sessionId && SID_RE.test(wsid)) candidates.push(wsid);
  let attributed = false;
  const notes = [];
  for (const sid of candidates) {
    // No early break: every candidate marker is consumed so none can linger.
    const r = readAndClearProvenance(sid, target);
    if (r.attributed) attributed = true;
    if (r.note) notes.push(r.note);
  }
  return {
    provenance: attributed ? OFF_EMERGENCY_PROVENANCE_SOURCE : OFF_EMERGENCY_PROVENANCE_UNATTRIBUTED,
    notes,
  };
}

// resolveEmergencyProvenance(sessionId, target): the value only. `target`
// defaults to "workflow" so a caller that omits it cannot accidentally widen
// attribution to every target.
function resolveEmergencyProvenance(sessionId, target) {
  return resolveEmergencyProvenanceDetail(sessionId, target || "workflow").provenance;
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

  const provenanceDetail = resolveEmergencyProvenanceDetail(sessionId, target);
  const provenance = provenanceDetail.provenance;
  for (const note of provenanceDetail.notes) {
    process.stderr.write(`workflow-mark: WARNING — ${note}. Override still applied.\n`);
  }

  let markerPath;
  try {
    markerPath = writeMarker(kind, sessionId, {
      reason,
      emergency: true,
      provenance,
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
    detail:
      `emergency OFF activated target=${target} (Phase1 examination bypassed) ` +
      `provenance=${provenance} reason=${reason}` +
      (provenanceDetail.notes.length ? ` provenance_notes=${provenanceDetail.notes.join("; ")}` : ""),
    reporter: "off-clearance-examiner",
    record_type: "escape_hatch_event",
    provenance,
  });

  try {
    const { reportSentinel } = require("../../lib/supervisor-emit");
    reportSentinel(target === "workflow" ? "WORKFLOW_OFF" : "WORKTREE_OFF", reason, sessionId);
  } catch (_e) { /* fail-open */ }

  pushMessage(
    `workflow-mark: EMERGENCY ${target} override applied (marker: ${markerPath}). ` +
      `Phase1 examination was bypassed and the activation is recorded in the audit trail ` +
      `as provenance=${provenance}. ` +
      `Restore with: echo "<<WORKFLOW_ENFORCE_${target === "workflow" ? "WORKFLOW" : "WORKTREE"}_ON: {reason}>>"`
  );
  return true;
}

module.exports = { consumeOffClearance, handleEmergencyOff, resolveEmergencyProvenance };
