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
function resolveClearanceWsid() {
  try {
    const { resolveWorkflowSessionId } = require("../../lib/resolve-workflow-session-id");
    return resolveWorkflowSessionId() || null;
  } catch (_e) {
    return null;
  }
}

// readClearance(sid): read (without unlinking) one sid's CLAIMED token file.
// Returns { status: "found", claimedPath, token, raw } | { status: "malformed", claimedPath, raw }
//       | { status: "absent" } | { status: "error" }.
// "malformed" is its own status, NOT a found-with-null-token: a claim whose
// contents cannot be read says nothing about which target it authorized, so it
// must never stand in for one (#1780 M-1).
// `raw` is carried out with every non-absent result because removal is
// identity-bound (see ../../lib/consume-exact-file.js): the exact bytes inspected
// are what may be deleted later, so they must survive the read.
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
//   match    — the claim names this exact target (the only positive evidence).
//   mismatch — the claim names a different target; it authorizes nothing here.
//   legacy   — pre-#1626 shape with no claimed_target at all: no evidence either
//              way, accepted only as a LAST resort so upgrades do not strand an
//              in-flight claim (never ahead of a positive match).
function classifyClaim(token, target) {
  const ct = token && token.claimed_target;
  if (typeof ct !== "string") return "legacy";
  return ct === target ? "match" : "mismatch";
}

// takeExact(filePath, expectedRaw): IDENTITY-BOUND removal (#1780 round-5 M-2).
// True only when the exact bytes previously inspected were removed by THIS call —
// which is also the only case that may be audited as a consumption.
//
// A read-then-unlink pair races on the PATHNAME, not on identity: between the read
// and the unlink another consumer can remove the file and the shim's exclusive `wx`
// claim can re-create it, so the unlink destroys a LIVE claim that was never
// inspected (and the audit record misattributes it). "Already gone" (ENOENT) is
// likewise NOT success — it means another consumer removed it, so this call
// consumed nothing and must not claim the activation.
// The exclusion primitive and the reason it is `wx` and not rename are documented
// in ../../lib/consume-exact-file.js (shared with bin/request-off-clearance).
function takeExact(filePath, expectedRaw) {
  return consumeExactFile(filePath, expectedRaw) === "consumed";
}

// consumeOffClearance(target, sessionId): unlink the token that authorized this OFF
// activation and record an off_clearance_consumed audit entry keyed to whichever
// session id actually owned it. The shim may authorize on a FALLBACK token keyed to
// the resolved workflow session id, so consumption mirrors that fallback — otherwise
// a single-use token would survive its own use.
// #1626 MEDIUM (Codex round 6/7): a naive "try sessionId, else try the fallback
// wsid" order can consume the WRONG claim — an unrelated stale `.claimed` file
// left under sessionId from a prior, different-target grant would be unlinked
// and audited here while the real fallback claim for THIS activation survives
// untouched, wedging future proposals.
//
// #1780 M-1 (round 4): the first cut of that guard still short-circuited on any
// claim it could not read positively — an UNPARSEABLE claim, or a legacy claim
// carrying no claimed_target, stopped the candidate scan under the FIRST sid and
// was consumed as if it had authorized this activation, so the real matching
// claim under the fallback sid survived. Two rules replace that:
//
//   1. ALL candidates are classified before anything is consumed, and a positive
//      `claimed_target === target` match wins wherever it sits in the list. Only
//      when no candidate matches positively does a legacy (no-target) claim get
//      consumed, and a mismatching claim is never consumed at all.
//   2. A MALFORMED claim authorizes nothing: it is swept on its own terms, with
//      its own `off_clearance_malformed_claim_swept` warning-severity audit
//      record, and it neither ends the scan nor produces a "consumed" record.
//      Sweeping rather than leaving it is deliberate — the shim's atomic `wx`
//      claim treats ANY existing .claimed file as "already claimed", so an
//      unreadable one left in place would wedge every future proposal for that
//      sid (a denial of service, fixable only by hand) while proving nothing.
//      The audit trail keeps the two events distinguishable.
//
// Single-use: a granted clearance authorizes exactly one OFF activation.
// Fail-open — ENOENT and I/O errors are swallowed so a missing token never blocks an
// already-approved override.
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

// --- EMERGENCY provenance (#1780 M-2) -------------------------------------
// The emergency branch bypasses the Phase1 examination on the strength of ONE
// claim: that the human invoked skills/enforce-workflow-off. Nothing in the
// audit record used to carry evidence for that claim, so a model-initiated
// emission and a user-invoked one were indistinguishable after the fact.
// hooks/record-off-skill-invocation.js (UserPromptSubmit — an event the model
// cannot trigger) drops <sid>.off-emergency-invoked when the user types the
// skill's slash command; this consumes and unlinks it.
//
// Evidence, not a gate: absence never blocks the override, and the value is
// `unattributed` — "not provably user-invoked" — not an accusation. The marker
// is single-use and short-lived (record-off-skill-invocation.js clears it on
// the next user prompt), so a stale one cannot vouch for a later unprompted
// emission. What the marker does and does not prove, the freshness window, and
// the skill/target bindings all live in ../../lib/off-emergency-provenance.js
// (shared with the writer — CPR-2); this file owns only CONSUMPTION.
const {
  OFF_EMERGENCY_PROVENANCE_SOURCE,
  OFF_EMERGENCY_PROVENANCE_UNATTRIBUTED,
  verifyProvenanceMarker,
} = require("../../lib/off-emergency-provenance");

// readAndClearProvenance(sid, target) -> { attributed, note }
//
// #1780 M-2 (round 4): attribution is CONTINGENT ON SUCCESSFUL CONSUMPTION. The
// previous version unlinked best-effort and attributed anyway, so a marker that
// could not be removed (permissions, a lock, a read-only workflow dir) kept
// vouching for every emergency emission until its freshness window expired —
// one user invocation silently attributing many activations, which is precisely
// the single-use property the marker exists to provide. A failed unlink now
// yields `unattributed` plus a note that is carried into the audit record and
// announced on stderr, so the failure is visible instead of invisible.
//
// #1780 round-5 M-3: read-then-unlink was still not single-use under concurrency.
// Two handlers could both READ the one marker; the first unlink succeeded, the
// second got ENOENT and counted that as a successful consumption too — so ONE user
// invocation attributed TWO emergency activations, and a marker rewritten by a
// concurrent UserPromptSubmit could be deleted after different bytes were read.
// Attribution is now gated on identity-bound consumption of the exact bytes read
// (../../lib/consume-exact-file.js): exactly one caller can consume a given marker,
// and "already gone"/"someone else has it" means this call consumed NOTHING and
// must not attribute. That is also the ordinary "no marker" case, so it carries no
// note; only a real I/O fault does.
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
// workflow sid differs from the hook sid is attributed correctly (CPR-5).
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

// resolveEmergencyProvenance(sessionId, target): the value only. `target` is
// required for the M-4 target binding; it defaults to "workflow" so a caller
// that omits it cannot accidentally widen attribution to every target.
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
