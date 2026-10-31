"use strict";
// The ONE execution point for carrying a session-upstream's work record into the
// session-downstream (#1305, #2304). Two entry points use it — the automatic lineage
// path in the SessionStart hook and the explicit bin/workflow/adopt-session-state CLI
// — so both produce byte-identical state only because there is one implementation.
//
// Since #2304 the downstream receives a VERBATIM copy of the upstream state (events
// keep their seq/at/origin/provenance; only session_id and created_at change), bounded
// by `upstream_copy_seq`. What must not travel is then reverted by events appended
// AFTER that boundary, and the whole result is written exactly once.

const core = require("../state-io/core");
const { withStateLock } = require("../state-io/state-lock");
const { assertStreamIntegrity, projectState } = require("../state-io/projection");
const { composeAppendedState } = require("../state-io/events");
const { isContextIndependentStep } = require("../state-io/step-context-class");
const CA = require("../completion-approval");
const { rowFor } = require("../plan-stage-table");
const { stateAncestors, dedupKeepFirst, resolveFirstSid } = require("../state-ancestry");

const INHERIT_ORIGIN = "session-inherit";

const GRANULARITY_FULL = "full";
const GRANULARITY_CONTEXT_INDEPENDENT_ONLY = "context-independent-only";

class UpstreamStateUnavailableError extends Error {
  constructor(message) {
    super(message);
    this.name = "UpstreamStateUnavailableError";
  }
}

const isPlainObject = (v) => !!v && typeof v === "object" && !Array.isArray(v);
const statusOf = (projection, step) => {
  const entry = projection && projection.steps && projection.steps[step];
  return (entry && entry.status) || "pending";
};

// Read the upstream state for copying. Missing, unparseable or seq-broken input throws:
// a copy of a stream that could not have come from appendEvents would be a lie.
function readUpstreamForCopy(upstreamSid) {
  const raw = core.readRawState(upstreamSid);
  if (!isPlainObject(raw)) {
    throw new UpstreamStateUnavailableError(`no state file for session upstream ${upstreamSid}`);
  }
  const state = JSON.parse(JSON.stringify(core.normalizeStateVersion(raw)));
  state.events = Array.isArray(state.events) ? state.events : [];
  assertStreamIntegrity(state.events);
  return state;
}

function lastOfKind(events, kind) {
  for (let i = events.length - 1; i >= 0; i--) {
    if (events[i] && events[i].kind === kind) return events[i];
  }
  return null;
}

// A state handoff record belongs to the generation that wrote it: the upstream's stay in the
// upstream's file (the reader finds them there), the downstream's own travel with it (#2652).
const GENERATION_LOCAL_KINDS = Object.freeze(["state_handoff_record"]);

function excludeGenerationLocalKinds(events) {
  return events.filter((e) => !(e && GENERATION_LOCAL_KINDS.includes(e.kind)));
}

// Steps (3)-(6) of the copy: identity, boundary, and the downstream's own location facts.
function buildCopy(downstreamSid, createdAt, upstreamSid, upstream, downstream) {
  const clone = upstream;
  // Read before upstream_session_id is overwritten below: clone IS the upstream object.
  const firstSid = resolveFirstSid(upstreamSid, upstream);
  clone.previous_session_ids = dedupKeepFirst([...stateAncestors(upstream), upstreamSid]);
  clone.first_session_id = firstSid;
  clone.session_id = downstreamSid;
  clone.created_at = createdAt;
  clone.upstream_session_id = upstreamSid;
  // Events at or below an earlier adoption's boundary are that upstream's copy, not the downstream's own.
  const downBoundary = downstream && downstream.upstream_session_id ? Number(downstream.upstream_copy_seq) || 0 : 0;
  const downEvents = (downstream && Array.isArray(downstream.events) ? downstream.events : [])
    .filter((e) => e && Number(e.seq) > downBoundary);
  const downOwn = {};
  for (const kind of ["worktree", "session_model"]) downOwn[kind] = lastOfKind(downEvents, kind);

  const downRecords = downEvents.filter((e) => GENERATION_LOCAL_KINDS.includes(e.kind));

  // Renumbered below to 1..n, so the boundary is the filtered count.
  clone.events = excludeGenerationLocalKinds(clone.events);
  clone.upstream_copy_seq = clone.events.length;

  const downCtx = downstream && downstream.session_start_context;
  if (isPlainObject(downCtx) && JSON.stringify(downCtx) !== JSON.stringify(clone.session_start_context)) {
    clone.session_start_context = JSON.parse(JSON.stringify(downCtx));
  }

  // Where this process runs and on which model are downstream facts; dropping them
  // in the copy would make state.cwd / session_model describe the upstream.
  for (const kind of ["worktree", "session_model"]) {
    const ev = downOwn[kind];
    if (ev) clone.events.push(JSON.parse(JSON.stringify(ev)));
  }
  for (const ev of downRecords) clone.events.push(JSON.parse(JSON.stringify(ev)));
  clone.events.forEach((e, i) => { e.seq = i + 1; });
  return clone;
}

