"use strict";
// review_tests step lifecycle: review-scope manifest record, warning clearance,
// terminal-marker cleanup, write_code completion reopen, in_progress recovery after a
// review that ended non-block (rc 2/6, rc 1/5, rc 3 fallback). Entrypoint-private to state-io.js.

const fs = require("fs");
const { assertValidSessionId, readState, markStep } = require("./core");
// Called as events.appendEvents at call time (never destructured) so a wrapper
// installed on the module is honoured.
const events = require("./events");

const REVIEW_TESTS_REOPEN_REASONS = ["write-code-stale", "write-code-missing", "write-code-unavailable"];

// Accepts a plain { path: oid } map or a manifest result ({ ok?, v?, files }).
function manifestFiles(input) {
  if (!input || typeof input !== "object" || Array.isArray(input)) return null;
  const wrapped = ("files" in input) && ("ok" in input || "v" in input);
  const files = wrapped ? input.files : input;
  return files && typeof files === "object" && !Array.isArray(files) ? files : null;
}

// The review-scope annotation fields: the per-file manifest, plus tombstones for the
// legacy token and the write_code reopen mark (a fresh review supersedes both).
function buildReviewScopeAnnotation(files) {
  return { review_scope_manifest: { v: 1, files: { ...files } }, token: null, reopen_reason: null };
}

function markReviewTestsComplete(sessionId, files, extraFields = {}) {
  const map = manifestFiles(files);
  if (!map) throw new Error("markReviewTestsComplete: files must be a { path: oid } object");
  const { resolveWorkflowSessionId } = require("../../lib/resolve-workflow-session-id");
  let wsid = null;
  try { wsid = resolveWorkflowSessionId() || null; } catch (_) {}
  // The resolved workflow session id is a FALLBACK: an explicitly supplied
  // extraFields.wsid is the caller's own evidence and must win over the ambient probe.
  // A clean COMPLETE drops a past round's warning and acceptance reason; the WARNINGS path overrides
  // via extraFields. Recorded as observed by markStep (cleared by the handler), not declared.
  markStep(sessionId, "review_tests", "complete", { ...buildReviewScopeAnnotation(map), ...warningsTombstoneFields(), wsid, ...extraFields });
}

const CLEAR_OUTCOME = Object.freeze({
  RECOVERED: "recovered",
  RECOVERED_TERMINAL: "recovered-terminal",
  RECOVERED_CONTINUING: "recovered-continuing",
  RECOVERED_FALLBACK: "recovered-fallback",
  WARNINGS_CLEARED: "warnings-cleared",
  NOTHING_TO_CLEAR: "nothing-to-clear",
  MANIFEST_UNAVAILABLE: "manifest-unavailable",
  STALE_EVIDENCE: "stale-evidence",
  NO_STATE: "no-state",
});

const TERMINAL_MARKER = "test-review-terminal.txt";
const CONTINUING_MARKER = "test-review-continuing.txt";

// Trust boundary: single-user local filesystem (NFR); forgeability risk accepted.
function controlMarkerPath(sessionId, name) {
  assertValidSessionId(sessionId);
  const { controlPath } = require("./control-dir");
  return controlPath(sessionId, name);
}

// -> { rc, fp, mtimeMs } (line 1 = wrapper rc, line 2 = review-scope fingerprint) or null.
function readControlMarker(sessionId, name) {
  try {
    const p = controlMarkerPath(sessionId, name);
    const lines = fs.readFileSync(p, "utf8").split("\n");
    return { rc: (lines[0] || "").trim(), fp: (lines[1] || "").trim(), mtimeMs: fs.statSync(p).mtimeMs };
  } catch (e) {
    return null;
  }
}

// The exit-3 fallback output. Candidates: the workflow session id (the wrapper's SESSION_ID
// names plan artifacts), then the CC session id. Only the first existing file is judged, so a
// later candidate can never rescue a refused one (fail-closed).
function resolveFallbackRawPath(ccSid) {
  const { SESSION_ID_VALID_RE } = require("./core");
  const { resolveWorkflowSessionId } = require("../../lib/resolve-workflow-session-id");
  const { getPlansArtifactPath } = require("../../lib/plans-artifact-registry");
  let wsid = null;
  try { wsid = resolveWorkflowSessionId() || null; } catch (_) {}
  const seen = new Set();
  for (const sid of [wsid, ccSid]) {
    if (typeof sid !== "string" || !SESSION_ID_VALID_RE.test(sid) || seen.has(sid)) continue;
    seen.add(sid);
    let p;
    try { p = getPlansArtifactPath(sid, "test-review-fallback-raw"); } catch (_) { continue; }
    if (fs.existsSync(p)) return p;
  }
  return null;
}

