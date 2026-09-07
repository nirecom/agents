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
  buildUpstreamView,
};
