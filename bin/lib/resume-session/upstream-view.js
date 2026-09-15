"use strict";
// What is still knowable about an upstream session, and how much of it may be
// adopted here (#2218 Step 5/11).
//
// The ladder exists because the three evidence stores expire independently: the
// state file has a 7-day TTL, the plan artifacts outlive it, and the transcript
// outlives both. Calling adoptState on an expired state file reports "not
// resumable", which is a lie about work that plainly happened — so each rung
// degrades with its own honest reason instead.

const fs = require("fs");
const path = require("path");
const { readState } = require("../../../hooks/workflow-state/state-io");
const { getWorkflowPlansDir } = require("../../../hooks/lib/workflow-plans-dir");
const { adoptState } = require("../../../hooks/workflow-state/inheritance/adopt");
const {
  VERDICTS,
  compareRepoIdentity,
  compareRepoContentEquivalence,
} = require("../../workflow/lib/next-step/repo-dir-guard");
const { captureTranscriptTail } = require("./transcript-fallback");
const { readHandoff, renderHandoffForResume } = require("../../../hooks/lib/handoff-artifact");

const AVAILABILITY = Object.freeze({
  STATE_AND_ARTIFACTS: "state-and-artifacts",
  STATE_ONLY: "state-only",
  ARTIFACTS_ONLY: "artifacts-only",
  NONE: "none",
});

const ARTIFACT_KINDS = Object.freeze(["intent", "outline", "detail", "handoff"]);
const GRANULARITY_FULL = "full";
const GRANULARITY_DEGRADED = "context-independent-only";

function artifactsFor(sid) {
  const dir = getWorkflowPlansDir();
  const out = {};
  for (const kind of ARTIFACT_KINDS) {
    const p = path.join(dir, `${sid}-${kind}.md`);
    let ok = false;
    try {
      ok = fs.existsSync(p);
    } catch (e) {
      ok = false;
    }
    out[kind] = ok ? p : null;
  }
  return out;
}

function cwdOf(state) {
  if (!state) return null;
  // state.cwd is the PROJECTED cwd (worktree transitions update it); the
  // session_start_context copy is the immutable start value, so it is the fallback.
  if (typeof state.cwd === "string" && state.cwd.length) return state.cwd;
  const ctx = state.session_start_context;
  if (ctx && typeof ctx.cwd === "string" && ctx.cwd.length) return ctx.cwd;
  return null;
}

function classify(state, artifacts) {
  const hasArtifact = ARTIFACT_KINDS.some((k) => artifacts[k] !== null);
  if (state && hasArtifact) return AVAILABILITY.STATE_AND_ARTIFACTS;
  if (state) return AVAILABILITY.STATE_ONLY;
  if (hasArtifact) return AVAILABILITY.ARTIFACTS_ONLY;
  return AVAILABILITY.NONE;
}

// A sibling worktree of the SAME repo whose content is provably identical is
// the one cross-worktree case where the worktree-dependent steps still hold;
// everything else degrades rather than claiming evidence it cannot see.
function decideGranularity(upstreamCwd, heirCwd) {
  const verdict = compareRepoIdentity(upstreamCwd, heirCwd);
  if (verdict === VERDICTS.SAME) {
    return { granularity: GRANULARITY_FULL, verifiedEquivalent: false, repo_verdict: verdict };
  }
  if (verdict === VERDICTS.SIBLING && compareRepoContentEquivalence(upstreamCwd, heirCwd)) {
    return { granularity: GRANULARITY_FULL, verifiedEquivalent: true, repo_verdict: verdict };
  }
  return { granularity: GRANULARITY_DEGRADED, verifiedEquivalent: false, repo_verdict: verdict };
}

// The ONE resolver for "which cwd/branch is the heir working in?" (#2279 C3).
// `--from` read state.cwd with a session_start_context fallback while `--list`
// read only the top-level field, so the two paths disagreed about the same heir.
function heirContextOf(input) {
  const opts = input || {};
  const ctx = opts.ctx;
  if (ctx && typeof ctx.cwd === "string" && ctx.cwd.length) {
    return { cwd: ctx.cwd, git_branch: ctx.git_branch ?? null };
  }
  let state = opts.heirState || null;
  if (!state && opts.heirSid) {
    try {
      state = readState(opts.heirSid);
    } catch (e) {
      state = null;
    }
  }
  const cwd = cwdOf(state);
  if (cwd === null) return null;
  const start = (state && state.session_start_context) || null;
  const branch = state && state.git_branch !== undefined && state.git_branch !== null
    ? state.git_branch
    : (start && start.git_branch) ?? null;
  return { cwd, git_branch: branch };
}