// The fallback reviewer's NEEDS_REVISION is the RT-5 WARNINGS outcome; APPROVED / INPUT_ERROR /
// anything else, or a file older than the terminal marker, is no evidence of a non-block end.
function fallbackRawRefusal(rawPath, markerMtimeMs) {
  try {
    if (fs.statSync(rawPath).mtimeMs < markerMtimeMs) return "fallback-raw-stale";
    const first = fs.readFileSync(rawPath, "utf8").split("\n").map((l) => l.trim()).find((l) => l.length > 0);
    return first === "NEEDS_REVISION" ? null : "fallback-raw-not-warnings";
  } catch (e) {
    return "fallback-raw-missing";
  }
}

// Evidence that the last review ended non-block, for the in_progress recovery (#2491, #2664).
// -> { ok, source, reason }. terminal-2 / terminal-6 are judged on line 1 only (kept as before:
// the wrapper writes an empty line 2 when the fingerprint fails); continuing-1/5 and fallback-3
// must also be pinned to the current review-scope fingerprint, else reason "stale-evidence".
function reviewRecoveryEvidence(sessionId, opts = {}) {
  const fingerprint = typeof opts.fingerprint === "string" ? opts.fingerprint : "";
  const pinned = (m) => m.fp !== "" && fingerprint !== "" && m.fp === fingerprint;
  const stale = { ok: false, source: null, reason: "stale-evidence" };
  const term = readControlMarker(sessionId, TERMINAL_MARKER);
  if (term && (term.rc === "2" || term.rc === "6")) return { ok: true, source: `terminal-${term.rc}`, reason: null };
  if (term && term.rc === "3") {
    if (!pinned(term)) return stale;
    const raw = resolveFallbackRawPath(sessionId);
    const refusal = raw ? fallbackRawRefusal(raw, term.mtimeMs) : "fallback-raw-missing";
    return refusal ? { ok: false, source: null, reason: refusal } : { ok: true, source: "fallback-3", reason: null };
  }
  const cont = readControlMarker(sessionId, CONTINUING_MARKER);
  if (cont && (cont.rc === "1" || cont.rc === "5")) {
    return pinned(cont) ? { ok: true, source: `continuing-${cont.rc}`, reason: null } : stale;
  }
  return { ok: false, source: null, reason: "no-evidence" };
}

function recoveredOutcomeOf(source) {
  if (source.startsWith("continuing-")) return CLEAR_OUTCOME.RECOVERED_CONTINUING;
  if (source.startsWith("fallback-")) return CLEAR_OUTCOME.RECOVERED_FALLBACK;
  return CLEAR_OUTCOME.RECOVERED_TERMINAL;
}

function buildRecoveryEvents(origin, files, reason, ann, source) {
  const rann = (key, value, provenance) => ann(key, value, provenance, origin);
  const out = [{ kind: "step_status", step: "review_tests", status: "complete", provenance: "declared", origin }];
  for (const [key, value] of Object.entries(buildReviewScopeAnnotation(files))) out.push(rann(key, value, "observed"));
  out.push(rann("warnings_summary", null, "observed"), ...warningsAcceptedReasonEvents(reason, rann));
  if (source) out.push(rann("recovery_source", source, "observed"));
  return out;
}

// #2434 swap point: warningsAcceptedReasonEvents (record) and warningsTombstoneFields (clear)
// are the only places that know where the acceptance reason is recorded.
function warningsAcceptedReasonEvents(reason, ann) {
  return [ann("warnings_accepted_reason", reason || null, "declared")];
}

function warningsTombstoneFields() {
  return { warnings_summary: null, warnings_accepted_reason: null };
}

