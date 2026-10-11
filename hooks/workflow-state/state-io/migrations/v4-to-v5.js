"use strict";

// Stage 5 of the state-file migration chain (#2527): a v4 stream becomes a v5
// stream. Three changes, all pure functions of the input (no env, no markers,
// no clock): workflow_type is renamed to deliverable_type; a wf-code session
// past branching records the delivery path its stream proves; and the new
// push_branch / deliver steps are backfilled when the stream proves the old
// flow already did that work. `v4State` is never mutated.

const ORIGIN = "migration-v4-to-v5";
const PUSH_EVIDENCE_STEPS = ["user_verification", "cleanup", "pre_final_report_gate", "final_report"];
const DELIVER_EVIDENCE_STEPS = ["cleanup", "pre_final_report_gate", "final_report"];

function stepEvents(events, step) {
  return events.filter((e) => e && typeof e === "object" && e.kind === "step_status" && e.step === step);
}

function lastStatusInStream(events, step) {
  const rows = stepEvents(events, step);
  return rows.length ? rows[rows.length - 1].status : null;
}

// Recorded only when branching is settled: before that the session has not yet
// chosen a path, and the live config decides it later (session-profile.js).
function deriveDeliveryPath(src) {
  const type = src.deliverable_type === undefined ? "wf-code" : src.deliverable_type;
  if (type !== "wf-code") return null;
  const bc = lastStatusInStream(src.events, "branching_complete");
  if (bc !== "complete" && bc !== "skipped") return null;
  const entered = src.events.some((e) => e && e.kind === "worktree" && e.transition === "entered");
  // A worktree entered via `cd` leaves no event; the recorded session_worktree still proves it.
  const recordedWorktree = typeof src.session_worktree === "string" && src.session_worktree !== "";
  return entered || recordedWorktree ? "pull_request" : "direct";
}

// migrateV4ToV5(v4State) -> a fresh v5 state object.
function migrateV4ToV5(v4State) {
  const src = JSON.parse(JSON.stringify(v4State));
  src.version = 5;
  if (Object.prototype.hasOwnProperty.call(src, "workflow_type")) {
    src.deliverable_type = src.workflow_type;
    delete src.workflow_type;
  }
  if (!Array.isArray(src.events)) return src;

  const path = deriveDeliveryPath(src);
  if (path) {
    src.delivery_path = path;
    src.delivery_path_origin = ORIGIN;
  }

  // Lazy require: this module loads from within core.js's own
  // normalizeStateVersion, so a top-level require could see a half-init core.js.
  const { isSettledStatus } = require("../core");
  const { projectState } = require("../projection");
  const steps = projectState(src).steps || {};
  const settled = (step) => !!(steps[step] && isSettledStatus(steps[step].status));
  const uv = steps.user_verification || {};
  const uvPending = lastStatusInStream(src.events, "user_verification") === "pending";
  const postMerge = uv.status === "pending" && uv.reset_reason === "post-merge";
  const pushed = typeof src.last_pushed_sha === "string" && src.last_pushed_sha !== "";

  const pushDone = PUSH_EVIDENCE_STEPS.some(settled) || postMerge || pushed;
  const pushedBeforeApproval = uvPending && pushed && !postMerge;
  const deliverDone = DELIVER_EVIDENCE_STEPS.some(settled) || postMerge || pushedBeforeApproval;

  const createdAt =
    typeof src.created_at === "string" && src.created_at ? src.created_at : "1970-01-01T00:00:00.000Z";
  const last = src.events[src.events.length - 1];
  let seq = last && typeof last === "object" && Number.isFinite(last.seq) ? last.seq : src.events.length;
  const at = last && typeof last === "object" && typeof last.at === "string" && last.at ? last.at : createdAt;
  const push = (ev) => {
    seq += 1;
    src.events.push(Object.assign(ev, { at, at_estimated: true, provenance: "backfilled", origin: ORIGIN, seq }));
  };
  const backfill = (step) => {
    if (stepEvents(src.events, step).length) return;
    push({ kind: "step_status", step, status: "complete" });
  };

  if (pushDone) backfill("push_branch");
  if (deliverDone) backfill("deliver");
  // An old direct-path push before approval: the reset that follows it is the
  // v5 "post-push" boundary, so record it as such for the release phase.
  if (deliverDone && pushedBeforeApproval && !DELIVER_EVIDENCE_STEPS.some(settled)) {
    push({ kind: "step_annotation", step: "user_verification", key: "reset_reason", value: "post-push" });
  }
  return src;
}

module.exports = { migrateV4ToV5 };