// createAdoptabilityPreviewer({heirState|heirSid|ctx}) → { heir_cwd, preview(record) }
//
// `--list` says adoptable yes/no while `--from` answers at decideGranularity's
// finer grain; the previewer runs THAT function so a listing cannot promise more
// than the adoption would hand over (#2279 CPR-E2E). Granularity is memoized per
// donor cwd because a listing evaluates many candidates against one heir.
function createAdoptabilityPreviewer(input) {
  const heirCtx = heirContextOf(input);
  const heirCwd = heirCtx && heirCtx.cwd;
  const granularityByCwd = new Map();

  function granularityFor(donorCwd) {
    const key = typeof donorCwd === "string" && donorCwd.length ? donorCwd : null;
    if (granularityByCwd.has(key)) return granularityByCwd.get(key);
    const decided = heirCwd
      ? decideGranularity(donorCwd, heirCwd).granularity
      : GRANULARITY_DEGRADED;
    granularityByCwd.set(key, decided);
    return decided;
  }

  return {
    heir_cwd: heirCwd || null,
    // A record that may not be adopted has no granularity to state — null is the
    // honest answer, never a guess the caller would have to interpret.
    preview(record) {
      const adoptable = !!record && record.adoptable === true;
      // A donor accepted only through the degradation path never travels at full
      // granularity, regardless of repo identity — mirrors adopt.js's
      // effectiveGranularity, which forces this the same way (CPR-ORTH).
      const granularity = !adoptable
        ? null
        : (record && record.resumability_degraded_reason)
          ? GRANULARITY_DEGRADED
          : granularityFor(record && record.cwd);
      return {
        adoptable,
        adoptable_reason: (record && record.adoptable_reason) || null,
        adoptable_granularity: granularity,
      };
    },
  };
}

// Single-shot wrapper for callers evaluating one record rather than a listing.
function previewAdoptability(input, record) {
  return createAdoptabilityPreviewer(input).preview(record);
}

function attemptInherit(heirSid, upstreamSid, upstreamState, heirState) {
  if (!heirSid || !heirState) {
    return { attempted: false, reason: "no-heir-state" };
  }
  const plan = decideGranularity(cwdOf(upstreamState), cwdOf(heirState));
  const r = adoptState({
    heirSid,
    donorSid: upstreamSid,
    granularity: plan.granularity,
    verifiedEquivalent: plan.verifiedEquivalent,
  });
  return {
    attempted: true,
    ok: r.ok === true,
    error: r.ok === true ? null : r.error,
    repo_verdict: plan.repo_verdict,
    verified_equivalent: plan.verifiedEquivalent,
    granularity: r.ok === true ? r.granularity : plan.granularity,
    degraded_reason: r.ok === true ? r.degraded_reason || null : null,
    inheritance: r.ok === true ? r.inheritance || null : null,
  };
}

// The handoff artifact records what the state file cannot hold; without this
// reader it would be written durably and never restored into a resumed session.
function renderedHandoffFor(upstreamSid, artifacts) {
  if (!artifacts || artifacts.handoff === null) return null;
  let rendered = "";
  try {
    rendered = renderHandoffForResume(readHandoff(upstreamSid));
  } catch (e) {
    return null;
  }
  return typeof rendered === "string" && rendered.length ? rendered : null;
}

// buildUpstreamView({ heirSid, upstreamSid }) → view | { availability: "none" }
function buildUpstreamView(input) {
  const opts = input || {};
  const upstreamSid = opts.upstreamSid;
  const heirSid = opts.heirSid || null;
  let upstreamState = null;
  try {
    upstreamState = readState(upstreamSid);
  } catch (e) {
    upstreamState = null;
  }
  const artifacts = artifactsFor(upstreamSid);
  const availability = classify(upstreamState, artifacts);
  if (availability === AVAILABILITY.NONE) {
    // The transcript is the last rung of the ladder, so this branch — state AND
    // artifacts both gone — is the one it exists for; it must not skip the field.
    return {
      type: "upstream",
      upstream_session_id: upstreamSid,
      availability,
      reason: "unknown-session",
      handoff_rendered: null,
      transcript_tail: captureTranscriptTail({ upstreamSid, cwd: cwdOf(upstreamState) }),
    };
  }

  let heirState = null;
  try {
    heirState = heirSid ? readState(heirSid) : null;
  } catch (e) {
    heirState = null;
  }

  // The state file aged out; adopting is impossible, but nothing here failed a
  // resumability judgement, so no such verdict may be reported.
  const inherit = availability === AVAILABILITY.ARTIFACTS_ONLY
    ? { attempted: false, reason: "state_expired" }
    : attemptInherit(heirSid, upstreamSid, upstreamState, heirState);

  return {
    type: "upstream",
    upstream_session_id: upstreamSid,
    availability,
    reason: availability === AVAILABILITY.STATE_ONLY ? "intent-artifact-missing" : null,
    artifacts,
    inherit_result: inherit,
    handoff_rendered: renderedHandoffFor(upstreamSid, artifacts),
    transcript_tail: captureTranscriptTail({ upstreamSid, cwd: cwdOf(upstreamState) }),
  };
}

module.exports = {
  AVAILABILITY,
  ARTIFACT_KINDS,
  decideGranularity,
  heirContextOf,
  createAdoptabilityPreviewer,
  previewAdoptability,
  buildUpstreamView,
};