// WORKFLOW_REVIEW_TESTS_WARNINGS_ACCEPTED. The "anything to clear?" decision is taken
// INSIDE the lock; the clear, the reason and the current review-scope manifest (#2287)
// land in ONE batch, so a warning appended afterwards is never tombstoned.
// A write_code-reopened review_tests (#2482) is restored to complete in the same batch;
// without a manifest it stays reopened (fail-closed: the commit gate needs the manifest).
// opts.fingerprint is the current manifest's digest, computed by the caller so state-io
// never requires workflow-gate; reviewRecoveryEvidence pins the newer evidence to it.
function clearReviewTestsWarnings(sessionId, reason, manifest, opts = {}) {
  assertValidSessionId(sessionId); // explicit guard: readState's try-catch swallows errors
  if (!readState(sessionId)) return CLEAR_OUTCOME.NO_STATE; // fail-open: nothing to clear
  const files = manifestFiles(manifest);
  const origin = "clear-review-tests-warnings";
  const ann = (key, value, provenance, o = origin) => ({ kind: "step_annotation", step: "review_tests", key, value, provenance, origin: o });
  let outcome = CLEAR_OUTCOME.NOTHING_TO_CLEAR;
  events.appendEvents(sessionId, (_events, current) => {
    outcome = CLEAR_OUTCOME.NOTHING_TO_CLEAR;
    const existing = (current && current.steps && current.steps.review_tests) || {};
    if (existing.status === "pending" && REVIEW_TESTS_REOPEN_REASONS.includes(existing.reopen_reason)) {
      if (!files) {
        outcome = CLEAR_OUTCOME.MANIFEST_UNAVAILABLE;
        return [];
      }
      const out = buildRecoveryEvents("accept-reopened-review-tests", files, reason, ann);
      outcome = CLEAR_OUTCOME.RECOVERED;
      return out;
    }
    const evidence = existing.status === "in_progress"
      ? reviewRecoveryEvidence(sessionId, { fingerprint: opts && opts.fingerprint })
      : null;
    if (evidence && (evidence.ok || evidence.reason === "stale-evidence")) {
      if (!files) {
        outcome = CLEAR_OUTCOME.MANIFEST_UNAVAILABLE;
        return [];
      }
      if (!evidence.ok) {
        outcome = CLEAR_OUTCOME.STALE_EVIDENCE;
        return [];
      }
      const out = buildRecoveryEvents("accept-terminal-review-tests", files, reason, ann, evidence.source);
      outcome = recoveredOutcomeOf(evidence.source);
      return out;
    }
    if (!existing.warnings_summary) return []; // nothing to clear
    const out = [ann("warnings_summary", null, "observed"), ...warningsAcceptedReasonEvents(reason, ann)];
    if (files) {
      for (const [key, value] of Object.entries(buildReviewScopeAnnotation(files))) out.push(ann(key, value, "observed"));
    }
    outcome = CLEAR_OUTCOME.WARNINGS_CLEARED;
    return out;
  });
  return outcome;
}

// Remove the review-loop terminal marker written by run-codex-review-loop.sh
// after a non-success terminal exit (issue #1361), and the exit-1/5 continuing marker
// (#2664). Accepting the coverage gap ends the review, so the re-invoke guard must no
// longer fire and the evidence must not be reused. Fail-open.
function clearReviewTestsTerminalMarker(sessionId) {
  for (const name of [TERMINAL_MARKER, CONTINUING_MARKER]) {
    try {
      fs.unlinkSync(controlMarkerPath(sessionId, name));
    } catch (e) {
      // ENOENT (no marker) and any other failure are non-fatal.
      try { require("./control-dir").diagnoseControlMigration(e, "review-tests"); } catch (_) { /* fail-open */ }
    }
  }
}

function normalizeReopenDecision(d) {
  if (typeof d === "string") return REVIEW_TESTS_REOPEN_REASONS.includes(d) ? d : `write-code-${d}`;
  return d && d.reopen && typeof d.reason === "string" ? d.reason : null;
}

// write_code completion (#2327): record the completion-time review-scope snapshot on
// write_code and, when review_tests is complete and decide() says so, reopen it.
// Observed-evidence write outside the markStep registry (feature-1644): one builder
// under the lock; review_scope_manifest is kept so the second review can diff against it.
function recordWriteCodeCompletionScope(sessionId, snapshot, decide) {
  assertValidSessionId(sessionId);
  const snapFiles = snapshot && snapshot.ok !== false ? manifestFiles(snapshot) : null;
  const wcManifest = snapFiles ? { v: 1, files: { ...snapFiles } } : { v: 1, unavailable: true };
  const origin = "write-code-scope-drift";
  let reason = null;
  events.appendEvents(sessionId, (_events, current) => {
    reason = null;
    const out = [{ kind: "step_annotation", step: "write_code", key: "write_code_scope_manifest",
      value: wcManifest, provenance: "observed", origin }];
    const rt = (current && current.steps && current.steps.review_tests) || {};
    if (rt.status !== "complete" || typeof decide !== "function") return out;
    reason = normalizeReopenDecision(decide(rt));
    if (!reason) return out;
    out.push({ kind: "step_status", step: "review_tests", status: "pending", provenance: "observed", origin });
    out.push({ kind: "step_annotation", step: "review_tests", key: "reopen_reason", value: reason, provenance: "observed", origin });
    return out;
  });
  return { reopened: !!reason, reason };
}

module.exports = {
  REVIEW_TESTS_REOPEN_REASONS,
  CLEAR_OUTCOME,
  buildReviewScopeAnnotation,
  markReviewTestsComplete,
  clearReviewTestsWarnings,
  clearReviewTestsTerminalMarker,
  reviewRecoveryEvidence,
  resolveFallbackRawPath,
  recordWriteCodeCompletionScope,
};
