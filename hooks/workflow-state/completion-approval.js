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
  "reset-sentinel",
  // #1305: a completion carried over from a session this one provably descends
  // from (fork lineage) or that the user named by hand via
  // bin/workflow/adopt-session-state. The approval was given in that
  // conversation; the donor simply predates plan_approvals or never recorded
  // one. Used ONLY when the donor holds no approval record at all for the gated
  // steps in the batch — a donor that HAS a record is verified normally, so a
  // tampered or missing artifact is still refused.
  "session-inherit",
]);

// Approval sources that are approval-equivalent on their own (audit records):
// the source itself encodes an explicit user approval, so no artifact hash is
// bound to them.
const HASH_EXEMPT_SOURCES = Object.freeze([
  "reset-sentinel",
  "confirm-flag-off",
  // #1305: no artifact hash was ever bound to it — there was no donor record to
  // take one from. Omitting it here would make the audit record this module
  // itself stamps fail its own later re-read (artifact-hash-unverifiable).
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
    "Approval for " + step + " is not on record. Re-present the plan and end that turn with " +
    "the plan-link line (bin/plan-link); after the user replies with approval, emit echo \"<<" +
    confirmSentinelFor(step) + ": {summary}>>\" on its own to record it" +
    waiver + ". Do NOT use --mark."
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
    const artifact = getPlansArtifactPath(sessionId, rowFor(step).suffix);
    return shaOfArtifactBuffer(fs.readFileSync(artifact), step);
  } catch (_) {
    return null;
  }
}

// The approval range of an artifact's bytes (digestExcludes cut); null for a non-gated step.
// The glossary check scans and fingerprints this same range (#2529 I-FP rule R-A).
function artifactRangeOfBuffer(buf, step) {
  if (!isApprovalGatedStep(step)) return null;
  return digestBody(buf, rowFor(step).digestExcludes);
}

function shaOfArtifactBuffer(buf, step) {
  const range = artifactRangeOfBuffer(buf, step);
  if (range === null) return null;
  return crypto.createHash("sha256").update(range).digest("hex");
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
      // named <sid>-<suffix>.md, so a record inherited by a LATER session must keep
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
// the stream stamps `at`, and the projection derives recorded_at from it (CPR-SSOT).
function buildAuditApprovalEvent(step, source, reason, origin) {
  const rec = buildAuditApproval(source, reason);
  delete rec.recorded_at;
  return Object.assign({ kind: "plan_approval", step }, rec, {
    provenance: "declared",
    origin: origin || "completion-boundary",
  });
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
  // was approved against (<owner-sid>-<suffix>.md), so the hash still verifies.
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

    // 2. Sanctioned bypass. session-inherit never vouches for a stage with no off waiver
    // (intent): the inherited complete stays unapproved, so the effective state falls back
    // to pending until the user confirms that stage in this session.
    if (sanctioned === "session-inherit" && !(rowFor(step) || {}).offWaivable) continue;
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
  artifactRangeOfBuffer,
  shaOfArtifactBuffer,
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
