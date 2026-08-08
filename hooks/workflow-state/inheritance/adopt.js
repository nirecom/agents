"use strict";
// Explicit adoption of a prior session's state (#1305).
//
// WHY this module exists: automatic inheritance is now keyed on lineage, and a
// TRUE crash-resume has no lineage — the process died and came back without its
// session id, so nothing in the new transcript can prove descent. That case is
// served by an explicit, user-approved adoption instead.
//
// There are two ROUTES to it (bin/workflow/adopt-session-state and the
// /workflow-init `adopt-prior-state` phase) but only ONE implementation, here:
// both must re-run the same guards and append the same event stream, which is
// only guaranteed by a single execution point (CPR-SSOT).

const { readState, VALID_STEPS } = require("../state-io");
const { contextMatches } = require("./context-match");
const { listRecentContextCandidates } = require("./candidates");
const { applyInheritance } = require("./apply");

// The context an adoption is judged against is the HEIR's own recorded context,
// not the process cwd: the CLI may be run from anywhere (the AD-10 recovery
// command is executed from the agents repo root), and only the heir's state
// file says where its work actually lives.
function heirContextOf(heirState) {
  if (!heirState) return null;
  const cwd = typeof heirState.cwd === "string"
    ? heirState.cwd
    : (heirState.session_start_context && heirState.session_start_context.cwd) || null;
  if (typeof cwd !== "string") return null;
  const git_branch = heirState.git_branch !== undefined && heirState.git_branch !== null
    ? heirState.git_branch
    : (heirState.session_start_context && heirState.session_start_context.git_branch) ?? null;
  return { cwd, git_branch };
}

// An heir that has already recorded work is NOT a crash-resume shell: adopting
// into it would bulldoze real progress with a foreign session's record.
function isAllPending(state) {
  const steps = (state && state.steps) || {};
  for (const step of VALID_STEPS) {
    const entry = steps[step];
    if (entry && entry.status && entry.status !== "pending") return false;
  }
  return true;
}

// listAdoptCandidates(heirSid) → { ok, error, ctx, candidates }
function listAdoptCandidates(heirSid, fallbackCtx) {
  const heirState = heirSid ? readState(heirSid) : null;
  const ctx = heirContextOf(heirState) || fallbackCtx || null;
  if (!ctx) return { ok: false, error: "cannot resolve this session's cwd/branch context", ctx: null, candidates: [] };
  let candidates = [];
  try {
    candidates = listRecentContextCandidates(ctx) || [];
  } catch (e) {
    candidates = [];
  }
  // Never offer the heir its own state file.
  candidates = candidates.filter((c) => c.sessionId !== heirSid);
  return { ok: true, error: null, ctx, candidates };
}

// adoptState({ heirSid, donorSid }) → { ok: true } | { ok: false, error }
//
// Every guard the automatic path applies is re-run here. Being named on a
// command line is not evidence: without this re-validation the CLI would be a
// way to launder exactly the mis-inheritance #1305 removed.
//
// Authorization model: `heirSid` is caller-supplied (CLI --session / phase arg),
// not bound to the OS process invoking this call — the crash-resume case this
// exists for is exactly a session that lost its own id and cannot self-assert
// it. The blast radius that leaves open (an operator naming a DIFFERENT live
// session's sid) is bounded by two independent guards below, both mandatory:
// isAllPending(heirState) (refuses to touch a heir with any recorded step) and
// contextMatches (refuses a donor from a different cwd/branch). Both guards
// operate on state files the same local user already has direct filesystem
// access to, so this CLI grants no capability beyond what that user already
// has — it is a local admin tool, not a service boundary.
function adoptState(opts) {
  const heirSid = opts && opts.heirSid;
  const donorSid = opts && opts.donorSid;
  if (!heirSid) return { ok: false, error: "no heir session id resolved" };
  if (!donorSid) return { ok: false, error: "no donor session id given (--from)" };
  if (heirSid === donorSid) return { ok: false, error: "a session cannot adopt from itself" };

  const heirState = readState(heirSid);
  if (!heirState) return { ok: false, error: `no workflow state file for heir session ${heirSid}` };
  if (!isAllPending(heirState)) {
    return {
      ok: false,
      error: `heir session ${heirSid} has already recorded workflow steps; ` +
        `adoption only applies to an untouched session`,
    };
  }

  let donorState = readState(donorSid);
  if (!donorState) return { ok: false, error: `no workflow state file for donor session ${donorSid}` };
  if (donorState.session_id !== donorSid) {
    donorState = Object.assign({}, donorState, { session_id: donorSid });
  }

  const ctx = heirContextOf(heirState);
  if (!ctx) return { ok: false, error: `heir session ${heirSid} records no cwd/branch context` };
  if (!contextMatches(ctx, donorState)) {
    return {
      ok: false,
      error: `donor session ${donorSid} ran in a different cwd/branch than ${heirSid} (context-mismatch)`,
    };
  }

  const { evaluateResumability } = require("../effective-state");
  const verdict = evaluateResumability(donorState);
  if (!verdict || !verdict.eligible) {
    return {
      ok: false,
      error: `donor session ${donorSid} is not resumable ` +
        `(${(verdict && verdict.reason) || "unknown"})`,
    };
  }

  try {
    applyInheritance(heirSid, heirState.created_at, donorState);
  } catch (e) {
    return { ok: false, error: `adoption failed: ${(e && e.message) || String(e)}` };
  }
  return { ok: true, error: null, donorSessionId: donorSid };
}

module.exports = { adoptState, listAdoptCandidates, heirContextOf, isAllPending };
