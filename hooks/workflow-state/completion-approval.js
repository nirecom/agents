"use strict";
// Completion-approval authority for the approval-gated workflow steps (#1133, #2277).
//
// `hasCompletionEvidence()` (evidence-resolver.js) only sees that a plan file exists; it cannot
// tell "review finished" from "the user approved". A gated step may be persisted `complete` only
// when a `plan_approvals[step]` record exists (or CONFIRM_<STAGE>=off waives an off-waivable gate).
// Approvals are `plan_approval` / `plan_approval_revoked` events; `state.plan_approvals` is their
// projection (#1733). Read paths fail open; the verdict fails closed — an uncomputable or
// mismatching artifact hash is a rejection. Contract: docs/architecture/claude-code/workflow.md.

const fs = require("fs");
const crypto = require("crypto");

const { getPlansArtifactPath } = require("../lib/plans-artifact-registry");
const { isConfirmOffForStageFromFile } = require("../lib/plan-confirm-flag");
const { SESSION_ID_VALID_RE, readState } = require("./state-io");
const { PLAN_STAGE_TABLE, rowFor } = require("./plan-stage-table");

// The ONLY enumeration of the approval-gated step class, in workflow order. Every check iterates
// this array; the per-stage values live in plan-stage-table.js (CPR-ORTH).
const APPROVAL_GATED_STEPS = Object.freeze(Object.keys(PLAN_STAGE_TABLE));

// Frozen closed set of named exceptions. 1:1 with the sanctioned override
// inventory. An unknown token is a caller bug and throws — a typo must never
// silently disable the invariant.
const SANCTIONED_SOURCES = Object.freeze([
  "confirm-sentinel",
  "confirm-flag-off",
  // "session-inherit" was a member until #2633-1: inheritance now copies the upstream
  // stream verbatim and reverts any stage whose approval no longer verifies, so it never
  // crosses the boundary on a token. Existing records stay readable via HASH_EXEMPT_SOURCES.
]);

// Approval sources that are approval-equivalent on their own (audit records):
// the source itself encodes an explicit user approval, so no artifact hash is
// bound to them.
const HASH_EXEMPT_SOURCES = Object.freeze([
  // legacy read-only: no longer created from this PR on (#2709) — RESET_FROM now verifies the
  // prior gates instead of synthesising an approval, but records already in a state still approve.
  "reset-sentinel",
  "confirm-flag-off",
  // legacy read-only: no longer created since #2633-1, but a pre-#2633 inheritance stamped
  // it with no artifact hash, and those records must still approve on re-read.
  "session-inherit",
]);

class UnapprovedCompletionError extends Error {
  constructor(step, code, recovery) {
    super(
      `workflow step "${step}" cannot be completed: ${code}. ${recovery || ""}`.trim()
    );
    this.name = "UnapprovedCompletionError";
    this.step = step;
    this.code = code;
    this.recovery = recovery || "";
  }
}

let _envLoaded = false;
// plan-confirm-flag.js deliberately does not load .env (its hook callers do).
// workflow-mark.js and bin/workflow/next-step do NOT call loadDefaultEnv(), so
// this module loads it once itself — otherwise CONFIRM_<STAGE>=off users would
// be incorrectly blocked.
function ensureEnvLoaded() {
  if (_envLoaded) return;
  _envLoaded = true;
  try {
    const { loadDefaultEnv } = require("../lib/load-env");
    loadDefaultEnv();
  } catch (_) { /* fail-open: env stays as-is */ }
}

function isApprovalGatedStep(step) {
  return APPROVAL_GATED_STEPS.indexOf(step) !== -1;
}

function confirmSentinelFor(step) {
  const row = rowFor(step);
  return row ? row.sentinel : "WORKFLOW_CONFIRM_" + String(step).toUpperCase();
}

// Human-readable recovery instruction. Never contains a single quote — callers
// embed it in single-quoted NEXT_HINT/REASON output.
function recoveryFor(step) {
  const row = rowFor(step);
  const waiver = row && row.offWaivable
    ? " (or set " + row.confirmFlag + "=off to waive the gate)"
    : " (this gate has no off waiver)";
  return (
    "Approval for " + step + " is not on record. End the presentation turn with " +
    "the plan-link line (bin/plan-link); when the turn-end prompt asks for it, emit echo \"<<" +
    confirmSentinelFor(step) + ": {summary}>>\" alone to record it" + waiver +
    ". Otherwise emit it after the user replies with approval. Do NOT use --mark."
  );
}

