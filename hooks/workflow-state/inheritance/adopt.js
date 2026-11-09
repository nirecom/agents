"use strict";
// Explicit adoption of a prior session's state (#1305): the true-crash-resume
// case, where the process lost its session id so no lineage can prove descent.
// Two routes reach it (bin/workflow/adopt-session-state and /workflow-init's
// `adopt-prior-state` phase) but only ONE implementation, here (CPR-SSOT).

const { readState, readRawState, normalizeStateVersion, VALID_STEPS } = require("../state-io");
const { projectState } = require("../state-io/projection");
const { isEffectivelyPendingStep, LOOKAHEAD_ORIGIN } = require("../lifecycle");
const { listRecentContextCandidates } = require("./candidates");
const { applyInheritance, INHERIT_ORIGIN, GRANULARITY_CONTEXT_INDEPENDENT_ONLY, CARRIED_DOWNSTREAM_KINDS } = require("./apply");
const { abortUpstreamsFor } = require("../workflow-abort");
const { judgeInheritanceGranularity } = require("./granularity");
const repoIdentity = require("../../lib/repo-identity");

// Resumability verdicts that mean "the EVIDENCE aged out", not "this record must
// not be reused": a plan artifact past its retention leaves the session-upstream's
// work record intact. Explicit adoption degrades on these (the missing artifact
// is reported, not fatal) while `all-pending` and `delivered` — statements
// about the WORK itself — stay hard refusals.
const DEGRADABLE_RESUMABILITY_REASONS = Object.freeze(["intent-artifact-missing"]);

// Records a re-adopt may replace: where the process runs and on which model are
// re-carried by the copy, and a pending or lookahead-only mark claims no finished work.
const ENVIRONMENT_KINDS = Object.freeze(["worktree", "session_model"]);
// The copy carries the session-downstream's own state handoff records too, so they replace nothing (#2652).
const CARRIED_RECORD_KINDS = CARRIED_DOWNSTREAM_KINDS;

class AdoptionRefusedError extends Error {
  constructor(message) {
    super(message);
    this.name = "AdoptionRefusedError";
  }
}

const isPlainObject = (v) => !!v && typeof v === "object" && !Array.isArray(v);

// The context an adoption is judged against is the SESSION-DOWNSTREAM's own recorded context,
// not the process cwd: the CLI may be run from anywhere (the AD-10 recovery
// command is executed from the agents repo root), and only the session-downstream's state
// file says where its work actually lives.
function downstreamContextOf(downstreamState) {
  if (!downstreamState) return null;
  // A copied worktree event describes the session-upstream location, not where this
  // process runs: after an adoption, projected cwd counts only for a worktree event
  // the session-downstream recorded itself past the copy boundary.
  const boundary = Number(downstreamState.upstream_copy_seq) || 0;
  const ownWorktree = (Array.isArray(downstreamState.events) ? downstreamState.events : [])
    .filter((e) => e && e.kind === "worktree" && Number(e.seq) > boundary);
  // The LAST own event decides: an exit leaves the projected cwd at the last entered path.
  const lastOwn = ownWorktree.length ? ownWorktree[ownWorktree.length - 1] : null;
  const copiedCwd = !!downstreamState.upstream_session_id && !(lastOwn && lastOwn.transition === "entered");
  const startCwd = downstreamState.session_start_context && downstreamState.session_start_context.cwd;
  const cwd = !copiedCwd && typeof downstreamState.cwd === "string" && downstreamState.cwd.length
    ? downstreamState.cwd
    : startCwd || null;
  if (typeof cwd !== "string" || !cwd.length) return null;
  const git_branch = !copiedCwd && downstreamState.git_branch !== undefined && downstreamState.git_branch !== null
    ? downstreamState.git_branch
    : (downstreamState.session_start_context && downstreamState.session_start_context.git_branch) ?? null;
  return { cwd, git_branch };
}

// "Recorded work" is asked of isEffectivelyPendingStep, which folds
// isLookaheadOnlyInFlightState in: the WI-10 lookahead's own mark states that a
// TOOL CALL ran, not that the session-downstream did anything (#2279).
function isAllPending(state) {
  for (const step of VALID_STEPS) {
    if (!isEffectivelyPendingStep(state, step)) return false;
  }
  return true;
}

