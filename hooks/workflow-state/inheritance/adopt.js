"use strict";
// Explicit adoption of a prior session's state (#1305): the true-crash-resume
// case, where the process lost its session id so no lineage can prove descent.
// Two routes reach it (bin/workflow/adopt-session-state and /workflow-init's
// `adopt-prior-state` phase) but only ONE implementation, here (CPR-SSOT).

const { readState, VALID_STEPS } = require("../state-io");
const { contextMatches } = require("./context-match");
const { listRecentContextCandidates } = require("./candidates");
const { applyInheritance } = require("./apply");
const {
  compareRepoContentEquivalence,
  compareRepoIdentity,
  VERDICTS,
} = require("../../../bin/workflow/lib/next-step/repo-dir-guard");

const GRANULARITY_CONTEXT_INDEPENDENT_ONLY = "context-independent-only";

// Resumability verdicts that mean "the EVIDENCE aged out", not "this record must
// not be reused": a plan artifact past the 7-day retention leaves the donor's
// work record intact. Explicit adoption degrades on these (the missing artifact
// is reported, not fatal) while `all-pending` and `user-verified` — statements
// about the WORK itself — stay hard refusals.
const DEGRADABLE_RESUMABILITY_REASONS = Object.freeze(["intent-artifact-missing"]);

// The context an adoption is judged against is the HEIR's own recorded context,
// not the process cwd: the CLI may be run from anywhere (the AD-10 recovery
// command is executed from the agents repo root), and only the heir's state
// file says where its work actually lives.
function heirContextOf(heirState) {
  if (!heirState) return null;
  const cwd = typeof heirState.cwd === "string" && heirState.cwd.length
    ? heirState.cwd
    : (heirState.session_start_context && heirState.session_start_context.cwd) || null;
  if (typeof cwd !== "string" || !cwd.length) return null;
  const git_branch = heirState.git_branch !== undefined && heirState.git_branch !== null
    ? heirState.git_branch
    : (heirState.session_start_context && heirState.session_start_context.git_branch) ?? null;
  return { cwd, git_branch };
}

// A `--verified-equivalent` claim is an unproven assertion until this runs: it
// re-derives the equivalence itself, so an assertion about two unrelated repos
// cannot launder state. heirContextOf's cwd extraction is state-shape-agnostic
// despite its name, so the donor state passes through it too.
function verifyEquivalence(heirCwd, donorState) {
  const donorCtx = heirContextOf(donorState);
  const donorCwd = donorCtx && donorCtx.cwd;
  if (typeof heirCwd !== "string" || !heirCwd.length) return false;
  if (typeof donorCwd !== "string" || !donorCwd.length) return false;
  // Identity precondition, as at the other call site (resume-session's upstream
  // view): content equivalence answers "same bytes", never "same repository", so
  // without this two UNRELATED checkouts holding matching content would waive
  // the gate. false here means "identity precondition failed", not a diff.
  if (compareRepoIdentity(heirCwd, donorCwd) !== VERDICTS.SIBLING) return false;
  return compareRepoContentEquivalence(heirCwd, donorCwd) === true;
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

// adoptState({ heirSid, donorSid, granularity, verifiedEquivalent })
//   → { ok: true, ... } | { ok: false, error }
//
// Every guard the automatic path applies is re-run here: being named on a
// command line is not evidence. `heirSid` is caller-supplied and NOT bound to
// the invoking process (a session that lost its id cannot self-assert it), so
// the blast radius is bounded by isAllPending and the context gate — both
// reading files the same local user can already open. Local admin tool, not a
// service boundary.
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

  const granularity = opts && opts.granularity === GRANULARITY_CONTEXT_INDEPENDENT_ONLY
    ? GRANULARITY_CONTEXT_INDEPENDENT_ONLY
    : "full";
  const ctx = heirContextOf(heirState);
  if (!ctx) return { ok: false, error: `heir session ${heirSid} records no cwd/branch context` };

  // contextMatches is the ONE gate granularity relaxes — nothing worktree-bound
  // travels in the degraded mode. `verifiedEquivalent` claims the two checkouts
  // hold the same content, but the flag is a bare caller assertion (a human
  // types it on the CLI), so it is re-PROVED here rather than trusted.
  // isAllPending and evaluateResumability stay armed in both modes.
  const contextGateWaived = granularity === GRANULARITY_CONTEXT_INDEPENDENT_ONLY
    || (opts && opts.verifiedEquivalent === true && verifyEquivalence(ctx.cwd, donorState));

  if (!contextGateWaived && !contextMatches(ctx, donorState)) {
    return {
      ok: false,
      error: `donor session ${donorSid} ran in a different cwd/branch than ${heirSid} (context-mismatch)`,
    };
  }

  const { evaluateResumability } = require("../effective-state");
  const verdict = evaluateResumability(donorState);
  const degradedReason = verdict && !verdict.eligible
    && DEGRADABLE_RESUMABILITY_REASONS.indexOf(verdict.reason) !== -1
    ? verdict.reason
    : null;
  if ((!verdict || !verdict.eligible) && degradedReason === null) {
    return {
      ok: false,
      error: `donor session ${donorSid} is not resumable ` +
        `(${(verdict && verdict.reason) || "unknown"})`,
    };
  }

  // A donor accepted only through the degradation path has UNPROVEN evidence, so
  // it may not travel at full granularity however the caller asked. The raw
  // `granularity` still owns the contextGateWaived decision above — that gate was
  // settled before this verdict existed.
  const effectiveGranularity = degradedReason !== null ? GRANULARITY_CONTEXT_INDEPENDENT_ONLY : granularity;

  let result;
  try {
    result = applyInheritance(heirSid, heirState.created_at, donorState, {
      granularity: effectiveGranularity,
    });
  } catch (e) {
    return { ok: false, error: `adoption failed: ${(e && e.message) || String(e)}` };
  }
  return {
    ok: true,
    error: null,
    donorSessionId: donorSid,
    granularity: effectiveGranularity,
    degraded_reason: degradedReason,
    inheritance: result || null,
  };
}

module.exports = { adoptState, listAdoptCandidates, heirContextOf, isAllPending };
