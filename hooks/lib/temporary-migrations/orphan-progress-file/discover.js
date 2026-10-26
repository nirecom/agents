"use strict";
// Temporary (#2748): deleted with this folder per the deletion-condition in bin/migrate-orphan-progress-files.
// Finds every session chain, from the states: each session-downstream (a state with ancestors) is
// grouped under its first_session_id. Reads only.

const fs = require("fs");
const path = require("path");
const { SESSION_ID_VALID_RE } = require("../../../workflow-state/state-io/core");
const { listStateRoots } = require("../../../workflow-state/state-io/state-root");
const { stateAncestors, resolveFirstSid } = require("../../../workflow-state/state-ancestry");
const { getPlansArtifactPath } = require("../../plans-artifact-registry");
const { getWorkflowPlansDir } = require("../../workflow-plans-dir");
const { staleApprovals, isSelfPinned } = require("./rename");

const STAGES = ["intent", "outline", "detail"];
const ACTIVE_MS = 30 * 60 * 1000;
const PROGRESS_SUFFIX = "-session-progress.md";

const isFile = (p) => {
  try { return fs.lstatSync(p).isFile(); } catch (_) { return false; }
};
const mtimeOf = (p) => {
  try { return fs.statSync(p).mtimeMs; } catch (_) { return 0; }
};

// A missing optional directory holds nothing; any other read failure, and a missing required one,
// throws, so the run reports it instead of "nothing to do".
function readDir(dir, required) {
  try {
    return fs.readdirSync(dir);
  } catch (e) {
    if (!required && e && e.code === "ENOENT") return [];
    throw e;
  }
}

// readStates() -> { states, unreadable }; a state that exists but cannot be read is reported, never
// dropped silently, since its orphan progress file would otherwise look like one past the state's lifetime.
function readStates() {
  const { readState, getStatePath } = require("../../../workflow-state/state-io");
  const states = new Map();
  const unreadable = new Set();
  // The first root is the live one (the pin, else ~/.workflow-state); a missing one means a wrong
  // pin or home, not "no sessions". The legacy root that follows may be absent.
  for (const [i, root] of listStateRoots().entries()) {
    for (const name of readDir(root, i === 0)) {
      if (!name.endsWith(".json")) continue;
      const sid = name.slice(0, -5);
      if (!SESSION_ID_VALID_RE.test(sid) || states.has(sid) || !isFile(getStatePath(sid))) continue;
      let st;
      try { st = readState(sid); } catch (_) { st = null; }
      if (st && typeof st === "object") states.set(sid, st);
      else unreadable.add(sid);
    }
  }
  return { states, unreadable: [...unreadable].sort() };
}

const generationKey = (sid, st) => [stateAncestors(st).length, String(st.created_at || ""), sid];
function byGeneration(a, b) {
  for (let i = 0; i < 3; i++) {
    if (a.key[i] < b.key[i]) return -1;
    if (a.key[i] > b.key[i]) return 1;
  }
  return 0;
}

function chainWork(chain) {
  const sids = new Set([chain.firstSid, ...chain.downstreams.map((d) => d.sid)]);
  const firstState = chain.states.get(chain.firstSid);
  if (firstState && staleApprovals(firstState, sids, chain.firstSid).length) return true;
  return chain.downstreams.some((d) => isFile(d.orphan) || d.plans.length > 0
    || staleApprovals(d.state, sids, chain.firstSid).length > 0 || isSelfPinned(d.sid));
}

function newestMtime(chain) {
  const { getStatePath } = require("../../../workflow-state/state-io");
  const files = [getPlansArtifactPath(chain.firstSid, "progress")];
  for (const sid of [chain.firstSid, ...chain.downstreams.map((d) => d.sid)]) {
    try { files.push(getStatePath(sid)); } catch (_) { /* no state path */ }
    for (const stage of STAGES) files.push(getPlansArtifactPath(sid, stage));
  }
  for (const d of chain.downstreams) files.push(d.orphan);
  return Math.max(0, ...files.map(mtimeOf));
}

// discover({ session }) -> { chains: [{ firstSid, downstreams, states, work, active }], unknown: [sid], unreadable: [sid] }.
function discover(opts) {
  const { states, unreadable } = readStates();
  const groups = new Map();
  for (const [sid, st] of states) {
    if (stateAncestors(st).length === 0) continue;
    const firstSid = resolveFirstSid(sid, st);
    if (firstSid === sid) continue;
    if (!groups.has(firstSid)) groups.set(firstSid, []);
    groups.get(firstSid).push({
      sid, state: st, key: generationKey(sid, st),
      orphan: getPlansArtifactPath(sid, "progress"),
      plans: STAGES.filter((stage) => isFile(getPlansArtifactPath(sid, stage))),
    });
  }
  const only = opts && opts.session ? resolveFirstSid(opts.session) : null;
  const now = Date.now();
  const chains = [];
  for (const [firstSid, downstreams] of groups) {
    if (only !== null && firstSid !== only) continue;
    downstreams.sort(byGeneration);
    const chain = { firstSid, downstreams, states };
    chain.work = chainWork(chain);
    chain.active = chain.work && now - newestMtime(chain) < ACTIVE_MS;
    chains.push(chain);
  }
  const unknown = [];
  if (only === null) {
    for (const name of readDir(getWorkflowPlansDir()).sort()) {
      if (!name.endsWith(PROGRESS_SUFFIX)) continue;
      const sid = name.slice(0, -PROGRESS_SUFFIX.length);
      if (SESSION_ID_VALID_RE.test(sid) && !states.has(sid) && !groups.has(sid) && !unreadable.includes(sid)) unknown.push(sid);
    }
  }
  // A --session run cannot tell whether another unreadable state belongs to its own session chain,
  // so it reports only its own; the full run reports them all.
  const reported = only === null ? unreadable : unreadable.filter((sid) => sid === opts.session);
  return { chains, unknown, unreadable: reported, plansDir: path.resolve(getWorkflowPlansDir()) };
}

module.exports = { STAGES, ACTIVE_MS, discover, isFile };