// The revert batch, evaluated against the copy inside composeAppendedState.
// Returns { events, reverted } — `reverted` is the reverted_steps contract.
function planReverts(downstreamSid, copy, projection, degraded) {
  const { VALID_STEPS } = core;
  const reverted = [];
  // The copy carries upstream_session_id and events, which a bare projection lacks;
  // the evaluator needs both to resolve whose plan artifact a record points at.
  const evalState = Object.assign({}, copy, projection);

  // #2633-1: the first gated step whose approval no longer verifies, plus every later
  // non-pending step (cleanup included), goes back to pending.
  for (const step of CA.APPROVAL_GATED_STEPS) {
    if (statusOf(projection, step) !== "complete") continue;
    const verdict = CA.evaluateCompletionApproval(downstreamSid, step, evalState);
    if (verdict.approved) continue;
    reverted.push({ step, cause: "approval", code: verdict.code, trigger: step });
    for (const later of VALID_STEPS.slice(VALID_STEPS.indexOf(step) + 1)) {
      if (statusOf(projection, later) === "pending") continue;
      reverted.push({ step: later, cause: "approval", code: "follows-reverted-step", trigger: step });
    }
    break;
  }
  const approvalRevert = reverted.length > 0;

  if (degraded) {
    const done = new Set(reverted.map((r) => r.step));
    for (const step of VALID_STEPS) {
      if (done.has(step) || isContextIndependentStep(step)) continue;
      if (statusOf(projection, step) === "pending") continue;
      reverted.push({ step, cause: "context", code: "worktree-dependent", trigger: null });
    }
  }

  const stamp = (event) => Object.assign(event, { provenance: "backfilled", origin: INHERIT_ORIGIN });
  const events = [];
  for (const r of reverted) {
    const reason = r.cause === "context"
      ? "context:worktree-dependent"
      : r.step === r.trigger ? `approval:${r.code}` : `approval:follows:${r.trigger}`;
    events.push(stamp({ kind: "step_annotations_cleared", step: r.step }));
    events.push(stamp({ kind: "step_status", step: r.step, status: "pending" }));
    events.push(stamp({ kind: "step_annotation", step: r.step, key: "inherit_revert_reason", value: reason }));
  }

  // #772: cleanup never inherits as already done. Not when degraded (the downstream's
  // own worktree still needs tearing down) and not after an approval revert (the
  // downstream redoes the work, then runs its own cleanup).
  if (!degraded && !approvalRevert) {
    events.push(stamp({ kind: "step_annotations_cleared", step: "cleanup" }));
    events.push(stamp({ kind: "step_status", step: "cleanup", status: "skipped" }));
    events.push(stamp({
      kind: "step_annotation", step: "cleanup", key: "skip_reason", value: "inherited-from-prior-session",
    }));
  }
  return { events, reverted };
}

