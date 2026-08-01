"use strict";
// Completion-approval authority for the approval-gated workflow steps (#1133).
//
// `hasCompletionEvidence()` (evidence-resolver.js) is a heuristic: for outline /
// detail it cannot distinguish "review not started" from "review finished but
// the user has not approved yet" — both look identical on disk. This module owns
// the authoritative answer: a gated step may only be persisted `complete` when a
// `plan_approvals[step]` record exists on the session state (or the user has
// pre-waived the gate via CONFIRM_<STAGE>=off).
//
// Storage note (#1733): approvals are no longer a mutable top-level field. Each
// approval is a `plan_approval` event and each withdrawal a `plan_approval_revoked`
// event; `state.plan_approvals` is the projection folded from that stream, so the
// evidence behind a superseded or revoked approval stays readable forever.
//
// Failure contract: read paths fail-open (malformed → null / no record), but the
// verdict itself is FAIL-CLOSED — every uncomputable or mismatching artifact hash
// is a rejection, never a downgrade to an existence-only check.

const fs = require("fs");
const path = require("path");
const crypto = require("crypto");

const { getWorkflowPlansDir } = require("../lib/workflow-plans-dir");
const { isConfirmOffForStageFromFile } = require("../lib/plan-confirm-flag");
const { SESSION_ID_VALID_RE, readState } = require("./state-io");

// The ONLY enumeration of the approval-gated step class. Every check iterates
// this array — never hardcode one member without the other (CPR-5).
const APPROVAL_GATED_STEPS = Object.freeze(["outline", "detail"]);

// Frozen closed set of named exceptions. 1:1 with the sanctioned override
// inventory. An unknown token is a caller bug and throws — a typo must never
// silently disable the invariant.
const SANCTIONED_SOURCES = Object.freeze([
  "confirm-sentinel",
  "confirm-flag-off",
  "reset-sentinel",
]);

// Approval sources that are approval-equivalent on their own (audit records):
// the source itself encodes an explicit user approval, so no artifact hash is
// bound to them.
const HASH_EXEMPT_SOURCES = Object.freeze(["reset-sentinel", "confirm-flag-off"]);

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
  return "WORKFLOW_CONFIRM_" + String(step).toUpperCase();
}

