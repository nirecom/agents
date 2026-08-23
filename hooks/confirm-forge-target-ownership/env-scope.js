// Env and auth scope bookkeeping for the forge-target-ownership guard: what env
// value gh would actually see for a name, and which effects of a segment are
// allowed to outlive it. Entrypoint-private to confirm-forge-target-ownership.js.
"use strict";

const { ghEnvOfSegment } = require("./gh-env-state");

// The env value that gh would actually see for one name, highest rank first.
// Rank 1-2 are written by this very command line; ranks 3-4 are ambient and are
// therefore reconciled against the checkout before they can stand alone.
function lookupEnv(state, seg, name) {
  if (state.envReleased[name]) return { present: false, value: null, readable: true, rank: 0 };
  const local = state.segmentEnv[name];
  if (local) return { present: true, value: local.value, readable: local.readable, rank: 2 };
  const invocation = state.invocationEnv[name];
  if (invocation) return { present: true, value: invocation.value, readable: invocation.readable, rank: 2 };
  const session = state.sessionEnv[name];
  if (session) return { present: true, value: session.value, readable: session.readable !== false, rank: 3 };
  const ambient = process.env[name];
  if (typeof ambient === "string" && ambient !== "") {
    return { present: true, value: ambient, readable: true, rank: 4 };
  }
  return { present: false, value: null, readable: true, rank: 0 };
}

// A segment behind `&&` / `||` may never run, so — exactly as with its auth
// effects — its env effects are SYNTAX, not history. Recording them anyway lets
// `false && export GH_REPO=owner/repo` name a target the shell never set, and
// `true || unset GH_REPO` forget one it never released. Only effects that
// OUTLIVE the segment are gated: the per-segment scope is still filled for a
// branch that may not run, because the guard still reads that segment and has
// to read it the way the shell would if it did run.
function applyEnvEffects(state, seg, guaranteed) {
  const effects = ghEnvOfSegment(seg);
  state.segmentEnv = {};
  for (const set of effects.sets) {
    if (set.persist && !guaranteed) continue;
    const entry = { value: set.value, readable: set.readable, setAt: Date.now() };
    if (set.persist) state.invocationEnv[set.name] = entry;
    else state.segmentEnv[set.name] = entry;
    if (guaranteed) delete state.envReleased[set.name];
  }
  if (!guaranteed) return effects;
  // An unset does not merely forget what this command line set — it has to MASK
  // the session record and the ambient environment too, or the guard keeps
  // resolving against a variable that gh will no longer see.
  for (const name of effects.unsets) {
    delete state.invocationEnv[name];
    delete state.segmentEnv[name];
    state.envReleased[name] = true;
  }
  return effects;
}

// A segment behind `&&` / `||` may never run, so its auth effects are SYNTAX,
// not history. Recording them anyway lets `false && unset GH_TOKEN` clear the
// dirty flag for a token that is still set.
const NO_AUTH_EFFECTS = { segment: [], persistent: [], releases: [] };

function applyAuthEffects(state, causes) {
  for (const cause of causes.persistent) {
    if (state.dirty.indexOf(cause) === -1) state.dirty.push(cause);
  }
  for (const release of causes.releases) {
    const at = state.dirty.indexOf(release);
    if (at !== -1) state.dirty.splice(at, 1);
  }
  if (causes.persistent.length > 0) state.authMutated = true;
}

module.exports = { NO_AUTH_EFFECTS, lookupEnv, applyEnvEffects, applyAuthEffects };