// isOffWaived(step) -> whether the CONFIRM_* flag in the config FILE waives this gate. Never
// process.env: bin/workflow/next-step is spawnable by the Bash tool, so an inline
// `CONFIRM_<STAGE>=off node ...` prefix would otherwise mint a fake user-waiver record.
function isOffWaived(step) {
  const row = rowFor(step);
  if (!row || !row.offWaivable) return false;
  try { return isConfirmOffForStageFromFile(row.suffix) === true; } catch (_) { return false; }
}

// Named exception (CPR-UNV): a row's digestExcludes H2 sections are cut from the heading line up
// to the next H2 before hashing. A heading that appears more than once is not cut, so an
// ambiguous artifact falls back to the full-text digest (fail-closed).
function digestBody(buf, excludes) {
  if (!excludes || excludes.length === 0) return buf;
  let lines = buf.toString("utf8").split("\n");
  for (const title of excludes) {
    const heading = "## " + title;
    const hits = lines.map((l, i) => (l.replace(/\s+$/, "") === heading ? i : -1)).filter((i) => i !== -1);
    if (hits.length !== 1) continue;
    let end = hits[0] + 1;
    while (end < lines.length && !/^## /.test(lines[end])) end++;
    lines = lines.slice(0, hits[0]).concat(lines.slice(end));
  }
  return Buffer.from(lines.join("\n"), "utf8");
}

// Validates a sanctioned token against the frozen set. Returns the token on
// success; throws UnapprovedCompletionError(unknown-sanctioned-token) otherwise.
function assertSanctionedSource(token, step) {
  if (typeof token !== "string" || SANCTIONED_SOURCES.indexOf(token) === -1) {
    throw new UnapprovedCompletionError(
      step || "(any)",
      "unknown-sanctioned-token",
      "sanctioned token " + JSON.stringify(token) + " is not a member of the " +
        "closed SANCTIONED_SOURCES set: " + SANCTIONED_SOURCES.join(", ")
    );
  }
  return token;
}

// sha256 of <PLANS_DIR>/<sid>-<suffix>.md minus the row's digestExcludes. Returns null on ANY
// anomaly (invalid sessionId, missing/unreadable artifact). null means "anomaly" — callers must
// treat it fail-closed, never as "skip the check".
function computeArtifactSha(sessionId, step) {
  try {
    if (!sessionId || !SESSION_ID_VALID_RE.test(sessionId)) return null;
    if (!isApprovalGatedStep(step)) return null;
    const row = rowFor(step);
    const artifact = getPlansArtifactPath(sessionId, row.suffix);
    const buf = digestBody(fs.readFileSync(artifact), row.digestExcludes);
    return crypto.createHash("sha256").update(buf).digest("hex");
  } catch (_) {
    return null;
  }
}

// fail-open read: malformed / absent state yields null.
function readPlanApproval(state, step) {
  try {
    if (!state || typeof state !== "object") return null;
    const pa = state.plan_approvals;
    if (!pa || typeof pa !== "object") return null;
    const rec = pa[step];
    if (!rec || typeof rec !== "object") return null;
    return rec;
  } catch (_) {
    return null;
  }
}

// Appends an approval to the stream. Emits no step_status, so the
// completion-boundary invariant never fires on this append.
function recordPlanApproval(sessionId, step, fields = {}) {
  if (!isApprovalGatedStep(step)) {
    throw new Error(`recordPlanApproval: "${step}" is not an approval-gated step`);
  }
  const source = fields.source;
  assertSanctionedSource(source, step);
  const owner = fields.artifactSessionId;
  if (owner !== undefined && owner !== null && (typeof owner !== "string" || !SESSION_ID_VALID_RE.test(owner))) {
    throw new Error(`recordPlanApproval: invalid artifactSessionId: ${JSON.stringify(owner)}`);
  }

  const { appendEvents } = require("./state-io");
  appendEvents(sessionId, [
    {
      kind: "plan_approval",
      step,
      source,
      reason: fields.reason || null,
      artifact_sha256: fields.artifactSha || null,
      // Session whose artifact the recorded hash was taken from. Artifacts are
      // named <sid>-<suffix>.md, so a record inherited by a LATER session must keep
      // pointing at the session that owns the approved artifact (#1133). A downstream
      // session hashes its upstream's file, so the caller names that owner (#2633).
      artifact_session_id: fields.artifactSha ? (owner || sessionId) : null,
      artifact_hash_status: fields.artifactHashStatus || "unknown",
      provenance: "declared",
      origin: "record-plan-approval",
    },
  ]);
  const after = readState(sessionId);
  return readPlanApproval(after, step);
}

// Builds the audit record stamped when a sanctioned token or the
// CONFIRM_<STAGE>=off waiver authorizes a completion transition. Kept as the
// SSOT for the record's SHAPE; the stream form is buildAuditApprovalEvent below.
function buildAuditApproval(source, reason) {
  return {
    source,
    reason: reason || null,
    artifact_sha256: null,
    artifact_session_id: null,
    artifact_hash_status: "not-applicable",
    recorded_at: new Date().toISOString(),
  };
}

// The same audit record as a `plan_approval` event. `recorded_at` is dropped:
// the stream stamps `at`, and the projection derives recorded_at from it (CPR-SSOT).
function buildAuditApprovalEvent(step, source, reason, origin) {
  const rec = buildAuditApproval(source, reason);
  delete rec.recorded_at;
  return Object.assign({ kind: "plan_approval", step }, rec, {
    provenance: "declared",
    origin: origin || "completion-boundary",
  });
}

// Owner of <sid>-<suffix>.md as seen from the evaluated state; any anomaly -> sessionId.
function resolveOwnerSid(sessionId, step, state) {
  try {
    const { resolvePlanArtifactOwner } = require("./plan-artifact-owner");
    return resolvePlanArtifactOwner(sessionId, rowFor(step).suffix, state || null).ownerSid;
  } catch (_) {
    return sessionId;
  }
}

// Authoritative verdict for "may this gated step be persisted complete?" -> { approved, code,
// source }. Shared by the effective-state snapshot and the write boundary so they never diverge.
// confirm-sentinel needs a recorded sha equal to the current one (else artifact-hash-mismatch /
// -unverifiable); HASH_EXEMPT_SOURCES approve without a hash; no record -> no-approval-record.
function evaluateCompletionApproval(sessionId, step, state) {
  if (!isApprovalGatedStep(step)) {
    return { approved: true, code: null, source: null };
  }

  ensureEnvLoaded();
  const record = readPlanApproval(state, step);

  if ((!record || record.source === "confirm-flag-off") && isOffWaived(step)) {
    return { approved: true, code: null, source: "confirm-flag-off" };
  }

  if (!record) {
    return { approved: false, code: "no-approval-record", source: null };
  }

  const source = record.source;
  // A non-offWaivable step has no off waiver, so a stored confirm-flag-off record proves nothing.
  if (source === "confirm-flag-off" && !(rowFor(step) || {}).offWaivable) {
    return { approved: false, code: "no-approval-record", source };
  }
  if (HASH_EXEMPT_SOURCES.indexOf(source) !== -1) {
    return { approved: true, code: null, source };
  }
  if (source !== "confirm-sentinel") {
    // Unrecognized source is not proof of approval.
    return { approved: false, code: "no-approval-record", source: source || null };
  }

  const recordedSha = record.artifact_sha256;
  if (!recordedSha) {
    return { approved: false, code: "artifact-hash-unverifiable", source };
  }
  // A record inherited across a session boundary stays bound to the artifact it
  // was approved against (<owner-sid>-<suffix>.md), so the hash still verifies. A record
  // without an owner is resolved the way the reader would resolve it (#2633).
  const artifactSessionId = record.artifact_session_id || resolveOwnerSid(sessionId, step, state);
  // A record bound to a file other than the existing one the reader resolves (plan-artifact-owner)
  // approves content nobody reads: it needs re-approval.
  const readerSid = resolveOwnerSid(sessionId, step, state);
  if (artifactSessionId !== readerSid && computeArtifactSha(readerSid, step)) {
    return { approved: false, code: "artifact-hash-mismatch", source };
  }
  const currentSha = computeArtifactSha(artifactSessionId, step);
  if (!currentSha) {
    return { approved: false, code: "artifact-hash-unverifiable", source };
  }
  if (currentSha !== recordedSha) {
    return { approved: false, code: "artifact-hash-mismatch", source };
  }
  return { approved: true, code: null, source };
}

// Completion-boundary invariant over a BATCH of events (#1133, #1733): compares the on-disk fold
// with the fold plus the batch. Per gated step, in order: (1) leaving complete revokes the
// approval; (2) a validated opts.sanctioned token stamps an audit record instead of checking;
// (3) an unsanctioned ->complete transition must pass evaluateCompletionApproval or this throws
// UnapprovedCompletionError before any byte is written. Returns the extra events for the batch.
function completionBoundaryEventsForBatch(sessionId, prevProjection, nextProjection, opts) {
  const extra = [];
  const statusOf = (proj, step) => {
    const steps = (proj && proj.steps) || {};
    const entry = steps[step];
    return (entry && entry.status) || "pending";
  };
  const origin = (opts && typeof opts.origin === "string" && opts.origin) || "completion-boundary";
  // A revocation inside an inheritance copy is reconstructed, not observed (#2633-1).
  const revokeProvenance = opts && opts.provenance === "backfilled" ? "backfilled" : "declared";

  // Sanctioned token validation (throws on an unknown token, before any write).
  const rawToken = opts && opts.sanctioned;
  const sanctioned = (rawToken === undefined || rawToken === null)
    ? null
    : assertSanctionedSource(rawToken);

  for (const step of APPROVAL_GATED_STEPS) {
    const before = statusOf(prevProjection, step);
    const after = statusOf(nextProjection, step);

    // 1. Approval invalidation.
    if (before === "complete" && after !== "complete") {
      if (readPlanApproval(nextProjection, step)) {
        extra.push({
          kind: "plan_approval_revoked",
          step,
          reason: "gated step left complete",
          provenance: revokeProvenance,
          origin,
        });
      }
      continue;
    }

    if (before === "complete" || after !== "complete") continue;

    // 2. Sanctioned bypass.
    if (sanctioned) {
      extra.push(buildAuditApprovalEvent(step, sanctioned, opts && opts.reason, origin));
      continue;
    }

    // 3. Invariant enforcement.
    const verdict = evaluateCompletionApproval(sessionId, step, nextProjection);
    if (!verdict.approved) {
      throw new UnapprovedCompletionError(step, verdict.code, recoveryFor(step));
    }
    // CONFIRM_<STAGE>=off waiver: re-verified at write time, then stamped as an
    // audit record so a completion is never silent/unrecorded.
    if (verdict.source === "confirm-flag-off" && !readPlanApproval(nextProjection, step)) {
      extra.push(buildAuditApprovalEvent(step, "confirm-flag-off", "CONFIRM flag off", origin));
    }
  }
  return extra;
}

// writeState boundary. Since #1733 `steps` is derived from `events`, and writeState
// never touches `events` — so it can produce no status transition of its own. What
// remains for it to enforce is the token domain: an unknown opts.sanctioned value
// must abort the write rather than be silently ignored.
function applyCompletionBoundaryInvariant(sessionId, state, opts) {
  const rawToken = opts && opts.sanctioned;
  if (rawToken !== undefined && rawToken !== null) assertSanctionedSource(rawToken);
}

module.exports = {
  APPROVAL_GATED_STEPS,
  SANCTIONED_SOURCES,
  UnapprovedCompletionError,
  isApprovalGatedStep,
  assertSanctionedSource,
  computeArtifactSha,
  readPlanApproval,
  recordPlanApproval,
  buildAuditApproval,
  buildAuditApprovalEvent,
  evaluateCompletionApproval,
  applyCompletionBoundaryInvariant,
  completionBoundaryEventsForBatch,
  recoveryFor,
  confirmSentinelFor,
  isOffWaived,
};
