"use strict";
// What is still knowable about an upstream session, and how much of it may be
// adopted here (#2218 Step 5/11).
//
// The ladder exists because the three evidence stores expire independently: the
// state file has a 7-day TTL, the plan artifacts outlive it, and the transcript
// outlives both. Calling adoptState on an expired state file reports "not
// resumable", which is a lie about work that plainly happened — so each rung
// degrades with its own honest reason instead.

const { readState, readRawState, SESSION_ID_VALID_RE } = require("../../../hooks/workflow-state/state-io");
const { resolvePlanArtifactOwner } = require("../../../hooks/workflow-state/plan-artifact-owner");
const { adoptState, checkOverwriteAllowed, heirContextOf: adoptHeirContextOf } =require("../../../hooks/workflow-state/inheritance/adopt");
const { judgeInheritanceGranularity } = require("../../../hooks/workflow-state/inheritance/granularity");
// Per call, so a swapped owner cache entry is honored.
const repoIdentity = () => require("../../../hooks/lib/repo-identity");
const { captureTranscriptTail } = require("./transcript-fallback");
const { findHandoffPath, readHandoff, renderHandoffForResume } = require("../../../hooks/lib/handoff-artifact");
const { progressPathFor, isRegularFile } = require("../../../hooks/lib/progress-file");

const PROGRESS_FIRST_SECTION = "Current state";

const AVAILABILITY = Object.freeze({
  STATE_AND_ARTIFACTS: "state-and-artifacts",
  STATE_ONLY: "state-only",
  ARTIFACTS_ONLY: "artifacts-only",
  NONE: "none",
});

const ARTIFACT_KINDS = Object.freeze(["intent", "outline", "detail", "handoff"]);
const GRANULARITY_DEGRADED = "context-independent-only";

function isValidSid(sid) {
  return typeof sid === "string" && SESSION_ID_VALID_RE.test(sid);
}

// The plan the upstream's session chain reads: <first_session_id>-<kind>.md (#2748), when present.
function existingPlansArtifact(sid, kind) {
  try {
    const owner = resolvePlanArtifactOwner(sid, kind);
    return owner.exists ? owner.path : null;
  } catch (e) {
    return null;
  }
}

// Each kind has exactly one resolver: plan artifacts live in the plans dir, the
// handoff where its writer puts it (the control dir, #2576).
const ARTIFACT_RESOLVERS = Object.freeze({
  intent: (sid) => existingPlansArtifact(sid, "intent"),
  outline: (sid) => existingPlansArtifact(sid, "outline"),
  detail: (sid) => existingPlansArtifact(sid, "detail"),
  handoff: (sid) => findHandoffPath(sid),
});

function artifactsFor(sid) {
  const valid = isValidSid(sid);
  const out = {};
  for (const kind of ARTIFACT_KINDS) out[kind] = valid ? ARTIFACT_RESOLVERS[kind](sid) : null;
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

// Cwd-pair form of judgeInheritanceGranularity (#2297): only the same checkout
// keeps full; a sibling worktree degrades even with identical content.
function decideGranularity(upstreamCwd, heirCwd) {
  return judgeInheritanceGranularity(heirCwd, { cwd: upstreamCwd }, repoIdentity());
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
  // adopt.js owns the state-derived context (it discounts copied worktree events), so
  // the listing judges the heir exactly as `--from` does.
  return state ? adoptHeirContextOf(state) : null;
}

// createAdoptabilityPreviewer({heirState|heirSid|ctx}) → { heir_cwd, preview(record) }
//
// The previewer runs the SAME two judgements adoptState runs — checkOverwriteAllowed
// and judgeInheritanceGranularity — so a listing cannot promise more than `--from`
// would hand over (#2279 CPR-E2E, #2297). Granularity is memoized per upstream sid
// because a listing evaluates many candidates against one heir.
function createAdoptabilityPreviewer(input) {
  const opts = input || {};
  const heirCtx = heirContextOf(opts);
  const heirCwd = heirCtx && heirCtx.cwd;
  let heirRecord = opts.heirState || null;
  if (!heirRecord && opts.heirSid) {
    try {
      heirRecord = readRawState(opts.heirSid);
    } catch (e) {
      heirRecord = null;
    }
  }
  const granularityBySid = new Map();

  function granularityFor(record) {
    const key = record.sid || null;
    if (key !== null && granularityBySid.has(key)) return granularityBySid.get(key);
    let upstream = null;
    try {
      upstream = key ? readState(key) : null;
    } catch (e) {
      upstream = null;
    }
    const decided = judgeInheritanceGranularity(heirCwd, upstream || { cwd: record.cwd || null }, repoIdentity()).granularity;
    if (key !== null) granularityBySid.set(key, decided);
    return decided;
  }

  return {
    heir_cwd: heirCwd || null,
    // A record that may not be adopted has no granularity to state — null is the
    // honest answer, never a guess the caller would have to interpret.
    preview(record) {
      let adoptable = !!record && record.adoptable === true;
      let reason = (record && record.adoptable_reason) || null;
      // No heir record to judge (a ctx-only listing) leaves overwrite protection to `--from`.
      if (adoptable && heirRecord) {
        const ow = checkOverwriteAllowed(heirRecord, record.sid);
        if (!ow.ok) {
          adoptable = false;
          reason = ow.error;
        }
      }
      // Evidence accepted only through the degradation path never travels at full
      // granularity — mirrors adoptState, which forces this the same way (CPR-ORTH).
      const granularity = !adoptable
        ? null
        : record.resumability_degraded_reason
          ? GRANULARITY_DEGRADED
          : granularityFor(record);
      return { adoptable, adoptable_reason: reason, adoptable_granularity: granularity };
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
  const r = adoptState({ heirSid, donorSid: upstreamSid });
  const plan = r.ok === true ? null : decideGranularity(cwdOf(upstreamState), (adoptHeirContextOf(heirState) || {}).cwd);
  return {
    attempted: true,
    ok: r.ok === true,
    error: r.ok === true ? null : r.error,
    repo_verdict: r.ok === true ? r.repo_verdict : plan.repo_verdict,
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

// session-progress.md of the upstream's first generation (#2594): the path and the section a resumed
// session reads first. Absent file → no field, so a caller never points at nothing.
function progressFileFor(upstreamSid) {
  try {
    const p = progressPathFor(upstreamSid);
    if (!p || !isRegularFile(p)) return {};
    return { progress_file: { path: p, section: PROGRESS_FIRST_SECTION } };
  } catch (e) {
    return {};
  }
}

// buildUpstreamView({ heirSid, upstreamSid }) → view | { availability: "none" }
function buildUpstreamView(input) {
  const opts = input || {};
  const upstreamSid = opts.upstreamSid;
  const heirSid = opts.heirSid || null;
  // A malformed id must not reach any path join (#2302, CWE-22): no store is looked up.
  if (!isValidSid(upstreamSid)) {
    return {
      type: "upstream",
      upstream_session_id: upstreamSid,
      availability: AVAILABILITY.NONE,
      reason: "unknown-session",
      handoff_rendered: null,
      transcript_tail: captureTranscriptTail({ upstreamSid }),
    };
  }
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
      ...progressFileFor(upstreamSid),
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
    ...progressFileFor(upstreamSid),
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