// Human-readable recovery instruction. Never contains a single quote — callers
// embed it in single-quoted NEXT_HINT/REASON output.
function recoveryFor(step) {
  return (
    "Approval for " + step + " is not on record. Emit: echo \"<<" +
    confirmSentinelFor(step) + ": {summary}>>\" to record user approval " +
    "(or set " + (step === "outline" ? "CONFIRM_OUTLINE" : "CONFIRM_DETAIL") +
    "=off to waive the gate). Do NOT use --mark."
  );
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

// sha256 of <PLANS_DIR>/<sid>-<step>.md. Returns null on ANY anomaly (invalid
// sessionId, missing/unreadable artifact). null means "anomaly" — callers must
// treat it fail-closed, never as "skip the check".
function computeArtifactSha(sessionId, step) {
  try {
    if (!sessionId || !SESSION_ID_VALID_RE.test(sessionId)) return null;
    if (!isApprovalGatedStep(step)) return null;
    const plansDir = getWorkflowPlansDir();
    const artifact = path.join(plansDir, sessionId + "-" + step + ".md");
    const buf = fs.readFileSync(artifact);
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

  const { appendEvents } = require("./state-io");
  appendEvents(sessionId, [
    {
      kind: "plan_approval",
      step,
      source,
      reason: fields.reason || null,
      artifact_sha256: fields.artifactSha || null,
      // Session whose artifact the recorded hash was taken from. Artifacts are
      // named <sid>-<step>.md, so a record inherited by a LATER session must keep
      // pointing at the session that owns the approved artifact (#1133).
      artifact_session_id: fields.artifactSha ? sessionId : null,
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
// the stream stamps `at`, and the projection derives recorded_at from it (CPR-2).
function buildAuditApprovalEvent(step, source, reason, origin) {
  const rec = buildAuditApproval(source, reason);
  delete rec.recorded_at;
  return Object.assign({ kind: "plan_approval", step }, rec, {
    provenance: "declared",
    origin: origin || "completion-boundary",
  });
}

// Authoritative verdict for "may this gated step be persisted complete?".
// Returns { approved, code, source }. Used at BOTH the effective-state snapshot
// stage and the writeState boundary — divergence between the two would produce
// "scan passed but write rejected" inconsistencies.
//
// Artifact-hash transition table (all uncomputable/mismatch cases fail closed):
//   confirm-sentinel + recorded sha + current sha matches   → APPROVED
//   confirm-sentinel + recorded sha + current sha differs   → artifact-hash-mismatch
//   confirm-sentinel + recorded sha + uncomputable now      → artifact-hash-unverifiable
//   confirm-sentinel + no recorded sha                      → artifact-hash-unverifiable
//   reset-sentinel / confirm-flag-off (audit record)        → APPROVED (no hash check)
//   no record                                               → no-approval-record
function evaluateCompletionApproval(sessionId, step, state) {
  if (!isApprovalGatedStep(step)) {
    return { approved: true, code: null, source: null };
  }

  ensureEnvLoaded();
  const record = readPlanApproval(state, step);

  // CONFIRM_<STAGE>=off: user pre-waived the gate via config.
  if (!record || record.source === "confirm-flag-off") {
    // Config-file-only read: bin/workflow/next-step and bin/workflow/reconcile-state
    // are spawnable by the Bash tool, so an inline `CONFIRM_<STAGE>=off node ...`
    // prefix would otherwise waive the gate and mint a fake user-waiver record.
    let off = false;
    try { off = isConfirmOffForStageFromFile(step) === true; } catch (_) { off = false; }
    if (off) return { approved: true, code: null, source: "confirm-flag-off" };
  }

  if (!record) {
    return { approved: false, code: "no-approval-record", source: null };
  }

  const source = record.source;
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
  // was approved against (<owner-sid>-<step>.md), so the hash still verifies.
  const artifactSessionId = record.artifact_session_id || sessionId;
  const currentSha = computeArtifactSha(artifactSessionId, step);
  if (!currentSha) {
    return { approved: false, code: "artifact-hash-unverifiable", source };
  }
  if (currentSha !== recordedSha) {
    return { approved: false, code: "artifact-hash-mismatch", source };
  }
  return { approved: true, code: null, source };
}

// Completion-boundary invariant for the approval-gated steps (#1133), expressed
// over a BATCH of events (#1733).
//
// `prevProjection` is the fold of the stream as it stands on disk; `nextProjection`
// is the fold of that stream PLUS the batch about to be appended. Comparing the two
// folds — rather than a keyed step map before/after a rewrite — is what keeps the
// gate on the only remaining write path, appendEvents.
//
// Order is significant:
//   1. approval invalidation — a gated step LEAVING complete revokes its approval,
//      so a stale approval can never re-validate a later re-completion.
//   2. sanctioned bypass     — a validated opts.sanctioned token skips the check
//      and stamps an audit record for each gated completion transition.
//   3. invariant enforcement — an unsanctioned →complete transition must satisfy
//      evaluateCompletionApproval, else it throws.
// A complete→complete rewrite is not a transition and passes through, as does a
// transition to `skipped`.
//
// Returns the extra events the caller must append INSIDE the same batch (audit
// approvals and revocations). Throws UnapprovedCompletionError on a violation,
// before any byte is written.
function completionBoundaryEventsForBatch(sessionId, prevProjection, nextProjection, opts) {
  const extra = [];
  const statusOf = (proj, step) => {
    const steps = (proj && proj.steps) || {};
    const entry = steps[step];
    return (entry && entry.status) || "pending";
  };
  const origin = (opts && typeof opts.origin === "string" && opts.origin) || "completion-boundary";

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
          provenance: "declared",
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
};