// applyInheritance(downstreamSid, createdAt, upstreamSid, opts) ->
//   { upstream_session_id, granularity, inherited_steps, reverted_steps, supervisor_state }.
// opts.granularity: "full" (default) | "context-independent-only".
// opts.precheck(downstreamState): optional; throwing refuses before anything is read upstream.
// Throws (writing nothing) when the upstream state is missing or corrupt.
function applyInheritance(downstreamSid, createdAt, upstreamSid, opts) {
  const o = opts || {};
  const granularity = o.granularity === GRANULARITY_CONTEXT_INDEPENDENT_ONLY
    ? GRANULARITY_CONTEXT_INDEPENDENT_ONLY
    : GRANULARITY_FULL;
  const degraded = granularity === GRANULARITY_CONTEXT_INDEPENDENT_ONLY;
  let reverted = [];

  const written = withStateLock(downstreamSid, () => {
    const downRaw = core.readRawState(downstreamSid);
    const downstream = isPlainObject(downRaw) ? core.normalizeStateVersion(downRaw) : null;
    if (typeof o.precheck === "function") o.precheck(downstream);

    const upstream = readUpstreamForCopy(upstreamSid);
    const copy = buildCopy(downstreamSid, createdAt, upstreamSid, upstream, downstream);

    const { state: next } = composeAppendedState(downstreamSid, copy, (_events, projection) => {
      const planned = planReverts(downstreamSid, copy, projection, degraded);
      reverted = planned.reverted;
      return planned.events;
    }, { origin: INHERIT_ORIGIN, provenance: "backfilled", now: createdAt });

    // The single write: the downstream is either untouched or fully copied-and-reverted.
    core.writeStateLocked(downstreamSid, next);
    return next;
  });

  const projection = projectState(written);
  const inherited = core.VALID_STEPS.filter((s) => s !== "cleanup" && statusOf(projection, s) !== "pending");

  // A separate file, copied only after the workflow state landed; a failure here is
  // reported, never fatal — the downstream merely starts without the audit record.
  let supervisorState = "failed";
  try {
    supervisorState = require("../../lib/supervisor-state-writer/copy").copySupervisorState(upstreamSid, downstreamSid);
  } catch (_) {
    supervisorState = "failed";
  }

  return {
    upstream_session_id: upstreamSid,
    granularity,
    inherited_steps: inherited,
    reverted_steps: reverted,
    supervisor_state: supervisorState,
  };
}

function planPathHint(upstreamSid, step) {
  const row = rowFor(step);
  const suffix = row ? row.suffix : step;
  try {
    if (upstreamSid) {
      return require("../plan-artifact-owner").resolvePlanArtifactOwner(upstreamSid, suffix).path;
    }
  } catch (_) { /* fall through to the generic name */ }
  return `the ${suffix} plan`;
}

// The ONE renderer adopt-session-state and /resume-session print from, so the two
// can never describe the same inheritance differently.
function describeGranularInheritance(result) {
  const granularity = (result && result.granularity) || GRANULARITY_FULL;
  const inherited = (result && result.inherited_steps) || [];
  const reverted = ((result && result.reverted_steps) || []).filter(isPlainObject);
  const upstreamSid = (result && result.upstream_session_id) || null;
  const parts = [`Inherited ${inherited.length} step(s) at granularity ${granularity}: ` +
    `${inherited.length ? inherited.join(", ") : "(none)"}.`];

  const approval = reverted.filter((r) => r.cause === "approval");
  const context = reverted.filter((r) => r.cause === "context");
  if (approval.length === 0 && context.length === 0) {
    parts.push("Nothing was held back — the session upstream record carried over whole.");
    return parts.join(" ");
  }

  const triggers = approval.filter((r) => r.step === r.trigger);
  for (const t of triggers) {
    const followers = approval.filter((r) => r.trigger === t.step && r.step !== t.step).map((r) => r.step);
    let line = "Reverted to pending because the session upstream approval no longer verifies: " +
      `${t.step} (${t.code})`;
    if (t.code === "artifact-hash-unverifiable") {
      line += " (the session upstream plan file is missing or unreadable — it may have aged out of retention)";
    }
    if (followers.length) line += `; also reset: ${followers.join(", ")}`;
    line += `. Re-present ${planPathHint(upstreamSid, t.step)} and re-approve with ` +
      `<<${CA.confirmSentinelFor(t.step)}: {summary}>>.`;
    parts.push(line);
  }
  if (context.length) {
    parts.push("Left pending in this worktree because their evidence does not travel: " +
      `${context.map((r) => r.step).join(", ")}.`);
  }
  return parts.join(" ");
}

module.exports = {
  INHERIT_ORIGIN,
  GRANULARITY_FULL,
  GRANULARITY_CONTEXT_INDEPENDENT_ONLY,
  UpstreamStateUnavailableError,
  applyInheritance,
  describeGranularInheritance,
};