// A pending mark, or an in_progress one only the WI-10 lookahead wrote: neither claims work.
// A genuine in_progress mark is the session-downstream's own work and is retained.
const isUnfinishedMark = (e) =>
  e.status === "pending" || (e.status === "in_progress" && e.origin === LOOKAHEAD_ORIGIN);

// Events the session-downstream recorded itself after the copy boundary.
function retainedRecords(state) {
  const boundary = Number(state.upstream_copy_seq) || 0;
  const events = Array.isArray(state.events) ? state.events : [];
  return events
    .filter((e) => isPlainObject(e) && Number(e.seq) > boundary && e.origin !== INHERIT_ORIGIN)
    .filter((e) => ENVIRONMENT_KINDS.indexOf(e.kind) === -1 && CARRIED_RECORD_KINDS.indexOf(e.kind) === -1)
    .filter((e) => !(e.kind === "step_status" && isUnfinishedMark(e)))
    .map((e) => ({ kind: e.kind, seq: e.seq, step: e.step === undefined ? null : e.step }));
}

const allowed = () => ({ ok: true, error: null, retained: [] });
const refused = (error, retained) => ({ ok: false, error, retained: retained || [] });

// checkOverwriteAllowed(downstreamState, upstreamSid) -> { ok, error, retained }
// Overwriting is allowed only into an untouched session-downstream, or as a re-adopt from
// the SAME session-upstream that would replace nothing the session-downstream recorded itself.
// Accepts the raw on-disk record or a read/normalized one.
function checkOverwriteAllowed(downstreamState, upstreamSid) {
  if (!isPlainObject(downstreamState)) return refused("no workflow state to adopt into");
  let state;
  try {
    state = normalizeStateVersion(downstreamState);
  } catch (e) {
    return refused(`the session-downstream state is unreadable (${(e && e.message) || String(e)})`);
  }
  const sid = state.session_id || "this session";
  const linked = typeof state.upstream_session_id === "string" && state.upstream_session_id.length
    ? state.upstream_session_id
    : null;
  if (linked === null) {
    const view = isPlainObject(state.steps) ? state : Object.assign({}, state, projectState(state));
    const ownApprovals = (Array.isArray(state.events) ? state.events : []).some((e) => e && e.kind === "plan_approval");
    if (isAllPending(view) && !ownApprovals) return allowed();
    return refused(`session-downstream ${sid} has already recorded workflow steps; ` +
      "adoption only applies to an untouched session — start a new session to adopt");
  }
  if (linked !== upstreamSid) {
    return refused(`session-downstream ${sid} was already adopted from a different session-upstream (${linked}); ` +
      `start a new session to adopt from ${upstreamSid}`);
  }
  const retained = retainedRecords(state);
  if (retained.length === 0) return allowed();
  const shown = retained.slice(0, 5).map((r) => `${r.kind} (seq ${r.seq})`).join(", ");
  const more = retained.length > 5 ? ` and ${retained.length - 5} more` : "";
  return refused(`session-downstream ${sid} recorded its own work after adopting from ${upstreamSid}: ` +
    `${shown}${more}; re-adopting would overwrite it — start a new session to adopt again`, retained);
}

// listAdoptCandidates(downstreamSid) → { ok, error, ctx, candidates }
function listAdoptCandidates(downstreamSid, fallbackCtx) {
  const downstreamState = downstreamSid ? readState(downstreamSid) : null;
  const ctx = downstreamContextOf(downstreamState) || fallbackCtx || null;
  if (!ctx) return { ok: false, error: "cannot resolve this session's cwd/branch context", ctx: null, candidates: [] };
  let candidates = [];
  try {
    candidates = listRecentContextCandidates(ctx) || [];
  } catch (e) {
    candidates = [];
  }
  // Never offer the session-downstream its own state file.
  candidates = candidates.filter((c) => c.sessionId !== downstreamSid);
  return { ok: true, error: null, ctx, candidates };
}

function readRawOrNull(sid) {
  try {
    return readRawState(sid);
  } catch (e) {
    return null;
  }
}

// adoptState({ downstreamSid, upstreamSid }) → { ok: true, ... } | { ok: false, error }
//
// Being named on a command line is not evidence: overwrite protection and
// resumability are re-checked here, and the granularity is decided from where
// the session-downstream runs. `downstreamSid` is caller-supplied and NOT bound to the invoking
// process, so the blast radius is bounded by checkOverwriteAllowed — reading
// files the same local user can already open. Local admin tool, not a service.
function adoptState(opts) {
  const downstreamSid = opts && opts.downstreamSid;
  const upstreamSid = opts && opts.upstreamSid;
  if (!downstreamSid) return { ok: false, error: "no session-downstream id resolved" };
  if (!upstreamSid) return { ok: false, error: "no session-upstream id given (--from)" };
  if (downstreamSid === upstreamSid) return { ok: false, error: "a session cannot adopt from itself" };

  const downstreamState = readState(downstreamSid);
  if (!downstreamState) return { ok: false, error: `no workflow state file for session-downstream ${downstreamSid}` };
  const before = checkOverwriteAllowed(readRawOrNull(downstreamSid), upstreamSid);
  if (!before.ok) return { ok: false, error: before.error };

  let upstreamState = readState(upstreamSid);
  if (!upstreamState) return { ok: false, error: `no workflow state file for session-upstream ${upstreamSid}` };
  if (upstreamState.session_id !== upstreamSid) {
    upstreamState = Object.assign({}, upstreamState, { session_id: upstreamSid });
  }

  const { evaluateResumability } = require("../effective-state");
  const verdict = evaluateResumability(upstreamState);
  const degradedReason = verdict && !verdict.eligible
    && DEGRADABLE_RESUMABILITY_REASONS.indexOf(verdict.reason) !== -1
    ? verdict.reason
    : null;
  if ((!verdict || !verdict.eligible) && degradedReason === null) {
    return {
      ok: false,
      error: `session-upstream ${upstreamSid} is not resumable ` +
        `(${(verdict && verdict.reason) || "unknown"})`,
    };
  }

  const downstreamCtx = downstreamContextOf(downstreamState);
  const judged = judgeInheritanceGranularity(downstreamCtx && downstreamCtx.cwd, upstreamState, repoIdentity);
  // Evidence accepted only through the degradation path is unproven, so it never
  // travels at full granularity wherever the session-downstream runs.
  const granularity = degradedReason !== null ? GRANULARITY_CONTEXT_INDEPENDENT_ONLY : judged.granularity;

  let result;
  try {
    result = applyInheritance(downstreamSid, downstreamState.created_at, upstreamSid, {
      granularity,
      // Re-checked under the lock: a record landing between the two reads must still refuse.
      precheck: (precheckDownstreamState) => {
        const v = checkOverwriteAllowed(precheckDownstreamState, upstreamSid);
        if (!v.ok) throw new AdoptionRefusedError(v.error);
      },
    });
  } catch (e) {
    if (e instanceof AdoptionRefusedError) return { ok: false, error: e.message };
    return { ok: false, error: `adoption failed: ${(e && e.message) || String(e)}` };
  }
  return {
    ok: true,
    error: null,
    upstreamSessionId: upstreamSid,
    granularity,
    repo_verdict: judged.repo_verdict,
    degraded_reason: degradedReason,
    inheritance: result || null,
    session_upstream_aborts: abortAdoptedUpstreams(downstreamSid),
  };
}

// The session-downstream now owns the work, so every live session-upstream in its chain is aborted and every
// abort-sentinel-aborted one is handed over to it (#2920 S8-(1)).
// A failure is reported per session-upstream and never undoes the adoption.
function abortAdoptedUpstreams(downstreamSid) {
  try {
    return abortUpstreamsFor(downstreamSid, "adopt-auto", `adopted by ${downstreamSid}`);
  } catch (e) {
    return [{ sid: null, recorded: false, reason: `select failed: ${(e && e.message) || String(e)}` }];
  }
}

module.exports = {
  adoptState, checkOverwriteAllowed, listAdoptCandidates, downstreamContextOf, isAllPending, CARRIED_RECORD_KINDS,
};
